#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

REPO_URL=''
BRANCH=''
WORKDIR=''
COMPRESSION='zstd'
SPLIT_SIZE='1900M'
OUTPUTDIR=''
HTTP_HEADER=''

while (($#)); do
  case "$1" in
    --repo) REPO_URL="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --compression) COMPRESSION="$2"; shift 2 ;;
    --split-size) SPLIT_SIZE="$2"; shift 2 ;;
    --outputdir) OUTPUTDIR="$2"; shift 2 ;;
    --http-header) HTTP_HEADER="$2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "$REPO_URL" =~ ^https?:// ]] || die "Repository URL must use http(s)"
[[ -n "$WORKDIR" && -n "$OUTPUTDIR" ]] || die "Missing directories"
[[ -z "$BRANCH" || "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid branch"
mkdir -p "$WORKDIR" "$OUTPUTDIR"

require_cmd git
require_cmd sha256sum
require_cmd numfmt

REMOTE_NAME=$(basename "${REPO_URL%%\?*}" .git)
REMOTE_NAME=$(sanitize_name "$REMOTE_NAME")
CLONE_DIR="$WORKDIR/${REMOTE_NAME}.git"
rm -rf "$CLONE_DIR"

if [[ -n "$HTTP_HEADER" ]]; then
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=http.extraHeader
  export GIT_CONFIG_VALUE_0="$HTTP_HEADER"
fi
git clone --bare "$REPO_URL" "$CLONE_DIR"
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 2>/dev/null || true

if [[ -n "$BRANCH" ]]; then
  git -C "$CLONE_DIR" show-ref --verify --quiet "refs/heads/$BRANCH" || die "Branch not found: $BRANCH"
  REF="refs/heads/$BRANCH"
  SCOPE="branch:$BRANCH"
else
  REF='--all'
  SCOPE='all refs'
fi

BUNDLE_BASE="$REMOTE_NAME"
if [[ -n "$BRANCH" ]]; then BUNDLE_BASE="${REMOTE_NAME}-$(printf '%s' "$BRANCH" | tr '/' '-')"; fi
BUNDLE="$WORKDIR/${BUNDLE_BASE}.bundle"

if [[ "$REF" == "--all" ]]; then
  git -C "$CLONE_DIR" bundle create "$BUNDLE" --all
else
  git -C "$CLONE_DIR" bundle create "$BUNDLE" "$REF"
fi
git -C "$CLONE_DIR" bundle verify "$BUNDLE" >/dev/null

COMPRESSION_MODE="$COMPRESSION"
case "$COMPRESSION_MODE" in
  none) ARTIFACT="$BUNDLE" ;;
  zstd)
    require_cmd zstd
    ARTIFACT="$WORKDIR/$(basename "$BUNDLE").zst"
    zstd -T0 -6 --no-progress -f "$BUNDLE" -o "$ARTIFACT"
    ;;
  gzip)
    ARTIFACT="$WORKDIR/$(basename "$BUNDLE").gz"
    gzip -6 -c "$BUNDLE" > "$ARTIFACT"
    ;;
  *) die "Git bundle compression must be none|zstd|gzip" ;;
esac

SIZE=$(stat -c '%s' "$ARTIFACT")
HASH=$(sha256 "$ARTIFACT")
LIMIT=$(parse_bytes "$SPLIT_SIZE")
NAME=$(basename "$ARTIFACT")
find "$OUTPUTDIR" -mindepth 1 -maxdepth 1 -type f -delete

if (( SIZE > LIMIT )); then
  split --bytes="$SPLIT_SIZE" --numeric-suffixes=1 --suffix-length=3 \
    "$ARTIFACT" "$OUTPUTDIR/${NAME}.part"
else
  cp -- "$ARTIFACT" "$OUTPUTDIR/$NAME"
fi

printf '%s  %s\n' "$HASH" "$NAME" > "$OUTPUTDIR/ARTIFACT-SHA256.txt"
: > "$OUTPUTDIR/SHA256SUMS.txt"
for f in "$OUTPUTDIR"/*; do
  case "$(basename "$f")" in
    SHA256SUMS.txt|ARTIFACT-SHA256.txt|GIT-BUNDLE-INFO.txt|GIT-HEAD.txt|GIT-NAME.txt) continue ;;
  esac
  printf '%s  %s\n' "$(sha256 "$f")" "$(basename "$f")" >> "$OUTPUTDIR/SHA256SUMS.txt"
done

cat > "$OUTPUTDIR/GIT-BUNDLE-INFO.txt" <<EOF2
Repository: $(safe_url_for_notes "$REPO_URL")
Scope: $SCOPE
Bundle SHA256: $HASH
Bundle size: $SIZE bytes

Restore:
  # If split, join parts first:
  cat ${NAME}.part* > ${NAME}
  # Decompress if needed:
  zstd -d ${NAME}
  # Verify the resulting .bundle with:
  git bundle verify ${BUNDLE_BASE}.bundle
  # Clone:
  git clone ${BUNDLE_BASE}.bundle ${REMOTE_NAME}-restored
EOF2

git -C "$CLONE_DIR" rev-parse HEAD > "$OUTPUTDIR/GIT-HEAD.txt"
printf '%s\n' "$REMOTE_NAME" > "$OUTPUTDIR/GIT-NAME.txt"
log "Repo: $REMOTE_NAME"
log "Scope: $SCOPE"
log "Artifact: $NAME ($(format_bytes "$SIZE"))"
log "SHA256: $HASH"
