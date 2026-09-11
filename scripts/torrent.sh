#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

usage() {
  cat <<'USAGE'
Usage:
  torrent.sh --source SOURCE --workdir DIR --outputdir DIR [options]

Source:
  magnet:?xt=urn:btih:...      Magnet URI
  /path/file.torrent            Local torrent metainfo
  https://.../file.torrent     HTTP(S) .torrent URL
  https://lite.utorrent.com/player?...   uTorrent Lite share URL

Options:
  --source SOURCE              Torrent source (required)
  --workdir DIR                Temporary working directory (required)
  --outputdir DIR              Release asset directory (required)
  --compression MODE           auto|none|zstd|gzip|zip (default: auto)
  --split-size SIZE            e.g. 1900M (default: 1900M)
  --connections N              Maximum peers (default: 50)
  --seed-time MINUTES          Seed after completion; 0 disables seeding (default: 0)
  --expected-sha256 SHA256     Verify single-file torrent payload
  --auth-header HEADER         Optional HTTP header used only to fetch HTTP(S) metainfo
USAGE
}

SOURCE=''
ORIGINAL_SOURCE=''
WORKDIR=''
OUTPUTDIR=''
COMPRESSION='auto'
SPLIT_SIZE='1900M'
CONNECTIONS='50'
SEED_TIME='0'
EXPECTED=''
AUTH_HEADER=''

while (($#)); do
  case "$1" in
    --source) SOURCE="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --outputdir) OUTPUTDIR="$2"; shift 2 ;;
    --compression) COMPRESSION="$2"; shift 2 ;;
    --split-size) SPLIT_SIZE="$2"; shift 2 ;;
    --connections) CONNECTIONS="$2"; shift 2 ;;
    --seed-time) SEED_TIME="$2"; shift 2 ;;
    --expected-sha256) EXPECTED="$2"; shift 2 ;;
    --auth-header) AUTH_HEADER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "$SOURCE" ]] || die '--source is required'
ORIGINAL_SOURCE="$SOURCE"
[[ -n "$WORKDIR" && -n "$OUTPUTDIR" ]] || die '--workdir and --outputdir are required'
[[ "$CONNECTIONS" =~ ^[1-9][0-9]*$ ]] || die '--connections must be a positive integer'
[[ "$SEED_TIME" =~ ^[0-9]+$ ]] || die '--seed-time must be a non-negative integer'
[[ "$EXPECTED" =~ ^$|^[0-9a-fA-F]{64}$ ]] || die '--expected-sha256 must be 64 hexadecimal characters'

mkdir -p "$WORKDIR" "$OUTPUTDIR"
require_cmd aria2c
require_cmd sha256sum
require_cmd find
require_cmd stat
require_cmd tar
require_cmd numfmt

TORRENT_DIR="$WORKDIR/torrent"
DOWNLOAD_DIR="$WORKDIR/download"
mkdir -p "$TORRENT_DIR" "$DOWNLOAD_DIR"

cleanup_output() {
  find "$OUTPUTDIR" -mindepth 1 -maxdepth 1 -type f -delete
}
cleanup_output

TORRENT_FILE=''
SOURCE_TYPE=''
MAGNET_SOURCE=''

case "$SOURCE" in
  magnet:*)
    SOURCE_TYPE='magnet'
    ;;
  https://lite.utorrent.com/player?*|https://lite.utorrent.com/player/?*)
    require_cmd python3
    SOURCE_TYPE='utorrent-share'
    MAGNET_SOURCE="$(python3 - "$SOURCE" <<'PY'
from base64 import b64decode
from urllib.parse import parse_qs, urlsplit
import sys

url = sys.argv[1]
query = parse_qs(urlsplit(url).query)
encoded = query.get('m', [''])[0]
if not encoded:
    raise SystemExit('uTorrent Lite URL has no m= parameter')
try:
    value = b64decode(encoded, validate=True).decode('utf-8')
except Exception as exc:
    raise SystemExit(f'invalid uTorrent Lite m= value: {exc}')
if not value.startswith('magnet:?'):
    raise SystemExit('uTorrent Lite m= does not contain a Magnet URI')
print(value)
PY
)"
    SOURCE="$MAGNET_SOURCE"
    log 'Converted uTorrent Lite share URL to Magnet URI'
    ;;
  http://*|https://*)
    SOURCE_TYPE='torrent-url'
    require_cmd curl
    TORRENT_FILE="$TORRENT_DIR/input.torrent"
    curl_args=(--fail --location --retry 8 --retry-all-errors --connect-timeout 15 --max-time 120 -sS -o "$TORRENT_FILE")
    if [[ -n "$AUTH_HEADER" ]]; then
      echo "::add-mask::$AUTH_HEADER"
      curl_args+=(--header "$AUTH_HEADER")
    fi
    curl "${curl_args[@]}" "$SOURCE"
    [[ -s "$TORRENT_FILE" ]] || die 'Downloaded .torrent file is empty'
    SOURCE_TYPE='torrent-file'
    ;;
  *)
    [[ -f "$SOURCE" ]] || die "Torrent file not found: $SOURCE"
    cp -- "$SOURCE" "$TORRENT_DIR/input.torrent"
    TORRENT_FILE="$TORRENT_DIR/input.torrent"
    SOURCE_TYPE='torrent-file'
    ;;
esac

aria_args=(
  --dir="$DOWNLOAD_DIR"
  --continue=true
  --always-resume=true
  --allow-overwrite=true
  --auto-file-renaming=false
  --max-overall-download-limit=0
  --bt-max-peers="$CONNECTIONS"
  --bt-enable-lpd=true
  --enable-peer-exchange=true
  --seed-time="$SEED_TIME"
  --check-integrity=true
  --summary-interval=30
  --timeout=30
  --connect-timeout=15
  --max-tries=10
  --retry-wait=5
)

log "Torrent source: $SOURCE_TYPE"
log "Download directory: $DOWNLOAD_DIR"
log "Max peers: $CONNECTIONS"
log "Seed time: ${SEED_TIME} minute(s)"

if [[ "$SOURCE_TYPE" == 'magnet' ]]; then
  aria2c "${aria_args[@]}" "$SOURCE"
else
  aria2c "${aria_args[@]}" "$TORRENT_FILE"
fi

mapfile -t FILES < <(find "$DOWNLOAD_DIR" -type f ! -name '*.aria2' -printf '%p\n' | sort)
((${#FILES[@]} > 0)) || die 'Torrent completed without any regular files'

PAYLOAD=''
PAYLOAD_KIND=''
if ((${#FILES[@]} == 1)); then
  PAYLOAD="${FILES[0]}"
  PAYLOAD_KIND='single-file'
  if [[ -n "$EXPECTED" ]]; then
    actual="$(sha256 "$PAYLOAD")"
    [[ "${actual,,}" == "${EXPECTED,,}" ]] || die "SHA256 mismatch: got $actual, expected $EXPECTED"
  fi
else
  PAYLOAD="$WORKDIR/torrent-content.tar"
  tar --exclude='*.aria2' -cf "$PAYLOAD" -C "$DOWNLOAD_DIR" .
  PAYLOAD_KIND='multi-file-archive'
fi


INFO="$WORKDIR/TORRENT-INFO.txt"
{
  printf 'source_type=%s\n' "$SOURCE_TYPE"
  printf 'source=%s\n' "$(safe_url_for_notes "$ORIGINAL_SOURCE")"
  if [[ "$SOURCE_TYPE" == 'utorrent-share' ]]; then
    printf 'resolved_magnet=%s\n' "$(safe_url_for_notes "$SOURCE")"
  fi
  printf 'payload_kind=%s\n' "$PAYLOAD_KIND"
  printf 'file_count=%s\n' "${#FILES[@]}"
  printf 'seed_time_minutes=%s\n' "$SEED_TIME"
  printf 'max_peers=%s\n' "$CONNECTIONS"
  printf 'payload_name=%s\n' "$(basename -- "$PAYLOAD")"
  printf 'payload_sha256=%s\n' "$(sha256 "$PAYLOAD")"
} > "$INFO"

# A multi-file torrent is intentionally archived as one payload before the common
# packaging stage. A single-file torrent is passed through unchanged.
args=(
  --input "$PAYLOAD"
  --workdir "$WORKDIR/package"
  --outputdir "$OUTPUTDIR"
  --compression "$COMPRESSION"
  --split-size "$SPLIT_SIZE"
)
mkdir -p "$WORKDIR/package"
scripts_dir="$(dirname "$0")"
"$scripts_dir/process-file.sh" "${args[@]}"

cp -- "$INFO" "$OUTPUTDIR/TORRENT-INFO.txt"

# Add a compact restore guide specific to the torrent workflow.
cat > "$OUTPUTDIR/TORRENT-RESTORE.txt" <<EOF2
Torrent payload restore
=======================

Payload type: $PAYLOAD_KIND
Files downloaded from torrent: ${#FILES[@]}

For a single-file torrent, use the packaged file after verifying its SHA256.

For a multi-file torrent, the payload is a tar archive containing the torrent contents.
First join any split assets and decompress the artifact when RESTORE.txt says to do so, then:
  tar -tf torrent-content.tar
  mkdir restored
  tar -xf torrent-content.tar -C restored
EOF2

log "Torrent completed: ${#FILES[@]} file(s)"
log "Payload: $(basename -- "$PAYLOAD")"
