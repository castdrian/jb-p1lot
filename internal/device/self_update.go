package device

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	jbp1lot "github.com/castdrian/jb-p1lot"
	"github.com/castdrian/jb-p1lot/internal/discovery"
	"github.com/castdrian/jb-p1lot/internal/registry"
	"github.com/castdrian/jb-p1lot/internal/transport"
)

const (
	selfUpdateTimeout      = 90 * time.Second
	selfUpdatePollInterval = 2 * time.Second
	selfUpdateLog          = "/var/tmp/jb-p1lot-self-update.log"
	unlockAfterUpdateWait  = 30 * time.Second
)

type bridgeState struct {
	version string
	pid     int
}

func (m *Manager) selfUpdate(ctx context.Context, selected discovery.Device, request registry.Request) (registry.Result, error) {
	params := cloneParams(request.Params)
	packagePath := paramString(params, "package", "")
	if packagePath == "" {
		return registry.Result{}, fmt.Errorf("self_update needs --package with the built jb-p1lot .deb")
	}
	params["path"] = packagePath
	params["device"] = selected.ID
	client, err := m.client(ctx, selected)
	if err != nil {
		return registry.Result{}, err
	}
	previous := bridgeIdentity(ctx, client)
	if _, err := m.stageTweakPackage(ctx, client, params); err != nil {
		return registry.Result{}, err
	}
	staged := paramString(params, "path", "")
	if _, err := client.Call(ctx, "shell_exec", map[string]any{"command": detachedInstallCommand(staged), "timeoutMs": 10000}); err != nil {
		m.invalidateClient(client)
		return registry.Result{}, fmt.Errorf("start the install: %w", err)
	}
	m.invalidateClient(client)
	started := time.Now()
	installLog, err := m.awaitInstallLog(ctx, selected, selfUpdateTimeout)
	if err != nil {
		return registry.Result{}, err
	}
	if !strings.Contains(installLog, "Setting up") {
		return registry.Result{}, fmt.Errorf("dpkg did not install the package: %s", strings.TrimSpace(installLog))
	}
	current, err := m.awaitRestartedBridge(ctx, selected, previous, selfUpdateTimeout)
	if err != nil {
		return registry.Result{}, err
	}
	if current.version != jbp1lot.Version {
		return registry.Result{}, fmt.Errorf("the device bridge restarted as %s, not host %s; the package was built from another version", current.version, jbp1lot.Version)
	}
	return registry.Result{Data: map[string]any{
		"updated":         true,
		"previousVersion": previous.version,
		"version":         current.version,
		"hostVersion":     jbp1lot.Version,
		"restartMs":       time.Since(started).Milliseconds(),
		"unlocked":        m.unlockAfterRespring(ctx, selected),
	}}, nil
}

func (m *Manager) unlockAfterRespring(ctx context.Context, selected discovery.Device) bool {
	deadline := time.Now().Add(unlockAfterUpdateWait)
	for time.Now().Before(deadline) {
		if client, err := m.client(ctx, selected); err == nil {
			response, callErr := client.Call(ctx, "ui_action", map[string]any{"action": "button", "button": "home"})
			if callErr == nil && response.Status != "error" && pressed(response.Payload) {
				return true
			}
			m.invalidateClient(client)
		}
		if err := pause(ctx); err != nil {
			return false
		}
	}
	return false
}

func pressed(response json.RawMessage) bool {
	var result struct {
		Performed bool `json:"performed"`
	}
	return json.Unmarshal(response, &result) == nil && result.Performed
}

func detachedInstallCommand(staged string) string {
	return fmt.Sprintf("rm -f %s; nohup sh -c 'sleep 1; /var/jb/usr/bin/dpkg -i %s > %s 2>&1; rm -f %s; killall -9 SpringBoard' >/dev/null 2>&1 &", selfUpdateLog, staged, selfUpdateLog, staged)
}

func (m *Manager) awaitInstallLog(ctx context.Context, selected discovery.Device, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if err := pause(ctx); err != nil {
			return "", err
		}
		log := m.readInstallLog(ctx, selected)
		if installFinished(log) {
			return log, nil
		}
	}
	return "", fmt.Errorf("dpkg did not finish within %s", timeout)
}

func installFinished(log string) bool {
	return strings.Contains(log, "Setting up") || strings.Contains(log, "dpkg: error") || strings.Contains(log, "dpkg-deb: error")
}

func (m *Manager) awaitRestartedBridge(ctx context.Context, selected discovery.Device, previous bridgeState, timeout time.Duration) (bridgeState, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if err := pause(ctx); err != nil {
			return bridgeState{}, err
		}
		client, err := m.client(ctx, selected)
		if err != nil {
			continue
		}
		current := bridgeIdentity(ctx, client)
		if current.version != "" && current.pid != 0 && current.pid != previous.pid {
			return current, nil
		}
		m.invalidateClient(client)
	}
	return bridgeState{}, fmt.Errorf("the device bridge did not restart within %s of installing the package", timeout)
}

func (m *Manager) readInstallLog(ctx context.Context, selected discovery.Device) string {
	client, err := m.client(ctx, selected)
	if err != nil {
		return ""
	}
	response, err := client.Call(ctx, "shell_exec", map[string]any{"command": "tail -c 2000 " + selfUpdateLog, "timeoutMs": 10000})
	if err != nil {
		m.invalidateClient(client)
		return ""
	}
	var result struct {
		Output string `json:"output"`
	}
	if json.Unmarshal(response.Payload, &result) != nil {
		return ""
	}
	return result.Output
}

func bridgeIdentity(ctx context.Context, client *transport.Client) bridgeState {
	callCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	response, err := client.Call(callCtx, "device.status", map[string]any{})
	if err != nil {
		return bridgeState{}
	}
	var status struct {
		Version string `json:"version"`
		PID     int    `json:"pid"`
	}
	if json.Unmarshal(response.Payload, &status) != nil {
		return bridgeState{}
	}
	return bridgeState{version: status.Version, pid: status.PID}
}

func pause(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(selfUpdatePollInterval):
		return nil
	}
}
