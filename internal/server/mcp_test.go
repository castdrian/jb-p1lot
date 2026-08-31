package server

import (
	"context"
	"testing"

	"github.com/castdrian/jb-p1lot/internal/registry"
)

type fakeExecutor struct{}

func (fakeExecutor) Execute(_ context.Context, request registry.Request) (registry.Result, error) {
	return registry.Result{Data: map[string]any{"command": request.Command}}, nil
}

func TestServerRegistersAllCommands(t *testing.T) {
	value := registry.NewDeviceRegistry(fakeExecutor{})
	server := New(value)
	if server == nil || len(value.Names()) < 25 {
		t.Fatalf("registry unexpectedly small: %d", len(value.Names()))
	}
}
