package session

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/castdrian/jb-p1lot/internal/protocol"
)

type State string

const (
	Running State = "running"
	Stopped State = "stopped"
	Failed  State = "failed"
)

type Info struct {
	ID        string    `json:"id"`
	Kind      string    `json:"kind"`
	Device    string    `json:"device,omitempty"`
	State     State     `json:"state"`
	StartedAt time.Time `json:"startedAt"`
	UpdatedAt time.Time `json:"updatedAt"`
	Error     string    `json:"error,omitempty"`
}

type Record struct {
	Info
	Output []byte `json:"-"`
}

type Manager struct {
	mu      sync.RWMutex
	items   map[string]*Record
	maxSize int
}

func NewManager(maxSize int) *Manager {
	if maxSize <= 0 {
		maxSize = 1 << 20
	}
	return &Manager{items: make(map[string]*Record), maxSize: maxSize}
}

func (m *Manager) Start(kind, device string, run func(context.Context, io.Writer) error) (Info, error) {
	if run == nil {
		return Info{}, errors.New("session runner is nil")
	}
	id := fmt.Sprintf("s-%x", protocol.NewID())
	now := time.Now().UTC()
	record := &Record{Info: Info{ID: id, Kind: kind, Device: device, State: Running, StartedAt: now, UpdatedAt: now}}
	m.mu.Lock()
	m.items[id] = record
	m.mu.Unlock()
	go func() {
		err := run(context.Background(), &sessionWriter{manager: m, id: id})
		m.mu.Lock()
		defer m.mu.Unlock()
		current, ok := m.items[id]
		if !ok {
			return
		}
		current.UpdatedAt = time.Now().UTC()
		if err != nil && !errors.Is(err, context.Canceled) {
			current.State = Failed
			current.Error = err.Error()
			return
		}
		current.State = Stopped
	}()
	return record.Info, nil
}

func (m *Manager) List() []Info {
	m.mu.RLock()
	defer m.mu.RUnlock()
	items := make([]Info, 0, len(m.items))
	for _, record := range m.items {
		items = append(items, record.Info)
	}
	return items
}

func (m *Manager) Read(id string, maxBytes int) (Info, []byte, error) {
	m.mu.RLock()
	record, ok := m.items[id]
	if !ok {
		m.mu.RUnlock()
		return Info{}, nil, osErrNotFound(id)
	}
	info := record.Info
	data := append([]byte(nil), record.Output...)
	m.mu.RUnlock()
	if maxBytes > 0 && len(data) > maxBytes {
		data = data[len(data)-maxBytes:]
	}
	return info, data, nil
}

func (m *Manager) Write(id string, data []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	record, ok := m.items[id]
	if !ok {
		return osErrNotFound(id)
	}
	if record.State != Running {
		return errors.New("session is not running")
	}
	if len(data) > m.maxSize {
		data = data[len(data)-m.maxSize:]
	}
	record.Output = append(record.Output, data...)
	if len(record.Output) > m.maxSize {
		record.Output = record.Output[len(record.Output)-m.maxSize:]
	}
	record.UpdatedAt = time.Now().UTC()
	return nil
}

func (m *Manager) Stop(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	record, ok := m.items[id]
	if !ok {
		return osErrNotFound(id)
	}
	record.State = Stopped
	record.UpdatedAt = time.Now().UTC()
	return nil
}

type sessionWriter struct {
	manager *Manager
	id      string
}

func (w *sessionWriter) Write(data []byte) (int, error) {
	if err := w.manager.Write(w.id, data); err != nil {
		return 0, err
	}
	return len(data), nil
}

type notFoundError string

func (e notFoundError) Error() string { return "session not found: " + string(e) }

func osErrNotFound(id string) error { return notFoundError(id) }
