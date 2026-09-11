#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/fakebin" "$TMP/out-single" "$TMP/out-multi"
cat > "$TMP/fakebin/aria2c" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
dir=''
for arg in "$@"; do
  case "$arg" in
    --dir=*) dir="${arg#--dir=}" ;;
  esac
done
[[ -n "$dir" ]] || { echo 'fake aria2c: --dir missing' >&2; exit 2; }
mkdir -p "$dir"
if [[ "${FAKE_TORRENT_MODE:-single}" == single ]]; then
  printf 'fake torrent payload\n' > "$dir/payload.bin"
else
  mkdir -p "$dir/torrent-root"
  printf 'one\n' > "$dir/torrent-root/one.txt"
  printf 'two\n' > "$dir/torrent-root/two.txt"
  : > "$dir/torrent-root/incomplete.aria2"
fi
FAKE
chmod +x "$TMP/fakebin/aria2c"
export PATH="$TMP/fakebin:$PATH"

torrent="$TMP/test.torrent"
printf 'not a real torrent; fake aria2c consumes it\n' > "$torrent"

# uTorrent Lite share URL -> embedded Magnet conversion path. The fake aria2c
# means this validates parsing without contacting any real torrent peers.
utorrent_url='https://lite.utorrent.com/player?m=bWFnbmV0Oj94dD11cm46YnRpaDo5QjRFMUM4REYxQTFCMENDRUI1NDJBRDFGRDZGQ0Y2RDAzNjk0Mjk4JmRuPXRlc3Q%3D&only_test=1'
"$ROOT/scripts/torrent.sh" \
  --source "$utorrent_url" \
  --workdir "$TMP/work-utorrent" \
  --outputdir "$TMP/out-single" \
  --compression none \
  --split-size 1K
[[ -f "$TMP/out-single/TORRENT-INFO.txt" ]] || { echo 'uTorrent share conversion failed' >&2; exit 1; }
grep -q '^source_type=utorrent-share$' "$TMP/out-single/TORRENT-INFO.txt"
grep -q '^resolved_magnet=redacted' "$TMP/out-single/TORRENT-INFO.txt"

"$ROOT/scripts/torrent.sh" \
  --source "$torrent" \
  --workdir "$TMP/work-single" \
  --outputdir "$TMP/out-single" \
  --compression none \
  --split-size 1K

[[ -f "$TMP/out-single/payload.bin" ]] || { echo 'single-file output missing' >&2; exit 1; }
grep -q 'payload_kind=single-file' "$TMP/out-single/TORRENT-INFO.txt"
(cd "$TMP/out-single" && sha256sum -c SHA256SUMS.txt >/dev/null)

export FAKE_TORRENT_MODE=multi
"$ROOT/scripts/torrent.sh" \
  --source "$torrent" \
  --workdir "$TMP/work-multi" \
  --outputdir "$TMP/out-multi" \
  --compression none \
  --split-size 1K

[[ -f "$TMP/out-multi/TORRENT-INFO.txt" ]] || { echo 'multi-file metadata missing' >&2; exit 1; }
grep -q 'payload_kind=multi-file-archive' "$TMP/out-multi/TORRENT-INFO.txt"
cat "$TMP/out-multi"/torrent-content.tar.part* > "$TMP/reassembled.tar"
mkdir "$TMP/restored"
tar -xf "$TMP/reassembled.tar" -C "$TMP/restored"
[[ "$(cat "$TMP/restored/torrent-root/one.txt")" == one ]]
[[ "$(cat "$TMP/restored/torrent-root/two.txt")" == two ]]
[[ ! -e "$TMP/restored/torrent-root/incomplete.aria2" ]]
(cd "$TMP/out-multi" && sha256sum -c SHA256SUMS.txt >/dev/null)

echo 'Torrent tests passed.'
