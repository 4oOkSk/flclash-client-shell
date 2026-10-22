package resource

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestSafeWriteReplacesContentWithoutBroadeningPermissions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "provider.yaml")
	if err := os.WriteFile(path, []byte("previous"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := safeWrite(path, []byte("next")); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "next" {
		t.Fatalf("data=%q err=%v", data, err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	// Windows permissions are ACLs, not the synthetic Unix mode bits from Stat.
	// Content/replacement assertions remain active on every platform.
	if runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0 {
		t.Fatalf("permissions widened: %v", err)
	}
}

func TestFailedReplacementPreservesExistingTarget(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "existing-directory")
	if err := os.Mkdir(target, 0700); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(target, "sentinel")
	if err := os.WriteFile(sentinel, []byte("previous"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := safeWrite(target, []byte("new")); err == nil {
		t.Fatal("replacement unexpectedly succeeded")
	}
	data, err := os.ReadFile(sentinel)
	if err != nil || string(data) != "previous" {
		t.Fatal("existing target changed")
	}
	entries, _ := os.ReadDir(root)
	if len(entries) != 1 {
		t.Fatal("staged provider file leaked")
	}
}
