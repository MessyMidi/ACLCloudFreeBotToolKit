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

make_release_renew() {
    local path="$1"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    version) printf '%s\n' 'acl-renew test' ;;
    check) env > "${ACL_BASE_DIR:?}/data/renew-test.env"; printf '%s\n' '[renew] test check' ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "$path"
}

make_failing_renew() {
    local path="$1"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    version) printf '%s\n' 'acl-renew test' ;;
    check) printf '%s\n' '[renew] test failure'; exit 1 ;;
    *) exit 2 ;;
esac
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

# Configuration migration is the boundary between browser/Pterodactyl files
# and Linux Bash. It must canonicalize CRLF before launcher sources the file.
crlf_migration_dir="$TEST_DIR/crlf-migration"
mkdir -p "$crlf_migration_dir"
cp "$PROJECT_DIR/bootstrap.sh" "$crlf_migration_dir/bootstrap.sh"
printf "CONFIG_SCHEMA_VERSION='2'\r\nMIHOMO_ENABLED='0'\r\nMONITOR_ENABLED='0'\r\nAUTO_RENEW_ENABLED='1'\r\n" \
    > "$crlf_migration_dir/config.env"
(
    cd "$crlf_migration_dir"
    bash bootstrap.sh --INTERNAL_MIGRATE_CONFIG="$crlf_migration_dir/config.env" >output.log 2>&1
)
if od -An -tx1 "$crlf_migration_dir/config.env" | grep -Eq '(^|[[:space:]])0d([[:space:]]|$)'; then
    printf 'configuration migration left CR bytes in config.env\n' >&2
    exit 1
fi
assert_contains "^CONFIG_SCHEMA_VERSION='2'$" "$crlf_migration_dir/config.env"

embedded_cr_dir="$TEST_DIR/embedded-cr"
mkdir -p "$embedded_cr_dir"
cp "$PROJECT_DIR/bootstrap.sh" "$embedded_cr_dir/bootstrap.sh"
printf "CONFIG_SCHEMA_VERSION='2'\nMIHOMO_ENABLED='0'\nMONITOR_TOKEN='bad\rvalue'\n" \
    > "$embedded_cr_dir/config.env"
if (
    cd "$embedded_cr_dir"
    bash bootstrap.sh --INTERNAL_MIGRATE_CONFIG="$embedded_cr_dir/config.env" >output.log 2>&1
); then
    printf 'configuration migration accepted an embedded CR control character\n' >&2
    exit 1
fi
assert_contains 'embedded carriage return' "$embedded_cr_dir/output.log"

release_dir="$TEST_DIR/release"
server_dir="$TEST_DIR/server"
release_url=''
mkdir -p "$release_dir" "$server_dir"
cp "$PROJECT_DIR/bootstrap.sh" "$release_dir/bootstrap.sh"
cp "$PROJECT_DIR/bootstrap.sh" "$server_dir/bootstrap.sh"
make_release_launcher "$release_dir/launcher.sh"
make_release_renew "$release_dir/acl-renew-linux-amd64"
(
    cd "$release_dir"
    sha256sum bootstrap.sh launcher.sh acl-renew-linux-amd64 > SHA256SUMS
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
assert_contains "^CONFIG_SCHEMA_VERSION='2'$" "$server_dir/config.env"
assert_contains "^AUTO_RENEW_ENABLED='0'$" "$server_dir/config.env"
assert_contains 'Update verified; switching launcher under supervision' "$server_dir/output.log"
assert_contains 'Updated launcher reported ready; update committed' "$server_dir/output.log"
[[ -f "$server_dir/launcher.sh" ]] || { printf 'launcher was not installed\n' >&2; exit 1; }
[[ -x "$server_dir/bin/acl-renew" ]] || { printf 'acl-renew was not installed\n' >&2; exit 1; }
[[ ! -f "$server_dir/data/bootstrap/pending-update" ]] || { printf 'pending transaction was not committed\n' >&2; exit 1; }

# A clean install with no local launcher must survive a CRLF schema-1 config,
# migrate it, and commit the verified release instead of rolling back to no
# launcher at all.
crlf_release="$TEST_DIR/crlf-update-release"
crlf_server="$TEST_DIR/crlf-update-server"
mkdir -p "$crlf_release" "$crlf_server"
cp "$PROJECT_DIR/bootstrap.sh" "$crlf_release/bootstrap.sh"
cp "$PROJECT_DIR/launcher.sh" "$crlf_release/launcher.sh"
make_release_renew "$crlf_release/acl-renew-linux-amd64"
(
    cd "$crlf_release"
    sha256sum bootstrap.sh launcher.sh acl-renew-linux-amd64 > SHA256SUMS
)
cp "$PROJECT_DIR/bootstrap.sh" "$crlf_server/bootstrap.sh"
printf "CONFIG_SCHEMA_VERSION='1'\r\nMIHOMO_ENABLED='0'\r\nMONITOR_ENABLED='0'\r\nAUTO_RENEW_ENABLED='1'\r\n" \
    > "$crlf_server/config.env"
(
    cd "$crlf_server"
    exec env \
        ACL_UPDATE_BASE_URL="$(file_url "$crlf_release")" \
        ACL_UPDATE_CHECK_INTERVAL=0 \
        ACL_UPDATE_JITTER_MAX=0 \
        ACL_RENEW_CHECK_INTERVAL=3600 \
        ACL_RENEW_JITTER_MAX=0 \
        ACL_LAUNCHER_READY_TIMEOUT=10 \
        ACL_LAUNCHER_READY_STABLE_SECONDS=1 \
        bash bootstrap.sh --AUTO_UPDATE=enable </dev/null >output.log 2>&1
) &
crlf_bootstrap_pid=$!
if ! wait_for_pattern 'Updated launcher reported ready' "$crlf_server/output.log"; then
    printf 'clean CRLF deployment did not commit the verified update\n' >&2
    cat "$crlf_server/output.log" >&2 || true
    kill -TERM "$crlf_bootstrap_pid" 2>/dev/null || true
    wait "$crlf_bootstrap_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$crlf_bootstrap_pid" 2>/dev/null || true
wait "$crlf_bootstrap_pid" 2>/dev/null || true
assert_contains "^CONFIG_SCHEMA_VERSION='2'$" "$crlf_server/config.env"
assert_contains '^change this part$' "$crlf_server/output.log"
if od -An -tx1 "$crlf_server/config.env" | grep -Eq '(^|[[:space:]])0d([[:space:]]|$)'; then
    printf 'clean deployment left CR bytes in migrated config.env\n' >&2
    exit 1
fi
if grep -q "command not found" "$crlf_server/output.log"; then
    printf 'clean deployment interpreted CR bytes as shell commands\n' >&2
    cat "$crlf_server/output.log" >&2
    exit 1
fi

# Automatic renewal runs as an isolated one-shot child and leaves launcher alive.
renew_dir="$TEST_DIR/renew-server"
mkdir -p "$renew_dir/bin"
cp "$PROJECT_DIR/bootstrap.sh" "$renew_dir/bootstrap.sh"
cp "$release_dir/launcher.sh" "$renew_dir/launcher.sh"
cp "$release_dir/acl-renew-linux-amd64" "$renew_dir/bin/acl-renew"
chmod +x "$renew_dir/bin/acl-renew"
cat > "$renew_dir/config.env" <<'EOF'
CONFIG_SCHEMA_VERSION='2'
MIHOMO_ENABLED='0'
MONITOR_ENABLED='0'
AUTO_RENEW_ENABLED='1'
ACL_USERNAME='person@example.com'
ACL_PASSWORD='password'
MONITOR_TOKEN='monitor-secret-must-not-leak'
EOF
(
    cd "$renew_dir"
    exec env \
        ACL_RENEW_CHECK_INTERVAL=3600 \
        ACL_RENEW_JITTER_MAX=0 \
        ACL_LAUNCHER_READY_TIMEOUT=10 \
        ACL_LAUNCHER_READY_STABLE_SECONDS=1 \
        bash bootstrap.sh --AUTO_UPDATE=disable </dev/null >output.log 2>&1
) &
renew_bootstrap_pid=$!
if ! wait_for_pattern '^\[renew\] test check$' "$renew_dir/logs/renew.log" || \
   ! wait_for_pattern '^change this part$' "$renew_dir/output.log"; then
    printf 'bootstrap did not run the isolated renewal check\n' >&2
    cat "$renew_dir/output.log" >&2 || true
    cat "$renew_dir/logs/renew.log" >&2 || true
    kill -TERM "$renew_bootstrap_pid" 2>/dev/null || true
    wait "$renew_bootstrap_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$renew_bootstrap_pid" 2>/dev/null || true
wait "$renew_bootstrap_pid" 2>/dev/null || true
assert_contains '^\[renew\] Check finished with exit code 0$' "$renew_dir/logs/renew.log"
assert_contains '^ACL_USERNAME=person@example.com$' "$renew_dir/data/renew-test.env"
assert_contains '^ACL_PASSWORD=password$' "$renew_dir/data/renew-test.env"
if grep -Eq 'monitor-secret-must-not-leak|^MONITOR_TOKEN=' "$renew_dir/data/renew-test.env"; then
    printf 'monitor credentials leaked into the renewal helper environment\n' >&2
    exit 1
fi

# A failed renewal check is retried soon, with a growing delay, instead of
# waiting for the next daily check.
renew_retry_dir="$TEST_DIR/renew-retry-server"
mkdir -p "$renew_retry_dir/bin"
cp "$PROJECT_DIR/bootstrap.sh" "$renew_retry_dir/bootstrap.sh"
cp "$release_dir/launcher.sh" "$renew_retry_dir/launcher.sh"
make_failing_renew "$renew_retry_dir/bin/acl-renew"
cp "$renew_dir/config.env" "$renew_retry_dir/config.env"
(
    cd "$renew_retry_dir"
    exec env \
        ACL_RENEW_CHECK_INTERVAL=3600 \
        ACL_RENEW_JITTER_MAX=0 \
        ACL_RENEW_RETRY_INTERVAL=1 \
        ACL_LAUNCHER_READY_TIMEOUT=10 \
        ACL_LAUNCHER_READY_STABLE_SECONDS=1 \
        bash bootstrap.sh --AUTO_UPDATE=disable </dev/null >output.log 2>&1
) &
renew_retry_pid=$!
if ! wait_for_pattern 'Renewal check failed with exit code 1; retrying in 2s' "$renew_retry_dir/output.log"; then
    printf 'bootstrap did not retry a failed renewal check with backoff\n' >&2
    cat "$renew_retry_dir/output.log" >&2 || true
    kill -TERM "$renew_retry_pid" 2>/dev/null || true
    wait "$renew_retry_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$renew_retry_pid" 2>/dev/null || true
wait "$renew_retry_pid" 2>/dev/null || true
assert_contains 'Renewal check failed with exit code 1; retrying in 1s' "$renew_retry_dir/output.log"

# The hidden prerelease channel resolves the newest published prerelease and
# preserves that channel after bootstrap replaces itself. The selected entry
# is written on one line, as a minified API response would be.
prerelease_tag='v0.5.1-pre1'
prerelease_root="$TEST_DIR/prerelease-downloads"
prerelease_release="$prerelease_root/$prerelease_tag"
prerelease_server="$TEST_DIR/prerelease-server"
mkdir -p "$prerelease_release" "$prerelease_server"
cp "$PROJECT_DIR/bootstrap.sh" "$prerelease_release/bootstrap.sh"
make_release_launcher "$prerelease_release/launcher.sh"
make_release_renew "$prerelease_release/acl-renew-linux-amd64"
(
    cd "$prerelease_release"
    sha256sum bootstrap.sh launcher.sh acl-renew-linux-amd64 > SHA256SUMS
)
cat > "$TEST_DIR/releases.json" <<EOF
[
  {
    "tag_name": "v0.6.0-draft",
    "draft": true,
    "prerelease": true
  },
  {"tag_name":"$prerelease_tag","author":{"login":"someone"},"draft":false,"prerelease":true,"assets":[{"name":"SHA256SUMS"}]},
  {
    "tag_name": "v0.5.0",
    "draft": false,
    "prerelease": false
  }
]
EOF
cp "$PROJECT_DIR/bootstrap.sh" "$prerelease_server/bootstrap.sh"
cat > "$prerelease_server/config.env" <<'EOF'
CONFIG_SCHEMA_VERSION='2'
BOOTSTRAP_UPDATE_CHANNEL='prerelease'
MIHOMO_ENABLED='0'
MONITOR_ENABLED='1'
EOF
(
    cd "$prerelease_server"
    exec env \
        ACL_RELEASES_API_URL="$(file_url "$TEST_DIR/releases.json")" \
        ACL_RELEASE_DOWNLOAD_BASE_URL="$(file_url "$prerelease_root")" \
        ACL_UPDATE_CHECK_INTERVAL=0 \
        ACL_UPDATE_JITTER_MAX=0 \
        ACL_LAUNCHER_READY_TIMEOUT=10 \
        ACL_LAUNCHER_READY_STABLE_SECONDS=1 \
        bash bootstrap.sh --AUTO_UPDATE=enable </dev/null >output.log 2>&1
) &
prerelease_pid=$!
if ! wait_for_pattern "Selected prerelease $prerelease_tag" "$prerelease_server/output.log" || \
   ! wait_for_pattern 'Updated launcher reported ready' "$prerelease_server/output.log"; then
    printf 'bootstrap did not install from the prerelease channel\n' >&2
    cat "$prerelease_server/output.log" >&2 || true
    kill -TERM "$prerelease_pid" 2>/dev/null || true
    wait "$prerelease_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$prerelease_pid" 2>/dev/null || true
wait "$prerelease_pid" 2>/dev/null || true
assert_contains 'Checking prerelease channel for updates' "$prerelease_server/output.log"

# A historical prerelease older than the latest Stable release must not cause
# a downgrade when a tester leaves the hidden channel enabled.
cat > "$TEST_DIR/releases.json" <<'EOF'
[
  {
    "tag_name": "v0.5.0",
    "draft": false,
    "prerelease": false
  },
  {
    "tag_name": "v0.4.1-pre1",
    "draft": false,
    "prerelease": true
  }
]
EOF
(
    cd "$prerelease_server"
    exec env \
        ACL_RELEASES_API_URL="$(file_url "$TEST_DIR/releases.json")" \
        ACL_RELEASE_DOWNLOAD_BASE_URL="$(file_url "$prerelease_root")" \
        ACL_UPDATE_CHECK_INTERVAL=0 \
        ACL_UPDATE_JITTER_MAX=0 \
        ACL_LAUNCHER_READY_TIMEOUT=10 \
        ACL_LAUNCHER_READY_STABLE_SECONDS=1 \
        bash bootstrap.sh --AUTO_UPDATE=enable </dev/null >no-downgrade.log 2>&1
) &
no_downgrade_pid=$!
if ! wait_for_pattern 'No active prerelease newer than the latest Stable release' "$prerelease_server/no-downgrade.log" || \
   ! wait_for_pattern '^change this part$' "$prerelease_server/no-downgrade.log"; then
    printf 'prerelease channel did not preserve the newer local Stable-compatible files\n' >&2
    cat "$prerelease_server/no-downgrade.log" >&2 || true
    kill -TERM "$no_downgrade_pid" 2>/dev/null || true
    wait "$no_downgrade_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$no_downgrade_pid" 2>/dev/null || true
wait "$no_downgrade_pid" 2>/dev/null || true

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
make_release_renew "$rollback_release/acl-renew-linux-amd64"
(
    cd "$rollback_release"
    sha256sum bootstrap.sh launcher.sh acl-renew-linux-amd64 > SHA256SUMS
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

# The release that was rolled back is not installed again at the next check.
(
    cd "$rollback_dir"
    exec env \
        ACL_UPDATE_BASE_URL="$rollback_url" \
        ACL_UPDATE_CHECK_INTERVAL=0 \
        ACL_UPDATE_JITTER_MAX=0 \
        ACL_LAUNCHER_READY_TIMEOUT=3 \
        ACL_LAUNCHER_READY_STABLE_SECONDS=1 \
        bash bootstrap.sh --AUTO_UPDATE=enable </dev/null >rejected.log 2>&1
) &
rejected_pid=$!
if ! wait_for_pattern 'Skipping the stable release that was rolled back' "$rollback_dir/rejected.log" || \
   ! wait_for_pattern '^change this part$' "$rollback_dir/rejected.log"; then
    printf 'bootstrap installed a release that had already been rolled back\n' >&2
    cat "$rollback_dir/rejected.log" >&2 || true
    kill -TERM "$rejected_pid" 2>/dev/null || true
    wait "$rejected_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$rejected_pid" 2>/dev/null || true
wait "$rejected_pid" 2>/dev/null || true

# An updated bootstrap that crashes before committing the update is rolled
# back on the next start, even though the crash happened in the new code.
crash_release="$TEST_DIR/crash-release"
crash_dir="$TEST_DIR/crash-server"
mkdir -p "$crash_release" "$crash_dir"
sed 's/^find_latest_prerelease_tag() {$/exit 42\n&/' "$PROJECT_DIR/bootstrap.sh" > "$crash_release/bootstrap.sh"
grep -q '^exit 42$' "$crash_release/bootstrap.sh" || { printf 'could not build the crashing bootstrap fixture\n' >&2; exit 1; }
make_release_launcher "$crash_release/launcher.sh"
make_release_renew "$crash_release/acl-renew-linux-amd64"
(
    cd "$crash_release"
    sha256sum bootstrap.sh launcher.sh acl-renew-linux-amd64 > SHA256SUMS
)
cp "$PROJECT_DIR/bootstrap.sh" "$crash_dir/bootstrap.sh"
make_release_launcher "$crash_dir/launcher.sh"
cat > "$crash_dir/config.env" <<'EOF'
CONFIG_SCHEMA_VERSION='2'
MIHOMO_ENABLED='0'
MONITOR_ENABLED='1'
EOF
crash_env=(
    ACL_UPDATE_BASE_URL="$(file_url "$crash_release")"
    ACL_UPDATE_CHECK_INTERVAL=0
    ACL_UPDATE_JITTER_MAX=0
    ACL_LAUNCHER_READY_TIMEOUT=10
    ACL_LAUNCHER_READY_STABLE_SECONDS=1
)
if (cd "$crash_dir" && env "${crash_env[@]}" bash bootstrap.sh --AUTO_UPDATE=enable </dev/null >first.log 2>&1); then
    printf 'the crashing bootstrap fixture did not crash\n' >&2
    exit 1
fi
assert_contains 'Update verified; switching launcher under supervision' "$crash_dir/first.log"
(
    cd "$crash_dir"
    exec env "${crash_env[@]}" bash bootstrap.sh --AUTO_UPDATE=enable </dev/null >second.log 2>&1
) &
crash_pid=$!
if ! wait_for_pattern 'stopped unexpectedly before the update was committed' "$crash_dir/second.log" || \
   ! wait_for_pattern '^change this part$' "$crash_dir/second.log"; then
    printf 'bootstrap did not recover from an update that crashed during startup\n' >&2
    cat "$crash_dir/second.log" >&2 || true
    kill -TERM "$crash_pid" 2>/dev/null || true
    wait "$crash_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$crash_pid" 2>/dev/null || true
wait "$crash_pid" 2>/dev/null || true
cmp -s "$PROJECT_DIR/bootstrap.sh" "$crash_dir/bootstrap.sh" || { printf 'the previous bootstrap was not restored\n' >&2; exit 1; }
[[ -s "$crash_dir/data/bootstrap/rejected-update" ]] || { printf 'the crashed release was not recorded\n' >&2; exit 1; }

# A process killed between the individual file replacements and the final
# activation marker must not commit a mixed-version installation.
partial_dir="$TEST_DIR/partial-switch-server"
mkdir -p "$partial_dir/data/bootstrap/backups/update-partial" "$partial_dir/bin"
cp "$PROJECT_DIR/bootstrap.sh" "$partial_dir/bootstrap.sh"
make_release_launcher "$partial_dir/launcher.sh"
make_release_renew "$partial_dir/bin/acl-renew"
cp "$crash_dir/config.env" "$partial_dir/config.env"
partial_backup="$partial_dir/data/bootstrap/backups/update-partial"
cp "$partial_dir/launcher.sh" "$partial_dir/launcher.previous"
cp "$partial_dir/bootstrap.sh" "$partial_backup/bootstrap.sh"
cp "$partial_dir/launcher.previous" "$partial_backup/launcher.sh"
cp "$partial_dir/bin/acl-renew" "$partial_backup/acl-renew-linux-amd64"
cp "$partial_dir/config.env" "$partial_backup/config.snapshot"
printf 'config.env\n' > "$partial_backup/config.name"
printf '1\n' > "$partial_backup/renew.existed"
printf 'partial-update-id\n' > "$partial_backup/update.id"
printf '2\n' > "$partial_backup/transaction.version"
printf 'update-partial\n' > "$partial_dir/data/bootstrap/pending-update"
printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$partial_dir/launcher.sh"
chmod +x "$partial_dir/launcher.sh"
(
    cd "$partial_dir"
    exec env ACL_LAUNCHER_READY_TIMEOUT=10 ACL_LAUNCHER_READY_STABLE_SECONDS=1 \
        bash bootstrap.sh --AUTO_UPDATE=disable </dev/null >output.log 2>&1
) &
partial_pid=$!
if ! wait_for_pattern 'interrupted while switching files' "$partial_dir/output.log" || \
   ! wait_for_pattern '^change this part$' "$partial_dir/output.log"; then
    printf 'bootstrap did not roll back an interrupted multi-file switch\n' >&2
    cat "$partial_dir/output.log" >&2 || true
    kill -TERM "$partial_pid" 2>/dev/null || true
    wait "$partial_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$partial_pid" 2>/dev/null || true
wait "$partial_pid" 2>/dev/null || true
cmp -s "$partial_dir/launcher.previous" "$partial_dir/launcher.sh" || {
    printf 'interrupted switch did not restore the previous launcher\n' >&2
    exit 1
}

# Stopping the container while an update is being verified leaves the failed
# verification marker in place. This covers ACLClouds terminating a container
# that does not become ready before the platform startup deadline.
graceful_dir="$TEST_DIR/graceful-server"
mkdir -p "$graceful_dir"
cp "$PROJECT_DIR/bootstrap.sh" "$graceful_dir/bootstrap.sh"
make_release_launcher "$graceful_dir/launcher.sh"
cp "$crash_dir/config.env" "$graceful_dir/config.env"
mkdir -p "$graceful_dir/data/bootstrap/backups/update-test"
cp "$graceful_dir/bootstrap.sh" "$graceful_dir/launcher.sh" "$graceful_dir/data/bootstrap/backups/update-test/"
cp "$graceful_dir/config.env" "$graceful_dir/data/bootstrap/backups/update-test/config.snapshot"
printf 'config.env\n' > "$graceful_dir/data/bootstrap/backups/update-test/config.name"
printf '0\n' > "$graceful_dir/data/bootstrap/backups/update-test/renew.existed"
printf 'update-test\n' > "$graceful_dir/data/bootstrap/pending-update"
(
    cd "$graceful_dir"
    exec env ACL_LAUNCHER_READY_TIMEOUT=10 ACL_LAUNCHER_READY_STABLE_SECONDS=30 \
        bash bootstrap.sh --AUTO_UPDATE=disable </dev/null >output.log 2>&1
) &
graceful_pid=$!
if ! wait_for_pattern '^change this part$' "$graceful_dir/output.log"; then
    printf 'the pending update was not verified\n' >&2
    cat "$graceful_dir/output.log" >&2 || true
    kill -TERM "$graceful_pid" 2>/dev/null || true
    wait "$graceful_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$graceful_pid" 2>/dev/null || true
wait "$graceful_pid" 2>/dev/null || true
[[ -f "$graceful_dir/data/bootstrap/pending-update" && -f "$graceful_dir/data/bootstrap/pending-update.started" ]] || {
    printf 'shutdown discarded the pending update failure marker\n' >&2
    exit 1
}
(
    cd "$graceful_dir"
    exec env ACL_LAUNCHER_READY_TIMEOUT=10 ACL_LAUNCHER_READY_STABLE_SECONDS=1 \
        bash bootstrap.sh --AUTO_UPDATE=disable </dev/null >restart.log 2>&1
) &
graceful_restart_pid=$!
if ! wait_for_pattern 'stopped unexpectedly before the update was committed' "$graceful_dir/restart.log" || \
   ! wait_for_pattern '^change this part$' "$graceful_dir/restart.log"; then
    printf 'bootstrap did not roll back an update interrupted by shutdown\n' >&2
    cat "$graceful_dir/restart.log" >&2 || true
    kill -TERM "$graceful_restart_pid" 2>/dev/null || true
    wait "$graceful_restart_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$graceful_restart_pid" 2>/dev/null || true
wait "$graceful_restart_pid" 2>/dev/null || true
[[ ! -e "$graceful_dir/data/bootstrap/pending-update" ]] || {
    printf 'rollback did not close the interrupted update transaction\n' >&2
    exit 1
}

printf 'bootstrap tests passed\n'
