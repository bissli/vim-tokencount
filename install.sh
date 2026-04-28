#!/usr/bin/env bash
set -euo pipefail

# Resolve the binary for vim-tokencount. Strategy:
#   1. If target/release/tokencount already exists, do nothing.
#   2. Otherwise try to download a matching prebuilt asset from the latest
#      GitHub release.
#   3. If the download fails (no asset, no network, unsupported arch),
#      fall back to `cargo build --release`.

REPO="bissli/vim-tokencount"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$ROOT/target/release"
BIN="$BIN_DIR/tokencount"

if [[ -x "$BIN" ]]; then
    echo "tokencount: binary already present at $BIN"
    exit 0
fi

uname_s="$(uname -s)"
uname_m="$(uname -m)"

case "$uname_s-$uname_m" in
    Linux-x86_64)   ASSET="tokencount-linux-x86_64" ;;
    Linux-aarch64)  ASSET="tokencount-linux-aarch64" ;;
    Linux-arm64)    ASSET="tokencount-linux-aarch64" ;;
    Darwin-arm64)   ASSET="tokencount-macos-aarch64" ;;
    *)              ASSET="" ;;
esac

download_release() {
    local asset="$1"
    local url="https://github.com/$REPO/releases/latest/download/$asset"
    local sumurl="$url.sha256"
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN

    echo "tokencount: trying prebuilt asset $asset"
    if ! curl -fsSL --max-time 30 -o "$tmpdir/$asset" "$url"; then
        return 1
    fi
    if ! curl -fsSL --max-time 10 -o "$tmpdir/$asset.sha256" "$sumurl"; then
        echo "tokencount: checksum file missing, refusing prebuilt"
        return 1
    fi
    (cd "$tmpdir" && shasum -a 256 -c "$asset.sha256") || return 1

    mkdir -p "$BIN_DIR"
    install -m 0755 "$tmpdir/$asset" "$BIN"
    return 0
}

build_from_source() {
    if ! command -v cargo >/dev/null 2>&1; then
        echo "tokencount: cargo not found and no prebuilt asset matched." >&2
        echo "  install rust (https://rustup.rs) or set g:tokencount_fast=1 in vim." >&2
        exit 1
    fi
    echo "tokencount: building from source (this is slow on first run)"
    cargo build --release --locked
}

if [[ -n "$ASSET" ]] && download_release "$ASSET"; then
    echo "tokencount: installed $ASSET"
    exit 0
fi

build_from_source
