# Step-by-step: Offline replace wkhtmltopdf 0.12.6 → 0.12.6.1 (patched Qt)

A copy-paste runbook for swapping the unpatched **wkhtmltopdf 0.12.6** for the
official **wkhtmltox 0.12.6.1 patched-Qt** build on an **airgapped** server.

> The patched-Qt build (release tag `0.12.6.1-3` from
> [`wkhtmltopdf/packaging`](https://github.com/wkhtmltopdf/packaging)) is what
> restores full headers/footers, page breaks, forms, and outline support.

---

## Overview

```
[ Internet box ]                         [ Airgapped server ]
  stage-download.sh                         install-offline.sh
        │                                          │
        ├─ query GitHub release API               ├─ detect distro/arch
        ├─ download .deb/.rpm + SHA256SUMS         ├─ pick + checksum package
        └─ tar up bundle  ──── scp / USB ────►     ├─ remove old 0.12.6
                                                   ├─ install new (offline)
                                                   └─ verify "patched qt"
```

---

## Part A — Staging machine (has internet)

### A1. Get the scripts onto the staging box
Copy `stage-download.sh` and `install-offline.sh` (and `README.md`) into a folder.

### A2. Download and bundle the packages

```bash
chmod +x stage-download.sh install-offline.sh

# Option 1 — grab every distro/arch (safe if you're unsure of the target):
./stage-download.sh

# Option 2 — narrow it down if you know the target, e.g. Debian 12 / amd64:
./stage-download.sh -f bookworm -f amd64
```

Result: **`wkhtmltox-offline-bundle.tar.gz`** plus a `.sha256` next to it.

The bundle contains:
```
wkhtmltox-offline-bundle/
├── packages/            # .deb / .rpm files + SHA256SUMS
├── install-offline.sh   # installer (auto-included)
└── MANIFEST.txt
```

### A3. (Optional) note the tarball checksum for transfer integrity
```bash
cat wkhtmltox-offline-bundle.tar.gz.sha256
```

---

## Part B — Transfer to the airgapped server

Use whatever your environment allows (SCP through a jump host, USB, etc.):

```bash
scp wkhtmltox-offline-bundle.tar.gz user@airgapped-host:/tmp/
```

Then on the airgapped server, optionally confirm the tarball survived transfer:
```bash
sha256sum -c wkhtmltox-offline-bundle.tar.gz.sha256   # if you copied the .sha256 too
```

---

## Part C — Airgapped server (no internet)

### C1. Extract
```bash
cd /tmp
tar -xzf wkhtmltox-offline-bundle.tar.gz
cd wkhtmltox-offline-bundle
```

### C2. Check the current version (before)
```bash
wkhtmltopdf --version || echo "not installed yet"
# typically:  wkhtmltopdf 0.12.6 (with unpatched qt)
```

### C3. Run the installer (as root)
```bash
sudo ./install-offline.sh           # interactive (asks before changes)
# or fully non-interactive:
sudo ./install-offline.sh -y
```

What it does automatically:
1. Detects distro family, version codename, and architecture.
2. Picks the matching package from `packages/` — with fallbacks
   (e.g. Ubuntu Focal/amd64 → `jammy_amd64`, Debian Buster → `bullseye`,
   RHEL/Rocky 8 → `almalinux8`).
3. Verifies the package SHA256 against `SHA256SUMS`.
4. Removes the conflicting old distro `wkhtmltopdf` (skip with `--keep-old`).
5. Installs the new package via `dpkg -i` / `rpm -Uvh` — **no network**.
6. Verifies the result and offers a render smoke-test.
7. Logs to `/var/log/wkhtmltox-offline-install.<timestamp>.log`.

### C4. Verify (after)
```bash
wkhtmltopdf --version
# expected:  wkhtmltopdf 0.12.6.1 (with patched qt)

which -a wkhtmltopdf      # patched build installs to /usr/local/bin
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `dpkg`/`rpm` reports **missing dependencies** | The patched build bundles its own Qt, so deps are few (fontconfig, freetype, libjpeg, libpng, libx11/xext/xrender, zlib). Install the named dep from your offline repo, then re-run. |
| `wkhtmltopdf` still shows **0.12.6 / unpatched** | An old binary is shadowing the new one. Run `which -a wkhtmltopdf`; remove/relink the stale one. The new build lives in `/usr/local/bin`. |
| "no matching .deb/.rpm for distro" | Your bundle didn't include the target distro. Re-run `stage-download.sh` without a filter, or pass `-P <file>` to force a specific package. |
| Checksum mismatch | The tarball was corrupted in transfer — re-copy it. |
| Wrong distro picked | Force it: `sudo ./install-offline.sh -P packages/wkhtmltox_0.12.6.1-3.<codename>_<arch>.deb` |

---

## Command reference

**`stage-download.sh`** (online)

| Flag | Meaning |
|------|---------|
| `-f <term>` | Keep only packages whose name contains `<term>` (repeatable, AND'd) |
| `-t <tag>`  | Release tag (default `0.12.6.1-3`) |
| `-o <dir>`  | Output directory |
| `-B`        | Don't build the tarball |

**`install-offline.sh`** (airgapped, root)

| Flag | Meaning |
|------|---------|
| `-y`          | Assume yes (non-interactive) |
| `-p <dir>`    | Package directory (default `./packages`) |
| `-P <file>`   | Force a specific package file |
| `--keep-old`  | Don't remove the old distro `wkhtmltopdf` |
| `--no-verify` | Skip checksum verification |
