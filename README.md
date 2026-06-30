# Offline replace wkhtmltopdf 0.12.6 → 0.12.6.1 (patched Qt)

Replaces an existing **wkhtmltopdf 0.12.6** (the distro package, built against an
*unpatched* Qt — "reduced functionality") with the official **wkhtmltox 0.12.6.1
patched-Qt** build on an **airgapped** server. No internet is touched on the target.

`0.12.6.1-3` is the release tag from the official
[`wkhtmltopdf/packaging`](https://github.com/wkhtmltopdf/packaging) repo. The
patched-Qt build is what gives you full headers/footers, page breaks, forms, etc.

## Two-step workflow

### 1. On an internet-connected machine — stage the packages

```bash
./stage-download.sh                 # download ALL distro/arch packages (safe)
# or narrow it down if you know the target:
./stage-download.sh -f bookworm -f amd64
```

Produces `wkhtmltox-offline-bundle.tar.gz` containing:

```
wkhtmltox-offline-bundle/
├── packages/            # the .deb / .rpm files + SHA256SUMS
├── install-offline.sh   # the installer (copied in automatically)
└── MANIFEST.txt
```

Filenames are discovered live from the GitHub release API, so they're always the
real assets — nothing is hard-coded/guessed.

| Flag | Meaning |
|------|---------|
| `-f <term>` | Keep only packages whose name contains `<term>` (repeatable, AND'd) |
| `-t <tag>`  | Use a different release tag (default `0.12.6.1-3`) |
| `-o <dir>`  | Output directory |
| `-B`        | Don't build the tarball, just stage the folder |

### 2. Copy to the airgapped server, then install

```bash
tar -xzf wkhtmltox-offline-bundle.tar.gz
cd wkhtmltox-offline-bundle
sudo ./install-offline.sh           # interactive
# or:
sudo ./install-offline.sh -y        # non-interactive
```

The installer:

1. Auto-detects distro family, version codename, and architecture.
2. Picks the matching package from `packages/` (with sensible fallbacks — e.g.
   Ubuntu Focal/amd64 → `jammy_amd64`, Debian Buster → `bullseye`).
3. Verifies the package SHA256 against `SHA256SUMS`.
4. Records the current `wkhtmltopdf --version`.
5. Removes the conflicting old distro `wkhtmltopdf` package (skip with `--keep-old`).
6. Installs the new package via `dpkg -i` / `rpm -Uvh` — **offline**.
7. Verifies the result reports `0.12.6.1 (with patched qt)` and offers a render smoke-test.
8. Logs everything to `/var/log/wkhtmltox-offline-install.<timestamp>.log`.

| Flag | Meaning |
|------|---------|
| `-y`            | Assume "yes" (non-interactive) |
| `-p <dir>`      | Package directory (default `./packages`) |
| `-P <file>`     | Force a specific package file |
| `--keep-old`    | Don't remove the old distro `wkhtmltopdf` |
| `--no-verify`   | Skip checksum verification |

## Important: dependencies on the airgapped box

The patched-Qt build **bundles its own Qt**, so it has only a handful of runtime
deps (fontconfig, freetype, libjpeg, libpng, libx11/xext/xrender, zlib). These are
present on almost every server. If `dpkg`/`rpm` reports a missing dependency, it
cannot be fetched offline — install it from your own offline repo/mirror first,
then re-run. The installer prints exactly which deps are missing.

## Verify manually any time

```bash
wkhtmltopdf --version
# expected:  wkhtmltopdf 0.12.6.1 (with patched qt)
which -a wkhtmltopdf      # patched build installs to /usr/local/bin
```
