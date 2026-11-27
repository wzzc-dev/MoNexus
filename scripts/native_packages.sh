#!/usr/bin/env bash
# Print the native package directories that belong to the current host OS.
#
# A root-wide native build also compiles the other platform's desktop entry:
# on Linux that reaches AppKit/Foundation stubs and fails, and on macOS it
# reaches Linux-only dependencies. Keep the platform entry selection here so
# CI, packaging, and smoke scripts all use the same package list.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

case "$(uname -s)" in
  Linux)
    DESKTOP_DIR=linux_skia
    OTHER_DESKTOP_DIR=macos_skia
    ;;
  Darwin)
    DESKTOP_DIR=macos_skia
    OTHER_DESKTOP_DIR=linux_skia
    ;;
  *)
    echo "native_packages.sh: unsupported OS: $(uname -s)" >&2
    echo "supported native hosts are Linux and Darwin" >&2
    exit 1
    ;;
esac

if [[ ! -f "apps/desktop/$DESKTOP_DIR/moon.pkg" ]]; then
  echo "native_packages.sh: missing desktop package apps/desktop/$DESKTOP_DIR" >&2
  exit 1
fi

find apps packages services spikes \
  \( -type d \( -name _build -o -name .repos -o -name node_modules -o -name target \) -prune \) -o \
  \( -type f -name moon.pkg -print \) |
  sed 's#/moon.pkg$##' |
  grep -Ev "^apps/desktop/$OTHER_DESKTOP_DIR(/|$)" |
  LC_ALL=C sort
