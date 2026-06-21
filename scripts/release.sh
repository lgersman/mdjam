#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$ROOT_DIR"

if [[ $# -gt 0 ]]; then
  VERSION="$1"
else
  VERSION="$(bun -e "console.log(require('./package.json').version)")"
fi
OUTDIR="$ROOT_DIR/release/mdjam-v${VERSION}"

TARGETS=(
  bun-linux-x64
  bun-linux-arm64
  bun-linux-x64-musl
  bun-linux-arm64-musl
  bun-darwin-x64
  bun-darwin-arm64
  bun-windows-x64
)

# @opentui/core uses dynamic imports for all platform packages; bun's bundler
# resolves them statically, so all variants must be present in node_modules
# before cross-compiling. We install them temporarily and restore on exit.
OPENTUI_VERSION="$(bun -e "console.log(require('./node_modules/@opentui/core/package.json').version)")"

cp package.json package.json.release-bak
cp bun.lock bun.lock.release-bak

restore_packages() {
  echo "Restoring package files..."
  mv package.json.release-bak package.json
  mv bun.lock.release-bak bun.lock
  bun install --silent
}
trap restore_packages EXIT

echo "Installing cross-compilation dependencies (@opentui/core ${OPENTUI_VERSION})..."
bun add --dev \
  "@opentui/core-darwin-x64@${OPENTUI_VERSION}" \
  "@opentui/core-darwin-arm64@${OPENTUI_VERSION}" \
  "@opentui/core-linux-arm64@${OPENTUI_VERSION}" \
  "@opentui/core-linux-arm64-musl@${OPENTUI_VERSION}" \
  "@opentui/core-win32-x64@${OPENTUI_VERSION}" \
  "@opentui/core-win32-arm64@${OPENTUI_VERSION}"
# bun add respects cpu/os restrictions and skips extracting cross-platform packages to
# node_modules; re-run with wildcard overrides to force all variants into node_modules
bun install --cpu='*' --os='*'

echo "Building mdjam v${VERSION}"
mkdir -p "$OUTDIR"

for TARGET in "${TARGETS[@]}"; do
  case "$TARGET" in
    bun-windows-*)  EXT=".exe" ;;
    *)              EXT="" ;;
  esac

  OUTFILE="$OUTDIR/mdjam-${TARGET}${EXT}"
  echo "  compiling $TARGET -> $OUTFILE"

  bun build "$ROOT_DIR/src/cli.ts" \
    --compile \
    --target "$TARGET" \
    --minify \
    --outfile "$OUTFILE"
done

echo "Generating checksums..."
cd "$OUTDIR"
sha256sum mdjam-* > SHA256SUMS
cd - > /dev/null

echo ""
echo "Release artifacts in $OUTDIR:"
ls -lh "$OUTDIR"
