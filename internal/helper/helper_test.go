package helper

import "testing"

func TestParseForwardReadsTheHelperCommandLine(t *testing.T) {
	forward, ok := ParseForward("  4242 /Users/me/.cargo/bin/jb-p1lot-idevice forward 50915 5912 -u 00008030-001624583AF9402E", "00008030-001624583AF9402E")
	if !ok || forward != (Forward{PID: 4242, LocalPort: 50915, RemotePort: 5912}) {
		t.Fatalf("forward=%+v ok=%v", forward, ok)
	}
}

func TestParseForwardIgnoresOtherDevicesAndProcesses(t *testing.T) {
	for _, line := range []string{
		"4242 /Users/me/.cargo/bin/jb-p1lot-idevice forward 50915 5912 -u 00008130-000A2D412182001C",
		"4242 /opt/homebrew/bin/iproxy 50915 5912 -u 00008030-001624583AF9402E",
		"4242 /Users/me/.cargo/bin/jb-p1lot-idevice list",
	} {
		if _, ok := ParseForward(line, "00008030-001624583AF9402E"); ok {
			t.Fatalf("parsed %q", line)
		}
	}
}
