package discovery

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
)

func TestSelectRequiresSelectorWhenAmbiguous(t *testing.T) {
	devices := []Device{{ID: "a", Name: "one"}, {ID: "b", Name: "two"}}
	if _, err := Select(devices, ""); err == nil || !strings.Contains(err.Error(), "candidates") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestSelectAcceptsExplicitAddress(t *testing.T) {
	device, err := Select(nil, "192.168.2.52:5912")
	if err != nil || device.Address != "192.168.2.52" || device.Port != 5912 || device.Source != "explicit" {
		t.Fatalf("device=%#v err=%v", device, err)
	}
}

func TestSelectKeepsPinnedUDIDForSoleBonjourBridge(t *testing.T) {
	pinnedID := "00008130-000A2D412182001C"
	devices := []Device{{
		ID:         "bonjour:Adrians-iPhone.local",
		Name:       "Adrians-iPhone.local",
		Connection: "wifi",
		Address:    "Adrians-iPhone.local.",
		Port:       5912,
		Paired:     true,
		Bridge:     true,
	}}
	device, err := Select(devices, pinnedID)
	if err != nil || device.ID != pinnedID || device.Address != "Adrians-iPhone.local." || device.Port != 5912 {
		t.Fatalf("device=%#v err=%v", device, err)
	}
}

func TestSelectDoesNotGuessPinnedUDIDWithMultipleBridges(t *testing.T) {
	devices := []Device{
		{ID: "bonjour:one", Bridge: true, Address: "one.local"},
		{ID: "bonjour:two", Bridge: true, Address: "two.local"},
	}
	if _, err := Select(devices, "00008130-000A2D412182001C"); err == nil {
		t.Fatal("expected ambiguous pinned device to require a bridge selector")
	}
}

func TestDiscoverMergesUSBDiagnostics(t *testing.T) {
	runner := func(_ context.Context, command string, args ...string) ([]byte, error) {
		switch command {
		case "jb-p1lot-idevice":
			return []byte(`[{"udid":"00008030-001624583AF9402E","connection":"usb","name":"SE","productType":"iPhone12,8","osVersion":"26.0.1"}]`), nil
		default:
			return nil, nil
		}
	}
	devices, err := DiscoverWithRunner(context.Background(), runner)
	if err != nil || len(devices) != 1 || devices[0].ID != "00008030-001624583AF9402E" || devices[0].Name != "SE" || devices[0].Product != "iPhone12,8" || devices[0].OSVersion != "26.0.1" {
		t.Fatalf("devices=%#v err=%v", devices, err)
	}
}

func TestDiscoverResolvesBonjourServiceToPairedDevice(t *testing.T) {
	runner := func(_ context.Context, command string, args ...string) ([]byte, error) {
		switch command {
		case "jb-p1lot-idevice":
			return []byte(`[{"udid":"00008130-000A2D412182001C","connection":"network","name":"Adrian’s iPhone","productType":"iPhone16,2","osVersion":"27.0"},{"udid":"fff48:e1:5c:79:40:83fff","connection":"network","name":"TV"}]`), nil
		case "dns-sd":
			if len(args) > 0 && args[0] == "-B" {
				return []byte("Timestamp     A/R    Flags  IF Domain               Service Type         Instance Name\n17:59:28.057  Add        3  15 local.               _jb-p1lot._tcp.      jb-p1lot\n17:59:28.057  Add        3  13 local.               _jb-p1lot._tcp.      jb-p1lot\n"), errors.New("command timed out")
			}
			return []byte("jb-p1lot._jb-p1lot._tcp.local. can be reached at Adrians-iPhone.local.:5912 (interface 15)\n"), errors.New("command timed out")
		default:
			return nil, nil
		}
	}
	devices, err := DiscoverWithRunner(context.Background(), runner)
	if err != nil || len(devices) != 1 {
		t.Fatalf("devices=%#v err=%v", devices, err)
	}
	device := devices[0]
	if device.ID != "00008130-000A2D412182001C" || device.Name != "Adrian’s iPhone" || device.Address != "Adrians-iPhone.local." || device.Port != 5912 || device.Connection != "wifi" || !device.Bridge {
		t.Fatalf("device=%#v", device)
	}
}

func TestParseBonjourLookupSupportsIPv6Endpoint(t *testing.T) {
	host, port, ok := parseBonjourLookup("service can be reached at [fe80::1%en0]:5912 (interface 15)\n")
	if !ok || host != "fe80::1%en0" || port != 5912 {
		t.Fatalf("host=%q port=%d ok=%v", host, port, ok)
	}
}

func TestDiscoverKeepsUSBMuxTransportWhenBonjourIsAvailable(t *testing.T) {
	runner := func(_ context.Context, command string, args ...string) ([]byte, error) {
		switch command {
		case "jb-p1lot-idevice":
			return []byte(`[{"udid":"00008030-001624583AF9402E","connection":"usb","name":"SE","productType":"iPhone12,8","osVersion":"26.0.1"}]`), nil
		case "dns-sd":
			if len(args) > 0 && args[0] == "-B" {
				return []byte("17:59:28.057  Add        3  15 local. _jb-p1lot._tcp. jb-p1lot\n"), nil
			}
			return []byte("jb-p1lot._jb-p1lot._tcp.local. can be reached at SE.local.:5912 (interface 15)\n"), nil
		default:
			return nil, nil
		}
	}
	devices, err := DiscoverWithRunner(context.Background(), runner)
	if err != nil || len(devices) != 1 {
		t.Fatalf("devices=%#v err=%v", devices, err)
	}
	device := devices[0]
	if device.Connection != "usb" || device.Address != "" || !device.Bridge || device.Source != "usbmux+bonjour" {
		t.Fatalf("device=%#v", device)
	}
}

func TestDiscoverForUsesAPluggedInDeviceWithoutTheSlowSources(t *testing.T) {
	var mutex sync.Mutex
	var commands []string
	runner := func(_ context.Context, command string, args ...string) ([]byte, error) {
		mutex.Lock()
		commands = append(commands, command)
		mutex.Unlock()
		if command == "jb-p1lot-idevice" && len(args) == 2 && args[1] == "--brief" {
			return []byte(`[{"udid":"00008030-001624583AF9402E","connection":"usb"}]`), nil
		}
		return nil, errors.New("not expected")
	}
	devices, err := DiscoverForWithRunner(context.Background(), runner, "00008030-001624583AF9402E")
	if err != nil || len(devices) != 1 || devices[0].Connection != "usb" {
		t.Fatalf("unexpected devices %#v, %v", devices, err)
	}
	if len(commands) != 1 {
		t.Fatalf("expected only the brief listing, ran %v", commands)
	}
}

func TestDiscoverForFallsBackWhenTheDeviceIsNotPluggedIn(t *testing.T) {
	var mutex sync.Mutex
	ran := map[string]bool{}
	runner := func(_ context.Context, command string, args ...string) ([]byte, error) {
		mutex.Lock()
		ran[command] = true
		mutex.Unlock()
		return nil, errors.New("nothing")
	}
	if _, err := DiscoverForWithRunner(context.Background(), runner, "phone.local"); err != nil {
		t.Fatal(err)
	}
	if !ran["jb-p1lot-idevice"] || !ran["dns-sd"] {
		t.Fatalf("expected the full discovery, ran %v", ran)
	}
}

func TestBrowseBatchEndsOnLastRecord(t *testing.T) {
	more := "21:19:07.645  Add        3  17 local.               _jb-p1lot._tcp.      jb-p1lot"
	last := "21:19:07.645  Add        2  13 local.               _jb-p1lot._tcp.      jb-p1lot"
	header := "Timestamp     A/R    Flags  if Domain               Service Type         Instance Name"
	if browseBatchEnded(more) || browseBatchEnded(header) {
		t.Fatal("a record with more coming or the header ended the batch")
	}
	if !browseBatchEnded(last) {
		t.Fatal("the last record of a batch did not end it")
	}
}

func TestLookupSettlesOnAddress(t *testing.T) {
	settled := bonjourSettled([]string{"-L", "jb-p1lot", "_jb-p1lot._tcp", "local."})
	if settled("Lookup jb-p1lot._jb-p1lot._tcp.local.") {
		t.Fatal("the lookup header settled the lookup")
	}
	if !settled("21:19:07.700  jb-p1lot._jb-p1lot._tcp.local. can be reached at iPhone.local.:8642 (interface 13)") {
		t.Fatal("the resolved address did not settle the lookup")
	}
}

func TestBonjourPrefersTheUSBDeviceWhenNamesTie(t *testing.T) {
	merged := map[string]Device{
		"00008130-000A2D412182001C": {ID: "00008130-000A2D412182001C", Name: "Adrian’s iPhone", Connection: "network"},
		"00008030-001624583AF9402E": {ID: "00008030-001624583AF9402E", Name: "Adrian’s iPhone", Connection: "usb"},
	}
	for attempt := 0; attempt < 20; attempt++ {
		if id := matchByName(merged, normalizeDeviceName("Adrians-iPhone.local.")); id != "00008030-001624583AF9402E" {
			t.Fatalf("matched %q", id)
		}
	}
}
