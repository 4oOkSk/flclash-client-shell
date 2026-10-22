package updater

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/metacubex/mihomo/constant"
)

func TestGeoUpdaterPreservesScheduleAndStopsWhenDisabled(test *testing.T) {
	oldAutoUpdate, oldInterval := GeoAutoUpdate(), GeoUpdateInterval()
	geoUpdateMu.Lock()
	oldTask := geoUpdateTask
	cancelled := 0
	done := make(chan struct{})
	task := &geoUpdaterTask{
		interval: time.Hour,
		done:     done,
		cancel: func() {
			cancelled++
			close(done)
		},
	}
	geoUpdateTask = task
	geoUpdateMu.Unlock()
	test.Cleanup(func() {
		geoUpdateMu.Lock()
		geoUpdateTask = oldTask
		autoUpdate, updateInterval = oldAutoUpdate, oldInterval
		geoUpdateMu.Unlock()
	})
	SetGeoAutoUpdate(true)
	SetGeoUpdateInterval(1)
	RegisterGeoUpdaterWithCancel()
	RegisterGeoUpdater()
	if geoUpdateTask != task || cancelled != 0 {
		test.Fatal("unchanged policy replaced the live schedule")
	}
	SetGeoAutoUpdate(false)
	RegisterGeoUpdaterWithCancel()
	RegisterGeoUpdaterWithCancel()
	if geoUpdateTask != nil || cancelled != 1 {
		test.Fatalf("disabled schedule: task=%v cancellations=%d", geoUpdateTask != nil, cancelled)
	}
}

func TestGeoUpdaterReplacesCompletedSchedule(test *testing.T) {
	oldHome := constant.Path.HomeDir()
	constant.SetHomeDir(test.TempDir())
	test.Cleanup(func() { constant.SetHomeDir(oldHome) })
	if err := os.WriteFile(constant.Path.GeoIP(), []byte("schedule timestamp fixture"), 0600); err != nil {
		test.Fatal(err)
	}
	oldAutoUpdate, oldInterval := GeoAutoUpdate(), GeoUpdateInterval()
	geoUpdateMu.Lock()
	oldTask := geoUpdateTask
	done := make(chan struct{})
	close(done)
	completed := &geoUpdaterTask{interval: time.Hour, cancel: func() {}, done: done}
	geoUpdateTask = completed
	geoUpdateMu.Unlock()
	test.Cleanup(func() {
		geoUpdateMu.Lock()
		active := geoUpdateTask
		if active != nil && active != oldTask {
			active.cancel()
		}
		geoUpdateTask = oldTask
		autoUpdate, updateInterval = oldAutoUpdate, oldInterval
		geoUpdateMu.Unlock()
		if active != nil && active != oldTask {
			select {
			case <-active.done:
			case <-time.After(time.Second):
				test.Error("scheduler did not stop before fixture cleanup")
			}
		}
	})
	SetGeoAutoUpdate(true)
	SetGeoUpdateInterval(1)
	RegisterGeoUpdaterWithCancel()
	task := geoUpdateTask
	if task == nil || task == completed {
		test.Fatal("completed schedule was treated as live")
	}
	SetGeoUpdateInterval(2)
	RegisterGeoUpdaterWithCancel()
	replacement := geoUpdateTask
	if replacement == nil || replacement == task || replacement.interval != 2*time.Hour {
		test.Fatal("changed interval did not replace the schedule")
	}
	select {
	case <-task.done:
	case <-time.After(time.Second):
		test.Fatal("replaced scheduler did not terminate")
	}
	SetGeoUpdateInterval(0)
	RegisterGeoUpdaterWithCancel()
	if geoUpdateTask != nil {
		test.Fatal("invalid interval did not stop the schedule")
	}
	select {
	case <-replacement.done:
	case <-time.After(time.Second):
		test.Fatal("cancelled scheduler did not terminate")
	}
}

func TestGeoUpdaterRetriesFailuresAndBusyUpdates(test *testing.T) {
	for _, scenario := range []string{"overdue", "missing timestamp", "fresh"} {
		test.Run(scenario, func(test *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			calls := make(chan int, 4)
			done := make(chan struct{})
			go func() {
				defer close(done)
				attempt := 0
				runGeoUpdater(ctx, 40*time.Millisecond, 5*time.Millisecond,
					func() (time.Time, error) {
						if scenario == "missing timestamp" {
							return time.Time{}, errors.New("missing")
						}
						if scenario == "fresh" {
							return time.Now(), nil
						}
						return time.Now().Add(-time.Hour), nil
					},
					func() error {
						attempt++
						calls <- attempt
						if attempt == 1 {
							return errors.New("temporary network failure")
						}
						if attempt == 2 {
							return ErrGetDatabaseUpdateSkip
						}
						return nil
					},
				)
			}()
			for expected := 1; expected <= 3; expected++ {
				select {
				case actual := <-calls:
					if actual != expected {
						test.Fatalf("attempt=%d want=%d", actual, expected)
					}
				case <-time.After(time.Second):
					test.Fatal("scheduler stopped after a recoverable failure")
				}
			}
			cancel()
			select {
			case <-done:
			case <-time.After(time.Second):
				test.Fatal("scheduler ignored cancellation")
			}
		})
	}
}

func TestGeoUpdaterDoesNotUpdateAfterCancellation(test *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	runGeoUpdater(ctx, time.Hour, time.Minute,
		func() (time.Time, error) { return time.Time{}, nil },
		func() error {
			test.Error("cancelled scheduler attempted an update")
			return nil
		},
	)
}

func TestGeoDatabaseUpdatesAreExclusiveAndRecoverAfterFailure(test *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	finished := make(chan error, 1)
	test.Cleanup(func() {
		select {
		case <-release:
		default:
			close(release)
		}
	})
	updateErr := errors.New("temporary failure")
	go func() {
		finished <- runGeoDatabaseUpdate(func() error {
			close(entered)
			<-release
			return updateErr
		})
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		test.Fatal("first update did not start")
	}
	if err := runGeoDatabaseUpdate(func() error {
		test.Error("overlapping updater entered the critical section")
		return nil
	}); !errors.Is(err, ErrGetDatabaseUpdateSkip) {
		test.Errorf("overlapping update returned %v", err)
	}
	close(release)
	if err := <-finished; !errors.Is(err, updateErr) {
		test.Fatalf("initial update returned %v", err)
	}
	if err := runGeoDatabaseUpdate(func() error { return nil }); err != nil {
		test.Fatalf("failed update left the lock occupied: %v", err)
	}
}
