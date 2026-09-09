#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/aurora-location-check.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -module-cache-path "$test_dir/cache" \
  AuroraLocation/Models/Location.swift AuroraLocation/Storage/LocalStore.swift \
  AuroraLocation/Storage/TunnelKeys.swift Tests/main.swift \
  -o "$test_dir/check"
"$test_dir/check"
xcrun clang -I Vendor/idevice -c Tests/EngineFFIStub.c -o "$test_dir/engine-stub.o"
xcrun swiftc -module-cache-path "$test_dir/cache" -I Vendor/idevice \
  AuroraLocation/Models/Location.swift AuroraLocation/Core/LocationEngine.swift \
  Tests/EngineSessionCheck.swift "$test_dir/engine-stub.o" -o "$test_dir/engine-check"
"$test_dir/engine-check"
plutil -lint AuroraLocation/Resources/Info.plist AuroraLocation.xcodeproj/project.pbxproj
