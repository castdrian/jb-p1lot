package discovery

import (
	"bufio"
	"context"
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

type deviceInfo struct {
	Name      string
	Product   string
	OSVersion string
}

func parseDeviceInfo(value string) deviceInfo {
	var info deviceInfo
	for _, line := range strings.Split(value, "\n") {
		key, field, ok := strings.Cut(line, ": ")
		if !ok {
			continue
		}
		field = strings.TrimSpace(field)
		switch key {
		case "DeviceName":
			info.Name = field
		case "ProductType":
			info.Product = field
		case "ProductVersion":
			info.OSVersion = field
		}
	}
	return info
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
	var usbOutput, networkOutput, browseOutput []byte
	var usbErr, networkErr error
	var wait sync.WaitGroup
	wait.Add(3)
	go func() {
		defer wait.Done()
		usbOutput, usbErr = run(ctx, "idevice_id", "-l")
	}()
	go func() {
		defer wait.Done()
		networkOutput, networkErr = run(ctx, "idevice_id", "-n")
	}()
	go func() {
		defer wait.Done()
		browseOutput, _ = run(ctx, "dns-sd", "-B", "_jb-p1lot._tcp", "local.")
	}()
	wait.Wait()

	merged := make(map[string]Device)
	addListed(merged, usbOutput, usbErr, "usb")
	addListed(merged, networkOutput, networkErr, "network")
	var unnamed []string
	for id, device := range merged {
		if device.Name == "" {
			unnamed = append(unnamed, id)
		}
	}
	var detailWait sync.WaitGroup
	var detailMutex sync.Mutex
	for _, id := range unnamed {
		detailWait.Add(1)
		args := deviceInfoArgs(merged[id])
		go func(id string, args []string) {
			defer detailWait.Done()
			output, err := run(ctx, "ideviceinfo", args...)
			if err != nil {
				return
			}
			info := parseDeviceInfo(string(output))
			detailMutex.Lock()
			defer detailMutex.Unlock()
			device := merged[id]
			device.Name, device.Product, device.OSVersion = info.Name, info.Product, info.OSVersion
			merged[id] = device
		}(id, args)
	}
	var lookups [][]byte
	if len(browseOutput) > 0 {
		services := parseBonjourBrowse(string(browseOutput))
		lookups = make([][]byte, len(services))
		var lookupWait sync.WaitGroup
		for index, service := range services {
			lookupWait.Add(1)
			go func(index int, service bonjourService) {
				defer lookupWait.Done()
				lookups[index], _ = run(ctx, "dns-sd", "-L", service.instance, service.typeName, service.domain)
			}(index, service)
		}
		lookupWait.Wait()
	}
	detailWait.Wait()
	for _, lookupOutput := range lookups {
		host, port, ok := parseBonjourLookup(string(lookupOutput))
		if ok {
			mergeBonjourEndpoint(merged, host, port)
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

func addListed(merged map[string]Device, output []byte, err error, connection string) {
	if err != nil {
		return
	}
	for _, id := range strings.Fields(string(output)) {
		if _, ok := merged[id]; ok || !looksLikeDeviceID(id) {
			continue
		}
		merged[id] = Device{ID: id, Connection: connection, Paired: true, Source: "libimobiledevice"}
	}
}

func deviceInfoArgs(device Device) []string {
	if device.Connection == "network" {
		return []string{"-n", "-u", device.ID}
	}
	return []string{"-u", device.ID}
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

const (
	bonjourTimeout = 2 * time.Second
	bonjourQuiet   = 400 * time.Millisecond
)

func defaultRunner(ctx context.Context, command string, args ...string) ([]byte, error) {
	if command == "dns-sd" {
		return runUntilSettled(ctx, bonjourSettled(args), command, args...)
	}
	callCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return exec.CommandContext(callCtx, command, args...).CombinedOutput()
}

func bonjourSettled(args []string) func(string) bool {
	if len(args) > 0 && args[0] == "-L" {
		return func(line string) bool { return strings.Contains(line, "can be reached at") }
	}
	return browseBatchEnded
}

func browseBatchEnded(line string) bool {
	fields := strings.Fields(line)
	if len(fields) < 3 || (fields[1] != "Add" && fields[1] != "Rmv") {
		return false
	}
	flags, err := strconv.Atoi(fields[2])
	return err == nil && flags&1 == 0
}

func runUntilSettled(ctx context.Context, settled func(string) bool, command string, args ...string) ([]byte, error) {
	callCtx, cancel := context.WithTimeout(ctx, bonjourTimeout)
	defer cancel()
	cmd := exec.CommandContext(callCtx, command, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	lines := make(chan string)
	go func() {
		defer close(lines)
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			lines <- scanner.Text()
		}
	}()
	var output strings.Builder
	quiet := time.NewTimer(bonjourQuiet)
	defer quiet.Stop()
	defer func() {
		cancel()
		for range lines {
		}
		_ = cmd.Wait()
	}()
	for {
		select {
		case line, ok := <-lines:
			if !ok {
				return []byte(output.String()), nil
			}
			output.WriteString(line)
			output.WriteByte('\n')
			if settled(line) {
				return []byte(output.String()), nil
			}
			quiet.Reset(bonjourQuiet)
		case <-quiet.C:
			return []byte(output.String()), nil
		case <-callCtx.Done():
			return []byte(output.String()), nil
		}
	}
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
	matchingID := matchByName(merged, normalizeDeviceName(host))
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

func matchByName(merged map[string]Device, hostName string) string {
	if hostName == "" {
		return ""
	}
	ids := make([]string, 0, len(merged))
	for id, device := range merged {
		if hostName == normalizeDeviceName(device.Name) {
			ids = append(ids, id)
		}
	}
	sort.Slice(ids, func(i, j int) bool {
		left, right := merged[ids[i]].Connection == "usb", merged[ids[j]].Connection == "usb"
		if left != right {
			return left
		}
		return ids[i] < ids[j]
	})
	if len(ids) == 0 {
		return ""
	}
	return ids[0]
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
