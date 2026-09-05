# Commands

## Building

Update submodules first. The ClashMeta Go core lives in `core/Clash.Meta/`.

```bash
git submodule update --init --recursive
```

Full package build, including Go core, Flutter, and packaging, runs through `setup.dart`:

```bash
dart setup.dart macos
dart setup.dart linux
dart setup.dart windows
dart setup.dart android
```

Build only the Go core and skip Flutter packaging:

```bash
make core-macos
make core-linux
make core-windows
make core-android
```

Pass `ARCH` or `TARGET_PLATFORM` through `make` when needed, for example:

```bash
make core-macos
make core-macos ARCH=arm64
make core-android TARGET_PLATFORM=android-arm64
```

Core builds use setup's input fingerprint cache. Pass `FORCE=1` to bypass it,
for example `make core-macos ARCH=arm64 FORCE=1`.

The Makefile wraps `plugins/setup/buildkit/run_build_tool.sh`; prefer the `make` entry points unless debugging the build tool itself.
macOS package and core builds default to Universal 2 (`arm64` + `x86_64`).
Pass `ARCH=arm64` or `ARCH=amd64` only for an explicit thin diagnostic build.

## Flutter Development

Use the default Flutter SDK directly:

```bash
flutter pub get
flutter run
flutter test
```

Use `flutter test`, not `dart test`, because models pull in Flutter types.

## Code Generation

Run code generation after modifying models, providers, or database schema:

```bash
dart run build_runner build --delete-conflicting-outputs
dart run build_runner watch
```

Code generation covers:

- Riverpod providers through `riverpod_generator`.
- Models through `freezed` and `json_serializable`.
- Database tables through `drift_dev`.

Generated output paths, configured in `build.yaml`:

- `lib/models/generated/*.g.dart`, `*.freezed.dart`.
- `lib/providers/generated/*.g.dart`.
- `lib/database/generated/*.g.dart`.

## Testing

Tests use `package:test/test.dart` for pure Dart logic and `flutter_test` for provider and widget tests. `mocktail` is the mocking framework.

```bash
flutter test test/models/
flutter test test/core/
flutter test test/core/desktop/
flutter test test/providers/
flutter test test/common/
flutter test test/database/
flutter test test/widgets/
flutter test test/setup_test.dart
flutter test plugins/proxy/test/proxy_test.dart
```

Root `flutter test` only discovers the root package's `test/` directory by default. Include bundled plugin Dart tests by passing paths explicitly, or run `flutter test` from that plugin package directory. Native plugin tests under platform folders are not run by `flutter test`.

For the current Core/service architecture, useful focused checks are:

```bash
flutter test test/core/desktop/
flutter test test/core/service_test.dart
flutter test test/core/protocol_contract_test.dart
flutter test test/manager/core_manager_test.dart
flutter test test/providers/action_test.dart test/providers/system_action_test.dart
flutter test test/widgets/core_status_button_test.dart
```

What those suites own:

- `test/core/desktop/`: replaceable IPC transport, RPC request correlation/failure, direct process leases, and
  latest-intent desktop lifecycle convergence.
- `test/core/service_test.dart`: `CoreService` composition and terminal close behavior.
- `test/core/protocol_contract_test.dart`: shared Dart/Go method and event-envelope compatibility, including event batches.
- `test/providers/action_test.dart`: Core start/restart orchestration and overlapping restart requests.
- `test/providers/system_action_test.dart`: ordered, idempotent exit cleanup and watchdog behavior.
- `test/widgets/core_status_button_test.dart`: 600-millisecond connecting presentation hold, immediate failure display,
  long-running connecting state, and disconnected restart.

## Native Component Verification

The public release workflow's no-CGO Go checks can be reproduced with:

```bash
cd core
tidy_diff=$(go mod tidy -diff)
test -z "$tidy_diff"
CGO_ENABLED=0 go list -deps -tags=with_gvisor ./... >/dev/null
CGO_ENABLED=0 go test -tags=with_gvisor ./...
CGO_ENABLED=0 go test -tags=with_gvisor github.com/metacubex/mihomo/component/updater github.com/metacubex/mihomo/tunnel/statistic github.com/metacubex/mihomo/adapter/outbound github.com/metacubex/mihomo/transport/hysteria/core github.com/metacubex/sing-quic/hysteria2
```

The workflow then compiles the Core for the supported desktop and Android targets. It does not currently run `go vet`.

Windows direct-Core launcher and hash checks are covered by `test/core/desktop/launcher_test.dart`; elevation, named-pipe
peer identity, and Job Object behavior still require a real Windows package smoke test. Native Android lifecycle edits
should at minimum compile the modules they touch; use JDK 17 in this checkout:

```bash
cd android
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :service:compileDebugKotlin
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:compileDebugKotlin
```

Always-on VPN entry, system VPN revoke, actual permission UI, and rapid device start/stop still require Android device or
emulator validation; Kotlin compilation cannot prove those system callbacks.

## Verify

The public release workflow is started manually through `workflow_dispatch` and runs these root-package checks in order:

```bash
flutter pub get
flutter analyze --no-fatal-warnings --no-fatal-infos
flutter test --reporter expanded
```

Run `flutter analyze` locally before committing when practical.

The workflow has no tag-push or pull-request trigger. Root analysis excludes `plugins/**`, and root tests do not discover
nested plugin packages. Release verification separately checks the setup build tool and Go Core; other nested plugin
tests and device-level behavior require their focused checks.
