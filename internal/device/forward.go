package device

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/castdrian/jb-p1lot/internal/discovery"
	"github.com/castdrian/jb-p1lot/internal/protocol"
	"github.com/castdrian/jb-p1lot/internal/registry"
	"github.com/castdrian/jb-p1lot/internal/transport"
)

type portForwardEntry struct {
	PID        int  `json:"pid"`
	LocalPort  int  `json:"localPort"`
	RemotePort int  `json:"remotePort"`
	Bridge     bool `json:"bridge"`
}

func listPortForwards(deviceID string) []portForwardEntry {
	output, err := exec.Command("ps", "-axo", "pid=,command=").Output()
	if err != nil {
		return nil
	}
	var entries []portForwardEntry
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 6 || filepath.Base(fields[1]) != "iproxy" || fields[4] != "-u" || fields[5] != deviceID {
			continue
		}
		pid, pidErr := strconv.Atoi(fields[0])
		local, localErr := strconv.Atoi(fields[2])
		remote, remoteErr := strconv.Atoi(fields[3])
		if pidErr == nil && localErr == nil && remoteErr == nil {
			entries = append(entries, portForwardEntry{PID: pid, LocalPort: local, RemotePort: remote, Bridge: remote == 5912})
		}
	}
	return entries
}

func freeLocalPort() (int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port, nil
}

func localPortBound(port int) bool {
	output, err := exec.Command("lsof", "-nP", "-iTCP:"+strconv.Itoa(port), "-sTCP:LISTEN", "-t").Output()
	return err == nil && strings.TrimSpace(string(output)) != ""
}

func startPortForward(deviceID string, localPort, remotePort int) (portForwardEntry, error) {
	for _, entry := range listPortForwards(deviceID) {
		if entry.RemotePort == remotePort && (localPort == 0 || entry.LocalPort == localPort) {
			return entry, nil
		}
	}
	if localPort == 0 {
		port, err := freeLocalPort()
		if err != nil {
			return portForwardEntry{}, err
		}
		localPort = port
	}
	command := exec.Command("iproxy", strconv.Itoa(localPort), strconv.Itoa(remotePort), "-u", deviceID)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		return portForwardEntry{}, fmt.Errorf("start iproxy: %w", err)
	}
	go func() { _ = command.Wait() }()
	for attempt := 0; attempt < 30; attempt++ {
		if localPortBound(localPort) {
			return portForwardEntry{PID: command.Process.Pid, LocalPort: localPort, RemotePort: remotePort}, nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	_ = command.Process.Kill()
	return portForwardEntry{}, errors.New("iproxy did not open the local port")
}

func stopPortForwards(deviceID string, match func(portForwardEntry) bool) []portForwardEntry {
	var stopped []portForwardEntry
	for _, entry := range listPortForwards(deviceID) {
		if entry.Bridge || !match(entry) {
			continue
		}
		if err := syscall.Kill(entry.PID, syscall.SIGTERM); err == nil {
			stopped = append(stopped, entry)
		}
	}
	return stopped
}

func (m *Manager) portForward(selected discovery.Device, params map[string]any) (registry.Result, error) {
	if selected.Connection != "usb" {
		return registry.Result{}, protocol.NewError(protocol.ErrUnavailable, "port forwarding needs a USB connection", map[string]any{"connection": selected.Connection})
	}
	localPort := paramInt(params, "localPort", 0)
	remotePort := paramInt(params, "remotePort", 0)
	switch normalizeAction(params) {
	case "", "start", "create":
		if remotePort <= 0 {
			return registry.Result{}, protocol.NewError(protocol.ErrInvalidFrame, "remotePort is required", nil)
		}
		entry, err := startPortForward(selected.ID, localPort, remotePort)
		if err != nil {
			return registry.Result{}, err
		}
		return registry.Result{Data: map[string]any{"forward": entry, "address": net.JoinHostPort("127.0.0.1", strconv.Itoa(entry.LocalPort))}}, nil
	case "list":
		return registry.Result{Data: map[string]any{"forwards": listPortForwards(selected.ID)}}, nil
	case "stop", "remove":
		stopped := stopPortForwards(selected.ID, func(entry portForwardEntry) bool {
			return (localPort > 0 && entry.LocalPort == localPort) || (remotePort > 0 && entry.RemotePort == remotePort)
		})
		return registry.Result{Data: map[string]any{"stopped": stopped}}, nil
	default:
		return registry.Result{}, protocol.NewError(protocol.ErrInvalidFrame, "action must be start, list, or stop", nil)
	}
}

func (m *Manager) remoteSession(ctx context.Context, client *transport.Client, selected discovery.Device, command string, params map[string]any) (registry.Result, error) {
	response, err := client.Call(ctx, command, params)
	if err != nil {
		m.invalidateClient(client)
		return registry.Result{}, err
	}
	result, err := m.responseResult(command, response)
	if err != nil {
		return result, err
	}
	payload, _ := result.Data.(map[string]any)
	action := normalizeAction(params)
	remotePort, _ := payload["remotePort"].(float64)
	if payload == nil || remotePort <= 0 || selected.Connection != "usb" {
		return result, nil
	}
	if action == "stop" {
		payload["forwardsStopped"] = stopPortForwards(selected.ID, func(entry portForwardEntry) bool { return entry.RemotePort == int(remotePort) })
		return result, nil
	}
	if action != "" && action != "start" {
		return result, nil
	}
	forward, err := startPortForward(selected.ID, paramInt(params, "localPort", 0), int(remotePort))
	if err != nil {
		payload["forwardError"] = err.Error()
		return result, nil
	}
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(forward.LocalPort))
	payload["localPort"] = forward.LocalPort
	if command == "debug_session" {
		payload["connect"] = "process connect connect://" + address
	} else {
		payload["connect"] = "frida -H " + address
	}
	if hostRun, ok := runHostTool(ctx, command, address, params); ok {
		payload["host"] = hostRun
		stopPortForwards(selected.ID, func(entry portForwardEntry) bool { return entry.LocalPort == forward.LocalPort })
	}
	return result, nil
}

func hostToolInvocation(command, address string, params map[string]any) (string, []string) {
	if command == "debug_session" {
		lldbCommands := paramStrings(params, "commands")
		if single := paramString(params, "command", ""); single != "" {
			lldbCommands = append(lldbCommands, single)
		}
		if len(lldbCommands) == 0 {
			return "", nil
		}
		args := []string{"--batch", "-O", "settings set target.memory-module-load-level minimal", "-o", "process connect connect://" + address}
		for _, value := range lldbCommands {
			args = append(args, "-o", value)
		}
		return "lldb", args
	}
	script := paramString(params, "script", "")
	if script == "" {
		return "", nil
	}
	args := []string{"-H", address, "-l", script, "-q"}
	if target := paramString(params, "process", ""); target != "" {
		args = append(args, "-n", target)
	} else if pid := paramInt(params, "pid", 0); pid > 0 {
		args = append(args, "-p", strconv.Itoa(pid))
	} else if bundle := paramString(params, "bundleId", ""); bundle != "" {
		args = append(args, "-f", bundle)
	}
	return "frida", args
}

func runHostTool(ctx context.Context, command, address string, params map[string]any) (map[string]any, bool) {
	name, args := hostToolInvocation(command, address, params)
	if name == "" {
		return nil, false
	}
	path, err := exec.LookPath(name)
	if err != nil {
		return map[string]any{"tool": name, "error": name + " is not installed on the host"}, true
	}
	timeout := time.Duration(paramInt(params, "durationMs", 60000)) * time.Millisecond
	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	output, runErr := exec.CommandContext(runCtx, path, args...).CombinedOutput()
	run := map[string]any{"tool": name, "args": args, "output": boundedString(output)}
	if runErr != nil {
		run["error"] = runErr.Error()
	}
	return run, true
}

func paramStrings(params map[string]any, key string) []string {
	switch value := params[key].(type) {
	case []any:
		var items []string
		for _, item := range value {
			if text, ok := item.(string); ok && text != "" {
				items = append(items, text)
			}
		}
		return items
	case string:
		var items []string
		if json.Unmarshal([]byte(value), &items) == nil {
			return items
		}
		return []string{value}
	}
	return nil
}
