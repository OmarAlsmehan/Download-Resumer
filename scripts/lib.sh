#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '[download-resumer] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

sanitize_name() {
  local name="$1"
  name="$(basename -- "$name")"
  name="${name// /_}"
  name="$(printf '%s' "$name" | tr -cd '[:alnum:]._-')"
  [[ -n "$name" && "$name" != "." && "$name" != ".." ]] || name="download.bin"
  printf '%s' "$name"
}

sanitize_branch() {
  local branch="$1"
  [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid branch name: $branch"
  printf '%s' "$branch"
}

safe_url_for_notes() {
  python3 - "$1" <<'PY'
from urllib.parse import urlsplit, urlunsplit
import sys
u = urlsplit(sys.argv[1])
if u.scheme not in ('http', 'https'):
    print('redacted')
else:
    host = u.hostname or ''
    port = f':{u.port}' if u.port else ''
    print(urlunsplit((u.scheme, host + port, u.path, '', '')))
PY
}

sha256() { sha256sum -- "$1" | awk '{print $1}'; }

detect_filename() {
  local url="$1"
  local header_name="$2"
  if [[ -n "$header_name" ]]; then
    printf '%s' "$header_name"
    return
  fi
  local path
  path="$(python3 - "$url" <<'PY'
from urllib.parse import urlsplit, unquote
import sys
p = unquote(urlsplit(sys.argv[1]).path)
print(p.rsplit('/', 1)[-1])
PY
)"
  [[ -n "$path" ]] || path='download.bin'
  printf '%s' "$path"
}

is_probably_compressed() {
  local f="$1"
  case "${f,,}" in
    *.7z|*.br|*.bz2|*.gz|*.gzip|*.lz4|*.lz|*.rar|*.xz|*.zst|*.zip|*.z01|*.cab|*.apk|*.jar|*.war|*.whl|*.deb|*.rpm|*.iso.xz|*.tar.gz|*.tgz|*.tar.zst|*.tzst) return 0 ;;
    *) return 1 ;;
  esac
}

parse_bytes() {
  numfmt --from=iec "$1"
}

format_bytes() {
  numfmt --to=iec "$1"
}
