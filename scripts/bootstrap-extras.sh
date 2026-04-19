#!/usr/bin/env bash
# bootstrap-extras.sh — runtime fallback for environment setup.
#
# Purpose: even though the Dockerfile bakes in Playwright, Chromium, gh, and git,
# this script is the "belt" to the Dockerfile's "suspenders." It runs on every
# container start, is idempotent, and:
#
#   1. Installs anything missing from the image (e.g. Playwright Chromium if
#      PLAYWRIGHT_BROWSERS_PATH was moved to /data, or packages added after
#      initial deploy via /data/.hermes/extra-apt-packages).
#   2. Lets the agent extend its environment at runtime without rebuilding the
#      image — drop a script at /data/.hermes/post-bootstrap.sh and it will
#      run here on every boot.
#
# Safe to run multiple times: everything is guarded.

set -uo pipefail

log() { printf '[bootstrap-extras] %s\n' "$*"; }
warn() { printf '[bootstrap-extras] WARN: %s\n' "$*" >&2; }

# --- 1. Verify Playwright Chromium is usable -----------------------------------
# If the image was built without `playwright install chromium` (or the browsers
# path was overridden to a fresh volume), install it on first boot.
if command -v playwright >/dev/null 2>&1; then
  if ! playwright install --dry-run chromium 2>/dev/null | grep -q "is already installed"; then
    log "Chromium not found in PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH:-default} — installing…"
    playwright install chromium 2>&1 | tail -5 || warn "playwright install chromium failed; browser tool may not work"
  fi
fi

# --- 2. Optional extra apt packages --------------------------------------------
# Let the user list extra Debian packages at /data/.hermes/extra-apt-packages
# (one per line, # comments allowed). Useful for pulling in things that weren't
# anticipated in the image — ffmpeg, imagemagick, poppler-utils, etc.
EXTRA_APT_LIST="${HERMES_HOME:-/data/.hermes}/extra-apt-packages"
if [[ -f "$EXTRA_APT_LIST" ]]; then
  PKGS=$(grep -vE '^\s*#|^\s*$' "$EXTRA_APT_LIST" | tr '\n' ' ')
  if [[ -n "$PKGS" ]] && command -v apt-get >/dev/null 2>&1; then
    log "Installing extra apt packages from $EXTRA_APT_LIST: $PKGS"
    (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $PKGS) \
      2>&1 | tail -5 || warn "apt-get install failed; continuing"
  fi
fi

# --- 3. Optional extra pip packages --------------------------------------------
EXTRA_PIP_LIST="${HERMES_HOME:-/data/.hermes}/extra-pip-packages"
if [[ -f "$EXTRA_PIP_LIST" ]]; then
  PKGS=$(grep -vE '^\s*#|^\s*$' "$EXTRA_PIP_LIST" | tr '\n' ' ')
  if [[ -n "$PKGS" ]]; then
    log "Installing extra pip packages from $EXTRA_PIP_LIST: $PKGS"
    pip install --no-cache-dir $PKGS 2>&1 | tail -5 || warn "pip install failed; continuing"
  fi
fi

# --- 4. User-defined post-bootstrap hook ---------------------------------------
# Anything the agent wants to do on every boot — extend PATH, start a sidecar,
# seed config, etc. — can live here. Running it last means all of the above is
# already in place.
POST_HOOK="${HERMES_HOME:-/data/.hermes}/post-bootstrap.sh"
if [[ -x "$POST_HOOK" ]]; then
  log "Running user post-bootstrap hook: $POST_HOOK"
  "$POST_HOOK" || warn "post-bootstrap hook exited non-zero; continuing"
elif [[ -f "$POST_HOOK" ]]; then
  warn "$POST_HOOK exists but is not executable; chmod +x it to enable"
fi

log "bootstrap-extras completed."
exit 0
