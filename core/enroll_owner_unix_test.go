//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestWriteSecretFileUsesRealUserWhenSetuid(t *testing.T) {
	if os.Geteuid() != 0 || os.Getuid() == 0 {
		t.Skip("requires a setuid-root test binary run by a non-root user")
	}
	path := filepath.Join(t.TempDir(), "setuid-secret.bin")
	if err := writeSecretFile(path, []byte("secret")); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatal("unexpected stat type")
	}
	if int(stat.Uid) != os.Getuid() || int(stat.Gid) != os.Getgid() {
		t.Fatalf(
			"secret owner is %d:%d, want real user %d:%d",
			stat.Uid,
			stat.Gid,
			os.Getuid(),
			os.Getgid(),
		)
	}
}
