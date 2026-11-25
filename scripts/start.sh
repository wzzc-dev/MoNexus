#!/usr/bin/env bash
# One-command start: delegates to the M7 launcher.
#   scripts/start.sh            -> host + desktop window
#   scripts/start.sh --headless -> host only (no display needed)
set -u -o pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/monexus.sh" start "$@"
