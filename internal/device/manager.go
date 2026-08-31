package device

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/castdrian/jb-p1lot/internal/artifacts"
	"github.com/castdrian/jb-p1lot/internal/discovery"
	"github.com/castdrian/jb-p1lot/internal/protocol"
	"github.com/castdrian/jb-p1lot/internal/registry"
	"github.com/castdrian/jb-p1lot/internal/session"
	"github.com/castdrian/jb-p1lot/internal/transport"
)

type Config struct {
	Identity      transport.Identity
	ArtifactRoot  string
	ProjectRoot   string
	MaxArtifactMB int64
}

type Manager struct {
	mu        sync.Mutex
	config    Config
	artifacts *artifacts.Store
	sessions  *session.Manager
	clients   map[string]*transport.Client
	forwards  map[string]*usbMuxForward
	dial      func(context.Context, transport.Endpoint, transport.Identity) (*transport.Client, error)
}

func NewManager(config Config) (*Manager, error) {
	store, err := artifacts.New(config.ArtifactRoot, config.MaxArtifactMB*1<<20)
	if err != nil {
		return nil, err
	}
	if config.ProjectRoot == "" {
		config.ProjectRoot, _ = os.Getwd()
	}
	return &Manager{config: config, artifacts: store, sessions: session.NewManager(1 << 20), clients: make(map[string]*transport.Client), forwards: make(map[string]*usbMuxForward), dial: transport.Dial}, nil
}

func (m *Manager) Execute(ctx context.Context, request registry.Request) (registry.Result, error) {
	switch request.Command {
	case "device_list":
		return m.deviceList(ctx)
	case "device_status":
		return m.deviceStatus(ctx, request.Device)
	case "tweak_build":
		return m.tweakBuild(ctx, request)
	}
	if request.Command == "device_action" && normalizeAction(request.Params) == "reboot" {
		request.Params["action"] = "userspace_reboot"
	}
	if request.Command == "device_action" {
		if action := normalizeAction(request.Params); action == "full_reboot" || action == "hardware_reboot" || action == "reboot_full" {
			return registry.Result{}, protocol.NewError(protocol.ErrInvalidFrame, "hardware reboot is not exposed; use userspace_reboot", map[string]any{"action": action})
		}
	}
	devices, err := discovery.Discover(ctx)
	if err != nil {
		return registry.Result{}, fmt.Errorf("discover devices: %w", err)
	}
	selected, err := discovery.Select(devices, request.Device)
	if err != nil {
		return registry.Result{}, protocol.NewError(protocol.ErrAmbiguous, err.Error(), map[string]any{"candidates": devices})
	}
	if request.Command == "tweak_cycle" {
		return m.tweakCycle(ctx, selected, request)
	}
	if strings.HasPrefix(request.Command, "session_") {
		return m.sessionCommand(request)
	}
	client, err := m.client(ctx, selected)
	if err != nil {
		return registry.Result{}, err
	}
	params := cloneParams(request.Params)
	params["device"] = selected.ID
	if request.Command == "tweak_deploy" && paramString(params, "path", "") == "" {
		if packagePath := paramString(params, "package", ""); packagePath != "" {
			params["path"] = packagePath
		}
	}
	if request.Command == "device_action" && isDisplayAction(normalizeAction(params)) {
		params["action"] = normalizeAction(params)
		response, err := client.Call(ctx, "ui_action", params)
		if err != nil {
			m.invalidateClient(client)
			return registry.Result{}, err
		}
		return m.responseResult("device_action", response)
	}
	if request.Command == "tweak_deploy" {
		stagedPath, err := m.stageTweakPackage(ctx, client, params)
		if err != nil {
			return registry.Result{}, err
		}
		response, callErr := client.Call(ctx, request.Command, params)
		m.cleanupTweakPackage(client, stagedPath)
		if callErr != nil {
			m.invalidateClient(client)
			return registry.Result{}, callErr
		}
		return m.responseResult(request.Command, response)
	}
	if request.Command == "screen_capture" {
		return m.screenCapture(ctx, client, params)
	}
	if request.Command == "file_transfer" {
		return m.fileTransfer(ctx, client, params)
	}
	if request.Command == "screen_stream" || request.Command == "metrics_stream" || request.Command == "debug_session" || request.Command == "frida_session" {
		return m.streamCommand(ctx, client, request.Command, params)
	}
	response, err := client.Call(ctx, request.Command, params)
	if err != nil {
		m.invalidateClient(client)
		return registry.Result{}, err
	}
	return m.responseResult(request.Command, response)
}

func (m *Manager) deviceList(ctx context.Context) (registry.Result, error) {
	devices, err := discovery.Discover(ctx)
	if err != nil {
		return registry.Result{}, err
	}
	return registry.Result{Data: map[string]any{"devices": devices, "count": len(devices), "generatedAt": time.Now().UTC()}}, nil
}

func (m *Manager) deviceStatus(ctx context.Context, selector string) (registry.Result, error) {
	devices, err := discovery.Discover(ctx)
	if err != nil {
		return registry.Result{}, err
	}
	selected, err := discovery.Select(devices, selector)
	if err != nil {
		return registry.Result{}, protocol.NewError(protocol.ErrAmbiguous, err.Error(), map[string]any{"candidates": devices})
	}
	status := map[string]any{"device": selected, "hostTime": time.Now().UTC()}
	client, clientErr := m.client(ctx, selected)
	if clientErr == nil {
		response, callErr := client.Call(ctx, "device.status", map[string]any{})
		if callErr != nil {
			m.invalidateClient(client)
			client, clientErr = m.client(ctx, selected)
			if clientErr == nil {
				response, callErr = client.Call(ctx, "device.status", map[string]any{})
			}
		}
		if callErr == nil {
			var bridge map[string]any
			if json.Unmarshal(response.Payload, &bridge) == nil {
				status["bridge"] = bridge
				if enabled, ok := bridge["bridge"].(bool); ok && enabled {
					selected.Bridge = true
					if uid, ok := bridge["uid"].(float64); ok && uid == 0 {
						selected.Jailbroken = true
					}
					status["device"] = selected
				}
			}
		}
		if callErr != nil {
			status["bridgeError"] = callErr.Error()
		}
	} else {
		status["bridgeError"] = clientErr.Error()
	}
	return registry.Result{Data: status}, nil
}

func (m *Manager) client(ctx context.Context, selected discovery.Device) (*transport.Client, error) {
	m.mu.Lock()
	if client := m.clients[selected.ID]; client != nil {
		m.mu.Unlock()
		return client, nil
	}
	m.mu.Unlock()
	address := discovery.ResolveAddress(selected)
	if address == "" && selected.Connection == "usb" {
		forward, err := m.ensureForward(selected)
		if err != nil {
			return nil, protocol.NewError(protocol.ErrUnavailable, "USBMux bridge forwarding unavailable", map[string]any{"error": err.Error(), "device": selected.ID})
		}
		address = forward.Address()
	}
	if address == "" {
		return nil, protocol.NewError(protocol.ErrUnavailable, "device has no discovered bridge address", map[string]any{"device": selected.ID})
	}
	endpoint := transport.Endpoint{ID: selected.ID, Name: selected.Name, Address: address, Transport: selected.Connection, ServerName: "jb-p1lot"}
	client, err := m.dial(ctx, endpoint, m.config.Identity)
	if err != nil {
		return nil, protocol.NewError(protocol.ErrUnavailable, "unable to connect to device bridge", map[string]any{"device": selected.ID, "address": address, "error": err.Error()})
	}
	m.mu.Lock()
	m.clients[selected.ID] = client
	m.mu.Unlock()
	return client, nil
}

func (m *Manager) invalidateClient(client *transport.Client) {
	if client == nil {
		return
	}
	deviceID := client.Endpoint().ID
	m.mu.Lock()
	if current := m.clients[deviceID]; current == client {
		delete(m.clients, deviceID)
	}
	m.mu.Unlock()
	_ = client.Close()
}

func (m *Manager) screenCapture(ctx context.Context, client *transport.Client, params map[string]any) (registry.Result, error) {
	response, err := client.Call(ctx, "screen.capture", params)
	if err != nil {
		m.invalidateClient(client)
		return registry.Result{}, err
	}
	data := response.Binary
	if len(data) == 0 {
		var payload struct {
			Data string `json:"data"`
			MIME string `json:"mimeType"`
		}
		if json.Unmarshal(response.Payload, &payload) == nil && payload.Data != "" {
			data, _ = base64.StdEncoding.DecodeString(payload.Data)
		}
	}
	if len(data) == 0 {
		return m.responseResult("screen_capture", response)
	}
	path, err := m.artifacts.WriteBytes("screen.png", data)
	if err != nil {
		return registry.Result{}, err
	}
	return registry.Result{Image: data, MIMEType: "image/png", ArtifactPath: path, Meta: map[string]any{"protectedLayers": false}}, nil
}

func (m *Manager) fileTransfer(ctx context.Context, client *transport.Client, params map[string]any) (registry.Result, error) {
	source := paramString(params, "source", "")
	destination := paramString(params, "destination", "")
	if source == "" || destination == "" {
		return registry.Result{}, protocol.NewError(protocol.ErrInvalidFrame, "source and destination are required", nil)
	}
	direction := strings.ToLower(paramString(params, "direction", ""))
	if direction == "" {
		if _, err := os.Stat(source); err == nil {
			direction = "host_to_device"
		} else {
			direction = "device_to_host"
		}
	}
	switch direction {
	case "host_to_device", "upload", "to_device":
		data, err := os.ReadFile(source)
		if err != nil {
			return registry.Result{}, fmt.Errorf("read transfer source: %w", err)
		}
		if len(data) > protocol.MaxFrameBytes {
			return registry.Result{}, protocol.NewError(protocol.ErrFrameTooLarge, "transfer exceeds protocol limit", map[string]any{"bytes": len(data), "limit": protocol.MaxFrameBytes})
		}
		writeParams := map[string]any{"path": destination, "data": base64.StdEncoding.EncodeToString(data), "encoding": "base64"}
		if mode, ok := params["mode"]; ok && mode != nil {
			writeParams["mode"] = mode
		}
		response, err := client.Call(ctx, "file_write", writeParams)
		if err != nil {
			m.invalidateClient(client)
			return registry.Result{}, err
		}
		return m.responseResult("file_transfer", response)
	case "device_to_host", "download", "to_host":
		maxBytes := paramInt(params, "maxBytes", protocol.MaxFrameBytes)
		if maxBytes <= 0 || maxBytes > protocol.MaxFrameBytes {
			maxBytes = protocol.MaxFrameBytes
		}
		response, err := client.Call(ctx, "file_read", map[string]any{"path": source, "maxBytes": maxBytes})
		if err != nil {
			m.invalidateClient(client)
			return registry.Result{}, err
		}
		var payload struct {
			Data string `json:"data"`
		}
		if err := json.Unmarshal(response.Payload, &payload); err != nil || payload.Data == "" {
			return registry.Result{}, protocol.NewError(protocol.ErrBackend, "device file response was invalid", nil)
		}
		data, err := base64.StdEncoding.DecodeString(payload.Data)
		if err != nil {
			return registry.Result{}, protocol.NewError(protocol.ErrBackend, "device file data was not base64", nil)
		}
		if err := os.WriteFile(destination, data, 0o600); err != nil {
			return registry.Result{}, fmt.Errorf("write transfer destination: %w", err)
		}
		return registry.Result{Data: map[string]any{"source": source, "destination": destination, "bytes": len(data), "direction": "device_to_host"}, Meta: map[string]any{"status": "ok"}}, nil
	default:
		return registry.Result{}, protocol.NewError(protocol.ErrInvalidFrame, "direction must be host_to_device or device_to_host", map[string]any{"direction": direction})
	}
}

func (m *Manager) streamCommand(ctx context.Context, client *transport.Client, command string, params map[string]any) (registry.Result, error) {
	method := command
	if command == "screen_stream" {
		method = "screen.stream.start"
	}
	response, err := client.Call(ctx, method, params)
	if err != nil {
		m.invalidateClient(client)
		return registry.Result{}, err
	}
	return m.responseResult(command, response)
}

func (m *Manager) responseResult(command string, response transport.Response) (registry.Result, error) {
	var data any
	if len(response.Payload) > 0 && json.Unmarshal(response.Payload, &data) != nil {
		data = string(response.Payload)
	}
	result := registry.Result{Data: data, Meta: map[string]any{"status": response.Status}}
	if len(response.Binary) > 0 {
		result.Image = response.Binary
		result.MIMEType = response.Meta["mimeType"]
		if result.MIMEType == "" {
			result.MIMEType = "application/octet-stream"
		}
		name := command + ".bin"
		if strings.Contains(result.MIMEType, "png") {
			name = command + ".png"
		}
		path, err := m.artifacts.WriteBytes(name, response.Binary)
		if err != nil {
			return registry.Result{}, err
		}
		result.ArtifactPath = path
	}
	if object, ok := data.(map[string]any); ok {
		if value, ok := object["sessionId"].(string); ok {
			result.SessionID = value
		}
		if value, ok := object["url"].(string); ok {
			result.URL = value
		}
		if value, ok := object["artifactPath"].(string); ok {
			result.ArtifactPath = value
		}
	}
	return result, nil
}

func (m *Manager) sessionCommand(request registry.Request) (registry.Result, error) {
	switch request.Command {
	case "session_list":
		return registry.Result{Data: map[string]any{"sessions": m.sessions.List()}}, nil
	case "session_read":
		id, err := registry.RequiredString(request.Params, "sessionId")
		if err != nil {
			return registry.Result{}, err
		}
		info, data, err := m.sessions.Read(id, paramInt(request.Params, "maxBytes", 1<<20))
		return registry.Result{Data: map[string]any{"session": info, "output": string(data)}}, err
	case "session_write":
		id, err := registry.RequiredString(request.Params, "sessionId")
		if err != nil {
			return registry.Result{}, err
		}
		if err := m.sessions.Write(id, []byte(paramString(request.Params, "data", ""))); err != nil {
			return registry.Result{}, err
		}
		return registry.Result{Data: map[string]any{"sessionId": id, "written": true}}, nil
	case "session_stop":
		id, err := registry.RequiredString(request.Params, "sessionId")
		if err != nil {
			return registry.Result{}, err
		}
		return registry.Result{Data: map[string]any{"sessionId": id, "stopped": true}}, m.sessions.Stop(id)
	default:
		return registry.Result{}, errors.New("unsupported session command")
	}
}

func (m *Manager) tweakBuild(ctx context.Context, request registry.Request) (registry.Result, error) {
	project := paramString(request.Params, "project", m.config.ProjectRoot)
	if !filepath.IsAbs(project) {
		project = filepath.Join(m.config.ProjectRoot, project)
	}
	args := []string{"package", "DEBUG=1", "FINALPACKAGE=1"}
	if paramBool(request.Params, "clean", false) {
		args = append([]string{"clean"}, args...)
	}
	command := "gmake"
	if _, err := exec.LookPath(command); err != nil {
		command = "make"
	}
	callCtx, cancel := context.WithTimeout(ctx, time.Duration(paramInt(request.Params, "timeoutMs", 20*60*1000))*time.Millisecond)
	defer cancel()
	buildCommand := exec.CommandContext(callCtx, command, args...)
	buildCommand.Dir = project
	output, err := buildCommand.CombinedOutput()
	if err != nil {
		return registry.Result{Data: map[string]any{"output": boundedString(output)}}, fmt.Errorf("tweak build: %w", err)
	}
	packages, _ := filepath.Glob(filepath.Join(project, "packages", "*.deb"))
	if len(packages) == 0 {
		packages, _ = filepath.Glob(filepath.Join(project, "*.deb"))
	}
	sort.Strings(packages)
	if len(packages) == 0 {
		return registry.Result{Data: map[string]any{"output": boundedString(output)}}, errors.New("build completed without a Debian package")
	}
	packagePath := packages[len(packages)-1]
	return registry.Result{Data: map[string]any{"package": packagePath, "output": boundedString(output)}}, nil
}

func (m *Manager) tweakCycle(ctx context.Context, selected discovery.Device, request registry.Request) (registry.Result, error) {
	buildResult, err := m.tweakBuild(ctx, request)
	if err != nil {
		return buildResult, err
	}
	data, _ := buildResult.Data.(map[string]any)
	packagePath, _ := data["package"].(string)
	params := cloneParams(request.Params)
	params["path"] = packagePath
	params["package"] = packagePath
	params["device"] = selected.ID
	client, err := m.client(ctx, selected)
	if err != nil {
		return registry.Result{}, err
	}
	stagedPath, err := m.stageTweakPackage(ctx, client, params)
	if err != nil {
		return registry.Result{}, err
	}
	response, err := client.Call(ctx, "tweak.cycle", params)
	m.cleanupTweakPackage(client, stagedPath)
	if err != nil {
		m.invalidateClient(client)
		return registry.Result{}, err
	}
	return m.responseResult("tweak_cycle", response)
}

func normalizeAction(params map[string]any) string {
	return strings.ToLower(strings.ReplaceAll(paramString(params, "action", ""), "-", "_"))
}

func isDisplayAction(action string) bool {
	switch action {
	case "screen_off", "display_off", "dark_on", "screen_on", "display_on", "dark_off":
		return true
	default:
		return false
	}
}

func (m *Manager) stageTweakPackage(ctx context.Context, client *transport.Client, params map[string]any) (string, error) {
	source := paramString(params, "path", "")
	if source == "" {
		source = paramString(params, "package", "")
	}
	if source == "" || !filepath.IsAbs(source) {
		return "", nil
	}
	info, err := os.Stat(source)
	if err != nil || info.IsDir() {
		return "", nil
	}
	data, err := os.ReadFile(source)
	if err != nil {
		return "", fmt.Errorf("read tweak package: %w", err)
	}
	if len(data) > protocol.MaxFrameBytes {
		return "", protocol.NewError(protocol.ErrFrameTooLarge, "tweak package exceeds protocol limit", map[string]any{"bytes": len(data), "limit": protocol.MaxFrameBytes})
	}
	remote := fmt.Sprintf("/tmp/jb-p1lot-package-%d.deb", time.Now().UnixNano())
	_, err = client.Call(ctx, "file_write", map[string]any{
		"path":     remote,
		"data":     base64.StdEncoding.EncodeToString(data),
		"encoding": "base64",
		"mode":     0o600,
	})
	if err != nil {
		m.invalidateClient(client)
		return "", fmt.Errorf("stage tweak package: %w", err)
	}
	params["path"] = remote
	params["package"] = remote
	return remote, nil
}

func (m *Manager) cleanupTweakPackage(client *transport.Client, remote string) {
	if client == nil || remote == "" {
		return
	}
	cleanupCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, _ = client.Call(cleanupCtx, "shell_exec", map[string]any{"command": "rm -f " + shellQuote(remote)})
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func cloneParams(params map[string]any) map[string]any {
	result := make(map[string]any, len(params)+1)
	for key, value := range params {
		result[key] = value
	}
	return result
}

func paramString(params map[string]any, key, fallback string) string {
	value, ok := params[key].(string)
	if !ok {
		return fallback
	}
	return value
}

func paramInt(params map[string]any, key string, fallback int) int {
	switch value := params[key].(type) {
	case float64:
		return int(value)
	case int:
		return value
	case string:
		parsed, err := strconv.Atoi(value)
		if err == nil {
			return parsed
		}
	}
	return fallback
}

func paramBool(params map[string]any, key string, fallback bool) bool {
	value, ok := params[key].(bool)
	if !ok {
		return fallback
	}
	return value
}

func boundedString(output []byte) string {
	const limit = 256 * 1024
	if len(output) > limit {
		return string(output[len(output)-limit:])
	}
	return string(output)
}

type usbMuxForward struct {
	process *exec.Cmd
	port    int
}

func (f *usbMuxForward) Address() string { return net.JoinHostPort("127.0.0.1", strconv.Itoa(f.port)) }

func (m *Manager) ensureForward(device discovery.Device) (*usbMuxForward, error) {
	m.mu.Lock()
	if forward := m.forwards[device.ID]; forward != nil {
		m.mu.Unlock()
		return forward, nil
	}
	m.mu.Unlock()
	if forward := existingForward(device.ID); forward != nil {
		m.mu.Lock()
		m.forwards[device.ID] = forward
		m.mu.Unlock()
		return forward, nil
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	command := exec.Command("iproxy", strconv.Itoa(port), "5912", "-u", device.ID)
	if err := command.Start(); err != nil {
		return nil, err
	}
	forward := &usbMuxForward{process: command, port: port}
	ready := false
	for attempt := 0; attempt < 20; attempt++ {
		connection, dialErr := net.DialTimeout("tcp", forward.Address(), 100*time.Millisecond)
		if dialErr == nil {
			connection.Close()
			ready = true
			break
		}
		if command.ProcessState != nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !ready {
		_ = command.Process.Kill()
		return nil, errors.New("iproxy did not open a local tunnel")
	}
	m.mu.Lock()
	m.forwards[device.ID] = forward
	m.mu.Unlock()
	return forward, nil
}

func existingForward(deviceID string) *usbMuxForward {
	output, err := exec.Command("ps", "-axo", "pid=,command=").Output()
	if err != nil {
		return nil
	}
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 6 || filepath.Base(fields[1]) != "iproxy" || fields[4] != "-u" || fields[5] != deviceID {
			continue
		}
		localPort, localErr := strconv.Atoi(fields[2])
		remotePort, remoteErr := strconv.Atoi(fields[3])
		if localErr == nil && remoteErr == nil && localPort > 0 && remotePort == 5912 {
			return &usbMuxForward{port: localPort}
		}
	}
	return nil
}
