---
name: core-platform
description: Use when changing FlClash Core routing, DNS, protocol/events, process lifecycle, Android services, desktop IPC, VPN/TUN, or native build integration.
---

# Core And Platform

## Select The Affected Branch

Identify the changed behavior and its authoritative owner. Follow only the branches it can affect. A routing edit does
not automatically require tracing every lifecycle entry point or building four platform packages.

- **Routing, DNS, or managed configuration:** start with `core/client_route.go` and its tests; follow directly affected
  configuration producers and consumers. Verify rule order, mode isolation, DNS/IPv6 behavior, and serialization where
  changed. Include lifecycle or native-platform checks only when the change reaches those contracts.
- **Protocol or event delivery:** use the facade, connection, and IPC owners below; follow changed envelope/event shapes
  across their actual consumers. Preserve queue isolation and scope-specific IPC APIs.
- **Lifecycle, binding, or shutdown:** use the lifecycle workflow below. Shared arbitration changes require checking all
  callers of that arbitration; a local change needs only entry paths it can affect.
- **Native launch or packaging:** use the launcher and build-harness references below. Check the affected package targets
  and Windows-specific invariants when relevant, not every platform by default.

## Owner Map

- Shared facade/protocol: `lib/core/controller.dart`, `lib/core/interface.dart`, and `lib/core/method.dart`.
- Android Core connection: `lib/core/lib.dart`, `lib/plugins/service.dart`, and Android `ServicePlugin`.
- Android start/stop intent: `ServiceState`; binding/process-time bookkeeping: `ServiceController`.
- Desktop composition: `lib/core/service.dart`; lifecycle/process ownership: `lib/core/desktop/lifecycle.dart`.
- Desktop IPC/RPC: `lib/core/desktop/transport.dart` and `lib/core/desktop/rpc_client.dart`.
- Desktop launch ownership and Windows executable verification: `lib/core/desktop/launcher.dart` and
  `lib/common/system.dart`.
- Flutter orchestration: `lib/providers/actions/core.dart` and `system.dart`; UI/event observation: `lib/manager/`.

## Lifecycle Workflow

1. Trace affected entry paths into the owner: UI/provider calls, Quick Settings, notification actions, Always-on VPN,
   revoke callbacks, application exit, and crash/disconnect recovery as applicable. Callbacks are not implicit user intent.
2. Preserve latest-intent semantics:
   - Desktop revisions converge to running/restarted/stopped/closed and report applied/coalesced/superseded outcomes.
   - Android start acknowledges queued intent; stop awaits the native operation. `ServiceState` still identity-checks
     the latest `RunRequest`; completion observation is not a second owner.
3. Route feature calls through `CoreController` and `CoreHandlerInterface`. Do not bypass desktop process leases or create a
   second Android service binding owner.
4. Keep shutdown single-owned and terminal. `SystemExitCoordinator` sequences resource cleanup, window close, Core close,
   and process exit; widget/manager disposal must not race it.

## Verification And Completion

Use existing or targeted tests at the narrowest layer that can detect the changed behavior. Select matching commands from
`.agents/commands.md`; the list below is a routing aid, not a mandatory combined suite:

- Managed routing/configuration: affected Go tests in `core/client_route_test.go` and Flutter configuration tests.
- Desktop lifecycle/transport/RPC: the affected tests under `test/core/desktop/` or `test/core/service_test.dart`.
- Cross-language envelopes/events: `test/core/protocol_contract_test.dart` and `CGO_ENABLED=0 go test .`.
- Provider/exit convergence: `test/providers/action_test.dart` and `test/providers/system_action_test.dart`.
- Android Kotlin: compile each touched Gradle module with JDK 17.
- Windows launch or packaging: launcher/hash tests and a real package smoke test for affected native behavior.

Stop when the changed behavior and directly affected contracts have sufficient evidence. Reuse valid unaffected checks.
Explicitly state host gaps: Always-on VPN, VPN permission, system revoke, named-pipe peer identity, elevation, and Job
Object behavior need their real platform even when portable tests pass. Do not claim untested native behavior is verified.

## Reference Files

Read `.agents/architecture.md` when the task needs core modes, manager ownership, build hooks, local plugins, or Windows
direct-Core composition. Do not turn a local routing or documentation edit into an unrelated architecture audit.

## Pitfalls

Preserve these invariants when touching their area; they do not require unrelated checks:

- Keep shared JSON envelopes identical across Dart, Go, JNI, and desktop IPC without double encoding.
- Windows release packaging must embed the exact Core SHA256 before compiling Flutter. The direct launcher verifies it
  again immediately before every spawn.
- The Windows GUI manifest stays `requireAdministrator`; do not introduce an unelevated fallback or a helper service.
- The runner Job Object owns the GUI and direct Core lifetime, while Dart's process lease owns orderly shutdown.
- A desktop process lease with unconfirmed exit must remain owned until cleanup succeeds. Do not discard it and start a
  replacement Core.
- `CoreController.close()` is terminal. Do not call it from a reusable manager lifecycle or recover by starting it again.
- `ServiceBroadcastReceiver.goAsync()` must finish once even on timeout; its watchdog releases the broadcast only and must
  not become a service timeout.
- Do not interpret service creation/destruction as start/stop intent. Always-on startup is explicit through
  `VPN_START_REQUESTED`; revoke is explicit through `VPN_REVOKED`.
- Keep log/request floods from evicting state-bearing Core events. Each queue may evict only its own oldest item.
- Do not expose direct filesystem deletion APIs through Core IPC; use
  a scope-specific cleanup API instead.
- `plugins/setup/` is a build harness, not a Dart API plugin.
- Build hooks can trigger Go compilation indirectly through Flutter platform builds.
