# Borrowed Android TUN descriptor

When a positive external descriptor is supplied to Linux/Android NativeTun, duplicate it before
wrapping it in `os.File`. The Android service owns and closes the original ParcelFileDescriptor;
NativeTun owns and closes only its duplicate. Creation failure closes the duplicate as well.
JNI returns startup failure so the service can clean up its original descriptor.

Regression: `borrowed_fd_linux_test.go`, called from parent `core/` via
`CGO_ENABLED=0 go test -tags=with_gvisor github.com/metacubex/sing-tun`.
