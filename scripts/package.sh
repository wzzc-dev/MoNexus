#!/usr/bin/env bash
# MoNexus V0.1 release packaging.
#
# Produces a fixed-path native release build, stages an install layout
# (bin/ + share/monexus resources), writes a tar.gz and its SHA-256, and
# checks that the staged launcher runs `--version`.
#
# Usage:
#   scripts/package.sh                 # build release, stage, tar, checksum
#   scripts/package.sh --skip-build    # reuse existing release binaries
#   scripts/package.sh --out DIR       # output root (default: dist/)
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist"
SKIP_BUILD=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --out) shift; OUT="${1:-$ROOT/dist}" ;;
    --out=*) OUT="${1#--out=}" ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "package.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

VERSION="$(head -n 1 "$ROOT/VERSION" | tr -d '[:space:]')"
CONTRACT_VERSION="$(sed -n 's/.*PRODUCT_VERSION : String = "\([^"]*\)".*/\1/p' \
  "$ROOT/packages/contracts/version.mbt" | head -n 1)"
if [[ -z "$VERSION" ]]; then
  echo "package.sh: VERSION file is missing or empty" >&2
  exit 1
fi
if [[ "$VERSION" != "$CONTRACT_VERSION" ]]; then
  echo "package.sh: VERSION ($VERSION) and contracts PRODUCT_VERSION ($CONTRACT_VERSION) disagree" >&2
  exit 1
fi

case "$(uname -s)" in
  Linux) OS=linux; DESKTOP_DIR=linux_skia ;;
  Darwin) OS=macos; DESKTOP_DIR=macos_skia ;;
  *) echo "package.sh: unsupported OS $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) echo "package.sh: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
PLATFORM="$OS-$ARCH"
NAME="monexus-$VERSION-$PLATFORM"
STAGE="$OUT/$NAME"
TARBALL="$OUT/$NAME.tar.gz"

if [[ "$SKIP_BUILD" == "0" ]]; then
  echo "[1/5] moon build --target native --release"
  (cd "$ROOT" && moon build --target native --release) || exit 1
else
  echo "[1/5] reusing existing release build"
fi

HOST_EXE="$ROOT/_build/native/release/build/monexus/host/host.exe"
DESKTOP_EXE="$ROOT/_build/native/release/build/monexus/desktop/$DESKTOP_DIR/$DESKTOP_DIR.exe"
if [[ ! -x "$HOST_EXE" || ! -x "$DESKTOP_EXE" ]]; then
  echo "package.sh: release products not found at fixed paths:" >&2
  echo "  $HOST_EXE" >&2
  echo "  $DESKTOP_EXE" >&2
  echo "run: moon build --target native --release" >&2
  exit 1
fi

echo "[2/5] stage $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/share/monexus/docs/adr" \
  "$STAGE/share/monexus/examples/workspace"
install -m 0755 "$ROOT/scripts/monexus.sh" "$STAGE/bin/monexus"
install -m 0755 "$HOST_EXE" "$STAGE/bin/monexus-host"
install -m 0755 "$DESKTOP_EXE" "$STAGE/bin/monexus-desktop"
install -m 0644 "$ROOT/VERSION" "$STAGE/share/monexus/VERSION"
install -m 0644 "$ROOT/README.md" "$STAGE/share/monexus/README.md"
for doc in usage.md troubleshooting.md architecture.md m7.md; do
  if [[ -f "$ROOT/docs/$doc" ]]; then
    install -m 0644 "$ROOT/docs/$doc" "$STAGE/share/monexus/docs/$doc"
  fi
done
if compgen -G "$ROOT/docs/adr/*.md" >/dev/null; then
  cp "$ROOT/docs/adr/"*.md "$STAGE/share/monexus/docs/adr/"
fi
cat >"$STAGE/share/monexus/examples/workspace/README.md" <<'SAMPLE'
# Hello Workspace

A sample workspace shipped with MoNexus. Open it from the Projects page (or
with `workspace.open`) to try worktrees, terminals and agents without
creating a repository first.
SAMPLE
cat >"$STAGE/share/monexus/examples/workspace/AGENTS.md" <<'SAMPLE'
# AGENTS.md

Project conventions for agents. MoNexus keeps this file read-only for
sessions; durable memory lives in the agent home.
SAMPLE

echo "[3/5] verify the staged launcher"
"$STAGE/bin/monexus" version
"$STAGE/bin/monexus" --help >/dev/null
"$STAGE/bin/monexus-host" version >/dev/null
"$STAGE/bin/monexus-desktop" --version >/dev/null

echo "[4/5] tar $TARBALL"
mkdir -p "$OUT"
if [[ "$OS" == "macos" ]]; then
  # Avoid AppleDouble metadata sidecars in the archive.
  COPYFILE_DISABLE=1 tar -C "$OUT" -czf "$TARBALL" "$NAME"
else
  tar -C "$OUT" -czf "$TARBALL" "$NAME"
fi
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$OUT" && sha256sum "$NAME.tar.gz" >"$NAME.tar.gz.sha256")
else
  (cd "$OUT" && shasum -a 256 "$NAME.tar.gz" >"$NAME.tar.gz.sha256")
fi

echo "[5/5] artifacts"
echo "stage:    $STAGE"
echo "tarball:  $TARBALL"
echo "checksum: $TARBALL.sha256"
echo "layout:"
(cd "$STAGE" && find . -maxdepth 4 -type f | sort | sed 's/^/  /')
echo "size:     $(du -h "$TARBALL" | cut -f1)"
