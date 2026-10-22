# FlClash Client Shell

[简体中文](README_zh_CN.md)

A generic Flutter proxy client for Android, Linux, Windows and macOS, based on
[FlClash](https://github.com/chen08209/FlClash) and
[Mihomo](https://github.com/MetaCubeX/mihomo). The sample application is named
**HarborProxy** and uses `com.example.harborproxy` as its application ID.

The source includes desktop Core lifecycle and IPC, Android VPN integration,
subscription profiles, routing configuration, responsive navigation, and local
diagnostics. Example requests and credentials in tests are synthetic fixtures.

## Build

Use Flutter **3.44.8**, Go **1.26.8**, and the platform's native build tools.
Android requires JDK 17 and NDK r28c. Core source is included in `core/Clash.Meta`;
there are no Git submodules to initialize.

```sh
python3 tool/download_geodata.py
flutter pub get
dart setup.dart linux
# Or: dart setup.dart android|windows|macos
```

Build on the target operating system. Linux requires C/C++ build tools, CMake,
Ninja, pkg-config, GTK 3 development files, `libayatana-appindicator3-dev`, and
`libkeybinder-3.0-dev`. Windows requires Visual Studio C++ tools; macOS requires
Xcode. Install Rust for the local Rust plugin. Set `ANDROID_NDK` for Android.

GeoData is downloaded from the public MetaCubeX release. The downloader verifies
the release asset SHA-256 digests and records the source and hashes in
`assets/data/GEODATA.lock`. Downloaded databases are not tracked in Git.

Verify source changes with:

```sh
flutter analyze --no-fatal-warnings --no-fatal-infos
flutter test --concurrency=2
(cd core && CGO_ENABLED=0 go test -p 2 -tags=with_gvisor ./...)
```

The template has no release-upload workflow or signing credentials. Supply your
own branding and deployment configuration when distributing a derivative.

## License

[GPLv3](LICENSE). Upstream copyright notices and third-party licenses are retained.
