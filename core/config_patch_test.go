package main

import "testing"

func TestConfigPatchPreservesOmittedAndPublishesExplicitZero(test *testing.T) {
	current, disabled := true, false
	publications := 0
	publish := func(value bool) {
		publications++
		if value || current != value {
			test.Fatal("publisher did not observe the applied false value")
		}
	}
	patchConfigValue(&current, nil, publish)
	if !current || publications != 0 {
		test.Fatal("omitted field changed configuration")
	}
	patchConfigValue(&current, &disabled, publish)
	patchConfigValue(&current, &disabled, publish)
	if current || publications != 2 {
		test.Fatal("explicit patches must publish, including unchanged values")
	}
}
