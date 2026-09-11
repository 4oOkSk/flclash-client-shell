# AGENTS.md

This file is the entry point for AI coding agents working in this repository. Keep it small: detailed guidance lives under
`.agents/`, and discoverable repo skills live under `.agents/skills/*/SKILL.md`.

## Start Here

Use this entry point, then read the references needed for the current task. Do not preload every linked file for a
documentation edit or an unrelated small change. Reuse already-read, unchanged context.

- [.agents/rules.md](.agents/rules.md): before code, configuration, or test edits; also when changing repository policy.
- [.agents/project.md](.agents/project.md): project orientation, versions, or build dependencies.
- [.agents/commands.md](.agents/commands.md): when running builds, code generation, or tests; select the relevant commands.
- [.agents/architecture.md](.agents/architecture.md): core integration, providers, database, managers, build system, and
  local plugins.
- [.agents/agent-config.md](.agents/agent-config.md): how to choose between `AGENTS.md`, `.agents`, skills, Codex config,
  command rules, and hooks.
- [.agents/skills.md](.agents/skills.md): index of repo-scoped skills in `.agents/skills/`.

## Highest Priority Rules

- When the user explicitly requests a scoped, low-risk change, inspect the relevant context and implement it directly.
  Do not require brainstorming, design documents, implementation plans, multiple-option proposals, or repeated confirmation.
  Ask only when material ambiguity, destructive impact, additional authority, or scope expansion could change the result.
- Keep comments sparse and useful; no exact-text approval ritual or unrelated cleanup.
  See [.agents/rules.md](.agents/rules.md) for comment and verification conventions.
- Use `flutter test`, not `dart test`, because models pull in Flutter types.
- Run code generation when changes to model, provider, or database declarations affect generated output.
- Do not manually edit generated files.
- Preserve lifecycle ownership: desktop Core process convergence belongs to `lib/core/desktop/`; Android service intent
  arbitration belongs to `ServiceState`. UI/provider code may request a transition but must not become a second source of
  truth.
- Keep start/stop/restart paths latest-intent-safe. Android start acknowledges queued intent; stop awaits the native
  operation. `ServiceState` remains the single owner. See `.agents/architecture.md` for the lifecycle contract.
- Follow `analysis_options.yaml`, especially single quotes, trailing commas, `child:` last, no `print()`, const/final
  preferences, and declared return types.
- Select checks through [.agents/rules.md](.agents/rules.md#testing-rules); command lists are references, not a mandatory
  suite. Documentation-only edits do not require an application build.

## Repo Skills

Use repo skills from `.agents/skills/` when a task matches their descriptions. Current skills cover localization,
provider tests, UI work, and core/platform changes.
