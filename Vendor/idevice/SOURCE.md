# idevice source and build record

## Source

- Upstream: https://github.com/jkcoxson/idevice.git
- Commit: `e98264c4194e6980173c576ac79a58adce95492b`
- Upstream license: MIT, preserved in `LICENSE.idevice.txt`
- Aurora source changes: `aurora-ios.patch`
- Dependency resolution: `Cargo.lock`
- Dependency licenses and notices: `LICENSES.txt`

The source commit, lock file and patch are the source of truth. The checked-in
header and static library are build artifacts produced from that combination.

## Build

Requirements:

- macOS with Xcode 26.6 and iPhoneOS 26.5 SDK
- Rust 1.93.1 with the `aarch64-apple-ios` target
- Git access to the upstream repository and Cargo registry

Run from the repository root:

```sh
scripts/build-idevice.sh
```

The script checks out the fixed commit in the ignored
`Vendor/idevice/.build/source` directory, restores the fixed lock file, applies
the patch, builds with `--locked`, verifies the expected C symbols, and replaces
`libidevice_ffi.a` and `idevice.h` together. Set `IDEVICE_BUILD_DIR` to use a
different disposable checkout. The script owns and resets that checkout. Rust
and C source paths are remapped so the archive does not disclose the builder's
local user or temporary directories.

Build target and feature set:

```text
target: aarch64-apple-ios
minimum deployment target: iOS 17.0
profile: release
default features: disabled
features: ring,remote_pairing,tunnel_tcp_stack,dvt,location_simulation
```

Aurora Location itself has an iOS 18.0 deployment target. The library's lower
minimum target is compatible with that application target.

## Aurora patch scope

The patch supplies the C ABI needed by Aurora Location:

- A single cancellable pairable-host accept operation with a 180-second bound.
- Callbacks for the PIN, Bonjour TXT data/listening port, and relay connection.
- Pairing-file serialization with ownership safe across the C boundary.
- Bounded remote-pairing tunnel, RSD and DVT location operations.
- DVT set and clear calls that do not wait for replies those methods do not send.
- Borrowed ownership for the location client/server relationship.
- Removal of private pairing-key logging.

The process-wide pairing slot intentionally matches the app's single pairing
screen. Concurrent pairing sessions require a future session-handle ABI.

All callbacks from `aurora_pairable_host_accept` finish before that function
returns. Callback strings are borrowed only for the duration of the callback and
must be copied by the caller. Returned errors and handles use the matching free
functions declared in `idevice.h`.

## Recorded artifacts

Built on 2026-09-09 with Xcode 26.6, iPhoneOS 26.5 SDK and Rust 1.93.1:

```text
735ead5f87f6b44b2ba033abfef3159e0d27dbf7a1bad44da4a305378e4f1131  Cargo.lock
9f3e7d862dc0d17a259cf292223b16b9936989a5cfdfee83e4ddc393ea540344  aurora-ios.patch
8b05783cfc7496edc25c0429fa91e2069a2c5d2c30c9f1c7e4bc8de9410cdabf  idevice.h
87c1b34bedd1e3568b8540f04fda92a0bf1e6c2845a3a9ded271645e91a31e7f  libidevice_ffi.a
d98e25796e1135d892d81e6922a61e78e82b3d6c33322112e9eca1e089c7a300  module.modulemap
```

The archive contains only the arm64 iOS slice. Rust archives are not promised to
be byte-for-byte identical across paths or later toolchain/SDK versions; source,
lock and patch hashes establish the reproducible input.

Rebuilt on 2026-09-17 with the same pinned source, Xcode 27.0, iPhoneOS 27.0 SDK,
and Rust 1.93.1 after adding the synchronous tunnel-stage callback ABI:

```text
735ead5f87f6b44b2ba033abfef3159e0d27dbf7a1bad44da4a305378e4f1131  Cargo.lock
01d7f11701c83ee9e3167bd9376ea2aa9ae70b6bef84f97f651154b6a72c79e0  aurora-ios.patch
6c42d428dd8a820d5ab073d472c41d1d10aa4cb62fcd609848bdff6b72e5506d  idevice.h
eacd72e90c4ce5531e7f8a59e90d2afb7e6cc8f45412729b63ac0839d1a00874  libidevice_ffi.a
d98e25796e1135d892d81e6922a61e78e82b3d6c33322112e9eca1e089c7a300  module.modulemap
```

This rebuild verified the arm64 slice and both `tunnel_create_rppairing` and
`aurora_tunnel_create_rppairing_with_progress` symbols. The new callback is an
optional direct C function pointer receiving only `(uint32_t stage, bool completed)`;
its invocation and lifetime rules are documented in the generated declaration.

## Validation record

- Host `cargo check --offline --locked` passed for the exact feature set.
- The repeatable pre-cancellation unit test passed and verified error code 27,
  null output, and release of the single active slot.
- The arm64 iOS release build passed.
- `lipo` verified the arm64 slice.
- `nm` verified the pairing, serialization, tunnel, RSD and location symbols.
- A clang iOS link smoke test passed against the generated header and archive.
- The ABI-equivalent build before local source-path remapping linked in unsigned
  and signed Aurora Location builds. Strict code-sign verification, installation
  and launch on an iOS 27 iPhone passed. Relink validation of the final remapped
  archive is recorded by the app-level build.

Live remote pairing and live DVT set/clear remain device acceptance checks; build,
installation and launch do not establish those protocol outcomes.
