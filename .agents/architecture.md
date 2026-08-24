# Architecture

## Core Integration

The Go proxy core in `core/` operates in two modes.

Android lib mode:

- Go core is compiled as a C shared library, `libclash.so`, through `go build -buildmode=c-shared` with CGO.
- Flutter calls it via FFI through the `service` plugin.
- Dart-side implementation: `lib/core/lib.dart` (`CoreLib`).

Desktop core mode:

- Go core runs as a separate process with `CGO_ENABLED=0`.
- Flutter communicates via JSON over socket, using a Unix socket on macOS/Linux and TCP on Windows.
- Dart-side implementation: `lib/core/service.dart` (`CoreService`).

`lib/core/controller.dart` (`CoreController`) selects the implementation based on platform. `lib/core/interface.dart` defines the shared `CoreHandlerInterface`.

Key Go core files:

- `core/hub.go`: handler functions.
- `core/action.go`: dispatch.
- `core/lib.go`: CGO exports.
- `core/server.go`: socket server.

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

Business logic lives in Riverpod notifier classes in `lib/providers/action.dart`:

- `CommonAction`: update check and common UI operations.
- `SetupAction`: config setup and TUN management.
- `BackupAction`: backup/restore with WebDAV sync.
- `CoreAction`: core lifecycle, init, connect, restart, shutdown.
- `SystemAction`: system integration, tray, exit, brightness.
- `StoreAction`: profile storage operations.
- `ThemeAction`: theme state updates.
- `ProxiesAction`: group management and proxy selection.
- `ProfilesAction`: profile CRUD, auto-update, import.

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

1. On Windows, pre-builds Go core via `dart run build_tool windows` and reads `core_sha256.json`.
2. Writes `env.json` (`APP_ENV`).
3. Passes SHA256 as `--dart-define=CORE_SHA256=$val`, embedded at compile time for Windows.
4. Activates `flutter_distributor` for packaging.

Go core building is handled by `build_tool`, a standalone Dart CLI in `plugins/setup/buildkit/build_tool/`.

Platform build hooks inside `flutter build` trigger `build_tool` automatically:

- macOS: podspec script phase, `build_pod.sh`, `build_tool macos`.
- Linux: CMake include, `buildkit/cmake/buildkit.cmake`, `build_tool linux`.
- Windows: CMake include, `buildkit/cmake/buildkit.cmake`, `build_tool windows`. Debug passes `--dev` via `CMAKE_BUILD_TYPE`.
- Android: Gradle include, `buildkit/gradle/plugin.gradle`, `build_tool android`.

Windows direct core:

- The GUI requests administrator privileges through its manifest and starts
  `HarborProxyCore.exe` directly.
- Release builds embed the core SHA256 in the Flutter app and refuse to launch
  a mismatched core. Debug builds skip this release-integrity check.
- The runner assigns itself and its child core to a kill-on-close Windows Job
  Object so an abnormal GUI exit does not leave the core running.

`plugins/setup/` is an FFI plugin that exists only as a build harness. It
carries no Dart API, only platform build hooks that trigger Go compilation.

Build configuration defaults live in `build_tool/lib/src/options.dart` and can be overridden via `build_config.yaml`.

Architecture detection is automatic except for macOS release packaging, which
defaults to Universal 2 (`arm64` + `x86_64`). The CocoaPods build hook maps the
resolved Xcode `ARCHS` into the matching Go core architecture and merges both
core slices with `lipo` for a universal release. The `--description` flag passed
to `flutter_distributor` adds arch suffixes to artifact names, such as
`FlClash-0.8.93-macos-universal.dmg`.

## Local Plugins

- `setup`: build harness FFI plugin.
- `proxy`: system proxy configuration.
- `rust_api`: Flutter Rust Bridge FFI plugin.
- `tray_manager`: system tray fork/customization.
- `wifi_ssid`: Wi-Fi SSID detection.
- `window_ext`: window extensions.
- `flutter_distributor`: app packaging/distribution.

## Windows Privilege Boundary

The Windows runner is the privilege boundary. It is elevated by the manifest,
starts only the packaged `HarborProxyCore.exe`, and owns the core process lifetime.
Installers remove the retired `HarborProxyHelperService` during upgrades.
