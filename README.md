# Download Resumer

> **Resumable downloads, Git repositories, and BitTorrent payloads — packaged and published through GitHub Actions.**

Download Resumer is a small GitHub Actions toolkit for moving large files and repositories through **GitHub Releases** without treating Git itself as a file-transfer protocol.

The project is deliberately split into independent pipelines:

| Pipeline | Input | Output |
|---|---|---|
| 🌐 **HTTP/HTTPS** | Direct download URL | GitHub Release assets |
| 🧬 **Git Bundle** | Git repository | Portable `.bundle` artifact |
| 🧲 **Torrent** | Magnet / `.torrent` | Torrent payload as release assets |

All three pipelines share the same packaging, splitting, hashing, and release conventions.

---

## ✨ Features

- **Resume support** through `aria2c`
- **Multi-connection HTTP downloads**
- **BitTorrent / Magnet support**
- **Real Git Bundles** instead of copying `.git`
- Optional **SHA256 verification** of downloaded source data
- Automatic or manual **compression**
- Automatic **splitting** for large artifacts
- Standard `sha256sum -c` compatible checksums
- Restore instructions included in every release
- Private download support through **GitHub Actions secrets**
- Shell scripts use strict error handling
- Separate Torrent pipeline — HTTP downloading does **not** depend on Torrent code
- GitHub Actions workflows are designed to be easy to fork and customize

---

## 🏗️ Architecture

```text
                         Download Resumer
                                │
              ┌─────────────────┼─────────────────┐
              │                 │                 │
           HTTP(S)          Git Bundle         Torrent
              │                 │                 │
           aria2c           git bundle          aria2c
              │                 │                 │
              └─────────────────┼─────────────────┘
                                │
                         Processing layer
                                │
                 ┌──────────────┼──────────────┐
                 │              │              │
             Compress         Split         SHA256
                 │              │              │
                 └──────────────┼──────────────┘
                                │
                         GitHub Release
```

The Torrent implementation is intentionally isolated in:

```text
scripts/torrent.sh
.github/workflows/torrent.yml
```

It does **not** get mixed into the normal HTTP downloader.

---

## 📁 Project structure

```text
Download-Resumer/
├── .github/
│   └── workflows/
│       ├── download.yml
│       ├── git-bundle.yml
│       ├── torrent.yml
│       └── test.yml
│
├── scripts/
│   ├── lib.sh
│   ├── process-file.sh
│   ├── make-git-bundle.sh
│   └── torrent.sh
│
├── tests/
│   ├── test.sh
│   └── torrent-test.sh
│
├── LICENSE
└── README.md
```

---

# 🌐 HTTP / HTTPS Downloads

Workflow:

**Actions → Download & Release → Run workflow**

### Inputs

| Input | Description | Default |
|---|---|---:|
| `url` | Direct HTTP/HTTPS download URL | required |
| `filename` | Override output filename | automatic |
| `expected_sha256` | Expected SHA256 of original download | empty |
| `connections` | Connections per server | `16` |
| `compression` | `auto`, `none`, `zstd`, `gzip`, `zip` | `auto` |
| `split_size` | Maximum release asset size | `1900M` |
| `prerelease` | Create a prerelease | `false` |

Example:

```text
url:
https://example.com/large-file.iso

connections:
16

compression:
auto

split_size:
1900M
```

The download uses `aria2c` with resume enabled. If the source provides suitable range support, multiple connections can significantly improve throughput.

---

# 🧬 Git Bundle

Workflow:

**Actions → Git Bundle & Release → Run workflow**

Instead of doing this:

```text
clone repository
      ↓
delete working tree
      ↓
keep .git
      ↓
archive .git
```

Download Resumer creates a **real Git Bundle**:

```text
Git repository
      ↓
git clone --bare
      ↓
git bundle create
      ↓
git bundle verify
      ↓
compress / split
      ↓
GitHub Release
```

### Branch selection

Leave `branch` empty to bundle all refs.

Set a branch such as:

```text
main
```

to create a branch-scoped bundle.

### Restore

After downloading and joining split parts:

```bash
# If compressed with zstd
zstd -d repo.bundle.zst

# Verify the bundle
git bundle verify repo.bundle

# Restore it
git clone repo.bundle restored-repo
```

A full bundle can preserve repository refs and tags. A branch-scoped bundle intentionally contains only the selected branch history.

---

# 🧲 Torrent

Torrent support is a **standalone pipeline**.

Workflow:

**Actions → Torrent & Release → Run workflow**

### Supported sources

| Source | Support |
|---|---:|
| Magnet URI | ✅ |
| uTorrent Lite share URL (`lite.utorrent.com/player?...`) | ✅ |
| HTTP/HTTPS `.torrent` URL | ✅ |
| Local `.torrent` file | ✅ script / suitable runner |

The actual Torrent download is handled only by:

```text
scripts/torrent.sh
```

The script also understands uTorrent Lite share links. It extracts the `m=` parameter, decodes it as Base64, validates that it contains a Magnet URI, and then passes the resolved Magnet directly to `aria2c`. The original share URL is retained in metadata in redacted form.

### Torrent flow

```text
Magnet / .torrent
       ↓
     aria2c
       ↓
Torrent payload
       ↓
Single file? ────── yes ──→ process directly
       │
       no
       ↓
torrent-content.tar
       ↓
compress / split / hash
       ↓
GitHub Release
```

### Torrent options

| Input | Description | Default |
|---|---|---:|
| `source` | Magnet, uTorrent Lite share URL, or HTTP(S) metainfo URL | required |
| `connections` | Maximum BitTorrent peers | `50` |
| `seed_time` | Seeding time after completion | `0` |
| `compression` | `auto`, `none`, `zstd`, `gzip`, `zip` | `auto` |
| `split_size` | Maximum release asset size | `1900M` |
| `expected_sha256` | SHA256 for a single-file payload | empty |
| `prerelease` | Create a prerelease | `false` |

### Multi-file torrents

Torrent metadata may contain several files. In that case the complete payload is packed into:

```text
torrent-content.tar
```

This keeps the release simple: one logical torrent payload becomes one restorable artifact, which can then be compressed and split if necessary.

### Torrent integrity

`aria2c` verifies BitTorrent pieces using the hashes contained in the torrent metadata.

For a single-file torrent, `expected_sha256` can additionally verify the final downloaded file against a known SHA256.

### ⚠️ Resume limitation on GitHub-hosted runners

`aria2c` can resume an interrupted torrent when its partial data and control files still exist.

However, standard GitHub-hosted Actions runners are **ephemeral**. A completely new workflow run starts on a fresh runner, so it cannot automatically continue the partial download from an earlier run.

True cross-run Torrent resume requires persistent storage, for example:

- a self-hosted runner
- a persistent disk
- external object storage

---

# 📦 Compression

The processing layer supports:

```text
none
zstd
gzip
zip
auto
```

`auto` avoids recompressing formats that are already compressed, while using Zstandard for data that normally benefits from compression.

For general-purpose large files, `zstd` is the recommended option.

---

# ✂️ Splitting large artifacts

GitHub Release assets have a size limit, so large final artifacts are split before publishing.

The default is intentionally conservative:

```text
1900M
```

Example:

```text
large-file.zst.001
large-file.zst.002
large-file.zst.003
```

Reassemble with:

```bash
cat large-file.zst.* > large-file.zst
```

Then verify it using the release checksum before extracting it.

---

# 🔐 Integrity

Every release contains checksum metadata.

### `SOURCE-SHA256.txt`

SHA256 of the **original downloaded source** before compression or splitting.

### `ARTIFACT-SHA256.txt`

SHA256 of the **final compressed artifact** before splitting.

### `SHA256SUMS.txt`

SHA256 hashes of the binary release assets in standard format.

Verify downloaded parts with:

```bash
sha256sum -c SHA256SUMS.txt
```

Then reconstruct the artifact:

```bash
cat large-file.zst.* > large-file.zst
```

And verify the reconstructed artifact against `ARTIFACT-SHA256.txt`.

---

# 🔑 Private sources

Do **not** put credentials directly into workflow inputs or URLs when avoidable.

Use repository secrets instead.

### HTTP(S)

Create:

```text
DOWNLOAD_AUTH_HEADER
```

Example value:

```text
Authorization: Bearer YOUR_TOKEN
```

### Git

Create:

```text
GIT_AUTH_HEADER
```

### Torrent `.torrent` URL

Create:

```text
TORRENT_AUTH_HEADER
```

Secrets are passed to the relevant workflow instead of being embedded in public workflow inputs.

---

# 🧪 Testing locally

Run the main test suite:

```bash
bash tests/test.sh
```

Run the Torrent-specific tests:

```bash
bash tests/torrent-test.sh
```

Validate shell syntax:

```bash
bash -n scripts/*.sh tests/*.sh
```

The test suite covers the important processing path, including compression, splitting, reconstruction, checksums, and restoration logic.

---

# 🚀 Getting started

1. Fork or copy the repository.
2. Push it to GitHub.
3. Open the **Actions** tab.
4. Enable workflows if GitHub asks.
5. Select the pipeline you need.
6. Choose **Run workflow**.
7. Wait for the job to finish.
8. Open the generated GitHub Release.

No server is required for the basic workflow.

---

# ⚙️ Design goals

This project intentionally favors:

- **simple shell scripts** over a large application
- **separate pipelines** over one giant downloader
- **real Git formats** over ad-hoc archives
- **verifiable artifacts** over blind uploads
- **GitHub Releases** as the publication layer
- **portable restore commands** that work outside GitHub Actions

The goal is not to replace dedicated download managers. The goal is to provide a small automation layer that can take a large remote object, process it safely, and publish it as a reproducible release artifact.

---

# 🛡️ Security notes

- Never commit access tokens or passwords.
- Prefer GitHub repository secrets for authentication headers.
- Release notes sanitize source URLs to avoid unnecessarily exposing query strings or URL userinfo.
- Scripts use strict Bash error handling.
- Filenames and branch names are validated before being used in filesystem paths or Git operations.

---

# 📄 License

MIT License.
