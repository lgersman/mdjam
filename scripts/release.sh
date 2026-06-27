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
  [[ -f package.json.release-bak ]] && mv package.json.release-bak package.json
  [[ -f bun.lock.release-bak ]] && mv bun.lock.release-bak bun.lock
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

# Build the sidecar syntax directory (platform-independent — JS + WASM only).
# Bun 1.x compiled binaries cannot embed workers or WASM files, so the
# parser worker and language WASM files ship as a separate mdjam-syntax/ directory
# that must live next to the mdjam binary at install time.
SIDECAR_DIR="$OUTDIR/mdjam-syntax"
echo "Building sidecar syntax assets -> $SIDECAR_DIR"
mkdir -p "$SIDECAR_DIR"

# Bundle parser.worker.js with all JS deps; Bun copies tree-sitter.wasm alongside.
bun build "$ROOT_DIR/node_modules/@opentui/core/parser.worker.js" \
  --outdir "$SIDECAR_DIR" \
  --target bun

# Copy bash parser assets
mkdir -p "$SIDECAR_DIR/bash"
cp "$ROOT_DIR/node_modules/tree-sitter-bash/tree-sitter-bash.wasm" \
  "$SIDECAR_DIR/bash/tree-sitter-bash.wasm"
cp "$ROOT_DIR/node_modules/tree-sitter-bash/queries/highlights.scm" \
  "$SIDECAR_DIR/bash/highlights.scm"

for TARGET in "${TARGETS[@]}"; do
  case "$TARGET" in
    bun-windows-*)  EXT=".exe" ;;
    *)              EXT="" ;;
  esac

  # Strip the "bun-" compiler prefix from the user-facing filename
  PLATFORM="${TARGET#bun-}"
  OUTFILE="$OUTDIR/mdjam-${PLATFORM}${EXT}"
  echo "  compiling $TARGET -> $OUTFILE"

  bun build "$ROOT_DIR/src/cli.ts" \
    --compile \
    --target "$TARGET" \
    --minify \
    --outfile "$OUTFILE"
done

echo "Packaging mdjam-syntax.tar.gz..."
cd "$OUTDIR"
tar -czf mdjam-syntax.tar.gz mdjam-syntax/
rm -rf mdjam-syntax/
cd - > /dev/null

echo "Generating checksums..."
cd "$OUTDIR"
sha256sum mdjam-linux-* mdjam-darwin-* mdjam-windows-* mdjam-syntax.tar.gz > SHA256SUMS
cd - > /dev/null

echo ""
echo "Release artifacts in $OUTDIR:"
ls -lh "$OUTDIR"
