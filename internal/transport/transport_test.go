package transport

import (
	"context"
	"net"
	"testing"

	"github.com/castdrian/jb-p1lot/internal/protocol"
)

func TestClientCall(t *testing.T) {
	left, right := net.Pipe()
	serverDone := make(chan error, 1)
	go func() {
		codec := protocol.NewCodec(right, right)
		request, err := codec.Read()
		if err != nil {
			serverDone <- err
			return
		}
		serverDone <- codec.Write(protocol.Frame{Version: protocol.Version, Kind: protocol.Response, ID: request.ID, Status: "ok", Payload: []byte(`{"value":42}`)})
	}()
	client := NewClient(left, Endpoint{ID: "test"})
	response, err := client.Call(context.Background(), "test", map[string]any{"x": 1})
	if err != nil {
		t.Fatal(err)
	}
	if response.Status != "ok" || string(response.Payload) != `{"value":42}` {
		t.Fatalf("unexpected response %#v", response)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}
