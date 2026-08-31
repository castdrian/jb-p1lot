package transport

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/castdrian/jb-p1lot/internal/protocol"
)

type Endpoint struct {
	ID         string
	Name       string
	Address    string
	Transport  string
	ServerName string
}

type Identity struct {
	CAFile                string
	CADERFile             string
	CAKeyFile             string
	CertificateFile       string
	KeyFile               string
	ServerCertificateFile string
	ServerKeyFile         string
	ServerPKCS12File      string
}

func (i Identity) TLSConfig(serverName string) (*tls.Config, error) {
	caBytes, err := os.ReadFile(i.CAFile)
	if err != nil {
		return nil, fmt.Errorf("read CA identity: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caBytes) {
		return nil, errors.New("CA identity contains no certificate")
	}
	cert, err := tls.LoadX509KeyPair(i.CertificateFile, i.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("load client identity: %w", err)
	}
	if serverName == "" {
		serverName = "jb-p1lot"
	}
	return &tls.Config{
		MinVersion:   tls.VersionTLS13,
		RootCAs:      pool,
		Certificates: []tls.Certificate{cert},
		ServerName:   serverName,
		NextProtos:   []string{"jb-p1lot/1"},
	}, nil
}

type Response struct {
	ID      uint64
	Status  string
	Meta    map[string]string
	Payload json.RawMessage
	Binary  []byte
}

type Client struct {
	conn     net.Conn
	codec    *protocol.Codec
	endpoint Endpoint
	nextID   atomic.Uint64
	mu       sync.Mutex
	guard    *protocol.ReplayGuard
	closed   atomic.Bool
}

func Dial(ctx context.Context, endpoint Endpoint, identity Identity) (*Client, error) {
	config, err := identity.TLSConfig(endpoint.ServerName)
	if err != nil {
		return nil, err
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 20 * time.Second}
	conn, err := tls.DialWithDialer(dialer, "tcp", endpoint.Address, config)
	if err != nil {
		return nil, fmt.Errorf("connect to %s: %w", endpoint.Address, err)
	}
	if err := conn.HandshakeContext(ctx); err != nil {
		conn.Close()
		return nil, fmt.Errorf("TLS handshake: %w", err)
	}
	client := NewClient(conn, endpoint)
	return client, nil
}

func NewClient(conn net.Conn, endpoint Endpoint) *Client {
	client := &Client{conn: conn, endpoint: endpoint, codec: protocol.NewCodec(conn, conn), guard: protocol.NewReplayGuard(protocol.MaxBufferedFrames)}
	client.nextID.Store(protocol.NewID())
	return client
}

func (c *Client) Endpoint() Endpoint {
	return c.endpoint
}

func (c *Client) Close() error {
	if c.closed.Swap(true) {
		return nil
	}
	return c.conn.Close()
}

func (c *Client) Call(ctx context.Context, method string, params any) (Response, error) {
	if c.closed.Load() {
		return Response{}, protocol.NewError(protocol.ErrUnavailable, "device connection is closed", nil)
	}
	if method == "" {
		return Response{}, protocol.NewError(protocol.ErrInvalidFrame, "method is required", nil)
	}
	payload, err := json.Marshal(params)
	if err != nil {
		return Response{}, protocol.NewError(protocol.ErrInvalidFrame, "encode method parameters", map[string]any{"error": err.Error()})
	}
	id := c.nextID.Add(1)
	deadline, hasDeadline := ctx.Deadline()
	frame := protocol.Frame{Version: protocol.Version, Kind: protocol.Request, ID: id, Method: method, Payload: payload}
	if hasDeadline {
		frame.Deadline = deadline.UnixNano()
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.guard.Mark(id); err != nil {
		return Response{}, err
	}
	if err := c.codec.Write(frame); err != nil {
		return Response{}, err
	}
	if hasDeadline {
		_ = c.conn.SetReadDeadline(deadline)
	}
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		select {
		case <-ctx.Done():
			_ = c.conn.SetReadDeadline(time.Now())
		case <-stop:
		}
	}()
	for {
		incoming, readErr := c.codec.Read()
		if readErr != nil {
			if contextErr := protocol.ContextError(ctx); contextErr != nil {
				cancel := protocol.Frame{Version: protocol.Version, Kind: protocol.Cancel, ID: protocol.NewID(), Stream: id, Meta: map[string]string{"target": fmt.Sprintf("%d", id)}}
				_ = c.codec.Write(cancel)
				return Response{}, contextErr
			}
			return Response{}, readErr
		}
		if incoming.ID != id {
			continue
		}
		if incoming.Kind == protocol.Error {
			var typed protocol.TypedError
			if err := json.Unmarshal(incoming.Payload, &typed); err == nil && typed.Code != "" {
				return Response{}, &typed
			}
			return Response{}, protocol.NewError(protocol.ErrBackend, incoming.Status, nil)
		}
		return Response{ID: incoming.ID, Status: incoming.Status, Meta: incoming.Meta, Payload: incoming.Payload, Binary: incoming.Binary}, nil
	}
}

type RetryingClient struct {
	Dial        func(context.Context) (*Client, error)
	MaxAttempts int
}

func (r RetryingClient) Call(ctx context.Context, method string, params any) (Response, error) {
	attempts := r.MaxAttempts
	if attempts < 1 {
		attempts = 2
	}
	var last error
	for attempt := 0; attempt < attempts; attempt++ {
		client, err := r.Dial(ctx)
		if err != nil {
			last = err
		} else {
			result, callErr := client.Call(ctx, method, params)
			_ = client.Close()
			if callErr == nil {
				return result, nil
			}
			last = callErr
		}
		if attempt+1 < attempts {
			delay := time.Duration(1<<attempt) * 100 * time.Millisecond
			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return Response{}, protocol.ContextError(ctx)
			case <-timer.C:
			}
		}
	}
	return Response{}, last
}
