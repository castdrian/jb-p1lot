package device

import (
	"fmt"
	"io"
	"strings"
	"testing"
)

func TestTransferFailureExplainsADroppedConnection(t *testing.T) {
	err := transferFailure("/var/tmp/unbound.deb", fmt.Errorf("read frame: %w", io.EOF))
	if !strings.Contains(err.Error(), "/var/tmp/unbound.deb failed: the device bridge closed the connection mid-transfer") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestConfirmWrittenRejectsAShortWrite(t *testing.T) {
	if err := confirmWritten([]byte(`{"bytes": 10, "path": "/x"}`), 10); err != nil {
		t.Fatal(err)
	}
	if err := confirmWritten([]byte(`{"bytes": 4, "path": "/x"}`), 10); err == nil || !strings.Contains(err.Error(), "wrote 4 of 10 bytes") {
		t.Fatalf("expected a short write error, got %v", err)
	}
	if err := confirmWritten([]byte(`{"path": "/x"}`), 10); err != nil {
		t.Fatal(err)
	}
}

func TestLargeTransfersAreSentInChunksToAPartFile(t *testing.T) {
	data := make([]byte, 2*transferChunkBytes+5)
	chunks := transferChunks(data, transferChunkBytes)
	if len(chunks) != 3 || len(chunks[2]) != 5 {
		t.Fatalf("unexpected chunks: %d", len(chunks))
	}
	first := chunkParams("/var/tmp/x.deb", chunks[0], 0, true, false)
	if first["path"] != "/var/tmp/x.deb.jb-p1lot-part" || first["truncate"] != true || first["renameTo"] != nil {
		t.Fatalf("unexpected first chunk: %#v", first)
	}
	last := chunkParams("/var/tmp/x.deb", chunks[2], 2, true, true)
	if last["append"] != true || last["truncate"] != nil || last["renameTo"] != "/var/tmp/x.deb" {
		t.Fatalf("unexpected last chunk: %#v", last)
	}
	small := chunkParams("/var/tmp/x.deb", []byte("hi"), 0, false, true)
	if small["path"] != "/var/tmp/x.deb" || small["append"] != nil {
		t.Fatalf("unexpected single write: %#v", small)
	}
	if err := confirmSize([]byte(`{"appended": true, "size": 7}`), 9); err == nil {
		t.Fatal("expected a size mismatch")
	}
}
