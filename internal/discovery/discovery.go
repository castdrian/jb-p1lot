package discovery

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"
)

type Device struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Product    string `json:"productType"`
	OSVersion  string `json:"osVersion"`
	Connection string `json:"connection"`
	Address    string `json:"address,omitempty"`
	Port       int    `json:"port,omitempty"`
	Paired     bool   `json:"paired"`
	Jailbroken bool   `json:"jailbroken"`
	Bridge     bool   `json:"bridge"`
	Source     string `json:"source"`
}

type usbmuxRecord struct {
	ConnectionType string `json:"ConnectionType"`
	DeviceName     string `json:"DeviceName"`
	ProductType    string `json:"ProductType"`
	ProductVersion string `json:"ProductVersion"`
	UniqueDeviceID string `json:"UniqueDeviceID"`
	Identifier     string `json:"Identifier"`
}

type Runner func(context.Context, string, ...string) ([]byte, error)

func Discover(ctx context.Context) ([]Device, error) {
	return DiscoverWithRunner(ctx, defaultRunner)
}

func DiscoverWithRunner(ctx context.Context, run Runner) ([]Device, error) {
	if run == nil {
		run = defaultRunner
	}
	merged := make(map[string]Device)
	if output, err := run(ctx, "pymobiledevice3", "usbmux", "list"); err == nil {
		var records []usbmuxRecord
		if json.Unmarshal(output, &records) == nil {
			for _, record := range records {
				id := record.UniqueDeviceID
				if id == "" {
					id = record.Identifier
				}
				if id == "" {
					continue
				}
				merged[id] = Device{ID: id, Name: record.DeviceName, Product: record.ProductType, OSVersion: record.ProductVersion, Connection: strings.ToLower(record.ConnectionType), Paired: true, Source: "usbmux"}
			}
		}
	}
	if output, err := run(ctx, "idevice_id", "-l"); err == nil {
		for _, line := range strings.Fields(string(output)) {
			if _, ok := merged[line]; !ok {
				merged[line] = Device{ID: line, Connection: "usb", Paired: true, Source: "libimobiledevice"}
			}
		}
	}
	if output, err := run(ctx, "dns-sd", "-B", "_jb-p1lot._tcp", "local."); err == nil {
		for _, record := range parseBonjour(string(output)) {
			current := merged[record.ID]
			if current.ID == "" {
				current = record
			}
			current.Address = record.Address
			current.Port = record.Port
			current.Connection = "wifi"
			current.Bridge = true
			current.Paired = true
			current.Source = "bonjour"
			merged[current.ID] = current
		}
	}
	devices := make([]Device, 0, len(merged))
	for _, device := range merged {
		if device.Address == "" && device.Connection == "wifi" {
			device.Address = ""
		}
		devices = append(devices, device)
	}
	sort.Slice(devices, func(i, j int) bool { return devices[i].ID < devices[j].ID })
	return devices, nil
}

func Select(devices []Device, selector string) (Device, error) {
	if selector != "" {
		for _, device := range devices {
			if device.ID == selector || device.Name == selector || device.Address == selector {
				return device, nil
			}
		}
		if device, ok := directDevice(selector); ok {
			return device, nil
		}
		return Device{}, fmt.Errorf("device %q not found", selector)
	}
	if len(devices) == 1 {
		return devices[0], nil
	}
	if len(devices) == 0 {
		return Device{}, errors.New("no paired jailbreak device discovered")
	}
	candidates := make([]string, 0, len(devices))
	for _, device := range devices {
		candidates = append(candidates, fmt.Sprintf("%s (%s, %s)", device.ID, device.Name, device.Connection))
	}
	return Device{}, fmt.Errorf("device selector is required; candidates: %s", strings.Join(candidates, ", "))
}

func directDevice(selector string) (Device, bool) {
	host := selector
	port := 5912
	if strings.HasPrefix(selector, "[") {
		parsedHost, parsedPort, err := net.SplitHostPort(selector)
		if err != nil {
			return Device{}, false
		}
		host = parsedHost
		port, err = strconv.Atoi(parsedPort)
		if err != nil || port < 1 || port > 65535 {
			return Device{}, false
		}
	} else if strings.Count(selector, ":") == 1 {
		parsedHost, parsedPort, err := net.SplitHostPort(selector)
		if err != nil {
			return Device{}, false
		}
		host = parsedHost
		port, err = strconv.Atoi(parsedPort)
		if err != nil || port < 1 || port > 65535 {
			return Device{}, false
		}
	}
	if net.ParseIP(host) == nil && !strings.Contains(host, ".") {
		return Device{}, false
	}
	return Device{ID: selector, Name: selector, Connection: "wifi", Address: host, Port: port, Paired: true, Bridge: true, Source: "explicit"}, true
}

func ResolveAddress(device Device) string {
	if device.Address != "" {
		if device.Port == 0 {
			return net.JoinHostPort(device.Address, "5912")
		}
		return net.JoinHostPort(device.Address, fmt.Sprintf("%d", device.Port))
	}
	return ""
}

func parseBonjour(value string) []Device {
	var records []Device
	scanner := bufio.NewScanner(strings.NewReader(value))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 6 || !strings.Contains(scanner.Text(), "_jb-p1lot._tcp") {
			continue
		}
		name := fields[len(fields)-1]
		id := strings.TrimSuffix(name, ".")
		records = append(records, Device{ID: id, Name: id, Address: id})
	}
	return records
}

func defaultRunner(ctx context.Context, command string, args ...string) ([]byte, error) {
	timeout := 5 * time.Second
	if command == "dns-sd" {
		timeout = 500 * time.Millisecond
	}
	callCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return exec.CommandContext(callCtx, command, args...).CombinedOutput()
}
