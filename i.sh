#!/usr/bin/env bash
set -euo pipefail

# nvtop installer/runner for Ubuntu/Debian pods.
# Designed for direct execution or curl|bash usage.
#
# Modes:
#   default: install + self-check + run (if interactive TTY), else install + self-check
#   --install-only: install + self-check, never launch TUI
#   --run: force launch TUI after install (requires interactive TTY)
#
# Example (once hosted somewhere reachable):
#   curl -fsSL "https://<host>/install_run_nvtop.sh" | bash

NVTOP_VERSION="${NVTOP_VERSION:-3.2.0}"
NVTOP_URL="${NVTOP_URL:-https://github.com/Syllo/nvtop/archive/refs/tags/${NVTOP_VERSION}.tar.gz}"
BUILD_DIR="${BUILD_DIR:-/tmp/nvtop-build}"
AUTORUN="auto" # auto|yes|no
SELF_TEST=1

log() { printf '[nvtop-installer] %s\n' "$*"; }
err() { printf '[nvtop-installer][ERROR] %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: install_run_nvtop.sh [--install-only] [--run] [--no-self-test] [--help]

Options:
  --install-only   Install and verify only; do not launch nvtop UI.
  --run            Force launch nvtop UI after install (interactive TTY required).
  --no-self-test   Skip post-install checks.
  --help           Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-only) AUTORUN="no"; shift ;;
    --run) AUTORUN="yes"; shift ;;
    --no-self-test) SELF_TEST=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    err "Need root or sudo to install packages."
    exit 1
  fi
fi

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

if [[ "$AUTORUN" == "auto" ]]; then
  if is_interactive; then
    AUTORUN="yes"
  else
    AUTORUN="no"
    log "Non-interactive context detected; using install-only behavior."
  fi
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Missing required command: $1"
    return 1
  }
}

apt_update() {
  if [[ -n "$SUDO" ]]; then
    $SUDO apt-get update -y
  else
    apt-get update -y
  fi
}

apt_install() {
  if [[ -n "$SUDO" ]]; then
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  else
    env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  fi
}

download_file() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$url" "$out" <<'PY'
import sys, urllib.request
url, out = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url, timeout=120) as r, open(out, 'wb') as f:
    f.write(r.read())
PY
    return 0
  fi
  return 1
}

preflight_checks() {
  require_cmd apt-get
  if [[ "$AUTORUN" == "yes" ]] && ! is_interactive; then
    err "--run requested but no interactive TTY available."
    exit 1
  fi
}

install_from_apt() {
  log "Trying apt package install..."
  apt_update

  if apt_install nvtop; then
    return 0
  fi

  if apt_install nvtop-nvidia; then
    return 0
  fi

  if command -v add-apt-repository >/dev/null 2>&1; then
    log "Trying to enable universe and reinstall..."
    if [[ -n "$SUDO" ]]; then
      $SUDO add-apt-repository -y universe || true
    else
      add-apt-repository -y universe || true
    fi
    apt_update
    if apt_install nvtop; then
      return 0
    fi
  fi

  return 1
}

install_from_source() {
  log "Falling back to source build from ${NVTOP_URL}"
  apt_update
  apt_install build-essential cmake pkg-config git libncurses5-dev libncursesw5-dev libdrm-dev

  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  local tarball="${BUILD_DIR}/nvtop.tar.gz"

  if ! download_file "$NVTOP_URL" "$tarball"; then
    err "Could not download nvtop source. Need curl, wget, or python3."
    return 1
  fi

  tar -xzf "$tarball" -C "$BUILD_DIR"
  local src
  src="$(find "$BUILD_DIR" -maxdepth 1 -type d -name 'nvtop-*' | head -n1)"
  [[ -n "$src" ]] || { err "Could not find extracted nvtop source."; return 1; }

  cmake -S "$src" -B "$src/build"
  cmake --build "$src/build" -j"$(nproc 2>/dev/null || echo 2)"
  if [[ -n "$SUDO" ]]; then
    $SUDO cmake --install "$src/build"
  else
    cmake --install "$src/build"
  fi
}

post_install_checks() {
  require_cmd nvtop

  local ver
  ver="$(nvtop --version 2>/dev/null || true)"
  if [[ -n "$ver" ]]; then
    log "$ver"
  else
    log "nvtop installed (version output not available)."
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    log "GPU detected via nvidia-smi."
  else
    log "nvidia-smi not found; nvtop may still work if NVML is present."
  fi
}

run_nvtop() {
  log "Launching nvtop... (Ctrl+C to exit)"
  exec nvtop
}

main() {
  preflight_checks

  if command -v nvtop >/dev/null 2>&1; then
    log "nvtop already installed."
  else
    if ! install_from_apt; then
      install_from_source
    fi
  fi

  if [[ "$SELF_TEST" -eq 1 ]]; then
    post_install_checks
  fi

  if [[ "$AUTORUN" == "yes" ]]; then
    run_nvtop
  else
    log "Install completed (run suppressed). Use: nvtop"
  fi
}

main "$@"
