package helper

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const IdeviceName = "jb-p1lot-idevice"

func Idevice() (string, error) {
	if executable, err := os.Executable(); err == nil {
		beside := filepath.Join(filepath.Dir(executable), IdeviceName)
		if info, statErr := os.Stat(beside); statErr == nil && !info.IsDir() {
			return beside, nil
		}
	}
	return exec.LookPath(IdeviceName)
}

type Forward struct {
	PID        int
	LocalPort  int
	RemotePort int
}

func ForwardCommand(deviceID string, localPort, remotePort int) (*exec.Cmd, error) {
	tool, err := Idevice()
	if err != nil {
		return nil, err
	}
	return exec.Command(tool, "forward", strconv.Itoa(localPort), strconv.Itoa(remotePort), "-u", deviceID), nil
}

func ParseForward(line, deviceID string) (Forward, bool) {
	fields := strings.Fields(line)
	if len(fields) < 7 || filepath.Base(fields[1]) != IdeviceName || fields[2] != "forward" || fields[5] != "-u" || fields[6] != deviceID {
		return Forward{}, false
	}
	pid, pidErr := strconv.Atoi(fields[0])
	local, localErr := strconv.Atoi(fields[3])
	remote, remoteErr := strconv.Atoi(fields[4])
	if pidErr != nil || localErr != nil || remoteErr != nil {
		return Forward{}, false
	}
	return Forward{PID: pid, LocalPort: local, RemotePort: remote}, true
}
