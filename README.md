# Download Resumer

A GitHub Actions toolkit for turning large HTTP downloads and Git repositories into **resumable, verifiable GitHub Releases**.

## What changed

This project intentionally uses two clean pipelines:

- **Download:** HTTP(S) URL → resumable `aria2c` download → optional SHA256 verification → optional compression → safe splitting → GitHub Release.
- **Git Bundle:** Git repository → bare clone → portable `git bundle` → optional compression → safe splitting → GitHub Release.

The old approach of cloning a working tree and then deleting everything except `.git` is gone. A Git repository is now represented by a real Git bundle, which can be verified and cloned back normally.

## Why GitHub Releases?

GitHub documents a per-release-asset limit of **under 2 GiB**, so the default chunk size is `1900M`, leaving headroom.

## Download workflow

Run **Actions → Download & Release → Run workflow**.

Inputs:

| Input | Purpose | Default |
|---|---|---|
| `url` | Direct HTTP(S) URL | required |
| `filename` | Filename override | auto |
| `expected_sha256` | Verify original bytes | blank |
| `connections` | `aria2c` connections/server | `16` |
| `compression` | `auto`, `none`, `zstd`, `gzip`, `zip` | `auto` |
| `split_size` | Maximum release asset size | `1900M` |

For private HTTP endpoints, set the repository secret `DOWNLOAD_AUTH_HEADER` to a value such as `Authorization: Bearer …`. For private Git repositories, set `GIT_AUTH_HEADER` similarly. Do not put credentials in workflow inputs or URLs.

## Git Bundle workflow

Run **Actions → Git Bundle & Release → Run workflow**.

- Leave `branch` empty to bundle all refs.
- Set `branch` to bundle only one branch.
- The workflow always creates a real Git bundle and verifies it with `git bundle verify` before publishing.
- A full bundle includes the repository refs and tags; a branch-scoped bundle intentionally contains only the selected branch history.

### Restore a bundle

```bash
# After joining split parts, decompress if needed.
zstd -d repo.bundle.zst

git bundle verify repo.bundle
git clone repo.bundle restored-repo
```

## Integrity model

Every release includes `SHA256SUMS.txt` plus restore instructions. The downloader records:

1. `SOURCE-SHA256.txt` — SHA256 of the original downloaded bytes.
2. `ARTIFACT-SHA256.txt` — SHA256 of the final compressed artifact.
3. `SHA256SUMS.txt` — SHA256 of every uploaded release asset, compatible with `sha256sum -c`.

So joining the parts can be checked against the hash of the original final artifact before decompression.

## Local tests

```bash
bash tests/test.sh
```

The test covers compression, splitting, reassembly, SHA256 verification, and restoration.

## Security notes

- Credentials should be supplied via repository secrets, not plain workflow inputs.
- URLs written to release notes are sanitized to remove query strings and userinfo.
- Shell scripts use `set -Eeuo pipefail` and validate names/branches before use.

## License

MIT
