package provision

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha1"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/castdrian/jb-p1lot/internal/discovery"
	"github.com/castdrian/jb-p1lot/internal/transport"
)

type ToolCheck struct {
	Name      string `json:"name"`
	Path      string `json:"path,omitempty"`
	Available bool   `json:"available"`
	Required  bool   `json:"required"`
	Error     string `json:"error,omitempty"`
}

type Report struct {
	Version       string             `json:"version"`
	Platform      string             `json:"platform"`
	Checks        []ToolCheck        `json:"checks"`
	Identity      transport.Identity `json:"identity"`
	HostBinary    string             `json:"hostBinary,omitempty"`
	DevicePackage string             `json:"devicePackage,omitempty"`
	Device        string             `json:"device,omitempty"`
	Actions       []string           `json:"actions"`
	Warnings      []string           `json:"warnings,omitempty"`
}

type Options struct {
	All            bool
	DeviceSelector string
	RepoRoot       string
	BuildHost      bool
	BuildDevice    bool
	InstallPlugin  bool
	SSHHost        string
	SSHPort        int
	SSHUser        string
	SSHPassword    string
}

func Run(ctx context.Context, options Options) (Report, error) {
	if options.RepoRoot == "" {
		options.RepoRoot, _ = os.Getwd()
	}
	report := Report{Version: "0.1.2", Platform: runtime.GOOS + "/" + runtime.GOARCH, Actions: []string{}}
	report.Checks = checkTools(ctx)
	identity, identityErr := EnsureIdentity()
	report.Identity = identity
	if identityErr != nil {
		report.Warnings = append(report.Warnings, identityErr.Error())
	}
	if options.BuildHost || options.All {
		path, err := buildHost(ctx, options.RepoRoot)
		if err != nil {
			report.Warnings = append(report.Warnings, err.Error())
		} else {
			report.HostBinary = path
			report.Actions = append(report.Actions, "built host binary")
		}
	}
	if options.BuildDevice || options.All {
		path, err := buildDevice(ctx, options.RepoRoot)
		if err != nil {
			report.Warnings = append(report.Warnings, err.Error())
		} else {
			report.DevicePackage = path
			report.Actions = append(report.Actions, "built rootless device package")
		}
	}
	if options.DeviceSelector != "" || options.All {
		devices, err := discovery.Discover(ctx)
		if err != nil {
			return report, err
		}
		selected, err := discovery.Select(devices, options.DeviceSelector)
		if err != nil {
			return report, err
		}
		report.Device = selected.ID
		if err := provisionDevice(ctx, selected, report.DevicePackage, identity, options); err != nil {
			report.Warnings = append(report.Warnings, err.Error())
		} else {
			report.Actions = append(report.Actions, "paired and verified device backends")
		}
	}
	if options.InstallPlugin || options.All {
		if err := installPlugin(ctx); err != nil {
			report.Warnings = append(report.Warnings, err.Error())
		} else {
			report.Actions = append(report.Actions, "registered Codex marketplace and plugin")
		}
	}
	if requiredMissing(report.Checks) {
		return report, errors.New("required host tooling is missing")
	}
	return report, nil
}

func checkTools(ctx context.Context) []ToolCheck {
	tools := []struct {
		name     string
		command  string
		args     []string
		required bool
	}{
		{"Xcode", "xcode-select", []string{"-p"}, true},
		{"Theos", "gmake", []string{"--version"}, true},
		{"GNU Make", "gmake", []string{"--version"}, true},
		{"ldid", "ldid", []string{"-h"}, true},
		{"Go", "go", []string{"version"}, true},
		{"pymobiledevice3", "pymobiledevice3", []string{"--version"}, true},
		{"libimobiledevice", "idevice_id", []string{"--version"}, true},
		{"LLDB", "lldb", []string{"--version"}, true},
		{"SSH", "ssh", []string{"-V"}, true},
		{"usbmux tunnel", "iproxy", []string{"--help"}, true},
		{"Frida", "frida", []string{"--version"}, false},
		{"sshpass", "sshpass", []string{"-V"}, false},
	}
	checks := make([]ToolCheck, 0, len(tools))
	for _, tool := range tools {
		path, err := exec.LookPath(tool.command)
		check := ToolCheck{Name: tool.name, Path: path, Available: err == nil, Required: tool.required}
		if err == nil {
			callCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
			_, runErr := exec.CommandContext(callCtx, path, tool.args...).CombinedOutput()
			cancel()
			if runErr != nil && tool.name != "ldid" && tool.name != "SSH" && tool.name != "sshpass" {
				check.Error = runErr.Error()
			}
		} else {
			check.Error = err.Error()
		}
		checks = append(checks, check)
	}
	return checks
}

func requiredMissing(checks []ToolCheck) bool {
	for _, check := range checks {
		if check.Required && !check.Available {
			return true
		}
	}
	return false
}

func buildHost(ctx context.Context, root string) (string, error) {
	outputDir := filepath.Join(root, "dist")
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(outputDir, "jb-p1lot-"+runtime.GOOS+"-"+runtime.GOARCH)
	command := exec.CommandContext(ctx, "go", "build", "-trimpath", "-ldflags", "-s -w", "-o", path, "./cmd/jb-p1lot")
	command.Dir = root
	if output, err := command.CombinedOutput(); err != nil {
		return "", fmt.Errorf("build host binary: %w: %s", err, bounded(output))
	}
	return path, nil
}

func buildDevice(ctx context.Context, root string) (string, error) {
	command := exec.CommandContext(ctx, "gmake", "package", "FINALPACKAGE=1")
	command.Dir = root
	if output, err := command.CombinedOutput(); err != nil {
		return "", fmt.Errorf("build device package: %w: %s", err, bounded(output))
	}
	packages, _ := filepath.Glob(filepath.Join(root, "packages", "*.deb"))
	if len(packages) == 0 {
		return "", errors.New("device build completed without packages/*.deb")
	}
	return packages[len(packages)-1], nil
}

func provisionDevice(ctx context.Context, device discovery.Device, packagePath string, identity transport.Identity, options Options) error {
	if packagePath == "" {
		return errors.New("device package was not built; pairing skipped")
	}
	var tunnel *exec.Cmd
	if options.SSHHost == "" && device.Connection == "usb" {
		tunnel = exec.Command("iproxy", "2222", "22", "-u", device.ID)
		if err := tunnel.Start(); err != nil {
			return fmt.Errorf("start USB SSH tunnel: %w", err)
		}
		defer tunnel.Process.Kill()
		options.SSHHost = "127.0.0.1"
		options.SSHPort = 2222
	}
	if options.SSHHost == "" {
		return errors.New("SSH host is required for device provisioning")
	}
	if options.SSHUser == "" {
		options.SSHUser = "mobile"
	}
	if options.SSHPort == 0 {
		options.SSHPort = 22
	}
	if options.SSHPassword == "" {
		options.SSHPassword = "alpine"
	}
	if err := runSSH(ctx, options, "id"); err != nil {
		return fmt.Errorf("verify SSH: %w", err)
	}
	if err := uploadFile(ctx, options, identity.ServerPKCS12File, "/var/mobile/jb-p1lot-server.p12"); err != nil {
		return fmt.Errorf("upload server identity: %w", err)
	}
	if err := uploadFile(ctx, options, identity.CADERFile, "/var/mobile/jb-p1lot-ca.der"); err != nil {
		return fmt.Errorf("upload CA identity: %w", err)
	}
	if err := runSSH(ctx, options, "mkdir -p /var/mobile/Media/jb-p1lot && printf '%s\n' alpine | sudo -S mkdir -p /var/jb/var/root/Library/Preferences && printf '%s\n' alpine | sudo -S install -m 600 /var/mobile/jb-p1lot-server.p12 /var/jb/var/root/Library/Preferences/dev.adrian.jb-p1lot.server.p12 && printf '%s\n' alpine | sudo -S install -m 644 /var/mobile/jb-p1lot-ca.der /var/jb/var/root/Library/Preferences/dev.adrian.jb-p1lot.ca.der"); err != nil {
		return err
	}
	if err := uploadFile(ctx, options, packagePath, "/var/mobile/jb-p1lot.deb"); err != nil {
		return fmt.Errorf("upload device package: %w", err)
	}
	if err := runSSH(ctx, options, "printf '%s\n' alpine | sudo -S /var/jb/usr/bin/dpkg -i /var/mobile/jb-p1lot.deb"); err != nil {
		return fmt.Errorf("install device package: %w", err)
	}
	if err := runCommand(ctx, "pymobiledevice3", "mounter", "auto-mount", "--udid", device.ID); err != nil {
		return fmt.Errorf("mount Developer Disk Image: %w", err)
	}
	return nil
}

func runSSH(ctx context.Context, options Options, command string) error {
	if _, err := exec.LookPath("sshpass"); err == nil {
		call := exec.CommandContext(ctx, "sshpass", "-p", options.SSHPassword, "ssh", "-p", fmt.Sprintf("%d", options.SSHPort), "-o", "UserKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no", "-o", "UpdateHostKeys=no", "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no", options.SSHUser+"@"+options.SSHHost, command)
		if output, err := call.CombinedOutput(); err != nil {
			return fmt.Errorf("%w: %s", err, bounded(output))
		}
		return nil
	}
	return errors.New("sshpass is required for non-interactive first pairing")
}

func uploadFile(ctx context.Context, options Options, source, destination string) error {
	if source == "" {
		return errors.New("source file is empty")
	}
	call := exec.CommandContext(ctx, "sshpass", "-p", options.SSHPassword, "scp", "-P", fmt.Sprintf("%d", options.SSHPort), "-o", "UserKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no", source, options.SSHUser+"@"+options.SSHHost+":"+destination)
	if output, err := call.CombinedOutput(); err != nil {
		return fmt.Errorf("%w: %s", err, bounded(output))
	}
	return nil
}

func runCommand(ctx context.Context, command string, args ...string) error {
	call := exec.CommandContext(ctx, command, args...)
	if output, err := call.CombinedOutput(); err != nil {
		return fmt.Errorf("%w: %s", err, bounded(output))
	}
	return nil
}

func installPlugin(ctx context.Context) error {
	if _, err := exec.LookPath("codex"); err != nil {
		return err
	}
	if err := runCommand(ctx, "codex", "plugin", "marketplace", "add", "https://github.com/castdrian/jb-p1lot", "--ref", "main"); err != nil {
		return err
	}
	return runCommand(ctx, "codex", "plugin", "add", "jb-p1lot@adrian")
}

func EnsureIdentity() (transport.Identity, error) {
	configRoot, err := os.UserConfigDir()
	if err != nil {
		return transport.Identity{}, err
	}
	root := filepath.Join(configRoot, "jb-p1lot", "identity")
	if err := os.MkdirAll(root, 0o700); err != nil {
		return transport.Identity{}, err
	}
	identity := transport.Identity{CAFile: filepath.Join(root, "ca.pem"), CADERFile: filepath.Join(root, "ca.der"), CAKeyFile: filepath.Join(root, "ca-key.pem"), CertificateFile: filepath.Join(root, "client.pem"), KeyFile: filepath.Join(root, "client-key.pem"), ServerCertificateFile: filepath.Join(root, "server.pem"), ServerKeyFile: filepath.Join(root, "server-key.pem"), ServerPKCS12File: filepath.Join(root, "server.p12")}
	if filesExist(identity.CAFile, identity.CADERFile, identity.CAKeyFile, identity.CertificateFile, identity.KeyFile, identity.ServerCertificateFile, identity.ServerKeyFile, identity.ServerPKCS12File) && identityValid(identity) {
		return identity, nil
	}
	caKey, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		return identity, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		return identity, err
	}
	now := time.Now().UTC()
	caKeyIdentifier := keyIdentifier(&caKey.PublicKey)
	caTemplate := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "jb-p1lot local CA"}, NotBefore: now.Add(-time.Minute), NotAfter: now.AddDate(10, 0, 0), IsCA: true, BasicConstraintsValid: true, SubjectKeyId: caKeyIdentifier, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		return identity, err
	}
	clientKey, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		return identity, err
	}
	clientSerial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		return identity, err
	}
	clientTemplate := &x509.Certificate{SerialNumber: clientSerial, Subject: pkix.Name{CommonName: "jb-p1lot host"}, DNSNames: []string{"jb-p1lot"}, NotBefore: now.Add(-time.Minute), NotAfter: now.AddDate(2, 0, 0), SubjectKeyId: keyIdentifier(&clientKey.PublicKey), AuthorityKeyId: caKeyIdentifier, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	clientDER, err := x509.CreateCertificate(rand.Reader, clientTemplate, caTemplate, &clientKey.PublicKey, caKey)
	if err != nil {
		return identity, err
	}
	if err := writePEM(identity.CAFile, "CERTIFICATE", caDER, 0o644); err != nil {
		return identity, err
	}
	if err := os.WriteFile(identity.CADERFile, caDER, 0o644); err != nil {
		return identity, err
	}
	if err := writePEM(identity.CAKeyFile, "RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(caKey), 0o600); err != nil {
		return identity, err
	}
	if err := writePEM(identity.CertificateFile, "CERTIFICATE", clientDER, 0o644); err != nil {
		return identity, err
	}
	if err := writePEM(identity.KeyFile, "RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(clientKey), 0o600); err != nil {
		return identity, err
	}
	serverKey, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		return identity, err
	}
	serverSerial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		return identity, err
	}
	serverTemplate := &x509.Certificate{SerialNumber: serverSerial, Subject: pkix.Name{CommonName: "jb-p1lot"}, DNSNames: []string{"jb-p1lot", "localhost"}, IPAddresses: nil, NotBefore: now.Add(-time.Minute), NotAfter: now.AddDate(2, 0, 0), SubjectKeyId: keyIdentifier(&serverKey.PublicKey), AuthorityKeyId: caKeyIdentifier, KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	serverDER, err := x509.CreateCertificate(rand.Reader, serverTemplate, caTemplate, &serverKey.PublicKey, caKey)
	if err != nil {
		return identity, err
	}
	if err := writePEM(identity.ServerCertificateFile, "CERTIFICATE", serverDER, 0o644); err != nil {
		return identity, err
	}
	if err := writePEM(identity.ServerKeyFile, "RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(serverKey), 0o600); err != nil {
		return identity, err
	}
	pkcs12 := exec.Command("openssl", "pkcs12", "-export", "-out", identity.ServerPKCS12File, "-inkey", identity.ServerKeyFile, "-in", identity.ServerCertificateFile, "-certfile", identity.CAFile, "-passout", "pass:")
	if output, err := pkcs12.CombinedOutput(); err != nil {
		return identity, fmt.Errorf("create server identity: %w: %s", err, bounded(output))
	}
	if err := os.Chmod(identity.ServerPKCS12File, 0o600); err != nil {
		return identity, err
	}
	return identity, nil
}

func filesExist(paths ...string) bool {
	for _, path := range paths {
		if _, err := os.Stat(path); err != nil {
			return false
		}
	}
	return true
}

func identityValid(identity transport.Identity) bool {
	readCertificate := func(path string) (*x509.Certificate, bool) {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, false
		}
		block, _ := pem.Decode(data)
		if block == nil {
			return nil, false
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		return certificate, err == nil
	}
	ca, caOK := readCertificate(identity.CAFile)
	client, clientOK := readCertificate(identity.CertificateFile)
	server, serverOK := readCertificate(identity.ServerCertificateFile)
	if !caOK || !clientOK || !serverOK {
		return false
	}
	if client.Subject.CommonName != "jb-p1lot host" || server.Subject.CommonName != "jb-p1lot" {
		return false
	}
	if !containsString(client.DNSNames, "jb-p1lot") || !containsString(server.DNSNames, "jb-p1lot") {
		return false
	}
	return len(ca.SubjectKeyId) > 0 && bytes.Equal(client.AuthorityKeyId, ca.SubjectKeyId) && bytes.Equal(server.AuthorityKeyId, ca.SubjectKeyId) && len(client.SubjectKeyId) > 0 && len(server.SubjectKeyId) > 0
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func keyIdentifier(publicKey any) []byte {
	der, err := x509.MarshalPKIXPublicKey(publicKey)
	if err != nil {
		return nil
	}
	identifier := sha1.Sum(der)
	return identifier[:]
}

func writePEM(path, kind string, data []byte, mode os.FileMode) error {
	value := pem.EncodeToMemory(&pem.Block{Type: kind, Bytes: data})
	if err := os.WriteFile(path, value, mode); err != nil {
		return err
	}
	return os.Chmod(path, mode)
}

func bounded(value []byte) string {
	const max = 8192
	value = []byte(strings.TrimSpace(string(value)))
	if len(value) > max {
		value = value[len(value)-max:]
	}
	return string(value)
}
