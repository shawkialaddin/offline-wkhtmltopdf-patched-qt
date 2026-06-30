#!/usr/bin/env bash
#
# install-offline.sh — AIRGAPPED side (run on the offline target server, as root)
#
# Replaces an existing wkhtmltopdf 0.12.6 (typically the distro package, unpatched
# Qt / "reduced functionality") with wkhtmltox 0.12.6.1 (patched Qt) from a local
# package file. NO network access is required or used.
#
# It auto-detects the distro/arch, picks the matching package out of ./packages/,
# verifies its checksum, removes the conflicting old distro package, installs the
# new one, and verifies the result reports "with patched qt".
#
# Usage (from inside the extracted bundle):
#   sudo ./install-offline.sh                 # interactive
#   sudo ./install-offline.sh -y              # non-interactive (assume yes)
#   sudo ./install-offline.sh -p /path/pkgs   # packages live elsewhere
#   sudo ./install-offline.sh -P pkg.deb      # force a specific package file
#   sudo ./install-offline.sh --keep-old      # don't remove old distro wkhtmltopdf
#   sudo ./install-offline.sh --no-verify     # skip SHA256 check
#
set -euo pipefail

# ----------------------------------------------------------------------------- config
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$SCRIPT_DIR/packages"
FORCE_PKG=""
ASSUME_YES=0
KEEP_OLD=0
DO_VERIFY=1
LOG="/var/log/wkhtmltox-offline-install.$(date +%Y%m%d-%H%M%S).log"

# ----------------------------------------------------------------------------- ui
c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()    { c_grn "[+] $*"; }
warn()  { c_ylw "[!] $*"; }
die()   { c_red "[x] $*" >&2; exit 1; }

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

ask() { # ask "question" -> 0 yes / 1 no
  [ "$ASSUME_YES" = 1 ] && return 0
  local a; read -r -p "$1 [y/N] " a || true
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ----------------------------------------------------------------------------- args
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)       ASSUME_YES=1; shift ;;
    -p|--pkg-dir)   PKG_DIR="${2:?}"; shift 2 ;;
    -P|--package)   FORCE_PKG="${2:?}"; shift 2 ;;
    --keep-old)     KEEP_OLD=1; shift ;;
    --no-verify)    DO_VERIFY=0; shift ;;
    -h|--help)      usage 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# tee everything to a log for audit on the airgapped box
exec > >(tee -a "$LOG") 2>&1
info "Logging to $LOG"

# ----------------------------------------------------------------------------- preflight
[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"
have() { command -v "$1" >/dev/null 2>&1; }
sha256() { if have sha256sum; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# ----------------------------------------------------------------------------- detect platform
. /etc/os-release 2>/dev/null || die "cannot read /etc/os-release"
DISTRO_ID="${ID:-unknown}"
DISTRO_LIKE="${ID_LIKE:-}"
CODENAME="${VERSION_CODENAME:-}"
VER_MAJOR="${VERSION_ID%%.*}"

PKG_KIND=""        # deb | rpm
case "$DISTRO_ID $DISTRO_LIKE" in
  *debian*|*ubuntu*) PKG_KIND="deb" ;;
  *rhel*|*fedora*|*centos*|*almalinux*|*rocky*|*amzn*|*suse*) PKG_KIND="rpm" ;;
  *) if have dpkg; then PKG_KIND="deb"; elif have rpm; then PKG_KIND="rpm"; fi ;;
esac
[ -n "$PKG_KIND" ] || die "could not determine package type (deb/rpm) for ID='$DISTRO_ID'"

if [ "$PKG_KIND" = deb ]; then
  ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
else
  case "$(uname -m)" in x86_64) ARCH=x86_64 ;; aarch64) ARCH=aarch64 ;; *) ARCH="$(uname -m)" ;; esac
fi

info "Detected: ID=$DISTRO_ID codename='${CODENAME:-?}' ver=$VERSION_ID type=$PKG_KIND arch=$ARCH"

# Build an ordered list of filename keywords to try (most specific first, then
# sensible fallbacks). The patched-Qt builds bundle their own Qt, so a near
# neighbour (e.g. bullseye on debian 11/12) works fine if the exact one is absent.
CANDIDATES=()
if [ "$PKG_KIND" = deb ]; then
  [ -n "$CODENAME" ] && CANDIDATES+=("$CODENAME")
  case "$DISTRO_ID" in
    debian) CANDIDATES+=(bookworm bullseye buster) ;;
    ubuntu) CANDIDATES+=(jammy focal bionic) ;;
    *)      CANDIDATES+=(bookworm jammy bullseye focal) ;;
  esac
else
  case "$DISTRO_ID" in
    amzn)                         CANDIDATES+=("amazonlinux2" "amazonlinux2023") ;;
    centos|rhel|rocky|almalinux)  CANDIDATES+=("almalinux${VER_MAJOR}" "centos${VER_MAJOR}" "almalinux9" "almalinux8" "centos7") ;;
    fedora)                       CANDIDATES+=("almalinux9" "almalinux8") ;;
    opensuse*|sles|suse)          CANDIDATES+=("openSUSE" "opensuse") ;;
    *)                            CANDIDATES+=("almalinux9" "almalinux8" "centos7") ;;
  esac
fi

# ----------------------------------------------------------------------------- pick package file
pick_package() {
  if [ -n "$FORCE_PKG" ]; then
    [ -f "$FORCE_PKG" ] || die "package not found: $FORCE_PKG"
    printf '%s\n' "$FORCE_PKG"; return 0
  fi
  [ -d "$PKG_DIR" ] || die "package dir not found: $PKG_DIR (use -p)"
  local ext="$PKG_KIND" f
  for kw in "${CANDIDATES[@]}"; do
    # match files containing both the distro keyword and the arch
    for f in "$PKG_DIR"/*"$kw"*"$ARCH"*."$ext"; do
      [ -e "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
  done
  # last resort: any package of the right type+arch
  for f in "$PKG_DIR"/*"$ARCH"*."$ext"; do
    [ -e "$f" ] && { warn "no exact distro match; falling back to $(basename "$f")" >&2; printf '%s\n' "$f"; return 0; }
  done
  return 1
}

PKG="$(pick_package)" || die "no matching .$PKG_KIND for distro=[${CANDIDATES[*]}] arch=$ARCH in $PKG_DIR
       available: $(ls -1 "$PKG_DIR" 2>/dev/null | tr '\n' ' ')"
ok "Selected package: $(basename "$PKG")"

# ----------------------------------------------------------------------------- verify checksum
if [ "$DO_VERIFY" = 1 ] && [ -f "$PKG_DIR/SHA256SUMS" ]; then
  info "Verifying checksum against SHA256SUMS"
  base="$(basename "$PKG")"
  if grep -q " $base\$\|  $base\$\| \*$base\$" "$PKG_DIR/SHA256SUMS"; then
    ( cd "$PKG_DIR" && grep " $base\$\|  $base\$\| \*$base\$" SHA256SUMS | sha256 -c - ) \
      || die "CHECKSUM MISMATCH for $base — bundle corrupted; re-transfer"
    ok "checksum verified"
  else
    warn "no checksum entry for $base in SHA256SUMS — skipping"
  fi
else
  [ "$DO_VERIFY" = 1 ] && warn "no SHA256SUMS present — skipping checksum verification"
fi

# ----------------------------------------------------------------------------- record current state
info "Current wkhtmltopdf state (pre-install):"
if have wkhtmltopdf; then
  echo "    path:    $(command -v wkhtmltopdf)"
  echo "    version: $(wkhtmltopdf --version 2>&1 | head -1 || true)"
else
  echo "    (wkhtmltopdf not currently on PATH)"
fi

# Identify a conflicting OLD distro package providing wkhtmltopdf (the 0.12.6 one).
OLD_PKG=""
if [ "$PKG_KIND" = deb ]; then
  if dpkg-query -W -f='${Package}\n' wkhtmltopdf 2>/dev/null | grep -q .; then OLD_PKG="wkhtmltopdf"; fi
else
  if rpm -q wkhtmltopdf >/dev/null 2>&1; then OLD_PKG="wkhtmltopdf"; fi
fi
[ -n "$OLD_PKG" ] && info "Found old distro package: $OLD_PKG"

echo
c_ylw "About to:"
[ -n "$OLD_PKG" ] && [ "$KEEP_OLD" = 0 ] && echo "  - remove old package: $OLD_PKG"
echo "  - install: $(basename "$PKG")"
echo
ask "Proceed?" || die "aborted by user"

# ----------------------------------------------------------------------------- remove old
if [ -n "$OLD_PKG" ] && [ "$KEEP_OLD" = 0 ]; then
  info "Removing $OLD_PKG (offline)"
  if [ "$PKG_KIND" = deb ]; then
    apt-get remove -y "$OLD_PKG" 2>/dev/null || dpkg -r "$OLD_PKG" || warn "removal returned non-zero; continuing"
  else
    rpm -e "$OLD_PKG" || warn "removal returned non-zero; continuing"
  fi
fi

# ----------------------------------------------------------------------------- install new
info "Installing $(basename "$PKG")"
INSTALL_RC=0
if [ "$PKG_KIND" = deb ]; then
  # dpkg installs from the local file with no network. If deps are missing it
  # fails cleanly and we report them (apt cannot fetch them on an airgapped box).
  dpkg -i "$PKG" || INSTALL_RC=$?
  if [ "$INSTALL_RC" -ne 0 ]; then
    warn "dpkg reported unmet dependencies. Missing deps must be pre-installed offline."
    echo "    Unmet dependencies (from apt-get check):"
    apt-get -f install --no-download -y 2>&1 | sed 's/^/      /' || true
    die "install failed due to missing dependencies — install them from your offline repo and re-run"
  fi
else
  # rpm -U upgrades in place; --replacepkgs allows reinstall of same NVR.
  rpm -Uvh --replacepkgs "$PKG" || INSTALL_RC=$?
  if [ "$INSTALL_RC" -ne 0 ]; then
    die "rpm install failed (likely missing deps) — install them from your offline repo and re-run"
  fi
fi
ok "package installed"

# Refresh shared-library cache (wkhtmltox ships its own libwkhtmltox).
have ldconfig && ldconfig || true
hash -r 2>/dev/null || true

# ----------------------------------------------------------------------------- verify
echo
info "Post-install verification:"
BIN="$(command -v wkhtmltopdf || true)"
[ -n "$BIN" ] || die "wkhtmltopdf not found on PATH after install (check /usr/local/bin is on PATH)"
echo "    path:    $BIN"
VOUT="$(wkhtmltopdf --version 2>&1 | head -1 || true)"
echo "    version: $VOUT"

case "$VOUT" in
  *0.12.6.1*patched*qt*|*0.12.6.1*"patched qt"*) ok "SUCCESS — wkhtmltopdf 0.12.6.1 with patched Qt is active" ;;
  *0.12.6.1*) warn "version is 0.12.6.1 but the string didn't confirm 'patched qt' — verify manually" ;;
  *) die "unexpected version output — replacement may not have taken effect. Check 'which -a wkhtmltopdf'." ;;
esac

# Quick functional smoke test (renders a tiny PDF) — does NOT need network.
if ask "Run a quick render smoke-test?"; then
  TMP_HTML="$(mktemp --suffix=.html)"; TMP_PDF="$(mktemp --suffix=.pdf)"
  printf '<html><body><h1>wkhtmltox offline OK</h1></body></html>' > "$TMP_HTML"
  if wkhtmltopdf --quiet "$TMP_HTML" "$TMP_PDF" 2>/dev/null && [ -s "$TMP_PDF" ]; then
    ok "render test passed ($(du -h "$TMP_PDF" | cut -f1) PDF produced)"
  else
    warn "render test failed — binary installed but rendering errored (often a missing font/lib). Check '$LOG'."
  fi
  rm -f "$TMP_HTML" "$TMP_PDF"
fi

echo
ok "Done. Full log: $LOG"
