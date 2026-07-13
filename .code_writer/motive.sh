#!/usr/bin/env bash
# motive.sh — standalone connectivity diagnostics.
#
# Kept in sync with the "MOTIVE DEBUG BLOCK" in .code_writer/setup.sh. Run this
# by hand inside a pod/container to see exactly what the egress proxy can reach
# (e.g. whether dl-cdn.alpinelinux.org is allowlisted) without running the whole
# setup script.
#
# TO REMOVE: delete this file and the matching MOTIVE DEBUG BLOCK in
# .code_writer/setup.sh.
set -uo pipefail

log() { echo "[motive $(date -u +%H:%M:%S)] $*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

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

motive_healthcheck
