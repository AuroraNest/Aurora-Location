#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aurora-location-check.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
for mode in debug release; do
  debug_flag=""
  if [ "$mode" = debug ]; then debug_flag="-DDEBUG"; fi
  xcrun swiftc $debug_flag -module-cache-path "$test_dir/cache" \
    AuroraLocation/Core/DiagnosticLog.swift Tests/DiagnosticLogCheck.swift \
    -o "$test_dir/diagnostics-$mode-check"
  "$test_dir/diagnostics-$mode-check"
done
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AuroraLocation/Models/Location.swift AuroraLocation/Storage/LocalStore.swift \
  AuroraLocation/Storage/TunnelKeys.swift Tests/main.swift \
  -o "$test_dir/check"
"$test_dir/check"
xcrun clang -I Vendor/idevice -c Tests/EngineFFIStub.c -o "$test_dir/engine-stub.o"
xcrun swiftc -module-cache-path "$test_dir/cache" -I Vendor/idevice \
  AuroraLocation/Models/Location.swift AuroraLocation/Core/LocationEngine.swift \
  AuroraLocation/Core/DiagnosticLog.swift \
  Tests/EngineSessionCheck.swift "$test_dir/engine-stub.o" -o "$test_dir/engine-check"
"$test_dir/engine-check"
xcrun swiftc -D DEBUG -module-cache-path "$test_dir/cache" \
  AuroraLocation/Core/NetworkStatus.swift Tests/NetworkProbeCheck.swift -o "$test_dir/network-check"
"$test_dir/network-check"
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AuroraLocation/Models/Location.swift AuroraLocation/Models/WalkingRoute.swift \
  AuroraLocation/Core/OpenStreetMapWalkingRoute.swift \
  Tests/WalkingRouteCheck.swift -o "$test_dir/walking-route-check"
"$test_dir/walking-route-check"
xcrun swiftc -D DEBUG -module-cache-path "$test_dir/cache" \
  AuroraLocation/Models/Location.swift AuroraLocation/Models/WalkingRoute.swift \
  AuroraLocation/App/AppState.swift Tests/AppStateWalkingCheck.swift \
  AuroraLocation/Core/CellularShortcut.swift AuroraLocation/Core/AuroraVPN.swift \
  -o "$test_dir/walking-state-check"
"$test_dir/walking-state-check"
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AuroraLocation/Core/AuroraVPN.swift Tests/AuroraVPNCheck.swift -o "$test_dir/aurora-vpn-check"
"$test_dir/aurora-vpn-check"
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AuroraLocation/Core/PersonalVPN.swift Tests/PersonalVPNCheck.swift \
  -o "$test_dir/personal-vpn-check"
"$test_dir/personal-vpn-check"
xcrun swiftc -module-cache-path "$test_dir/cache" \
  LocalTunnel/PacketTunnelProvider.swift Tests/LocalTunnelPacketCheck.swift \
  -o "$test_dir/local-tunnel-check"
"$test_dir/local-tunnel-check"
plutil -lint AuroraLocation/Resources/Info.plist AuroraLocation/Resources/AuroraLocation.entitlements \
  LocalTunnel/Info.plist LocalTunnel/LocalTunnel.entitlements AuroraLocation.xcodeproj/project.pbxproj
