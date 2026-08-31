package protocol

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"
)

const (
	Version           uint8 = 1
	MaxFrameBytes           = 16 << 20
	MaxBufferedFrames       = 256
)

type Kind string

const (
	Request  Kind = "request"
	Response Kind = "response"
	Event    Kind = "event"
	Binary   Kind = "binary"
	Cancel   Kind = "cancel"
	Error    Kind = "error"
)

type Frame struct {
	Version  uint8             `json:"version"`
	Kind     Kind              `json:"kind"`
	ID       uint64            `json:"id"`
	Stream   uint64            `json:"stream,omitempty"`
	Deadline int64             `json:"deadline,omitempty"`
	Method   string            `json:"method,omitempty"`
	Status   string            `json:"status,omitempty"`
	Meta     map[string]string `json:"meta,omitempty"`
	Payload  json.RawMessage   `json:"payload,omitempty"`
	Binary   []byte            `json:"binary,omitempty"`
}

type ErrorCode string

const (
	ErrInvalidFrame   ErrorCode = "invalid_frame"
	ErrFrameTooLarge  ErrorCode = "frame_too_large"
	ErrReplay         ErrorCode = "replay"
	ErrDeadline       ErrorCode = "deadline_exceeded"
	ErrCanceled       ErrorCode = "canceled"
	ErrDeviceNotFound ErrorCode = "device_not_found"
	ErrAmbiguous      ErrorCode = "ambiguous_device"
	ErrUnavailable    ErrorCode = "unavailable"
	ErrBackend        ErrorCode = "backend_error"
)

type TypedError struct {
	Code    ErrorCode      `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details,omitempty"`
}

func (e *TypedError) Error() string {
	if e == nil {
		return ""
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

func NewError(code ErrorCode, message string, details map[string]any) *TypedError {
	return &TypedError{Code: code, Message: message, Details: details}
}

func NewID() uint64 {
	var buf [8]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return uint64(time.Now().UnixNano())
	}
	id := binary.BigEndian.Uint64(buf[:])
	if id == 0 {
		return 1
	}
	return id
}

func NewNonce() string {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return fmt.Sprintf("%x", time.Now().UnixNano())
	}
	return hex.EncodeToString(buf[:])
}

func (f Frame) Validate() error {
	if f.Version != Version {
		return NewError(ErrInvalidFrame, "unsupported protocol version", map[string]any{"version": f.Version})
	}
	if f.ID == 0 {
		return NewError(ErrInvalidFrame, "frame id is required", nil)
	}
	switch f.Kind {
	case Request:
		if f.Method == "" {
			return NewError(ErrInvalidFrame, "request method is required", nil)
		}
	case Cancel:
		if f.Stream == 0 && f.ID == 0 {
			return NewError(ErrInvalidFrame, "cancel target is required", nil)
		}
	case Response, Event, Binary, Error:
	default:
		return NewError(ErrInvalidFrame, "unknown frame kind", map[string]any{"kind": f.Kind})
	}
	if f.Deadline != 0 && f.Deadline < time.Now().Add(-24*time.Hour).UnixNano() {
		return NewError(ErrDeadline, "deadline is stale", nil)
	}
	return nil
}

type Codec struct {
	reader *bufio.Reader
	writer io.Writer
	mu     sync.Mutex
	max    int
}

func NewCodec(r io.Reader, w io.Writer) *Codec {
	return &Codec{reader: bufio.NewReaderSize(r, 64*1024), writer: w, max: MaxFrameBytes}
}

func (c *Codec) SetMaxFrameBytes(n int) {
	if n > 0 && n <= MaxFrameBytes {
		c.max = n
	}
}

func (c *Codec) Write(frame Frame) error {
	if c.writer == nil {
		return errors.New("protocol writer is nil")
	}
	if err := frame.Validate(); err != nil {
		return err
	}
	body, err := json.Marshal(frame)
	if err != nil {
		return NewError(ErrInvalidFrame, "encode frame", map[string]any{"error": err.Error()})
	}
	if len(body) > c.max {
		return NewError(ErrFrameTooLarge, "frame exceeds configured limit", map[string]any{"bytes": len(body)})
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(body)))
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, err = c.writer.Write(header[:]); err != nil {
		return err
	}
	_, err = c.writer.Write(body)
	return err
}

func (c *Codec) Read() (Frame, error) {
	var zero Frame
	var header [4]byte
	if _, err := io.ReadFull(c.reader, header[:]); err != nil {
		return zero, err
	}
	n := int(binary.BigEndian.Uint32(header[:]))
	if n <= 0 || n > c.max {
		return zero, NewError(ErrFrameTooLarge, "invalid frame length", map[string]any{"bytes": n})
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(c.reader, body); err != nil {
		return zero, err
	}
	if err := json.Unmarshal(body, &zero); err != nil {
		return zero, NewError(ErrInvalidFrame, "decode frame", map[string]any{"error": err.Error()})
	}
	if err := zero.Validate(); err != nil {
		return zero, err
	}
	return zero, nil
}

type ReplayGuard struct {
	mu    sync.Mutex
	seen  map[uint64]struct{}
	order []uint64
	limit int
}

func NewReplayGuard(limit int) *ReplayGuard {
	if limit < 1 {
		limit = MaxBufferedFrames
	}
	return &ReplayGuard{seen: make(map[uint64]struct{}), limit: limit}
}

func (g *ReplayGuard) Mark(id uint64) error {
	if id == 0 {
		return NewError(ErrInvalidFrame, "zero id cannot be replay guarded", nil)
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if _, ok := g.seen[id]; ok {
		return NewError(ErrReplay, "request id was already processed", map[string]any{"id": id})
	}
	g.seen[id] = struct{}{}
	g.order = append(g.order, id)
	if len(g.order) > g.limit {
		oldest := g.order[0]
		g.order = g.order[1:]
		delete(g.seen, oldest)
	}
	return nil
}

func DeadlineContext(parent context.Context, deadline int64) (context.Context, context.CancelFunc, error) {
	if deadline == 0 {
		ctx, cancel := context.WithCancel(parent)
		return ctx, cancel, nil
	}
	when := time.Unix(0, deadline)
	if !when.After(time.Now()) {
		return nil, nil, NewError(ErrDeadline, "request deadline exceeded", nil)
	}
	ctx, cancel := context.WithDeadline(parent, when)
	return ctx, cancel, nil
}

func ContextError(ctx context.Context) error {
	if ctx == nil {
		return nil
	}
	switch ctx.Err() {
	case context.DeadlineExceeded:
		return NewError(ErrDeadline, "request deadline exceeded", nil)
	case context.Canceled:
		return NewError(ErrCanceled, "request canceled", nil)
	default:
		return nil
	}
}
