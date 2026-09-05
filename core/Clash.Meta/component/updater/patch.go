package updater

import (
	"context"
	"sync"
	"time"

	"github.com/metacubex/mihomo/log"
)

var (
	GeoUpdateHook func(geoType string, updating bool, skipped bool, updateErr error)
)

func sendGeoUpdateStatus(geoType string, updating bool, skipped bool, updateErr error) {
	if GeoUpdateHook != nil {
		GeoUpdateHook(geoType, updating, skipped, updateErr)
	}
}

type geoUpdaterTask struct {
	interval time.Duration
	cancel   context.CancelFunc
	done     chan struct{}
}

var geoUpdateMu sync.Mutex
var geoUpdateTask *geoUpdaterTask

func RegisterGeoUpdaterWithCancel() {
	geoUpdateMu.Lock()
	defer geoUpdateMu.Unlock()

	interval := time.Duration(updateInterval) * time.Hour
	if autoUpdate && interval > 0 && geoUpdateTask != nil && geoUpdateTask.interval == interval {
		select {
		case <-geoUpdateTask.done:
		default:
			return
		}
	}
	if geoUpdateTask != nil {
		geoUpdateTask.cancel()
		geoUpdateTask = nil
	}
	if !autoUpdate || interval <= 0 {
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	task := &geoUpdaterTask{interval: interval, cancel: cancel, done: make(chan struct{})}
	geoUpdateTask = task
	go func() {
		defer close(task.done)
		runGeoUpdater(ctx, interval, 5*time.Minute, getUpdateTime, UpdateGeoDatabases)
	}()
}

func runGeoUpdater(
	ctx context.Context,
	interval time.Duration,
	retryInterval time.Duration,
	lastUpdate func() (time.Time, error),
	update func() error,
) {
	if ctx.Err() != nil {
		return
	}
	delay := time.Duration(0)
	if updatedAt, err := lastUpdate(); err == nil {
		delay = time.Until(updatedAt.Add(interval))
		if delay < 0 {
			delay = 0
		} else if delay > interval {
			delay = interval
		}
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			if ctx.Err() != nil {
				return
			}
			delay = interval
			if err := update(); err != nil {
				log.Errorln("[GEO] Failed to update GEO database: %s", err.Error())
				if retryInterval > 0 && retryInterval < interval {
					delay = retryInterval
				}
			}
			timer.Reset(delay)
		}
	}
}
