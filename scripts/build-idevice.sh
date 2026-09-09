#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
vendor_dir="$root_dir/Vendor/idevice"
source_dir="${IDEVICE_BUILD_DIR:-$vendor_dir/.build/source}"
source_url="https://github.com/jkcoxson/idevice.git"
source_commit="e98264c4194e6980173c576ac79a58adce95492b"
rust_toolchain="${IDEVICE_RUST_TOOLCHAIN:-1.93.1}"
target="aarch64-apple-ios"
features="ring,remote_pairing,tunnel_tcp_stack,dvt,location_simulation"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: required command not found: $1" >&2
        exit 1
    fi
}

require_command git
require_command shasum
require_command strings
require_command xcrun

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
export SDKROOT="$sdk_path"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
export BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$sdk_path ${BINDGEN_EXTRA_CLANG_ARGS:-}"
export RUSTFLAGS="--remap-path-prefix=$source_dir=/idevice --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo ${RUSTFLAGS:-}"
export CFLAGS_aarch64_apple_ios="-ffile-prefix-map=$source_dir=/idevice -ffile-prefix-map=${CARGO_HOME:-$HOME/.cargo}=/cargo ${CFLAGS_aarch64_apple_ios:-}"

if command -v rustup >/dev/null 2>&1; then
    cargo_run() {
        rustup run "$rust_toolchain" cargo "$@"
    }
    rustc_run() {
        rustup run "$rust_toolchain" rustc "$@"
    }
else
    require_command cargo
    require_command rustc
    cargo_run() {
        cargo "$@"
    }
    rustc_run() {
        rustc "$@"
    }
fi

if ! rustc_run --version | grep -q "^rustc $rust_toolchain "; then
    echo "error: Rust $rust_toolchain is required" >&2
    echo "install it and the $target target with rustup before rebuilding" >&2
    exit 1
fi

target_libdir=$(rustc_run --print target-libdir --target "$target")
if [ ! -d "$target_libdir" ]; then
    echo "error: Rust target $target is not installed for $rust_toolchain" >&2
    exit 1
fi

mkdir -p "$(dirname "$source_dir")"
if [ ! -d "$source_dir/.git" ]; then
    if [ -e "$source_dir" ]; then
        echo "error: $source_dir exists but is not a Git checkout" >&2
        exit 1
    fi
    git clone --no-checkout "$source_url" "$source_dir"
fi

if [ "$(git -C "$source_dir" remote get-url origin)" != "$source_url" ]; then
    echo "error: unexpected idevice origin in $source_dir" >&2
    exit 1
fi

if ! git -C "$source_dir" cat-file -e "$source_commit^{commit}" 2>/dev/null; then
    git -C "$source_dir" fetch --no-tags origin "$source_commit"
fi
git -C "$source_dir" checkout --detach "$source_commit"
git -C "$source_dir" reset --hard "$source_commit"
git -C "$source_dir" clean -ffd -e target/

cp "$vendor_dir/Cargo.lock" "$source_dir/Cargo.lock"
git -C "$source_dir" apply --check "$vendor_dir/aurora-ios.patch"
git -C "$source_dir" apply "$vendor_dir/aurora-ios.patch"
touch "$source_dir/ffi/build.rs"

(
    cd "$source_dir"
    cargo_run build --locked --release --target "$target" -p idevice-ffi \
        --no-default-features --features "$features"
)

archive="$source_dir/target/$target/release/libidevice_ffi.a"
header="$source_dir/ffi/idevice.h"
test -f "$archive"
test -f "$header"

cp "$archive" "$vendor_dir/libidevice_ffi.a"
cp "$header" "$vendor_dir/idevice.h"

xcrun lipo -info "$vendor_dir/libidevice_ffi.a" | grep -q "architecture: arm64"
if strings "$vendor_dir/libidevice_ffi.a" | grep -Eq '/Users/|/private/tmp/'; then
    echo "error: unremapped local source path in libidevice_ffi.a" >&2
    exit 1
fi
symbols=$(xcrun nm -gU "$vendor_dir/libidevice_ffi.a" 2>/dev/null)
for symbol in \
    aurora_pairable_host_set_cancelled \
    aurora_pairable_host_accept \
    rp_pairing_file_from_bytes \
    rp_pairing_file_to_bytes \
    tunnel_create_rppairing \
    remote_server_connect_rsd \
    location_simulation_new \
    location_simulation_set \
    location_simulation_clear
do
    if ! printf '%s\n' "$symbols" | grep -q "_$symbol$"; then
        echo "error: missing expected symbol: $symbol" >&2
        exit 1
    fi
done

expected_lock="735ead5f87f6b44b2ba033abfef3159e0d27dbf7a1bad44da4a305378e4f1131"
actual_lock=$(shasum -a 256 "$source_dir/Cargo.lock" | awk '{print $1}')
if [ "$actual_lock" != "$expected_lock" ]; then
    echo "error: Cargo.lock changed during the locked build" >&2
    exit 1
fi

echo "Built idevice from $source_commit with Rust $rust_toolchain."
shasum -a 256 \
    "$vendor_dir/Cargo.lock" \
    "$vendor_dir/aurora-ios.patch" \
    "$vendor_dir/idevice.h" \
    "$vendor_dir/libidevice_ffi.a" \
    "$vendor_dir/module.modulemap"
