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

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_contains() {
    local pattern="$1"
    local file="$2"
    if ! grep -q "$pattern" "$file"; then
        printf 'missing expected output: %s\n' "$pattern" >&2
        cat "$file" >&2
        exit 1
    fi
}

make_release_launcher() {
    local path="$1"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
ready_file="${LAUNCHER_READY_FILE:?}"
generation="${LAUNCHER_GENERATION:?}"
printf '%s\n' "$generation" > "${ready_file}.tmp"
mv -f "${ready_file}.tmp" "$ready_file"
printf '%s\n' 'change this part'
trap 'exit 0' TERM INT
if IFS= read -r choice; then
    printf 'console-input:%s\n' "$choice"
fi
while true; do sleep 1; done
EOF
    chmod +x "$path"
}

wait_for_pattern() {
    local pattern="$1"
    local file="$2"
    local attempts=0
    while (( attempts < 30 )); do
        grep -q "$pattern" "$file" 2>/dev/null && return 0
        sleep 1
        attempts=$((attempts + 1))
    done
    return 1
}

file_url() {
    local path="$1"
    if command -v cygpath >/dev/null 2>&1; then
        printf 'file:///%s\n' "$(cygpath -m "$path")"
    else
        printf 'file://%s\n' "$path"
    fi
}

release_dir="$TEST_DIR/release"
server_dir="$TEST_DIR/server"
release_url=''
mkdir -p "$release_dir" "$server_dir"
cp "$PROJECT_DIR/bootstrap.sh" "$release_dir/bootstrap.sh"
cp "$PROJECT_DIR/bootstrap.sh" "$server_dir/bootstrap.sh"
make_release_launcher "$release_dir/launcher.sh"
(
    cd "$release_dir"
    sha256sum bootstrap.sh launcher.sh > SHA256SUMS
)
release_url="$(file_url "$release_dir")"
cat > "$server_dir/config.env" <<'EOF'
MIHOMO_ENABLED='0'
MONITOR_ENABLED='1'
MONITOR_TYPE='lite'
MONITOR_ENDPOINT='https://lite.example.com'
MONITOR_TOKEN='test-token'
MONITOR_REMOTE_CONTROL='false'
EOF
printf '2\n' > "$server_dir/console.input"

(
    cd "$server_dir"
    exec env \
        ACL_UPDATE_BASE_URL="$release_url" \
        ACL_UPDATE_CHECK_INTERVAL=0 \
        ACL_UPDATE_JITTER_MAX=0 \
        ACL_LAUNCHER_READY_TIMEOUT=10 \
        ACL_LAUNCHER_READY_STABLE_SECONDS=1 \
        bash bootstrap.sh --AUTO_UPDATE=enable <console.input >output.log 2>&1
) &
bootstrap_pid=$!

if ! wait_for_pattern 'Updated launcher reported ready' "$server_dir/output.log"; then
    printf 'bootstrap did not finish its verified update\n' >&2
    cat "$server_dir/output.log" >&2 || true
    kill -TERM "$bootstrap_pid" 2>/dev/null || true
    wait "$bootstrap_pid" 2>/dev/null || true
    exit 1
fi

kill -TERM "$bootstrap_pid" 2>/dev/null || true
wait "$bootstrap_pid" 2>/dev/null || true

assert_contains '^change this part$' "$server_dir/output.log"
assert_contains '^console-input:2$' "$server_dir/output.log"
assert_contains "^CONFIG_SCHEMA_VERSION='1'$" "$server_dir/config.env"
assert_contains 'Update verified; switching launcher under supervision' "$server_dir/output.log"
assert_contains 'Updated launcher reported ready; update committed' "$server_dir/output.log"
[[ -f "$server_dir/launcher.sh" ]] || { printf 'launcher was not installed\n' >&2; exit 1; }
[[ ! -f "$server_dir/data/bootstrap/pending-update" ]] || { printf 'pending transaction was not committed\n' >&2; exit 1; }

# A blocked update endpoint must not stop a valid local launcher.
fallback_dir="$TEST_DIR/fallback"
missing_url="$(file_url "$TEST_DIR/missing")"
mkdir -p "$fallback_dir"
cp "$PROJECT_DIR/bootstrap.sh" "$fallback_dir/bootstrap.sh"
cp "$release_dir/launcher.sh" "$fallback_dir/launcher.sh"
cat > "$fallback_dir/config.env" <<'EOF'
CONFIG_SCHEMA_VERSION='1'
MIHOMO_ENABLED='0'
MONITOR_ENABLED='1'
EOF
(
    cd "$fallback_dir"
    exec env \
        ACL_UPDATE_BASE_URL="$missing_url" \
        ACL_UPDATE_CHECK_INTERVAL=0 \
        ACL_UPDATE_JITTER_MAX=0 \
        ACL_LAUNCHER_READY_TIMEOUT=10 \
        ACL_LAUNCHER_READY_STABLE_SECONDS=1 \
        bash bootstrap.sh --AUTO_UPDATE=enable </dev/null >output.log 2>&1
) &
fallback_pid=$!

wait_for_pattern 'continuing with local files' "$fallback_dir/output.log"
wait_for_pattern '^change this part$' "$fallback_dir/output.log"
kill -TERM "$fallback_pid" 2>/dev/null || true
wait "$fallback_pid" 2>/dev/null || true

# A verified release that cannot become ready must restore the old launcher and config.
rollback_release="$TEST_DIR/rollback-release"
rollback_dir="$TEST_DIR/rollback-server"
mkdir -p "$rollback_release" "$rollback_dir"
cp "$PROJECT_DIR/bootstrap.sh" "$rollback_release/bootstrap.sh"
cat > "$rollback_release/launcher.sh" <<'EOF'
#!/usr/bin/env bash
exit 23
EOF
chmod +x "$rollback_release/launcher.sh"
(
    cd "$rollback_release"
    sha256sum bootstrap.sh launcher.sh > SHA256SUMS
)
cp "$PROJECT_DIR/bootstrap.sh" "$rollback_dir/bootstrap.sh"
make_release_launcher "$rollback_dir/launcher.sh"
cat > "$rollback_dir/config.env" <<'EOF'
CONFIG_SCHEMA_VERSION='1'
MIHOMO_ENABLED='0'
MONITOR_ENABLED='1'
ROLLBACK_SENTINEL='preserve-me'
EOF
rollback_url="$(file_url "$rollback_release")"
(
    cd "$rollback_dir"
    exec env \
        ACL_UPDATE_BASE_URL="$rollback_url" \
        ACL_UPDATE_CHECK_INTERVAL=0 \
        ACL_UPDATE_JITTER_MAX=0 \
        ACL_LAUNCHER_READY_TIMEOUT=3 \
        ACL_LAUNCHER_READY_STABLE_SECONDS=1 \
        bash bootstrap.sh --AUTO_UPDATE=enable </dev/null >output.log 2>&1
) &
rollback_pid=$!

if ! wait_for_pattern 'Rolling back scripts and configuration' "$rollback_dir/output.log" || \
   ! wait_for_pattern '^change this part$' "$rollback_dir/output.log"; then
    printf 'bootstrap did not recover from a bad launcher update\n' >&2
    cat "$rollback_dir/output.log" >&2 || true
    kill -TERM "$rollback_pid" 2>/dev/null || true
    wait "$rollback_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$rollback_pid" 2>/dev/null || true
wait "$rollback_pid" 2>/dev/null || true
assert_contains "^ROLLBACK_SENTINEL='preserve-me'$" "$rollback_dir/config.env"
if cmp -s "$rollback_release/launcher.sh" "$rollback_dir/launcher.sh"; then
    printf 'failed launcher remained installed after rollback\n' >&2
    exit 1
fi

printf 'bootstrap tests passed\n'
