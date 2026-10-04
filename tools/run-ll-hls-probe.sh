#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 2 ]]; then
  echo "usage: bash tools/run-ll-hls-probe.sh CHANNEL NEW_OUTPUT_DIRECTORY [SECONDS=90] [probe options...]" >&2
  exit 2
fi
channel="$1"
output="$2"
shift 2
seconds=90
if [[ $# -gt 0 && "$1" != --* ]]; then
  seconds="$1"
  shift
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
  Strozz/Services/NativeCMAF.swift \
  Strozz/Services/NativeTransportStream.swift \
  Strozz/Services/NativeHLSMediaServer.swift \
  Strozz/Services/NativeHLSChunkReader.swift \
  Strozz/Services/NativeLowLatencyHLS.swift \
  Strozz/Models/LivePlaybackProfile.swift \
  -o build/ll-hls-probe/player
PYTHONDONTWRITEBYTECODE=1 build/ll-hls-probe/venv/bin/python tools/ll-hls-probe.py \
  "$channel" --output "$output" --seconds "$seconds" \
  --player "$PWD/build/ll-hls-probe/player" "$@"
