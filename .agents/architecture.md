# Architecture

## Core Integration

The Go proxy core in `core/` operates in two modes.

Android lib mode:

- Go core is compiled as a C shared library, `libclash.so`, through `go build -buildmode=c-shared` with CGO.
- The Android `:core` module owns JNI access to the in-process library. Flutter crosses the `${packageName}/service`
  MethodChannel through `lib/plugins/service.dart` and Android's `ServicePlugin` rather than talking to JNI directly.
- `lib/core/lib.dart` (`CoreLib`) implements the shared Core interface, gates method calls on its connection completer,
  initializes and synchronizes Android shared state, and closes the native service path exactly once.
- Because Core is in the application process on Android, application RSS already includes Core memory.

Desktop core mode:

- Go core runs as a separate process with `CGO_ENABLED=0`.
- `rust_api` provides the native local-IPC primitives: a Unix domain socket on macOS/Linux and a named pipe on Windows.
  Dart now owns the transport state, RPC correlation, process ownership, and lifecycle convergence above those primitives.
- `lib/core/service.dart` (`CoreService`) is the composition root. It wires the IPC transport, launcher selection,
  lifecycle controller, RPC client, and crash-event bridge; it is no longer the whole desktop implementation by itself.
- `lib/core/desktop/transport.dart` converts native IPC frames into ready, connected, disconnected, failed, and data
  events. A replaceable binding keeps RPC subscriptions stable when a failed or stale transport must be rebuilt.
- `lib/core/desktop/rpc_client.dart` owns request IDs and pending completers, waits up to 10 seconds for a connection,
  applies a three-minute default method timeout, unwraps `CoreMethodResponse`, and fails all pending calls when transport
  disconnects or closes.
- `lib/core/desktop/lifecycle.dart` serializes process intents and owns the authoritative desktop state machine.
- `lib/core/desktop/launcher.dart` owns direct child-process launch through idempotent process leases. Windows supplies
  a pre-spawn executable verifier and runs the elevated GUI/Core pair inside one kill-on-close Job Object.

`lib/core/controller.dart` (`CoreController`) selects the implementation based on platform. `lib/core/interface.dart` defines the shared `CoreHandlerInterface`.

Key Go core files:

- `core/hub.go`: handler functions.
- `core/method.go`: MethodChannel-style method-call dispatch and response envelopes.
- `core/message.go`: non-blocking priority/bulk event queues and bounded message batching.
- `core/lib.go`: CGO exports.
- `core/server.go`: desktop socket/named-pipe client and framed message forwarding.

## Lifecycle Ownership And Convergence

### Shared Flutter Layer

`CoreController.start()`, `restart()`, `stop()`, and `close()` are the only shared lifecycle facade. `close()` is terminal;
callers must not try to reuse a closed platform implementation.

`CoreAction` in `lib/providers/actions/core.dart` owns the user-facing Core status and setup sequence:

- `startCore()` publishes `connecting`, starts the platform Core, publishes `connected`, then initializes Core state. A
  startup error publishes `disconnected` and displays the error.
- `restartCore()` coalesces overlapping callers behind one worker. `_requestedRestartRevision` records newer requests,
  while `_latestExplicitStart` retains the newest requested post-restart running intent. After the lifecycle restart and
  `initCore()`, the worker reapplies profile/running state until it has consumed the latest revision.
- The provider is an orchestration and presentation layer, not a process owner. Platform lifecycle code remains responsible
  for determining whether a Core process/service is actually running.

Application exit is centralized in `SystemAction` and `SystemExitCoordinator`:

1. Optionally save config and clean up DNS, system proxy, and tray resources in parallel.
2. Close the desktop window.
3. Call terminal `CoreController.close()`.
4. Exit the application exactly once.

The coordinator is idempotent, continues later cleanup steps after an earlier error, preserves the first error for the
caller, and uses a three-second watchdog as an emergency application-exit path. `Application.dispose()` and
`CoreManager.onCrash()` do not independently destroy Core; this avoids competing shutdown owners.

### Desktop Lifecycle

`DesktopCoreLifecycle` is a latest-desired-intent reconciler, not a queue that blindly executes every request:

- Public intents receive monotonically increasing revisions and target running, restarted, stopped, or closed.
- Observable phases are `idle`, `starting`, `running`, `stopping`, `failed`, and `closed`.
- A completed command reports `applied`, `coalesced`, or `superseded`, allowing callers and tests to distinguish a command
  that won from one satisfied or replaced by a newer compatible intent.
- Startup opens or replaces the IPC transport, resolves a launcher, generates a 128-bit lowercase hexadecimal session ID,
  launches Core, and waits for the matching connection. Windows additionally verifies that the named-pipe peer PID equals
  the direct child PID.
- Each running session retains its process owner, lease, PID, session ID, and transport connection generation. Stop waits
  for both process-exit confirmation and the matching disconnect generation; a missing disconnect replaces the transport
  before later starts.
- An unconfirmed process exit is retained as an unconfirmed lease. New start/restart intents fail until ownership can be
  cleaned up, preventing two Core instances from being treated as the active session. Terminal close may continue on a
  best-effort basis because the application is exiting.
- An unexpected disconnect or transport failure while running is converted to `DesktopCoreFailure`, the owned process is
  cleaned up, and `CoreService` emits a Core crash event for the normal UI recovery path.

Direct launch is used on every desktop platform. On Windows the GUI is already elevated, verifies the packaged Core hash
before each spawn, and owns the direct child through both the Dart lease and the runner Job Object.

### Android Service Lifecycle

Android deliberately keeps Flutter requests optimistic and the native layer authoritative:

- `ServicePlugin.start()` and `stop()` acknowledge immediately after submitting intent. They do not wait for service
  creation, VPN permission, binding, TUN establishment, or teardown.
- `ServiceState` owns the latest `RunRequest`, shared configuration, run time, and `STOPPED`/`STARTING`/`STARTED`/`STOPPING`
  state. Identity checks discard obsolete work. `startPreparationLock` serializes permission/setup preparation and
  `transitionLock` serializes actual service transitions.
- `ServiceController` owns exactly one `ManagedServiceBinding`, selects `VpnService` or `ProxyService` from `VpnOptions`,
  binds with a five-second connection timeout, invokes `ManagedService.start()`/`stop()` off the main thread, and clears
  binding/run-time state on failure or disconnection.
- Generic service creation/destruction is lifecycle evidence, not user intent. New commands must flow through
  `ServiceState.requestStart()`/`requestStop()` or the explicit system-action handlers instead of inferring intent from a
  callback.

Quick Settings, notification, revoke, and Always-on VPN paths converge on the same owner:

- With a Flutter engine attached, `ServiceState.handleStartAction()`/`handleStopAction()` forward through `TilePlugin` to
  `TileManager`, which updates normal Flutter setup state. Without Flutter, native code restores `SharedState` from
  preferences, runs `quickSetup`, checks VPN permission, and submits the native request directly.
- Android may create an Always-on `VpnService` through `onStartCommand()` without FlClash's bound-service path. The service
  sends the explicit, permission-protected `VPN_START_REQUESTED` broadcast to `ServiceBroadcastReceiver`, which routes it to
  `ServiceState.handleStartAction()` so Core/configuration and the normal binding are restored before TUN is treated as
  ready.
- `VpnService.onRevoke()` stops TUN/modules first, then sends `VPN_REVOKED`; the receiver only requests a stop when
  `ServiceController` still owns an active VPN binding.
- `ServiceBroadcastReceiver` uses `goAsync()` and an atomic one-shot completion. Normal completion or a nine-second
  watchdog calls `PendingResult.finish()` exactly once; the watchdog releases Android's broadcast lease and does not
  cancel or redefine the underlying lifecycle intent.

## Core Protocol And Event Delivery

The shared protocol uses `CoreMethodCall(id, method, arguments)` and `CoreMethodResponse(id, result, error)` in both
directions. The envelope is the only JSON serialization layer: keep arguments, results, and event data as structured JSON
values rather than embedding pre-encoded JSON strings. Plain domain strings, such as country codes or provider contents,
remain strings.

Go event delivery is intentionally non-blocking:

- State-bearing events such as delay, loaded-provider, and geo-update use a 256-entry priority queue. Desktop process
  crashes are generated locally by `CoreService` from lifecycle failures rather than sent through the Go queue.
- High-volume log and request/connection events use a separate 256-entry bulk queue, so bulk floods cannot evict state.
- A full queue evicts only its own oldest event and retries the newest event; Core work never blocks on event delivery.
- The batcher flushes at 32 messages or every 16 milliseconds. Priority events are preferred, but one bulk opportunity is
  guaranteed after eight priority messages to prevent starvation.

Desktop RPC accepts both a single event object and batched event lists. Android and desktop listener dispatch isolate
listener exceptions so one faulty observer does not prevent the remaining events/listeners from running.

## User-Facing Core And Delay Feedback

`CoreStatusButton` in `lib/views/dashboard/widgets/core_status_button.dart` is the desktop dashboard's status/restart
surface. It is shown only outside dashboard edit mode and only when `coreLib == null`:

- Provider state remains authoritative. The widget keeps a separate display-only status so a fast
  `connecting -> connected` transition still shows at least 600 milliseconds of progress instead of flashing.
- The hold arms only after an observed transition to `connecting`; mounting while already connecting does not invent a new
  delay. A real `disconnected` transition cancels the hold immediately so failure is never hidden, while a long-running
  connecting state remains visible after the timer expires.
- Taps during the display hold or while the provider is genuinely connecting are inert. Connected/disconnected taps show
  the appropriate confirmation and delegate restart to `CoreAction`; the widget never starts Core directly.

Proxy delay testing follows the same failure-safe UI rule. `proxyDelayTest()` records an in-progress zero delay, writes the
real result on success, and logs plus records `-1` on exceptions. `DelayTestButton` reverses its animation in `finally`, so
an RPC failure cannot leave the control permanently spinning.

## State Management

Provider files in `lib/providers/`:

- `app.dart`: runtime/UI state, logs, traffic, delays, loading, navigation.
- `config.dart`: persistent config providers, app settings, theme, VPN, proxy style.
- `state.dart`: derived/computed providers, navigation, proxy, tray, color scheme.
- `action.dart`: business logic notifiers, setup, backup, core lifecycle, proxy selection.
- `database.dart`: Drift database provider wrappers.

`globalState` in `lib/state.dart` is a singleton holding app lifecycle, timers, theme, and start/stop state. Providers are generated into `lib/providers/generated/`.

## Database

The app uses Drift/SQLite in `lib/database/`. Current schema version is 2.

Tables:

- `Profiles`
- `Scripts`
- `Rules`
- `ProfileRuleLinks` (`profile_rule_mapping`)
- `ProxyGroups`
- `IconRecords` (`icon_records`)

Rule scenes distinguish global added rules, profile added rules, profile custom rules, and disabled links. Rule and proxy-group ordering use fractional indexing.

Generated Drift output lives in `lib/database/generated/database.g.dart`. After schema changes, run code generation and add or update focused database tests under `test/database/` when converter or migration behavior changes.

## Manager Stack

Managers are nested `InheritedWidget`/`StatefulWidget` components in `lib/application.dart`:

```text
AppEnvManager > StatusManager > ThemeManager
  > [Desktop: WindowManager > TrayManager > HotKeyManager > ProxyManager]
  > ConnectivityManager > CoreManager > AppStateManager
  > [Mobile: AndroidManager > VpnManager | Desktop: WindowHeaderContainer]
```

Each manager in `lib/manager/` handles a specific platform concern. Desktop-only managers are conditionally inserted.

## Core Controller and Actions

`lib/core/controller.dart` (`CoreController`) is a singleton facade over `CoreHandlerInterface`. Public methods delegate to the platform-specific interface, either Android FFI or desktop socket. It has an `@visibleForTesting` constructor and `resetInstance()` for test injection.

`lib/providers/action.dart` is the public library entry point for action
providers. The Riverpod notifier implementations are split by responsibility
under `lib/providers/actions/` and joined to the entry point with `part`
directives, so consumers continue to import the same public API:

- `CommonAction`: update check and common UI operations.
- `SetupAction`: config setup and TUN management.
- `BackupAction`: backup/restore with WebDAV sync.
- `CoreAction`: core lifecycle, initialization, coalesced restart, and post-restart profile/running-state application.
- `SystemAction`: system integration, tray, coordinated resource cleanup, terminal Core close, exit, and brightness.
- `StoreAction`: profile storage operations.
- `ThemeAction`: theme state updates.
- `ProxiesAction`: group management and proxy selection.
- `ProfilesAction`: profile CRUD, auto-update, import.
- `GeoResourceAction`: geo resource updates and URL configuration.

## Platform Managers

Desktop:

- `WindowManager`
- `TrayManager`
- `HotKeyManager`
- `ProxyManager`

Mobile:

- `AndroidManager`
- `TileManager`
- `VpnManager`

Shared:

- `ConnectivityManager`
- `CoreManager`
- `AppStateManager`
- `StatusManager`
- `ThemeManager`

## Build System

`setup.dart` is the release build orchestrator:

1. Writes a private temporary Dart define file. Windows first builds the Core and embeds its exact SHA256.
2. Activates `flutter_distributor` for packaging.
3. Relies on the platform build hook to build the required Core artifacts before
   the native application is linked.

Go core building is handled by `build_tool`, a standalone Dart CLI in `plugins/setup/buildkit/build_tool/`.

Platform build hooks inside `flutter build` trigger `build_tool` automatically:

- macOS: podspec script phase, `build_pod.sh`, `build_tool macos`.
- Linux: CMake include, `buildkit/cmake/buildkit.cmake`, `build_tool linux`.
- Windows: CMake include, `buildkit/cmake/buildkit.cmake`, `build_tool windows`. CMake forwards the active configuration through `BUILDKIT_CONFIGURATION`.
- Android: Gradle include, `buildkit/gradle/plugin.gradle`, `build_tool android`.

### Setup Build Harness Plugin

`plugins/setup/` is a build-time Flutter plugin, not a runtime Dart or FFI API. Its plugin shape exists so Flutter's native
build graphs can run the Go build harness before platform consumers need the generated artifacts. Application code
must not import or call it.

Responsibilities are deliberately split:

- CocoaPods, Gradle, and CMake hooks schedule a lightweight check on every native build. They do not decide which Go files
  are stale.
- `buildkit/build_tool/` owns target resolution, input fingerprinting, compilation, output copying, and cache validation.
- `core/` remains the source owner; `libclash/` and Android `jniLibs`/header directories are generated
  output locations.
- `setup.dart` remains the release/package orchestrator. For Windows it pre-builds the Core, reads the generated
  `manifest.json`, and injects that SHA256 with `dart-define` before Flutter compilation. The native Windows hook then
  reuses the same cached Core and bundles both artifacts.

Platform outputs remain explicit:

- Android builds the Go core as `c-shared`, then copies `libclash.so` and generated headers into the `:core` Android module.
- macOS and Linux build a standalone `FlClashCore` process used by the desktop socket integration.
- Windows builds `HarborProxyCore.exe` and a `manifest.json` containing only `coreSha256`.

The hooks follow rust_api/Cargokit's phony-output scheduling pattern, but setup uses its own Go-core cache. Per-target
records live under `.dart_tool/setup_build_cache/v1/`:

- Go fingerprints cover the target-specific `go list -deps` inputs inside `core/` and `Clash.Meta`, module files, effective
  build configuration, build-tool sources, target flags, Go environment/toolchain, and Android NDK compiler details.
- A cache hit requires the fingerprint and every recorded output's path, size, and modification state to match. It exits
  silently without Go compilation or output copying.
- Cache records are written only after a successful build and protected by per-target process/file locks. Missing outputs,
  changed inputs, cache-schema changes, or `--force` rebuild only the affected target.
- `flutter clean` removes `.dart_tool`, so the next native build performs one full core rebuild. Manual builds can bypass
  the cache with `make core-<platform> FORCE=1`.

This differs from `rust_api`: rust_api is a runtime Flutter Rust Bridge integration whose Cargokit hooks produce its native
FFI library, while setup is only the build and packaging bridge for FlClash's external core artifacts.

Windows direct-Core integrity:

- The build tool constructs the Core first and writes its SHA256 to `manifest.json`; `setup.dart` embeds the same value in
  the Flutter application before packaging.
- The GUI manifest requests administrator privileges for the whole interactive lifecycle. There is no helper service and
  no unelevated fallback.
- Authorization and `DirectCoreLauncher` both fail closed when the packaged Core does not match the embedded SHA256. The
  launcher checks immediately before `Process.start` so a mismatched executable is never spawned elevated.
- Flutter creates a random named-pipe address per start and verifies the connected peer PID against its direct child PID.
- The Windows runner assigns itself to a kill-on-close Job Object. Because the Core is its direct child, an abnormal GUI
  exit cannot leave the elevated Core behind. Installers only retain helper references to remove retired installations.

Build configuration defaults live in `build_tool/lib/src/options.dart` and can be overridden via a root `build_config.yaml`.

Architecture detection is automatic; macOS release packaging defaults to Universal 2 (`arm64` + `x86_64`). The
`--description` flag adds architecture suffixes to artifacts.

## Local Plugins

- `setup`: build-time harness for Go core artifacts; no runtime Dart API.
- `proxy`: system proxy configuration.
- `rust_api`: runtime Flutter Rust Bridge FFI plugin built through Cargokit.
- `tray_manager`: system tray fork/customization.
- `wifi_ssid`: Wi-Fi SSID detection.
- `window_ext`: window extensions.
- `flutter_distributor`: app packaging/distribution.

## Windows Privilege Boundary

The Windows runner is the only privilege boundary. It is elevated by the application manifest, starts only the packaged
`HarborProxyCore.exe` after Dart verifies the embedded release hash, and owns the child lifetime through its Job Object.
Fresh packages contain no helper binary or service. The installer and SFX updater stop and delete the retired
`HarborProxyHelperService` only to clean upgrades from older releases.
