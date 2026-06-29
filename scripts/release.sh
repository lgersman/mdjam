#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$ROOT_DIR"

VERSION="$(grep '\.version' build.zig.zon | head -1 | grep -oP '"[^"]+"' | tr -d '"')"
OUTDIR="$ROOT_DIR/release/mdjam-v${VERSION}"

# Zig cross-compilation targets → output platform names
declare -A TARGETS=(
  ["x86_64-linux-musl"]="linux-x64-musl"
  ["aarch64-linux-musl"]="linux-arm64-musl"
  ["x86_64-macos"]="darwin-x64"
  ["aarch64-macos"]="darwin-arm64"
)

echo "Building mdjam v${VERSION}"
mkdir -p "$OUTDIR"

for ZIG_TARGET in "${!TARGETS[@]}"; do
  PLATFORM="${TARGETS[$ZIG_TARGET]}"
  OUTFILE="$OUTDIR/mdjam-${PLATFORM}"
  echo "  compiling $ZIG_TARGET -> mdjam-${PLATFORM}"

  zig build \
    -Dtarget="$ZIG_TARGET" \
    -Doptimize=ReleaseSafe \
    --prefix "$OUTDIR" \
    --prefix-exe-dir ""

  # zig build --prefix puts the binary at $prefix/mdjam; rename to platform-qualified name
  mv "$OUTDIR/mdjam" "$OUTFILE"
done

echo "Generating checksums..."
cd "$OUTDIR"
sha256sum mdjam-* > SHA256SUMS
cd - > /dev/null

echo ""
echo "Release artifacts in $OUTDIR:"
ls -lh "$OUTDIR"
