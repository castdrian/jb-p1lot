package registry

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
)

type Request struct {
	Command string         `json:"command"`
	Device  string         `json:"device,omitempty"`
	Params  map[string]any `json:"params,omitempty"`
}

type Result struct {
	Data         any            `json:"data,omitempty"`
	ArtifactPath string         `json:"artifactPath,omitempty"`
	MIMEType     string         `json:"mimeType,omitempty"`
	Image        []byte         `json:"-"`
	SessionID    string         `json:"sessionId,omitempty"`
	URL          string         `json:"url,omitempty"`
	Meta         map[string]any `json:"meta,omitempty"`
}

type Executor interface {
	Execute(context.Context, Request) (Result, error)
}

type Command struct {
	Name        string
	Description string
	ReadOnly    bool
	Destructive bool
	Schema      map[string]any
	Execute     func(context.Context, Request) (Result, error)
}

type Registry struct {
	commands map[string]Command
}

func New(commands ...Command) *Registry {
	r := &Registry{commands: make(map[string]Command, len(commands))}
	for _, command := range commands {
		if command.Name == "" || command.Execute == nil {
			continue
		}
		if command.Schema == nil {
			command.Schema = objectSchema(nil)
		}
		r.commands[command.Name] = command
	}
	return r
}

func (r *Registry) Names() []string {
	names := make([]string, 0, len(r.commands))
	for name := range r.commands {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func (r *Registry) Get(name string) (Command, bool) {
	command, ok := r.commands[name]
	return command, ok
}

func (r *Registry) Run(ctx context.Context, request Request) (Result, error) {
	command, ok := r.Get(request.Command)
	if !ok {
		return Result{}, fmt.Errorf("unknown command %q", request.Command)
	}
	if request.Params == nil {
		request.Params = map[string]any{}
	}
	return command.Execute(ctx, request)
}

func NewDeviceRegistry(executor Executor) *Registry {
	if executor == nil {
		panic("nil device executor")
	}
	commands := make([]Command, 0, len(commandDefinitions()))
	for _, definition := range commandDefinitions() {
		definition.Execute = func(ctx context.Context, request Request) (Result, error) {
			return executor.Execute(ctx, request)
		}
		commands = append(commands, definition)
	}
	return New(commands...)
}

func objectSchema(properties map[string]any, required ...string) map[string]any {
	schema := map[string]any{"type": "object", "additionalProperties": true}
	if properties != nil {
		schema["properties"] = properties
	}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}

func baseProperties() map[string]any {
	return map[string]any{
		"device":     map[string]any{"type": "string", "description": "Paired UDID, bridge address, or stable device selector"},
		"deadlineMs": map[string]any{"type": "integer", "minimum": 1, "maximum": 600000},
	}
}

func commandSchema(properties map[string]any) map[string]any {
	base := baseProperties()
	for key, value := range properties {
		base[key] = value
	}
	return objectSchema(base)
}

func commandDefinitions() []Command {
	stringValue := map[string]any{"type": "string"}
	intValue := map[string]any{"type": "integer"}
	boolValue := map[string]any{"type": "boolean"}
	return []Command{
		{Name: "device_list", Description: "Discover paired jailbreak devices and bridge addresses", ReadOnly: true, Schema: commandSchema(nil)},
		{Name: "device_status", Description: "Read bridge, jailbreak, transport, and backend status", ReadOnly: true, Schema: commandSchema(nil)},
		{Name: "device_action", Description: "Perform a lifecycle or display action; reboot always means a Dopamine userspace reboot", Destructive: true, Schema: commandSchema(map[string]any{"action": stringValue, "reason": stringValue})},
		{Name: "shell_exec", Description: "Execute a root shell command on the paired device", Destructive: true, Schema: commandSchema(map[string]any{"command": stringValue, "cwd": stringValue, "env": map[string]any{"type": "object"}, "timeoutMs": intValue})},
		{Name: "file_list", Description: "List a device directory", ReadOnly: true, Schema: commandSchema(map[string]any{"path": stringValue, "recursive": boolValue})},
		{Name: "file_read", Description: "Read a bounded device file", ReadOnly: true, Schema: commandSchema(map[string]any{"path": stringValue, "maxBytes": intValue})},
		{Name: "file_write", Description: "Write a device file atomically", Destructive: true, Schema: commandSchema(map[string]any{"path": stringValue, "data": stringValue, "encoding": stringValue, "mode": intValue})},
		{Name: "file_transfer", Description: "Transfer a file between host and device", Destructive: true, Schema: commandSchema(map[string]any{"source": stringValue, "destination": stringValue, "direction": stringValue})},
		{Name: "file_search", Description: "Search device paths with bounded results", ReadOnly: true, Schema: commandSchema(map[string]any{"root": stringValue, "pattern": stringValue, "maxResults": intValue})},
		{Name: "screen_capture", Description: "Capture the current display as PNG", ReadOnly: true, Schema: commandSchema(map[string]any{"display": stringValue, "includeProtectedReport": boolValue})},
		{Name: "screen_stream", Description: "Start a reconnectable H.264 screen stream", ReadOnly: true, Schema: commandSchema(map[string]any{"display": stringValue, "record": boolValue, "durationMs": intValue, "fps": intValue})},
		{Name: "ui_snapshot", Description: "Read a frame-scoped accessibility tree", ReadOnly: true, Schema: commandSchema(map[string]any{"application": stringValue, "includeSpringBoard": boolValue})},
		{Name: "ui_action", Description: "Perform semantic, coordinate, HID, keyboard, button, display, or system gesture input", Destructive: true, Schema: commandSchema(map[string]any{"action": stringValue, "frameId": stringValue, "nodeId": stringValue, "selector": stringValue, "x": map[string]any{"type": "number"}, "y": map[string]any{"type": "number"}, "points": map[string]any{"type": "array", "items": map[string]any{}}, "text": stringValue, "button": stringValue, "repeat": intValue, "intervalMs": intValue, "durationMs": intValue})},
		{Name: "ui_wait", Description: "Wait for an accessibility or visual condition", ReadOnly: true, Schema: commandSchema(map[string]any{"selector": stringValue, "timeoutMs": intValue, "pollMs": intValue})},
		{Name: "app_manage", Description: "Inspect, launch, install, or uninstall applications", Destructive: true, Schema: commandSchema(map[string]any{"action": stringValue, "bundleId": stringValue, "path": stringValue, "arguments": map[string]any{"type": "array", "items": stringValue}})},
		{Name: "process_manage", Description: "Inspect, signal, spawn, or terminate processes", Destructive: true, Schema: commandSchema(map[string]any{"action": stringValue, "pid": intValue, "command": stringValue, "signal": intValue})},
		{Name: "package_manage", Description: "Inspect, install, remove, or rollback Debian packages", Destructive: true, Schema: commandSchema(map[string]any{"action": stringValue, "package": stringValue, "path": stringValue, "version": stringValue})},
		{Name: "port_forward", Description: "Create or stop a USBMux or WiFi port forward", Destructive: true, Schema: commandSchema(map[string]any{"action": stringValue, "localPort": intValue, "remotePort": intValue, "protocol": stringValue})},
		{Name: "log_query", Description: "Stream scoped unified logs with bounded output", ReadOnly: true, Schema: commandSchema(map[string]any{"predicate": stringValue, "process": stringValue, "since": stringValue, "limit": intValue, "follow": boolValue})},
		{Name: "crash_manage", Description: "List, retrieve, symbolicate, or clear crash reports", Destructive: true, Schema: commandSchema(map[string]any{"action": stringValue, "process": stringValue, "path": stringValue})},
		{Name: "diagnostics_collect", Description: "Collect sysdiagnose and bridge diagnostics", ReadOnly: true, Schema: commandSchema(map[string]any{"kind": stringValue, "durationMs": intValue})},
		{Name: "metrics_stream", Description: "Read CPU, memory, graphics, energy, and network metrics", ReadOnly: true, Schema: commandSchema(map[string]any{"durationMs": intValue, "intervalMs": intValue, "process": stringValue})},
		{Name: "network_capture", Description: "Capture a bounded BPF-filtered PCAP artifact", ReadOnly: true, Schema: commandSchema(map[string]any{"interface": stringValue, "filter": stringValue, "durationMs": intValue, "snaplen": intValue})},
		{Name: "debug_session", Description: "Start and control an LLDB/debugserver session", Destructive: true, Schema: commandSchema(map[string]any{"action": stringValue, "sessionId": stringValue, "pid": intValue, "bundleId": stringValue, "command": stringValue, "breakpoints": map[string]any{"type": "array"}, "data": stringValue})},
		{Name: "frida_session", Description: "Start and control an official matching Frida session", Destructive: true, Schema: commandSchema(map[string]any{"action": stringValue, "sessionId": stringValue, "pid": intValue, "bundleId": stringValue, "script": stringValue, "data": stringValue})},
		{Name: "tweak_build", Description: "Build a Theos tweak and return the newest package artifact", Destructive: false, Schema: commandSchema(map[string]any{"project": stringValue, "configuration": stringValue, "clean": boolValue})},
		{Name: "tweak_deploy", Description: "Install a rootless tweak package and verify its heartbeat", Destructive: true, Schema: commandSchema(map[string]any{"package": stringValue, "reload": stringValue, "processes": map[string]any{"type": "array", "items": stringValue}})},
		{Name: "tweak_cycle", Description: "Build, install, reload, log, verify, and rollback a tweak package", Destructive: true, Schema: commandSchema(map[string]any{"project": stringValue, "reload": stringValue, "processes": map[string]any{"type": "array", "items": stringValue}, "rollbackOnCrash": boolValue, "clean": boolValue})},
		{Name: "session_list", Description: "List long-running device sessions", ReadOnly: true, Schema: commandSchema(nil)},
		{Name: "session_read", Description: "Read buffered output from a long-running session", ReadOnly: true, Schema: commandSchema(map[string]any{"sessionId": stringValue, "maxBytes": intValue, "waitMs": intValue})},
		{Name: "session_write", Description: "Write input to a long-running session", Destructive: true, Schema: commandSchema(map[string]any{"sessionId": stringValue, "data": stringValue})},
		{Name: "session_stop", Description: "Stop a long-running device session", Destructive: true, Schema: commandSchema(map[string]any{"sessionId": stringValue})},
	}
}

func ParseParams(raw json.RawMessage) (map[string]any, error) {
	if len(raw) == 0 {
		return map[string]any{}, nil
	}
	var params map[string]any
	if err := json.Unmarshal(raw, &params); err != nil {
		return nil, fmt.Errorf("invalid arguments: %w", err)
	}
	if params == nil {
		return map[string]any{}, nil
	}
	return params, nil
}

func RequiredString(params map[string]any, key string) (string, error) {
	value, ok := params[key].(string)
	if !ok || value == "" {
		return "", errors.New(key + " is required")
	}
	return value, nil
}
