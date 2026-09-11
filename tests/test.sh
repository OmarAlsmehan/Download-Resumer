#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'Download Resumer test payload\n%.0s' {1..10000} > "$TMP/source.bin"

mkdir -p "$TMP/out"
"$ROOT/scripts/process-file.sh" \
  --input "$TMP/source.bin" \
  --workdir "$TMP/work" \
  --outputdir "$TMP/out" \
  --compression zstd \
  --split-size 50

expected="$(sha256 "$TMP/source.bin")"
source_hash="$(awk '{print $1}' "$TMP/out/SOURCE-SHA256.txt")"
[[ "$expected" == "$source_hash" ]]

artifact="$TMP/work/source.bin.zst"
artifact_hash="$(sha256 "$artifact")"
manifest_hash="$(awk '{print $1}' "$TMP/out/ARTIFACT-SHA256.txt")"
[[ "$artifact_hash" == "$manifest_hash" ]]

mkdir "$TMP/reassembled"
cat "$TMP/out"/source.bin.zst.part* > "$TMP/reassembled/source.bin.zst"
[[ "$(sha256 "$TMP/reassembled/source.bin.zst")" == "$artifact_hash" ]]
(cd "$TMP/out" && sha256sum -c SHA256SUMS.txt >/dev/null)
zstd -q -d "$TMP/reassembled/source.bin.zst" -o "$TMP/restored.bin"
cmp "$TMP/source.bin" "$TMP/restored.bin"

echo 'All tests passed.'
