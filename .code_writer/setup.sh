#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Logging + retry helpers
# ------------------------------------------------------------------------------
# Timestamped log line so progress is visible in CI/sandbox output.
log() { echo "[code-writer $(date -u +%H:%M:%S)] $*"; }

# Retry a command a few times with a delay between attempts. Used to wrap the
# network-bound steps (apk/apt/curl/sdkmanager/uv) so a single transient
# timeout — e.g. fetching APKINDEX.tar.gz on the first pull — does not abort
# the whole setup via `set -e`.
#   usage: retry <max_attempts> <cmd> [args...]
retry() {
  local max="$1"; shift
  local delay="${RETRY_DELAY:-5}"
  local n=1
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "$n" -ge "$max" ]; then
      log "WARNING: command failed after ${n} attempts: $*"
      return 1
    fi
    log "attempt ${n}/${max} failed: $* — retrying in ${delay}s..."
    n=$((n + 1))
    sleep "$delay"
  done
}

START_TS=$(date -u +%s)
log "Setting up repo for Claude Code..."
log "shell: $(bash --version 2>/dev/null | head -n 1 || echo unknown)"
log "uname: $(uname -a 2>/dev/null || echo unknown)"

REPO_DIR="${REPO_DIR:-/workspace/repo}"
cd "$REPO_DIR"

# ------------------------------------------------------------------------------
# Policy knobs
# ------------------------------------------------------------------------------
export CODE_WRITER_GIT_AUTHOR_NAME="${CODE_WRITER_GIT_AUTHOR_NAME:-Michael Benisch}"
export CODE_WRITER_GIT_AUTHOR_EMAIL="${CODE_WRITER_GIT_AUTHOR_EMAIL:-michael.benisch@gomotive.com}"

# Android emulator setup is intentionally opt-in. It is slow, large, and may fail
# in containerized sandboxes without nested virtualization/KVM.
export CODE_WRITER_ANDROID_EMULATOR="${CODE_WRITER_ANDROID_EMULATOR:-0}"

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/workspace/android-sdk}"
ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
export ANDROID_SDK_ROOT ANDROID_HOME

export GRADLE_USER_HOME="${GRADLE_USER_HOME:-/workspace/.gradle}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-/workspace/.cache/uv}"
export PRE_COMMIT_HOME="${PRE_COMMIT_HOME:-/workspace/.cache/pre-commit}"

mkdir -p "$ANDROID_SDK_ROOT" "$GRADLE_USER_HOME" "$UV_CACHE_DIR" "$PRE_COMMIT_HOME"


# ------------------------------------------------------------------------------
# Basic tools
# ------------------------------------------------------------------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Install OS packages, detecting the distro's package manager. The sandbox image
# is Alpine (apk); Debian (apt-get) is supported as a fallback.
#
# Network steps are wrapped in retry() so a transient index-fetch timeout (e.g.
# APKINDEX.tar.gz from dl-cdn.alpinelinux.org on the first pull) is retried
# rather than aborting the whole script under `set -e`. A package step that
# still fails after retries is non-fatal here: downstream checks already warn
# and degrade gracefully when a tool is missing.
install_pkg() {
  log "installing OS package(s): $*"
  if need_cmd apk; then
    # `apk update` primes the index up front and gives the retry loop a cheap,
    # explicit target before `apk add` resolves packages against it.
    retry 2 apk update || log "WARNING: apk update did not complete; continuing"
    retry 2 apk add --no-cache "$@" || log "WARNING: apk add failed for: $*"
  elif need_cmd apt-get; then
    retry 2 apt-get update || log "WARNING: apt-get update did not complete; continuing"
    retry 2 env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" \
      || log "WARNING: apt-get install failed for: $*"
  else
    log "no apk/apt-get available; skipping package install for: $*"
  fi
}

# >>>>>>>>>>>>>>>>>>>>>> MOTIVE DEBUG BLOCK (safe to delete) >>>>>>>>>>>>>>>>>>>>>>
# Temporary connectivity diagnostics. The pod forces all egress through
# claude-egress-proxy (squid); apk failing to fetch dl-cdn.alpinelinux.org means
# that host is not on the proxy allowlist. These probes log exactly what is and
# isn't reachable so we can see it in the git-clone container logs.
#
# TO REMOVE: delete everything between the two "MOTIVE DEBUG BLOCK" marker lines,
# and delete /motive.sh (kept in sync with this block).
MOTIVE_PROBE_TIMEOUT="${MOTIVE_PROBE_TIMEOUT:-15}"

motive_probe() {
  url="$1"
  if need_cmd curl; then
    if code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$MOTIVE_PROBE_TIMEOUT" "$url" 2>/dev/null); then
      log "[motive] OK   curl $url -> HTTP $code"
    else
      log "[motive] FAIL curl $url (curl exit $?)"
    fi
  elif need_cmd wget; then
    # Alpine/busybox ships wget even when curl is absent; use it as a fallback.
    if wget -q -T "$MOTIVE_PROBE_TIMEOUT" -O /dev/null "$url" 2>/dev/null; then
      log "[motive] OK   wget $url"
    else
      log "[motive] FAIL wget $url (wget exit $?)"
    fi
  else
    log "[motive] SKIP no curl/wget available to probe $url"
  fi
}

motive_healthcheck() {
  log "[motive] ===== connectivity health check START ====="
  log "[motive] whoami=$(id -un 2>/dev/null || echo '?') uid=$(id -u 2>/dev/null || echo '?')"
  log "[motive] HTTP_PROXY=${HTTP_PROXY:-<unset>}"
  log "[motive] HTTPS_PROXY=${HTTPS_PROXY:-<unset>}"
  log "[motive] NO_PROXY=${NO_PROXY:-<unset>}"
  log "[motive] http client: curl=$(need_cmd curl && echo yes || echo no) wget=$(need_cmd wget && echo yes || echo no)"
  for url in \
    "https://dl-cdn.alpinelinux.org/alpine/v3.23/main/x86_64/APKINDEX.tar.gz" \
    "https://dl-cdn.alpinelinux.org/alpine/v3.23/community/x86_64/APKINDEX.tar.gz" \
    "https://github.com" \
    "https://pypi.org/simple/" \
    "https://astral.sh/uv/install.sh" \
    "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"; do
    motive_probe "$url"
  done
  log "[motive] ===== connectivity health check END ====="
}

# Never let diagnostics abort setup.
motive_healthcheck || true
# <<<<<<<<<<<<<<<<<<<<<< MOTIVE DEBUG BLOCK (safe to delete) <<<<<<<<<<<<<<<<<<<<<<

log "checking for basic tools (curl unzip git)..."
missing=()
for cmd in curl unzip git; do
  if need_cmd "$cmd"; then
    log "  found: $cmd"
  else
    log "  missing: $cmd"
    missing+=("$cmd")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  log "installing missing basic tools: ${missing[*]}"
  install_pkg "${missing[@]}"
else
  log "all basic tools already present; no package fetch needed"
fi

# Java 17. Prefer preinstalled Java; install if possible (package name differs per distro).
if ! need_cmd java; then
  log "java not found; attempting install..."
  if need_cmd apk; then
    install_pkg openjdk17-jdk
  else
    install_pkg openjdk-17-jdk
  fi
fi

if need_cmd java; then
  log "java: $(java -version 2>&1 | head -n 1)"
else
  log "WARNING: java not found; Gradle Android checks will fail"
fi

# uv for simulator tooling. Prefer the distro package (apk has uv) over
# astral.sh/uv/install.sh: that bootstrap shells out to wget to pull the uv binary
# from GitHub releases, which the egress proxy bumps and ICAP repo-scopes (-> EAGAIN/403).
if ! need_cmd uv; then
  log "uv not found; installing via package manager..."
  install_pkg uv
  if ! need_cmd uv; then
    log "WARNING: uv not available via package manager; falling back to astral installer"
    retry 2 sh -c 'curl -LsSf --connect-timeout 30 --retry 3 --retry-delay 5 --retry-connrefused https://astral.sh/uv/install.sh | sh' \
      || log "WARNING: astral uv installer failed"
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi

if need_cmd uv; then
  log "uv: $(uv --version)"
else
  log "WARNING: uv not found; Python checks will fail"
fi

# ------------------------------------------------------------------------------
# Android SDK command-line tools
# ------------------------------------------------------------------------------
if ! [ -x "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" ]; then
  log "installing Android command-line tools..."
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  log "downloading commandlinetools-linux-11076708_latest.zip..."
  if retry 2 curl -fSL --connect-timeout 30 --retry 3 --retry-delay 5 --retry-connrefused \
    "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
    -o "$TMP_DIR/cmdline-tools.zip"; then
    log "download complete; unpacking..."
    unzip -q "$TMP_DIR/cmdline-tools.zip" -d "$TMP_DIR"
    mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"
    rm -rf "$ANDROID_SDK_ROOT/cmdline-tools/latest"
    mv "$TMP_DIR/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"
    log "Android command-line tools installed"
  else
    log "WARNING: failed to download Android command-line tools; Android checks will fail"
  fi
else
  log "Android command-line tools already present; skipping download"
fi

export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH"

if need_cmd sdkmanager; then
  log "accepting Android SDK licenses..."
  yes | sdkmanager --licenses >/dev/null || true

  log "installing Android SDK packages (platform-tools, android-34, build-tools 34.0.0)..."
  retry 2 sdkmanager \
    "platform-tools" \
    "platforms;android-34" \
    "build-tools;34.0.0" \
    || log "WARNING: sdkmanager package install did not complete"

  if [ "$CODE_WRITER_ANDROID_EMULATOR" = "1" ]; then
    log "installing emulator packages; this can be slow..."
    retry 2 sdkmanager \
      "emulator" \
      "system-images;android-34;google_apis;x86_64" \
      || log "WARNING: emulator package install did not complete"

    if need_cmd avdmanager; then
      log "creating AVD code-writer-api34..."
      echo "no" | avdmanager create avd \
        --force \
        --name "code-writer-api34" \
        --package "system-images;android-34;google_apis;x86_64" \
        --device "pixel_6" || true
    fi
  else
    log "Android emulator setup skipped; set CODE_WRITER_ANDROID_EMULATOR=1 to enable"
  fi
else
  log "WARNING: sdkmanager not found; Android checks will fail"
fi

# ------------------------------------------------------------------------------
# Repo dependencies
# ------------------------------------------------------------------------------
if [ -f ./gradlew ]; then
  chmod +x ./gradlew
  log "made ./gradlew executable"
else
  log "no ./gradlew in repo; skipping"
fi

if need_cmd uv && [ -f pyproject.toml ]; then
  log "installing simulator dependencies (uv sync --frozen)..."
  retry 2 uv sync --frozen || log "WARNING: uv sync did not complete"
else
  log "no pyproject.toml in repo; skipping uv sync"
fi

# Install pre-commit hooks if available, but do not make setup fail on this.
if need_cmd uv && [ -f ".pre-commit-config.yaml" ]; then
  log "installing pre-commit hooks..."
  uv run pre-commit install --install-hooks || true
  uv run pre-commit install --hook-type commit-msg || true
fi

ELAPSED=$(( $(date -u +%s) - START_TS ))
log "Setup complete! (took ${ELAPSED}s)"
log "Git author: $(git config user.name) <$(git config user.email)>"
log "Android SDK: $ANDROID_SDK_ROOT"
log "Gradle cache: $GRADLE_USER_HOME"
log "Ready for development!"
