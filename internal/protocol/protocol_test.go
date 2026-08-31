package protocol

import (
	"bytes"
	"context"
	"testing"
	"time"
)

func TestCodecRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	codec := NewCodec(bytes.NewReader(nil), &buf)
	want := Frame{Version: Version, Kind: Request, ID: 7, Method: "ping", Payload: []byte(`{"ok":true}`)}
	if err := codec.Write(want); err != nil {
		t.Fatal(err)
	}
	got, err := NewCodec(&buf, nil).Read()
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != want.ID || got.Method != want.Method || string(got.Payload) != string(want.Payload) {
		t.Fatalf("got %#v want %#v", got, want)
	}
}

func TestCodecRejectsCorruption(t *testing.T) {
	var buf bytes.Buffer
	buf.Write([]byte{0, 0, 0, 4})
	buf.WriteString("nope")
	if _, err := NewCodec(&buf, nil).Read(); err == nil {
		t.Fatal("expected decode error")
	}
}

func TestReplayGuard(t *testing.T) {
	g := NewReplayGuard(2)
	if err := g.Mark(1); err != nil {
		t.Fatal(err)
	}
	if err := g.Mark(1); err == nil {
		t.Fatal("expected replay error")
	}
	if err := g.Mark(2); err != nil {
		t.Fatal(err)
	}
	if err := g.Mark(3); err != nil {
		t.Fatal(err)
	}
	if err := g.Mark(1); err != nil {
		t.Fatal("old ids should age out: ", err)
	}
}

func TestDeadlineContext(t *testing.T) {
	ctx, cancel, err := DeadlineContext(context.Background(), time.Now().Add(-time.Second).UnixNano())
	if err == nil || ctx != nil || cancel != nil {
		t.Fatal("expected stale deadline")
	}
}
