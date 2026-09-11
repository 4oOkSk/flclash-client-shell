# Rules

These are repository coding and testing conventions. Codex command permission rules belong in `.codex/rules/*.rules`; see `.agents/agent-config.md` before adding those.

## Dart and Flutter Style

`analysis_options.yaml` enforces these non-default rules:

- `prefer_single_quotes: true`: always use single quotes.
- `require_trailing_commas: true`: use trailing commas in multi-line argument lists.
- `sort_child_properties_last: true`: `child:` must be the last named parameter.
- `avoid_print: true`: do not use `print()` calls.
- `prefer_const_constructors: true` and `prefer_const_declarations: true`.
- `prefer_final_locals: true` and `prefer_final_in_for_each: true`.
- `always_declare_return_types: true`.

Generated directories are excluded from analysis:

- `build/**`
- `lib/l10n/intl/**`
- `lib/**/generated/**`
- `plugins/**`

## Comments

- Prefer clear names and structure. Add only useful explanations of non-obvious local constraints, not line-by-line
  narration; this repository does not require approving comment text separately. Higher-priority comment restrictions
  still apply, and are not a reason to introduce unnecessary abstractions or tests.
- Remove stale comments only where the requested change makes that necessary; do not clean unrelated code.
- Preserve analyzer/linter directives, coverage and generation markers, license headers, and vendored upstream material.
- Keep repository-wide invariants in `.agents/`; use focused tests for meaningful behavior regressions, not prose-matching
  assertions. Do not create a separate document for a fact that belongs at one call site.

## Core API Safety

- Do not expose direct filesystem deletion APIs through Core IPC; use
  a scope-specific cleanup API instead.
- Keep the shared `CoreMethodCall`/`CoreMethodResponse` JSON envelope structurally identical across Dart, Go, JNI, and
  desktop IPC. Do not double-encode `arguments`, `result`, or event batches.
- Keep high-volume log/request events separate from state-bearing events in `core/message.go`; bulk backpressure must not
  evict delay, loaded-provider, or geo-update state.

## Lifecycle Rules

- Desktop process ownership belongs to `DesktopCoreLifecycle`; do not start/kill `FlClashCore` from providers, widgets,
  managers, or ad hoc exit callbacks. Acquire and release it through a `CoreProcessLease`.
- `CoreController.close()` and platform `close()` implementations are terminal and idempotent. Application shutdown must
  stay centralized in `SystemAction`/`SystemExitCoordinator`.
- Android start acknowledges queued intent; stop awaits native teardown. Keep latest-wins arbitration in
  `ServiceState`; observing completion must not create a second lifecycle owner.
- Android service callbacks are not automatically user intent. Route explicit Quick Settings, Always-on VPN, and revoke
  actions through `ServiceState` and keep `ServiceController` as the sole binding/run-time owner.
- Every `BroadcastReceiver.goAsync()` path must finish its `PendingResult` exactly once. A watchdog may release the
  broadcast lease, but must not cancel, reverse, or otherwise redefine the service operation.
- Presentation smoothing such as `CoreStatusButton`'s connecting hold must remain local display state. It must not delay or
  overwrite `coreStatusProvider`, and a real failure must bypass/cancel the hold immediately.

## Testing Rules

Use existing tests for affected behavior and add only meaningful regression coverage. Do not build a new test framework
for a small edit. Reuse valid CI and local results; rerun only affected or invalidated checks. Full suites and platform
tests need shared-impact evidence or explicit acceptance requirements. Release CI requirements remain in force, but
artifact publication does not itself add device/network/TUN tests; copy/layout changes need relevant UI checks, not
unrelated network smoke. Documentation edits need diff/link checks, not Flutter or Core builds.

Choose commands from `.agents/commands.md`; its CI-parity examples are not a checklist for every edit.

The `core/` directory is excluded from automated coverage accounting. Do not add coverage instrumentation or coverage
collection for code under `core/`. The public release workflow runs `go mod tidy -diff`, dependency resolution and
`CGO_ENABLED=0 go test -tags=with_gvisor ./...`, then compiles the supported desktop and Android Core targets; it does not
currently run `go vet`. Verify cross-language protocol behavior through shared Dart contract tests under `test/core/` and
native platform build checks.

Use `CoreController.test(mock)` to inject a mocked `CoreHandlerInterface`. Call `CoreController.resetInstance()` in `tearDown` to clean up the singleton between tests.

Register fallback values for freezed params used with `any()` matchers.

Use `ProviderContainer` directly for simple Riverpod provider tests. The generated Riverpod `update()` method takes a callback:

```dart
notifier.update((state) => newValue);
```

When testing freezed models with nested objects, always round-trip through `jsonEncode` and `jsonDecode`. Direct `fromJson(toJson())` fails for nested freezed types because `toJson()` stores child objects directly instead of maps.

For async widgets, put visual cleanup in `finally` when the action may throw. Test success, failure, disposal, and timer
boundaries only where the changed behavior can affect them or existing coverage is demonstrably missing for this change.
Copy, spacing, or presentation-only edits do not require completing an unrelated async test matrix.

## Generated Code

Do not manually edit generated files under:

- `lib/l10n/l10n.dart`
- `lib/models/generated/`
- `lib/providers/generated/`
- `lib/database/generated/`
- `lib/l10n/intl/`

When schema, model, or provider declaration changes affect generated output, run code generation. Include focused tests
when meaningful behavior changes.
