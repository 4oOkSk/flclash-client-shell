# Development

- Preserve the GPLv3 license and upstream attribution.
- Follow `analysis_options.yaml` and the surrounding code. Use `flutter test` for Flutter-dependent tests.
- Build instructions and verification commands are in [README.md](README.md#build).
- Keep Core lifecycle ownership in `lib/core/desktop/` and Android `ServiceState`.
- Regenerate models/providers/database output with `dart run build_runner build --delete-conflicting-outputs`; regenerate localization with `dart run intl_utils:generate`.
- Keep service inputs and signing material outside the repository. Default builds use the generic client interface.
