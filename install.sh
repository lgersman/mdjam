#!/usr/bin/env sh
set -eu

REPO="lgersman/mdjam"
BINARY="mdjam"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

die() { echo "error: $1" >&2; exit 1; }

# Detect OS
case "$(uname -s)" in
  Linux)  OS="linux" ;;
  Darwin) OS="darwin" ;;
  *)      die "Unsupported OS: $(uname -s)" ;;
esac

# Detect architecture
case "$(uname -m)" in
  x86_64)         ARCH="x64" ;;
  aarch64|arm64)  ARCH="arm64" ;;
  *)              die "Unsupported architecture: $(uname -m)" ;;
esac

# Detect musl vs glibc on Linux
MUSL=""
if [ "$OS" = "linux" ]; then
  if ldd --version 2>&1 | grep -qi musl; then
    MUSL="-musl"
  fi
fi

PLATFORM="${OS}-${ARCH}${MUSL}"
ASSET="${BINARY}-${PLATFORM}"

# Resolve download URL
if [ "${VERSION:-}" = "" ]; then
  BASE_URL="https://github.com/${REPO}/releases/latest/download"
else
  BASE_URL="https://github.com/${REPO}/releases/download/v${VERSION}"
fi

ASSET_URL="${BASE_URL}/${ASSET}"
SUMS_URL="${BASE_URL}/SHA256SUMS"

# Check for required tools
for cmd in curl sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not found"
done

echo "Detected platform: ${PLATFORM}"
echo "Downloading ${ASSET}..."

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

curl -sSfL "$ASSET_URL" -o "$TMPDIR/$ASSET" || die "Failed to download $ASSET_URL"
curl -sSfL "$SUMS_URL" -o "$TMPDIR/SHA256SUMS" || die "Failed to download SHA256SUMS"

echo "Verifying checksum..."
cd "$TMPDIR"
grep "^[0-9a-f]*  ${ASSET}$" SHA256SUMS | sha256sum -c - || die "Checksum verification failed"
cd - >/dev/null

mkdir -p "$INSTALL_DIR"
mv "$TMPDIR/$ASSET" "$INSTALL_DIR/$BINARY"
chmod +x "$INSTALL_DIR/$BINARY"

echo "Installed $BINARY to $INSTALL_DIR/$BINARY"

# Warn if INSTALL_DIR is not in PATH
case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) ;;
  *) echo "warning: $INSTALL_DIR is not in your PATH" ;;
esac
