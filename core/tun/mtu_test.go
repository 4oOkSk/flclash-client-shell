package tun

import "testing"

func TestAndroidTUNMTUUsesOrdinaryUnderlayCeiling(t *testing.T) {
	if androidTUNMTU != 1500 {
		t.Fatalf("android TUN MTU = %d, want 1500", androidTUNMTU)
	}
}
