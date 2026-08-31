package discovery

import (
	"context"
	"encoding/json"
	"strings"
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

func TestDiscoverMergesUSBDiagnostics(t *testing.T) {
	runner := func(_ context.Context, command string, _ ...string) ([]byte, error) {
		switch command {
		case "pymobiledevice3":
			value, _ := json.Marshal([]map[string]string{{"ConnectionType": "USB", "DeviceName": "SE", "ProductType": "iPhone12,8", "ProductVersion": "26.0.1", "UniqueDeviceID": "u"}})
			return value, nil
		case "idevice_id":
			return []byte("u\n"), nil
		default:
			return nil, nil
		}
	}
	devices, err := DiscoverWithRunner(context.Background(), runner)
	if err != nil || len(devices) != 1 || devices[0].ID != "u" {
		t.Fatalf("devices=%#v err=%v", devices, err)
	}
}
