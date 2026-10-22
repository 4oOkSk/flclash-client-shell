package main

import (
	"context"
	"errors"
	"io"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/sync/semaphore"
)

type tunCallbackTestCloser func() error

func (closeListener tunCallbackTestCloser) Close() error {
	return closeListener()
}

func TestCloseTunAllowsTeardownCallbacksAfterDetaching(test *testing.T) {
	limit := semaphore.NewWeighted(tunCallbackConcurrency)
	closeError := errors.New("close result")
	err := closeTunAfterCallbacks(limit, func() io.Closer {
		if limit.TryAcquire(1) {
			limit.Release(1)
			test.Fatal("callback state was detached without exclusivity")
		}
		return tunCallbackTestCloser(func() error {
			if !limit.TryAcquire(1) {
				test.Fatal("listener teardown would deadlock while draining callbacks")
			}
			limit.Release(1)
			return closeError
		})
	})
	if !errors.Is(err, closeError) {
		test.Fatalf("close result = %v, want %v", err, closeError)
	}
}

func TestCloseTunWaitsForInFlightCallback(test *testing.T) {
	limit := semaphore.NewWeighted(tunCallbackConcurrency)
	if err := limit.Acquire(context.Background(), 1); err != nil {
		test.Fatal(err)
	}
	var callbackFinished atomic.Bool
	detached := make(chan bool, 1)
	completed := make(chan error, 1)
	go func() {
		completed <- closeTunAfterCallbacks(limit, func() io.Closer {
			detached <- callbackFinished.Load()
			return nil
		})
	}()
	select {
	case <-detached:
		test.Fatal("detached a live callback")
	case <-time.After(20 * time.Millisecond):
	}
	callbackFinished.Store(true)
	limit.Release(1)
	select {
	case err := <-completed:
		if err != nil || !<-detached {
			test.Fatalf("callback drain failed: %v", err)
		}
	case <-time.After(time.Second):
		test.Fatal("callback drain did not complete")
	}
	if !limit.TryAcquire(tunCallbackConcurrency) {
		test.Fatal("callback permits leaked")
	}
	limit.Release(tunCallbackConcurrency)
}
