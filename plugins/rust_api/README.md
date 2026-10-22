# rust_api

Flutter Rust Bridge integration for the client's native IPC helpers. Cargokit builds the Rust library as part of the host Flutter build.

- Rust API: `rust/src/api/`
- Generated Dart bindings: `lib/src/rust/`
- Public Dart entry point: `lib/rust_api.dart`
- Generator configuration: `flutter_rust_bridge.yaml`

After changing the exposed Rust API, regenerate bindings:

```sh
flutter_rust_bridge_codegen generate
```

Generated bindings are not edited by hand. Current IPC architecture is documented in [Core integration](../../docs/architecture.md#core-integration).
