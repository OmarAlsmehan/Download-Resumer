# ⬇️ Smart Download & Release

> A GitHub Actions workflow that downloads any file from the internet and publishes it as a GitHub Release — with resumable downloads, smart compression, automatic splitting, and checksum generation.

---

## ✨ Features

| Feature | Details |
|---------|---------|
| ⬇️ Smart Download | `aria2c` with automatic resume + parallel connections |
| 🧠 Filename Detection | From `Content-Disposition` header or URL path |
| 🗜️ Conditional Compression | ZIP compression only if the file isn't already compressed |
| ✂️ Auto Split | Splits large files that exceed GitHub's 2GB limit |
| 🔐 Checksums | Automatically generates `SHA256SUMS.txt` for all artifacts |
| 📝 Release Notes | Auto-generated table with source URL, details, and timestamp |
| 🏷️ Dynamic Tag | timestamp + run number — or set it manually |

---

## 🚀 Usage

### 1. Go to the **Actions** tab

### 2. Select **⬇️ Smart Download & Release**

### 3. Click **Run workflow** and fill in the inputs:

| Input | Description | Required? |
|-------|-------------|-----------|
| `url` | 🔗 URL of the file to download | ✅ Yes |
| `filename` | 📁 Output filename in the release | No (auto-detected) |
| `compress` | 🗜️ Compress the file if not already compressed | No (default: `true`) |
| `split_size` | ✂️ Split threshold (e.g. `1900M`) | No (default: `1900M`) |
| `release_tag` | 🏷️ Release tag | No (auto-generated) |
| `release_name` | 📝 Release title | No (auto-generated) |
| `connections` | ⚡ Number of parallel download connections | No (default: `8`) |

---

## 📋 Examples

**Download NDK from Google:**
```
url: https://dl.google.com/android/repository/android-ndk-r17c-linux-x86_64.zip
```

**Download a large file with splitting:**
```
url:         https://example.com/large-file.tar.gz
split_size:  1900M
connections: 16
```

**Download a raw image and compress it:**
```
url:      https://example.com/firmware.img
compress: true
filename: my-firmware.img
```

---

## 🔧 How It Works

```
1. Resolves the filename from Content-Disposition header or URL path
2. Downloads the file via aria2c with automatic resume support
3. Detects whether the file is already compressed — compresses it if not (when enabled)
4. Splits the file if it exceeds the configured size limit
5. Generates SHA256SUMS.txt for all output files
6. Publishes everything as a GitHub Release with auto-generated release notes
```

---

## ⚙️ Requirements

- A public or private GitHub repository
- `contents: write` permission enabled in the workflow (already included)
- No additional setup required

---

## 📦 Release Structure

```
📦 Release
├── filename.zip          ← the file (compressed or as-is)
├── filename.zip.part001  ← (if splitting was triggered)
├── filename.zip.part002
└── SHA256SUMS.txt        ← checksums for integrity verification
```

### Verify file integrity after downloading:
```bash
sha256sum -c SHA256SUMS.txt
```

### Reassemble split parts after downloading:
```bash
cat filename.zip.part* > filename.zip
```

---

## 📄 License

[MIT License](LICENSE) — free to use, modify, and distribute.

