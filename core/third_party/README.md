# Pinned TUN dependency

`sing-tun/` is the unmodified Go module distribution of
`github.com/metacubex/sing-tun v0.4.22` (commit
`dfc71de64aed159d9a09a5df43077bab0671db1f`), except for the nil-dispatcher guard in
`stack_gvisor_filter.go`. The upstream license and embedded Wintun files are
preserved. The parent `core/go.mod` replacement applies to every client target;
standalone builds of the nested Mihomo module do not use this replacement.

Original module checksum: `h1:6ARRJ2BIFD1u4r/DTMNcxaNuGyimfXEeUyD4iFJRaZs=`.

`LinkEndpointFilter.Attach(nil)` must forward nil to the wrapped endpoint.
Wrapping it in a non-nil filter suppresses the fdbased endpoint's eventfd stop
and reader join. Closing the TUN descriptor then leaves a polling reader holding
the interface alive after the native stop call has returned.

Regression tests live in the parent module and run with its existing CI command:

```sh
go test -tags with_gvisor -run 'TestTunFilter|TestGVisorCloseStopsPendingRead' .
```

The pending-read test uses a local Unix socket pair, not a privileged TUN or an
external network. The Android release check must also measure natural interface
removal, keep the app alive, and reconnect successfully: process termination,
debugger signals and forced garbage collection can mask the original defect.

When updating this dependency, compare against the pinned module distribution,
retain the guard until upstream forwards nil itself, and run these regressions.
Remove this local copy and the replacement together once a tested upstream
version contains the fix. Do not edit a machine's Go module cache as a release
patch mechanism.
