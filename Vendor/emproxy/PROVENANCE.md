# Source and build provenance

Aurora EMProxy is project code under the repository's MIT license. Its implementation uses the public `boringtun` API and WireGuard packet format. The AGPL-3.0 `SideStore/em_proxy` and `jkcoxson/em_proxy` implementations are not included or linked into this library.

## Runtime dependency

- Package: `boringtun` `0.7.1`
- Registry: crates.io
- Repository: https://github.com/cloudflare/boringtun
- Inspected repository commit: `6dcc889a95ad82400932f785d874421d70308195`
- License: BSD-3-Clause
- Cargo package and every transitive version/checksum are pinned by `Cargo.lock`.

## Build contract

- Rust: `1.93.1`
- Target: `aarch64-apple-ios`
- Minimum iOS deployment target: `17.0`
- Xcode SDK: selected by `xcrun --sdk iphoneos`
- Output: `libaurora_emproxy.a`
- Exported functions: `aurora_emproxy_start`, `aurora_emproxy_get_stats`, `aurora_emproxy_stop`

`scripts/build-emproxy.sh` checks the Rust version, installed target, lockfile hash, arm64 archive architecture and exported symbols. It prints the final archive and source-input SHA-256 values.

