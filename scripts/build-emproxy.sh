#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
vendor_dir="$root_dir/Vendor/emproxy"
manifest="$vendor_dir/Cargo.toml"
rust_toolchain="${EMPROXY_RUST_TOOLCHAIN:-1.93.1}"
target="aarch64-apple-ios"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: required command not found: $1" >&2
        exit 1
    fi
}

require_command cargo
require_command rustc
require_command shasum
require_command xcrun

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! rustc --version | grep -q "^rustc $rust_toolchain "; then
    echo "error: Rust $rust_toolchain is required" >&2
    exit 1
fi

target_libdir=$(rustc --print target-libdir --target "$target")
if [ ! -d "$target_libdir" ]; then
    echo "error: Rust target $target is not installed for $rust_toolchain" >&2
    exit 1
fi

sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
export SDKROOT="$sdk_path"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

expected_lock="7861d24d45766512015d555f358ef42487b9884cdb1998ffb8f5594c449753ca"
actual_lock=$(shasum -a 256 "$vendor_dir/Cargo.lock" | awk '{print $1}')
if [ "$actual_lock" != "$expected_lock" ]; then
    echo "error: Cargo.lock hash mismatch" >&2
    echo "expected: $expected_lock" >&2
    echo "actual:   $actual_lock" >&2
    exit 1
fi

cargo_home_dir="${CARGO_HOME:-${HOME}/.cargo}"
rust_sysroot=$(rustc --print sysroot)
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$root_dir=/source/aurora-location --remap-path-prefix=$cargo_home_dir=/source/cargo --remap-path-prefix=$rust_sysroot=/toolchain/rust-$rust_toolchain"
remap_cflags="-ffile-prefix-map=$root_dir=/source/aurora-location -ffile-prefix-map=$cargo_home_dir=/source/cargo -fdebug-prefix-map=$root_dir=/source/aurora-location -fdebug-prefix-map=$cargo_home_dir=/source/cargo"
export CFLAGS_aarch64_apple_ios="${CFLAGS_aarch64_apple_ios:+$CFLAGS_aarch64_apple_ios }$remap_cflags"

cargo build --locked --release --target "$target" --manifest-path "$manifest"

archive="$vendor_dir/target/$target/release/libaurora_emproxy.a"
output="$vendor_dir/libaurora_emproxy.a"
test -f "$archive"
cp "$archive" "$output"

xcrun lipo -info "$output" | grep -q "architecture: arm64"
symbols=$(xcrun nm -gU "$output")
for symbol in \
    aurora_emproxy_start \
    aurora_emproxy_get_stats \
    aurora_emproxy_stop
do
    if ! printf '%s\n' "$symbols" | grep -q "_$symbol$"; then
        echo "error: missing expected symbol: $symbol" >&2
        exit 1
    fi
done

echo "Built Aurora EMProxy with Rust $rust_toolchain for $target."
shasum -a 256 \
    "$vendor_dir/Cargo.toml" \
    "$vendor_dir/Cargo.lock" \
    "$vendor_dir/src/lib.rs" \
    "$vendor_dir/aurora_emproxy.h" \
    "$output"
