# Aurora EMProxy native library

This directory contains the source and iOS arm64 static library for Aurora Location's bounded WireGuard loopback responder.

The responder binds only `127.0.0.1:<port>`. After WireGuard authentication it accepts only unfragmented IPv4 TCP packets from `10.7.0.10` to `10.7.0.1` with both ports in the dynamic/private range `49152...65535`. Remote Pairing starts at `49152` and negotiates a second listener, observed at `54673` on the test device. It swaps the two IPv4 addresses and sends the authenticated packet back through the same WireGuard peer. UDP, IPv6, lower TCP ports, malformed headers and fragments are dropped. The filter does not identify individual services within the permitted port range.

The app supplies a per-device 32-byte server private key and the matching Shadowrocket client public key at runtime. No production key or sample production configuration is stored here. The matching Shadowrocket peer uses client address `10.7.0.10/24`, allowed IP `10.7.0.1/32` and endpoint `127.0.0.1:51820` unless the app exports a different port.

Build and run the host checks:

```sh
cargo test --locked --manifest-path Vendor/emproxy/Cargo.toml
sh scripts/build-emproxy.sh
```

The in-memory WireGuard test completes a real `boringtun` handshake, encrypts a TCP packet addressed to `10.7.0.1:49152`, applies the production filter/remap, decrypts the returned packet and verifies both checksums. This is a native component check. End-to-end acceptance still requires a Shadowrocket version and configuration that explicitly supports local WireGuard reflection, followed by a real iPhone connection to Remote Pairing TCP port `49152`.
