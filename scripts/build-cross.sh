#!/usr/bin/env bash
# Builds the Windows / Linux (and macOS CLI) binaries into dist/<os>-<arch>/.
#   ./scripts/build-cross.sh                 all targets
#   ./scripts/build-cross.sh linux/amd64     one target
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
TARGETS=("${@:-windows/amd64 windows/arm64 linux/amd64 linux/arm64}")
for t in ${TARGETS[@]}; do
  os=${t%/*}; arch=${t#*/}; out="dist/$os-$arch"; mkdir -p "$out"
  bin=ontutunnel; flags="-s -w -X main.Version=$VERSION"
  if [ "$os" = windows ]; then bin=ontutunnel.exe; flags="$flags -H windowsgui"; fi
  (cd cross && CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -ldflags "$flags" -o "../$out/$bin" .)
  echo "built $out/$bin"
done
