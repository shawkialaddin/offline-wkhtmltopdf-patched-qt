#!/usr/bin/env bash
#
# stage-download.sh — STAGING side (run on an INTERNET-CONNECTED machine)
#
# Downloads the wkhtmltopdf "wkhtmltox" 0.12.6.1 (patched Qt) packages from the
# official wkhtmltopdf/packaging GitHub release, generates checksums, and bundles
# everything into a single tarball you can copy to the airgapped server.
#
# On the airgapped server you then run install-offline.sh from the extracted bundle.
#
# Usage:
#   ./stage-download.sh                      # download ALL distro packages (safe default)
#   ./stage-download.sh -f bookworm          # only packages matching "bookworm"
#   ./stage-download.sh -f amd64             # only amd64 packages
#   ./stage-download.sh -f jammy -f amd64    # AND of multiple filters
#   ./stage-download.sh -t 0.12.6.1-3        # pin a specific release tag
#   ./stage-download.sh -o ./out -b          # custom out dir, build tarball (default on)
#
set -euo pipefail

# ----------------------------------------------------------------------------- config
REPO="wkhtmltopdf/packaging"
TAG="0.12.6.1-3"            # the patched-Qt 0.12.6.1 release tag
OUT_DIR="wkhtmltox-offline-bundle"
BUNDLE=1
FILTERS=()

# ----------------------------------------------------------------------------- ui
c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
info()   { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()     { c_grn "[+] $*"; }
warn()   { c_ylw "[!] $*"; }
die()    { c_red "[x] $*" >&2; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ----------------------------------------------------------------------------- args
while [ $# -gt 0 ]; do
  case "$1" in
    -t|--tag)     TAG="${2:?}"; shift 2 ;;
    -o|--out)     OUT_DIR="${2:?}"; shift 2 ;;
    -f|--filter)  FILTERS+=("${2:?}"); shift 2 ;;
    -b|--bundle)  BUNDLE=1; shift ;;
    -B|--no-bundle) BUNDLE=0; shift ;;
    -h|--help)    usage 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ----------------------------------------------------------------------------- tooling
have() { command -v "$1" >/dev/null 2>&1; }
DL=""
if have curl; then DL="curl"; elif have wget; then DL="wget"; else die "need curl or wget"; fi
have sha256sum || have shasum || die "need sha256sum (or shasum)"

fetch() { # fetch URL OUTFILE
  local url="$1" out="$2"
  if [ "$DL" = curl ]; then
    curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"
  else
    wget -t 3 -O "$out" "$url"
  fi
}
fetch_stdout() { # fetch URL -> stdout
  if [ "$DL" = curl ]; then curl -fsSL "$1"; else wget -qO- "$1"; fi
}
sha256() { if have sha256sum; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# ----------------------------------------------------------------------------- discover assets
API="https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
info "Querying release assets for ${REPO} @ ${TAG}"
ASSET_JSON="$(fetch_stdout "$API")" || die "failed to query GitHub API ($API)"

# Pull every browser_download_url without depending on jq.
mapfile -t ALL_URLS < <(printf '%s\n' "$ASSET_JSON" \
  | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | sed -E 's/.*"(https[^"]*)".*/\1/')

[ "${#ALL_URLS[@]}" -gt 0 ] || die "no assets found for tag '${TAG}' — check the tag name"

# Keep only real installable packages (.deb/.rpm/.pkg.tar.* etc.), skip source/checksums noise.
URLS=()
for u in "${ALL_URLS[@]}"; do
  case "$u" in
    *.deb|*.rpm|*.pkg.tar.zst|*.pkg.tar.xz|*.txz|*.apk) URLS+=("$u") ;;
    *) ;;
  esac
done
[ "${#URLS[@]}" -gt 0 ] || die "no installable packages (.deb/.rpm/...) in release '${TAG}'"

# Apply user filters (AND semantics: filename must contain every -f term).
if [ "${#FILTERS[@]}" -gt 0 ]; then
  FILTERED=()
  for u in "${URLS[@]}"; do
    base="${u##*/}"; keep=1
    for f in "${FILTERS[@]}"; do
      case "$base" in *"$f"*) ;; *) keep=0 ;; esac
    done
    [ "$keep" = 1 ] && FILTERED+=("$u")
  done
  URLS=("${FILTERED[@]}")
  [ "${#URLS[@]}" -gt 0 ] || die "no packages match filters: ${FILTERS[*]}"
fi

info "Will download ${#URLS[@]} package(s):"
for u in "${URLS[@]}"; do printf '      %s\n' "${u##*/}"; done

# ----------------------------------------------------------------------------- download
PKG_SUB="$OUT_DIR/packages"
mkdir -p "$PKG_SUB"
for u in "${URLS[@]}"; do
  base="${u##*/}"
  if [ -s "$PKG_SUB/$base" ]; then
    warn "exists, skipping: $base"
  else
    info "downloading $base"
    fetch "$u" "$PKG_SUB/$base.part"
    mv "$PKG_SUB/$base.part" "$PKG_SUB/$base"
  fi
done
ok "downloaded ${#URLS[@]} package(s) into $PKG_SUB"

# ----------------------------------------------------------------------------- checksums + manifest
( cd "$PKG_SUB" && sha256 ./*.deb ./*.rpm ./*.pkg.tar.* ./*.apk 2>/dev/null \
    | sed 's#\./##' > SHA256SUMS ) || true
ok "wrote $PKG_SUB/SHA256SUMS"

{
  echo "wkhtmltox offline bundle"
  echo "repo:    $REPO"
  echo "tag:     $TAG"
  echo "created: (staging machine)"
  echo "files:"
  ls -1 "$PKG_SUB" | sed 's/^/  /'
} > "$OUT_DIR/MANIFEST.txt"

# Ship the installer alongside the packages so the bundle is self-contained.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SELF_DIR/install-offline.sh" ]; then
  cp "$SELF_DIR/install-offline.sh" "$OUT_DIR/"
  chmod +x "$OUT_DIR/install-offline.sh"
  ok "included install-offline.sh in bundle"
else
  warn "install-offline.sh not found next to this script — add it to $OUT_DIR/ manually"
fi

# ----------------------------------------------------------------------------- bundle
if [ "$BUNDLE" = 1 ]; then
  TARBALL="${OUT_DIR%/}.tar.gz"
  info "creating $TARBALL"
  tar -czf "$TARBALL" "$OUT_DIR"
  ( sha256 "$TARBALL" > "${TARBALL}.sha256" ) || true
  ok "bundle ready: $TARBALL  ($(du -h "$TARBALL" | cut -f1))"
  echo
  c_grn "Next steps:"
  echo "  1. Copy '$TARBALL' to the airgapped server (scp/USB)."
  echo "  2. There:  tar -xzf $(basename "$TARBALL")"
  echo "  3.         cd $OUT_DIR && sudo ./install-offline.sh"
else
  ok "staged in $OUT_DIR/ (no tarball)"
fi
