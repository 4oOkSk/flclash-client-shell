//go:build linux

package tun

import (
	"os"
	"testing"
)

func TestBorrowedDescriptorSurvivesListenerClose(t *testing.T) {
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer read.Close()
	defer write.Close()
	device, err := New(Options{FileDescriptor: int(read.Fd())})
	if err != nil {
		t.Fatal(err)
	}
	if err := device.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := write.Write([]byte{7}); err != nil {
		t.Fatal(err)
	}
	data := make([]byte, 1)
	if _, err := read.Read(data); err != nil || data[0] != 7 {
		t.Fatalf("platform descriptor was closed: %v", err)
	}
}
