package provision

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestHelperInstallsFromTheCheckoutWhenItIsThere(t *testing.T) {
	root := t.TempDir()
	manifest := filepath.Join(root, "helpers", "idevice", "Cargo.toml")
	if err := os.MkdirAll(filepath.Dir(manifest), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(manifest, []byte("[package]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	want := []string{"install", "--locked", "--path", filepath.Dir(manifest)}
	if got := helperInstallArgs(root); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestHelperInstallsFromTheRepositoryOutsideACheckout(t *testing.T) {
	want := []string{"install", "--locked", "--git", helperRepository, "jb-p1lot-idevice"}
	if got := helperInstallArgs(t.TempDir()); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}
