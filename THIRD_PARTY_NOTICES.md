# Third-party notices

Aurora Location is derived in part from Locus. Apple device communication uses idevice. The underlying protocol implementation is not claimed as original work.

## Locus

- Source: https://github.com/ChrisMack32/Locus
- Commit: `83c8fb324983728e8f44759cfd834dc637ee38b5`
- License: MIT, Copyright (c) 2026 Locus contributors.
- Preserved full license: [LICENSE](LICENSE).
- Adapted: `LocationEngine` connection sequence; `PairOnDeviceService` callback integration; `PairableHostAdvertiser` native Bonjour/loopback relay design.
- Aurora rewrites storage, cancellation, state, error reporting and UI. No Locus app icon, route/joystick/background audio or prebuilt library is included.

## idevice

- Source: https://github.com/jkcoxson/idevice
- Commit: `e98264c4194e6980173c576ac79a58adce95492b`
- License: MIT. Fixed source/build/license material is stored in [Vendor/idevice](Vendor/idevice/).
- Aurora changes are supplied as a source patch. Use the matching generated header and static library together.
- Cargo dependencies are governed by their own licenses; see the vendored dependency notice inventory and license texts.

## Aurora local relay / boringtun

- The local relay in `Vendor/emproxy` is Aurora project code using the public API of `boringtun` 0.7.1, under BSD-3-Clause.
- Source: https://github.com/cloudflare/boringtun
- Build inputs, dependency notices and license texts are preserved in `Vendor/emproxy` and bundled in `ThirdPartyLicenses.txt`.
- No AGPL EMProxy implementation is copied or linked. Shadowrocket runs separately; its loopback compatibility requires device validation.

## System frameworks and external prerequisites

SwiftUI, MapKit, Network, UIKit, Foundation, Security and SystemConfiguration are Apple platform frameworks used under the Apple SDK terms. Shadowrocket is an external prerequisite for the documented single-VPN path and is not redistributed. LocalDevVPN was an earlier research reference and is not required by that path or redistributed. pymobiledevice3 is a behavior reference, not a bundled dependency.

## Excluded projects

No code from AGPL-3.0 t-location/StikDebug or non-commercial StikPair is included. See [RESEARCH.md](docs/RESEARCH.md) for the audit boundary.
