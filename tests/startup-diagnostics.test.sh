#!/usr/bin/env bash

# ACLCloudFreeBotToolKit
# Copyright (C) 2026 MessyMidi
#
# SPDX-License-Identifier: AGPL-3.0-only
# Additional terms under AGPLv3 Section 7:
# see /ADDITIONAL_TERMS.md

set -Eeuo pipefail
PATH="/usr/bin:/bin:$PATH"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
child=''
cleanup() {
    if [[ -n "$child" ]]; then
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_contains() {
    grep -q "$1" "$2" || { printf 'missing: %s in %s\n' "$1" "$2" >&2; exit 1; }
}

cp "$PROJECT_DIR/launcher.sh" "$TEST_DIR/launcher.sh"
# Even an expansion error in config loading, which bypasses ERR, is recorded.
printf ': "${ACL_DIAGNOSTIC_MISSING:?fixture-required-variable}"\n' > "$TEST_DIR/config.env"
if env -u ACL_DIAGNOSTIC_MISSING bash "$TEST_DIR/launcher.sh" > "$TEST_DIR/output" 2>&1; then
    printf 'expansion error unexpectedly accepted\n' >&2; exit 1
fi
assert_contains 'startup exited with status' "$TEST_DIR/logs/launcher.log"
printf "MONITOR_ENABLED='0'\n" > "$TEST_DIR/config.env"
# The actual early validation failure must remain on disk across retries.
for attempt in 1 2; do
    if env -u SERVER_IP -u SERVER_PORT bash "$TEST_DIR/launcher.sh" > "$TEST_DIR/output" 2>&1; then
        printf 'missing port unexpectedly accepted\n' >&2; exit 1
    fi
done
assert_contains 'SERVER_PORT is missing' "$TEST_DIR/logs/launcher.log"
[[ "$(grep -c 'SERVER_PORT is missing' "$TEST_DIR/logs/launcher.log")" == 2 ]]

# Bound startup failures even when the Console loop is never reached.
head -c 1100000 /dev/zero > "$TEST_DIR/logs/launcher.log"
env -u SERVER_IP -u SERVER_PORT bash "$TEST_DIR/launcher.sh" > "$TEST_DIR/output" 2>&1 || true
(( $(wc -c < "$TEST_DIR/logs/launcher.log") <= 1048576 ))
assert_contains 'SERVER_PORT is missing' "$TEST_DIR/logs/launcher.log"

# A public host is only needed for sharing, not for listening.
cat > "$TEST_DIR/bin/mihomo" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -v) printf 'Mihomo Meta fixture\n'; exit 0 ;;
    -t) exit 0 ;;
    generate)
        if [[ "$2" == uuid ]]; then
            printf '12345678-1234-4234-8234-123456789abc\n'
        else
            printf 'PrivateKey: test-private\nPublicKey: test-public\n'
        fi
        exit 0 ;;
esac
trap 'exit 0' TERM INT
while true; do sleep 1; done
EOF
chmod +x "$TEST_DIR/bin/mihomo"
if command -v cygpath >/dev/null 2>&1; then
    fixture_asset_url="file:///$(cygpath -m "$TEST_DIR/must-not-download")"
else
    fixture_asset_url="file://$TEST_DIR/must-not-download"
fi
# Adopt the cached fixture by its real version, and forbid remote assets even
# if a future regression accidentally enters the download path.
printf "MIHOMO_VERSION='fixture'\nMIHOMO_URL='%s'\nMIHOMO_FALLBACK_URL='%s'\n" "$fixture_asset_url" "$fixture_asset_url" >> "$TEST_DIR/config.env"
env -u SERVER_IP SERVER_PORT=30230 bash "$TEST_DIR/launcher.sh" </dev/null > "$TEST_DIR/output" 2>&1 &
child=$!
ready=0
for ((attempt = 0; attempt < 150; attempt += 1)); do
    if grep -q '请输入数字' "$TEST_DIR/output"; then ready=1; break; fi
    sleep 0.1
done
[[ "$ready" == 1 ]] || { cat "$TEST_DIR/output" >&2; exit 1; }
assert_contains 'Mihomo started' "$TEST_DIR/output"
if grep -q 'Downloading:' "$TEST_DIR/output"; then
    printf 'cached fixture unexpectedly attempted a download\n' >&2; exit 1
fi
assert_contains 'public address is unavailable' "$TEST_DIR/output"
assert_contains 'port: 30230' "$TEST_DIR/config/mihomo.yaml"
if grep -q 'vless://' "$TEST_DIR/output" "$TEST_DIR/logs/launcher.log"; then
    printf 'missing host produced a link, or credentials reached supervisor log\n' >&2; exit 1
fi
kill -TERM "$child" 2>/dev/null || true
wait "$child" 2>/dev/null || true
child=''

# With an address available, Console still prints the link; supervisor logs
# must never copy it or the key/UUID display that follows it.
env SERVER_IP=192.0.2.1 SERVER_PORT=30230 bash "$TEST_DIR/launcher.sh" </dev/null > "$TEST_DIR/output" 2>&1 &
child=$!
ready=0
for ((attempt = 0; attempt < 150; attempt += 1)); do
    if grep -q '请输入数字' "$TEST_DIR/output"; then ready=1; break; fi
    sleep 0.1
done
[[ "$ready" == 1 ]]
assert_contains 'vless://' "$TEST_DIR/output"
if grep -Eq 'vless://|test-private|test-public|12345678-1234-4234-8234-123456789abc' "$TEST_DIR/logs/launcher.log"; then
    printf 'proxy credentials reached supervisor log\n' >&2; exit 1
fi
kill -TERM "$child" 2>/dev/null || true
wait "$child" 2>/dev/null || true
child=''

# Bootstrap must persist its own errors before any launcher is available.
cp "$PROJECT_DIR/bootstrap.sh" "$TEST_DIR/bootstrap.sh"
if bash "$TEST_DIR/bootstrap.sh" --invalid-test-option > "$TEST_DIR/output" 2>&1; then
    printf 'invalid option unexpectedly accepted\n' >&2; exit 1
fi
assert_contains 'Unknown argument' "$TEST_DIR/logs/bootstrap.log"

# A broken local launcher must not block scheduled updates forever. This
# release is entirely local; the helper and launcher never contact ACLClouds.
release_dir="$TEST_DIR/release"
server_dir="$TEST_DIR/recovery"
mkdir -p "$release_dir" "$server_dir"
cp "$PROJECT_DIR/bootstrap.sh" "$release_dir/bootstrap.sh"
cat > "$release_dir/launcher.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${LAUNCHER_GENERATION:?}" > "${LAUNCHER_READY_FILE:?}"
printf 'recovered-launcher-ready\n'
trap 'exit 0' TERM INT
while true; do sleep 1; done
EOF
cat > "$release_dir/acl-renew-linux-amd64" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == version ]] && printf 'fixture\n'
EOF
chmod +x "$release_dir/acl-renew-linux-amd64"
(cd "$release_dir" && sha256sum bootstrap.sh launcher.sh acl-renew-linux-amd64 > SHA256SUMS)
cp "$PROJECT_DIR/bootstrap.sh" "$server_dir/bootstrap.sh"
printf '#!/usr/bin/env bash\nexit 23\n' > "$server_dir/launcher.sh"
printf "CONFIG_SCHEMA_VERSION='2'\nMIHOMO_ENABLED='0'\nMONITOR_ENABLED='1'\n" > "$server_dir/config.env"
if command -v cygpath >/dev/null 2>&1; then
    release_url="file:///$(cygpath -m "$release_dir")"
else
    release_url="file://$release_dir"
fi
env ACL_UPDATE_BASE_URL="$release_url" ACL_UPDATE_CHECK_INTERVAL=1 \
    ACL_UPDATE_JITTER_MAX=0 ACL_LAUNCHER_READY_TIMEOUT=2 \
    ACL_LAUNCHER_READY_STABLE_SECONDS=1 \
    bash "$server_dir/bootstrap.sh" --SKIP_INITIAL_UPDATE </dev/null > "$server_dir/output" 2>&1 &
child=$!
ready=0
for ((attempt = 0; attempt < 200; attempt += 1)); do
    if grep -q 'Updated launcher reported ready' "$server_dir/output"; then ready=1; break; fi
    sleep 0.1
done
[[ "$ready" == 1 ]] || { cat "$server_dir/output" >&2; exit 1; }
assert_contains 'Launcher did not become ready' "$server_dir/logs/bootstrap.log"
assert_contains 'Updated launcher reported ready' "$server_dir/logs/bootstrap.log"
cmp "$release_dir/launcher.sh" "$server_dir/launcher.sh"
kill -TERM "$child" 2>/dev/null || true
wait "$child" 2>/dev/null || true
child=''
printf 'Startup diagnostics tests passed\n'
