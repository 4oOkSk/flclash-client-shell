---
name: provider-tests
description: Use when adding or updating FlClash Riverpod provider tests, notifier tests, or state-management tests in this repository.
---

# Provider Tests

## When To Use

Use this for tests under `test/providers/` or any change that validates Riverpod providers, generated notifiers, app state defaults, or provider interactions.

Use `.agents/rules.md` and `.agents/commands.md` for the applicable test conventions and commands; they do not authorize
broader test expansion by themselves.

## Workflow

1. Read the provider under test and its generated public API before writing assertions.
2. Use `ProviderContainer` directly when no widget tree is needed.
3. Dispose containers in teardown or with `addTearDown(container.dispose)`.
4. Prefer generated notifier APIs over implementation details. Generated `update()` takes a callback:

   ```dart
   notifier.update((state) => newValue);
   ```

5. Reuse existing setup. When a mock is necessary, use `mocktail` and register fallback values for freezed params
   used with `any()`.
6. Apply `.agents/rules.md` Testing Rules and run the affected `flutter test` files/cases from `.agents/commands.md`.

## Pitfalls

- Do not use `dart test`; FlClash models and provider tests may depend on Flutter types.
- Re-check source defaults before asserting them; provider defaults can drift.
- If async provider timing matters, wait on provider futures or state changes instead of fixed sleeps.
