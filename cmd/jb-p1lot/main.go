package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/castdrian/jb-p1lot/internal/device"
	"github.com/castdrian/jb-p1lot/internal/provision"
	"github.com/castdrian/jb-p1lot/internal/registry"
	"github.com/castdrian/jb-p1lot/internal/server"
)

var version = "0.1.2"

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(2)
	}
	command := os.Args[1]
	if command == "version" || command == "--version" {
		fmt.Println(version)
		return
	}
	ctx := context.Background()
	if command == "mcp" {
		manager, err := newManager()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		if err := server.Run(ctx, registry.NewDeviceRegistry(manager)); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if command == "setup" {
		runSetup(ctx, os.Args[2:])
		return
	}
	if command == "plugin" {
		runPlugin(ctx, os.Args[2:])
		return
	}
	if !isRegisteredCommand(command) {
		fmt.Fprintf(os.Stderr, "unknown command %q\n", command)
		printUsage()
		os.Exit(2)
	}
	jsonOutput, deviceSelector, project, paramsArgs := parseInvocation(os.Args[2:])
	params := map[string]any{}
	for key, value := range parseKeyValues(paramsArgs) {
		params[key] = value
	}
	if project != "" {
		params["project"] = project
	}
	manager, err := newManager()
	if err != nil {
		writeError(err, jsonOutput)
		os.Exit(1)
	}
	callCtx, cancel := context.WithTimeout(ctx, 20*time.Minute)
	defer cancel()
	result, err := manager.Execute(callCtx, registry.Request{Command: command, Device: deviceSelector, Params: params})
	if err != nil {
		writeError(err, jsonOutput)
		os.Exit(1)
	}
	writeResult(result, jsonOutput)
}

func newManager() (*device.Manager, error) {
	identity, err := provision.EnsureIdentity()
	if err != nil {
		return nil, err
	}
	return device.NewManager(device.Config{Identity: identity, MaxArtifactMB: 64})
}

func runSetup(ctx context.Context, args []string) {
	flags := flag.NewFlagSet("setup", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	all := flags.Bool("all", false, "verify, build, pair, provision, and register the plugin")
	deviceSelector := flags.String("device", "", "device UDID or stable selector")
	repoRoot := flags.String("repo", "", "repository root")
	sshHost := flags.String("ssh-host", "", "device SSH address")
	sshPort := flags.Int("ssh-port", 22, "device SSH port")
	sshUser := flags.String("ssh-user", "mobile", "device SSH user")
	sshPassword := flags.String("ssh-password", "", "temporary provisioning password")
	if err := flags.Parse(args); err != nil {
		os.Exit(2)
	}
	if *repoRoot == "" {
		*repoRoot, _ = os.Getwd()
	}
	report, err := provision.Run(ctx, provision.Options{All: *all, DeviceSelector: *deviceSelector, RepoRoot: *repoRoot, BuildHost: *all, BuildDevice: *all, InstallPlugin: *all, SSHHost: *sshHost, SSHPort: *sshPort, SSHUser: *sshUser, SSHPassword: *sshPassword})
	if err != nil {
		writeJSON(map[string]any{"report": report, "error": err.Error()})
		os.Exit(1)
	}
	writeJSON(report)
}

func runPlugin(ctx context.Context, args []string) {
	if len(args) == 0 || args[0] != "install" {
		fmt.Fprintln(os.Stderr, "usage: jb-p1lot plugin install")
		os.Exit(2)
	}
	commands := [][]string{{"plugin", "marketplace", "add", "https://github.com/castdrian/jb-p1lot", "--ref", "main"}, {"plugin", "add", "jb-p1lot@adrian"}}
	for _, commandArgs := range commands {
		command := exec.CommandContext(ctx, "codex", commandArgs...)
		command.Stdout = os.Stdout
		command.Stderr = os.Stderr
		if err := command.Run(); err != nil {
			writeError(err, false)
			os.Exit(1)
		}
	}
	fmt.Println("jb-p1lot plugin installed")
}

func parseKeyValues(args []string) map[string]any {
	values := make(map[string]any)
	for index := 0; index < len(args); index++ {
		arg := args[index]
		if !strings.HasPrefix(arg, "--") {
			continue
		}
		keyValue := strings.TrimPrefix(arg, "--")
		if strings.Contains(keyValue, "=") {
			parts := strings.SplitN(keyValue, "=", 2)
			values[parts[0]] = coerce(parts[1])
			continue
		}
		if index+1 < len(args) && !strings.HasPrefix(args[index+1], "--") {
			values[keyValue] = coerce(args[index+1])
			index++
		} else {
			values[keyValue] = true
		}
	}
	return values
}

func parseInvocation(args []string) (bool, string, string, []string) {
	jsonOutput := false
	deviceSelector := ""
	project := ""
	params := make([]string, 0, len(args))
	for index := 0; index < len(args); index++ {
		arg := args[index]
		switch {
		case arg == "--json":
			jsonOutput = true
		case arg == "--device" && index+1 < len(args):
			deviceSelector = args[index+1]
			index++
		case strings.HasPrefix(arg, "--device="):
			deviceSelector = strings.TrimPrefix(arg, "--device=")
		case arg == "--project" && index+1 < len(args):
			project = args[index+1]
			index++
		case strings.HasPrefix(arg, "--project="):
			project = strings.TrimPrefix(arg, "--project=")
		default:
			params = append(params, arg)
		}
	}
	return jsonOutput, deviceSelector, project, params
}

func coerce(value string) any {
	if value == "true" {
		return true
	}
	if value == "false" {
		return false
	}
	if value == "" {
		return value
	}
	if strings.HasPrefix(value, "[") || strings.HasPrefix(value, "{") {
		var structured any
		if json.Unmarshal([]byte(value), &structured) == nil {
			return structured
		}
	}
	var number float64
	if json.Unmarshal([]byte(value), &number) == nil {
		return number
	}
	return value
}

func isRegisteredCommand(name string) bool {
	for _, command := range registry.NewDeviceRegistry(noopExecutor{}).Names() {
		if command == name {
			return true
		}
	}
	return false
}

type noopExecutor struct{}

func (noopExecutor) Execute(context.Context, registry.Request) (registry.Result, error) {
	return registry.Result{}, errors.New("noop")
}

func writeResult(result registry.Result, jsonOutput bool) {
	value := map[string]any{"data": result.Data}
	if result.ArtifactPath != "" {
		value["artifactPath"] = result.ArtifactPath
	}
	if result.SessionID != "" {
		value["sessionId"] = result.SessionID
	}
	if result.URL != "" {
		value["url"] = result.URL
	}
	if result.MIMEType != "" {
		value["mimeType"] = result.MIMEType
	}
	if result.Meta != nil {
		value["meta"] = result.Meta
	}
	if jsonOutput {
		writeJSON(value)
		return
	}
	if result.ArtifactPath != "" {
		fmt.Println(result.ArtifactPath)
		return
	}
	encoded, _ := json.MarshalIndent(value["data"], "", "  ")
	fmt.Println(string(encoded))
}

func writeError(err error, jsonOutput bool) {
	if jsonOutput {
		writeJSON(map[string]any{"error": err.Error()})
		return
	}
	fmt.Fprintln(os.Stderr, err)
}

func writeJSON(value any) {
	encoded, _ := json.MarshalIndent(value, "", "  ")
	fmt.Println(string(encoded))
}

func printUsage() {
	root := filepath.Base(os.Args[0])
	fmt.Printf("usage: %s <command> [options]\n", root)
	fmt.Println("commands: device_list device_status device_action shell_exec file_list file_read file_write file_transfer file_search screen_capture screen_stream ui_snapshot ui_action ui_wait app_manage process_manage package_manage port_forward log_query crash_manage diagnostics_collect metrics_stream network_capture debug_session frida_session tweak_build tweak_deploy tweak_cycle session_list session_read session_write session_stop setup plugin mcp")
}
