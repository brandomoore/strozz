#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "usage: bash tools/run-ll-hls-probe.sh CHANNEL NEW_OUTPUT_DIRECTORY [SECONDS=90] [--trust-localhost]" >&2
  exit 2
fi
source tools/lib/apple-build-lease.sh
acquire_apple_build_shared_lease "strozz/ll-hls-probe"
install_apple_build_lease_traps
if [[ ! -x build/ll-hls-probe/venv/bin/python ]]; then
  echo "Missing probe venv. See docs/low-latency.md for dependency setup." >&2
  exit 2
fi
mkdir -p build/ll-hls-probe
xcrun swiftc -parse-as-library -O \
  tools/ll-hls-player.swift \
  Strozz/Services/LowLatencyHLSProxy.swift \
  Strozz/Models/LivePlaybackProfile.swift \
  -o build/ll-hls-probe/player
extra=()
if [[ $# -eq 4 ]]; then extra+=("$4"); fi
build/ll-hls-probe/venv/bin/python tools/ll-hls-probe.py "$1" --output "$2" --seconds "${3:-90}" \
  --player "$PWD/build/ll-hls-probe/player" ${extra[@]+"${extra[@]}"}
