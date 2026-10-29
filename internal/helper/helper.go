package helper

import (
	"os"
	"os/exec"
	"path/filepath"
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
