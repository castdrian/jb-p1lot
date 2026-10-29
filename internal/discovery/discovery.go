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
	"sync"
	"time"
	"unicode"
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

type bonjourService struct {
	instance string
	typeName string
	domain   string
}

type Runner func(context.Context, string, ...string) ([]byte, error)

func Discover(ctx context.Context) ([]Device, error) {
	return DiscoverWithRunner(ctx, defaultRunner)
}

func DiscoverWithRunner(ctx context.Context, run Runner) ([]Device, error) {
	if run == nil {
		run = defaultRunner
	}
	var usbmuxOutput, ideviceOutput, browseOutput []byte
	var usbmuxErr, ideviceErr error
	var wait sync.WaitGroup
	wait.Add(3)
	go func() {
		defer wait.Done()
		usbmuxOutput, usbmuxErr = run(ctx, "pymobiledevice3", "usbmux", "list")
	}()
	go func() {
		defer wait.Done()
		ideviceOutput, ideviceErr = run(ctx, "idevice_id", "-l")
	}()
	go func() {
		defer wait.Done()
		browseOutput, _ = run(ctx, "dns-sd", "-B", "_jb-p1lot._tcp", "local.")
	}()
	wait.Wait()

	merged := make(map[string]Device)
	if usbmuxErr == nil {
		var records []usbmuxRecord
		if json.Unmarshal(usbmuxOutput, &records) == nil {
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
	if ideviceErr == nil {
		for _, line := range strings.Fields(string(ideviceOutput)) {
			if _, ok := merged[line]; !ok {
				merged[line] = Device{ID: line, Connection: "usb", Paired: true, Source: "libimobiledevice"}
			}
		}
	}
	if len(browseOutput) > 0 {
		services := parseBonjourBrowse(string(browseOutput))
		lookups := make([][]byte, len(services))
		var lookupWait sync.WaitGroup
		for index, service := range services {
			lookupWait.Add(1)
			go func(index int, service bonjourService) {
				defer lookupWait.Done()
				lookups[index], _ = run(ctx, "dns-sd", "-L", service.instance, service.typeName, service.domain)
			}(index, service)
		}
		lookupWait.Wait()
		for _, lookupOutput := range lookups {
			host, port, ok := parseBonjourLookup(string(lookupOutput))
			if ok {
				mergeBonjourEndpoint(merged, host, port)
			}
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

// DiscoverFor finds the device a command names: one plugged in over USB is used as soon as
// libimobiledevice lists it, skipping the slower usbmux and Bonjour sources.
func DiscoverFor(ctx context.Context, selector string) ([]Device, error) {
	return DiscoverForWithRunner(ctx, defaultRunner, selector)
}

func DiscoverForWithRunner(ctx context.Context, run Runner, selector string) ([]Device, error) {
	if run == nil {
		run = defaultRunner
	}
	if selector != "" {
		if output, err := run(ctx, "idevice_id", "-l"); err == nil {
			for _, line := range strings.Fields(string(output)) {
				if line == selector {
					return []Device{{ID: line, Connection: "usb", Paired: true, Source: "libimobiledevice"}}, nil
				}
			}
		}
	}
	return DiscoverWithRunner(ctx, run)
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
		if len(devices) == 1 && devices[0].Bridge && looksLikeDeviceID(selector) {
			device := devices[0]
			device.ID = selector
			device.Paired = true
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

func looksLikeDeviceID(value string) bool {
	compact := strings.ReplaceAll(strings.TrimSpace(value), "-", "")
	if len(compact) < 20 || len(compact) > 64 {
		return false
	}
	for _, character := range compact {
		if !((character >= '0' && character <= '9') ||
			(character >= 'a' && character <= 'f') ||
			(character >= 'A' && character <= 'F')) {
			return false
		}
	}
	return true
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
		timeout = 2 * time.Second
	}
	callCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return exec.CommandContext(callCtx, command, args...).CombinedOutput()
}

func parseBonjourBrowse(value string) []bonjourService {
	services := make([]bonjourService, 0)
	seen := make(map[string]struct{})
	scanner := bufio.NewScanner(strings.NewReader(value))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		serviceTypeIndex := -1
		for index, field := range fields {
			if strings.TrimSuffix(field, ".") == "_jb-p1lot._tcp" {
				serviceTypeIndex = index
				break
			}
		}
		if serviceTypeIndex < 1 || serviceTypeIndex+1 >= len(fields) {
			continue
		}
		if serviceTypeIndex > 1 && (fields[1] == "Rmv" || fields[1] == "Remove") {
			continue
		}
		instance := strings.TrimSuffix(fields[serviceTypeIndex+1], ".")
		domain := strings.TrimSuffix(fields[serviceTypeIndex-1], ".")
		if instance == "" {
			continue
		}
		if domain == "" {
			domain = "local"
		}
		service := bonjourService{instance: instance, typeName: "_jb-p1lot._tcp", domain: domain + "."}
		key := service.instance + "\x00" + service.typeName + "\x00" + service.domain
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		services = append(services, service)
	}
	return services
}

func parseBonjourLookup(value string) (string, int, bool) {
	const marker = " can be reached at "
	for _, line := range strings.Split(value, "\n") {
		markerIndex := strings.Index(line, marker)
		if markerIndex < 0 {
			continue
		}
		address := strings.TrimSpace(line[markerIndex+len(marker):])
		if end := strings.Index(address, " ("); end >= 0 {
			address = address[:end]
		}
		host, portText, ok := splitBonjourAddress(address)
		if !ok {
			continue
		}
		port, err := strconv.Atoi(portText)
		if err != nil || port < 1 || port > 65535 {
			continue
		}
		return host, port, true
	}
	return "", 0, false
}

func splitBonjourAddress(value string) (string, string, bool) {
	if host, port, err := net.SplitHostPort(value); err == nil {
		return host, port, host != ""
	}
	separator := strings.LastIndex(value, ":")
	if separator <= 0 || separator+1 >= len(value) {
		return "", "", false
	}
	host := strings.Trim(value[:separator], "[]")
	port := value[separator+1:]
	return host, port, host != ""
}

func mergeBonjourEndpoint(merged map[string]Device, host string, port int) {
	matchingID := ""
	hostName := normalizeDeviceName(host)
	for id, device := range merged {
		if hostName != "" && hostName == normalizeDeviceName(device.Name) {
			matchingID = id
			break
		}
	}
	if matchingID == "" && len(merged) == 1 {
		for id := range merged {
			matchingID = id
		}
	}
	if matchingID == "" {
		matchingID = "bonjour:" + strings.TrimSuffix(host, ".")
	}
	current := merged[matchingID]
	if current.ID == "" {
		current = Device{ID: matchingID, Name: strings.TrimSuffix(host, "."), Connection: "wifi", Paired: true, Source: "bonjour"}
	}
	if current.Connection != "usb" {
		current.Address = host
		current.Port = port
		current.Connection = "wifi"
		current.Source = "bonjour"
	} else {
		current.Source = "usbmux+bonjour"
	}
	current.Bridge = true
	current.Paired = true
	merged[matchingID] = current
}

func normalizeDeviceName(value string) string {
	value = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(value)), ".")
	value = strings.TrimSuffix(value, ".local")
	var normalized strings.Builder
	for _, character := range value {
		if unicode.IsLetter(character) || unicode.IsDigit(character) {
			normalized.WriteRune(character)
		}
	}
	return normalized.String()
}
