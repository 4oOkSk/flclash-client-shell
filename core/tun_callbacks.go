package main

import (
	"context"
	"io"

	"golang.org/x/sync/semaphore"
)

const tunCallbackConcurrency = 4

func closeTunAfterCallbacks(limit *semaphore.Weighted, detach func() io.Closer) error {
	if err := limit.Acquire(context.Background(), tunCallbackConcurrency); err != nil {
		return err
	}
	listener := func() io.Closer {
		defer limit.Release(tunCallbackConcurrency)
		return detach()
	}()
	if listener == nil {
		return nil
	}
	return listener.Close()
}
