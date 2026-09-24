#!/usr/bin/env bash

# ACLCloudFreeBotToolKit
# Copyright (C) 2026 MessyMidi
#
# SPDX-License-Identifier: AGPL-3.0-only
# Additional terms under AGPLv3 Section 7:
# see /ADDITIONAL_TERMS.md

set -Eeuo pipefail

# Git for Windows does not always prepend its Unix tool directories when bash
# is launched from another shell. Linux already resolves these paths normally.
PATH="/usr/bin:/bin:$PATH"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

make_fixture() {
    local name="$1"
    local dir="$TEST_DIR/$name"
    mkdir -p "$dir/bin"
    cp "$PROJECT_DIR/launcher.sh" "$dir/launcher.sh"
    printf '%s\n' "$dir"
}

make_long_running_agent() {
    local path="$1"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while true; do sleep 1; done
EOF
    chmod +x "$path"
}

wait_for_output() {
    local pattern="$1"
    local file="$2"
    local attempts=0
    while (( attempts < 100 )); do
        grep -q "$pattern" "$file" 2>/dev/null && return 0
        sleep 0.1
        attempts=$((attempts + 1))
    done
    return 1
}

run_for_startup() {
    local dir="$1"
    shift
    (
        cd "$dir"
        exec "$@" bash launcher.sh </dev/null >output.log 2>&1
    ) &
    local pid=$!
    # The first prompt is printed only after status and the optional VLESS link,
    # so this is a deterministic completion signal even on slower CI hosts.
    wait_for_output '请输入数字' "$dir/output.log" || true
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

run_for_startup_with_input() {
    local dir="$1"
    local input="$2"
    local expected="$3"
    shift 3
    (
        cd "$dir"
        exec "$@" bash launcher.sh <"$input" >output.log 2>&1
    ) &
    local pid=$!
    wait_for_output "$expected" "$dir/output.log" || true
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

assert_contains() {
    local pattern="$1"
    local file="$2"
    if ! grep -q "$pattern" "$file"; then
        printf 'missing expected output: %s\n' "$pattern" >&2
        cat "$file" >&2
        exit 1
    fi
}

assert_after() {
    local before="$1"
    local after="$2"
    local file="$3"
    local before_line after_line

    before_line="$(grep -n -m1 "$before" "$file" | cut -d: -f1)"
    after_line="$(grep -n -m1 "$after" "$file" | cut -d: -f1)"
    if [[ -z "$before_line" || -z "$after_line" || "$after_line" -le "$before_line" ]]; then
        printf 'expected "%s" after "%s"\n' "$after" "$before" >&2
        cat "$file" >&2
        exit 1
    fi
}

monitor_dir="$(make_fixture monitor-only)"
cat > "$monitor_dir/config.env" <<'EOF'
MIHOMO_ENABLED='0'
MONITOR_ENABLED='1'
MONITOR_TYPE='lite'
MONITOR_ENDPOINT='https://lite.example.com'
MONITOR_TOKEN='test-token'
MONITOR_REMOTE_CONTROL='false'
EOF
make_long_running_agent "$monitor_dir/bin/lite-agent"
run_for_startup "$monitor_dir" env LAUNCHER_READY_FILE="$monitor_dir/launcher.ready" LAUNCHER_GENERATION='test-generation'
assert_contains 'Monitor started (lite' "$monitor_dir/output.log"
assert_contains 'Mihomo : DISABLED' "$monitor_dir/output.log"
assert_contains '^change this part$' "$monitor_dir/output.log"
assert_after 'Startup completed' '^change this part$' "$monitor_dir/output.log"
assert_contains '^test-generation$' "$monitor_dir/launcher.ready"
if grep -q 'startup-probe candidate' "$monitor_dir/output.log"; then
    printf 'diagnostic startup probe unexpectedly remained enabled\n' >&2
    exit 1
fi
if grep -q 'VLESS + REALITY' "$monitor_dir/output.log"; then
    printf 'monitor-only mode unexpectedly printed a VLESS link\n' >&2
    exit 1
fi

proxy_dir="$(make_fixture proxy-only)"
cat > "$proxy_dir/config.env" <<'EOF'
# MIHOMO_ENABLED is intentionally omitted to verify backward compatibility.
MONITOR_ENABLED='0'
EOF
cat > "$proxy_dir/bin/mihomo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "generate" && "${2:-}" == "reality-keypair" ]]; then
    printf 'PrivateKey: test-private-key\nPublicKey: test-public-key\n'
    exit 0
fi
if [[ "${1:-}" == "generate" && "${2:-}" == "uuid" ]]; then
    printf '12345678-1234-4234-8234-123456789abc\n'
    exit 0
fi
if [[ "${1:-}" == "-t" ]]; then
    exit 0
fi
trap 'exit 0' TERM INT
while true; do sleep 1; done
EOF
chmod +x "$proxy_dir/bin/mihomo"
run_for_startup "$proxy_dir" env SERVER_IP=192.0.2.1 SERVER_PORT=443
assert_contains 'Mihomo started' "$proxy_dir/output.log"
assert_contains 'Monitor : DISABLED' "$proxy_dir/output.log"
assert_contains 'vless://' "$proxy_dir/output.log"
assert_contains '^change this part$' "$proxy_dir/output.log"

both_dir="$(make_fixture both-services)"
cat > "$both_dir/config.env" <<'EOF'
MIHOMO_ENABLED='1'
MONITOR_ENABLED='1'
MONITOR_TYPE='lite'
MONITOR_ENDPOINT='https://lite.example.com'
MONITOR_TOKEN='test-token'
MONITOR_REMOTE_CONTROL='false'
EOF
cp "$proxy_dir/bin/mihomo" "$both_dir/bin/mihomo"
make_long_running_agent "$both_dir/bin/lite-agent"
run_for_startup "$both_dir" env SERVER_IP=192.0.2.1 SERVER_PORT=443
assert_contains 'Mihomo started' "$both_dir/output.log"
assert_contains 'Monitor started (lite' "$both_dir/output.log"
assert_contains 'vless://' "$both_dir/output.log"
assert_contains '^change this part$' "$both_dir/output.log"

renew_dir="$(make_fixture renewal-only)"
cat > "$renew_dir/config.env" <<'EOF'
MIHOMO_ENABLED='0'
MONITOR_ENABLED='0'
AUTO_RENEW_ENABLED='1'
EOF
mkdir -p "$renew_dir/logs"
printf '%s\n' '[renew] previous check succeeded' > "$renew_dir/logs/renew.log"
printf '7\n' > "$renew_dir/console.input"
run_for_startup_with_input "$renew_dir" console.input 'previous check succeeded' env
assert_contains '^change this part$' "$renew_dir/output.log"
assert_contains 'Renewal : ENABLED' "$renew_dir/output.log"
assert_contains 'Automatic renewal log' "$renew_dir/output.log"
assert_contains 'previous check succeeded' "$renew_dir/output.log"

# Pterodactyl's file editor and Windows clipboard paths may persist config.env
# with CRLF line endings. The launcher must treat it exactly like an LF file.
crlf_dir="$(make_fixture crlf-config)"
printf "CONFIG_SCHEMA_VERSION='2'\r\nMIHOMO_ENABLED='0'\r\nMONITOR_ENABLED='0'\r\nAUTO_RENEW_ENABLED='1'\r\n" \
    > "$crlf_dir/config.env"
run_for_startup "$crlf_dir" env
assert_contains '^change this part$' "$crlf_dir/output.log"
assert_contains 'Renewal : ENABLED' "$crlf_dir/output.log"
if od -An -tx1 "$crlf_dir/config.env" | grep -Eq '(^|[[:space:]])0d([[:space:]]|$)'; then
    printf 'launcher left CR bytes in config.env\n' >&2
    exit 1
fi
if grep -q "command not found" "$crlf_dir/output.log"; then
    printf 'CRLF config.env was interpreted as shell commands\n' >&2
    cat "$crlf_dir/output.log" >&2
    exit 1
fi

disabled_dir="$(make_fixture all-disabled)"
cat > "$disabled_dir/config.env" <<'EOF'
MIHOMO_ENABLED='0'
MONITOR_ENABLED='0'
AUTO_RENEW_ENABLED='0'
EOF
if (cd "$disabled_dir" && bash launcher.sh >output.log 2>&1); then
    printf 'all-disabled mode unexpectedly succeeded\n' >&2
    exit 1
fi
assert_contains 'At least one of Mihomo, Monitor, or automatic renewal must be enabled' "$disabled_dir/output.log"

printf 'launcher mode tests passed\n'
