#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

usage() {
  cat <<'USAGE'
Usage:
  process-file.sh --input FILE --workdir DIR --outputdir DIR [options]

Options:
  --input FILE             Source file
  --workdir DIR            Temporary working directory
  --outputdir DIR          Release asset directory
  --compression MODE       auto|none|zstd|gzip|zip (default: auto)
  --split-size SIZE        e.g. 1900M (default: 1900M)
  --original-sha PATH      Write original SHA256 to this file
  --artifact-info PATH     Write machine-readable artifact metadata
USAGE
}

INPUT=''
WORKDIR=''
OUTPUTDIR=''
COMPRESSION='auto'
SPLIT_SIZE='1900M'
ORIG_SHA_FILE=''
INFO_FILE=''

while (($#)); do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --outputdir) OUTPUTDIR="$2"; shift 2 ;;
    --compression) COMPRESSION="$2"; shift 2 ;;
    --split-size) SPLIT_SIZE="$2"; shift 2 ;;
    --original-sha) ORIG_SHA_FILE="$2"; shift 2 ;;
    --artifact-info) INFO_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -f "$INPUT" ]] || die "Input file not found: $INPUT"
[[ -n "$WORKDIR" && -n "$OUTPUTDIR" ]] || die "--workdir and --outputdir are required"
mkdir -p "$WORKDIR" "$OUTPUTDIR"

require_cmd sha256sum
require_cmd numfmt
require_cmd split

ORIGINAL_SIZE=$(stat -c '%s' "$INPUT")
ORIGINAL_HASH=$(sha256 "$INPUT")
ORIGINAL_NAME=$(basename -- "$INPUT")
printf '%s  %s\n' "$ORIGINAL_HASH" "$ORIGINAL_NAME" > "${ORIG_SHA_FILE:-$WORKDIR/original.sha256}"

MODE="$COMPRESSION"
if [[ "$MODE" == 'auto' ]]; then
  if is_probably_compressed "$INPUT"; then MODE='none'; else MODE='zstd'; fi
fi

ARTIFACT="$INPUT"
case "$MODE" in
  none)
    ;;
  zstd)
    require_cmd zstd
    ARTIFACT="$WORKDIR/${ORIGINAL_NAME}.zst"
    zstd -T0 -6 --no-progress -f "$INPUT" -o "$ARTIFACT"
    ;;
  gzip)
    ARTIFACT="$WORKDIR/${ORIGINAL_NAME}.gz"
    gzip -6 -c "$INPUT" > "$ARTIFACT"
    ;;
  zip)
    require_cmd zip
    ARTIFACT="$WORKDIR/${ORIGINAL_NAME}.zip"
    (cd "$(dirname "$INPUT")" && zip -q -9 "$ARTIFACT" "$(basename "$INPUT")")
    ;;
  *) die "Unsupported compression mode: $MODE" ;;
esac

ARTIFACT_SIZE=$(stat -c '%s' "$ARTIFACT")
ARTIFACT_HASH=$(sha256 "$ARTIFACT")
ARTIFACT_NAME=$(basename -- "$ARTIFACT")

find "$OUTPUTDIR" -mindepth 1 -maxdepth 1 -type f -delete
LIMIT=$(parse_bytes "$SPLIT_SIZE")
PART_COUNT=1
SPLIT=false

if (( ARTIFACT_SIZE > LIMIT )); then
  SPLIT=true
  split --bytes="$SPLIT_SIZE" --numeric-suffixes=1 --suffix-length=3 \
    "$ARTIFACT" "$OUTPUTDIR/${ARTIFACT_NAME}.part"
  mapfile -t ASSETS < <(find "$OUTPUTDIR" -maxdepth 1 -type f -name "${ARTIFACT_NAME}.part*" -printf '%f\n' | sort)
  PART_COUNT=${#ASSETS[@]}
else
  cp -- "$ARTIFACT" "$OUTPUTDIR/$ARTIFACT_NAME"
  ASSETS=("$ARTIFACT_NAME")
fi

{
  printf 'source_name=%s\n' "$ORIGINAL_NAME"
  printf 'source_size=%s\n' "$ORIGINAL_SIZE"
  printf 'source_sha256=%s\n' "$ORIGINAL_HASH"
  printf 'compression=%s\n' "$MODE"
  printf 'artifact_name=%s\n' "$ARTIFACT_NAME"
  printf 'artifact_size=%s\n' "$ARTIFACT_SIZE"
  printf 'artifact_sha256=%s\n' "$ARTIFACT_HASH"
  printf 'split=%s\n' "$SPLIT"
  printf 'parts=%s\n' "$PART_COUNT"
} > "${INFO_FILE:-$WORKDIR/artifact.info}"

printf '%s  %s\n' "$ARTIFACT_HASH" "$ARTIFACT_NAME" > "$OUTPUTDIR/ARTIFACT-SHA256.txt"
printf '%s  %s\n' "$ORIGINAL_HASH" "$ORIGINAL_NAME" > "$OUTPUTDIR/SOURCE-SHA256.txt"
: > "$OUTPUTDIR/SHA256SUMS.txt"
for asset in "${ASSETS[@]}"; do
  if [[ -f "$OUTPUTDIR/$asset" ]]; then
    printf '%s  %s\n' "$(sha256 "$OUTPUTDIR/$asset")" "$asset" >> "$OUTPUTDIR/SHA256SUMS.txt"
  fi
done

cat > "$OUTPUTDIR/RESTORE.txt" <<EOF2
Download-Resumer artifact
========================
Source: $ORIGINAL_NAME
Original SHA256: $ORIGINAL_HASH
Compression: $MODE
Artifact SHA256: $ARTIFACT_HASH

If the artifact was split, join the parts first:
  cat ${ARTIFACT_NAME}.part* > ${ARTIFACT_NAME}

Then verify the artifact hash:
  sha256sum ${ARTIFACT_NAME}
  # expected: $ARTIFACT_HASH

Decompress when needed:
  zstd -d ${ARTIFACT_NAME}
  gzip -d ${ARTIFACT_NAME}
  unzip ${ARTIFACT_NAME}
EOF2

log "Source:  $ORIGINAL_NAME ($(format_bytes "$ORIGINAL_SIZE"))"
log "Artifact: $ARTIFACT_NAME ($(format_bytes "$ARTIFACT_SIZE"))"
log "Mode:    $MODE"
log "Split:   $SPLIT ($PART_COUNT asset(s))"
log "SHA256:  $ARTIFACT_HASH"
