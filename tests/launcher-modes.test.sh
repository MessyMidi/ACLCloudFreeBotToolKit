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

make_counted_crashing_monitor() {
    local path="$1"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
counter="${0}.starts"
count="$(cat "$counter" 2>/dev/null || printf '0')"
printf '%s\n' "$((count + 1))" > "$counter"
printf 'intentional monitor crash\n'
exit 23
EOF
    chmod +x "$path"
}

make_mihomo_asset() {
    local path="$1"
    local version="$2"
    cat > "$path" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-v" ]]; then printf 'Mihomo Meta $version\\n'; exit 0; fi
if [[ "\${1:-}" == "generate" && "\${2:-}" == "reality-keypair" ]]; then
    printf 'PrivateKey: test-private-key\\nPublicKey: test-public-key\\n'
    exit 0
fi
if [[ "\${1:-}" == "generate" && "\${2:-}" == "uuid" ]]; then
    printf '12345678-1234-4234-8234-123456789abc\\n'
    exit 0
fi
if [[ "\${1:-}" == "-t" ]]; then exit 0; fi
printf 'mihomo fixture $version\\n'
trap 'exit 0' TERM INT
while true; do sleep 1; done
EOF
    chmod +x "$path"
}

wait_for_output() {
    local pattern="$1"
    local file="$2"
    local attempts=0
    while (( attempts < 300 )); do
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

run_until_output() {
    local dir="$1"
    local expected="$2"
    shift 2
    (
        cd "$dir"
        exec "$@" bash launcher.sh </dev/null >output.log 2>&1
    ) &
    local pid=$!
    if ! wait_for_output "$expected" "$dir/output.log"; then
        printf 'timed out waiting for: %s\n' "$expected" >&2
        cat "$dir/output.log" >&2 || true
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        exit 1
    fi
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
printf "MONITOR_SHA256='%s'\n" "$(sha256sum "$monitor_dir/bin/lite-agent" | awk '{print $1}')" >> "$monitor_dir/config.env"
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

cfsm_dir="$(make_fixture cfsm-only)"
cat > "$cfsm_dir/config.env" <<'EOF'
MIHOMO_ENABLED='0'
MONITOR_ENABLED='1'
MONITOR_TYPE='cfsm'
MONITOR_ENDPOINT='https://worker.example.com/update'
MONITOR_TOKEN='test-secret'
MONITOR_AGENT_ID='server-id'
MONITOR_REMOTE_CONTROL='false'
MONITOR_VERSION='v1.0.18'
MONITOR_URL='https://example.invalid/cf-probe-linux-amd64'
CFSM_COLLECT_INTERVAL='2'
CFSM_REPORT_INTERVAL='60'
CFSM_CONNECTION_MODE='http'
CFSM_PING_MODE='icmp'
CFSM_RESET_DAY='0'
CFSM_DEBUG='0'
CFSM_CT_NODE='ct.example.com:80'
CFSM_INTERFACE='eth0'
EOF
make_long_running_agent "$cfsm_dir/bin/cf-probe"
printf "MONITOR_SHA256='%s'\n" "$(sha256sum "$cfsm_dir/bin/cf-probe" | awk '{print $1}')" >> "$cfsm_dir/config.env"
run_for_startup "$cfsm_dir" env
assert_contains 'Monitor started (cfsm' "$cfsm_dir/output.log"
assert_contains '^change this part$' "$cfsm_dir/output.log"
assert_contains '^SERVER_ID=server-id$' "$cfsm_dir/config/cfsm.conf"
assert_contains '^SECRET=test-secret$' "$cfsm_dir/config/cfsm.conf"
assert_contains '^WORKER_URL=https://worker.example.com/update$' "$cfsm_dir/config/cfsm.conf"
assert_contains '^COLLECT_INTERVAL=2$' "$cfsm_dir/config/cfsm.conf"
assert_contains '^CONNECTION_MODE=http$' "$cfsm_dir/config/cfsm.conf"
assert_contains '^PING_MODE=icmp$' "$cfsm_dir/config/cfsm.conf"
assert_contains '^AUTO_UPDATE=0$' "$cfsm_dir/config/cfsm.conf"

# A changed version/SHA/URL must replace a previously installed monitor binary.
monitor_update_dir="$(make_fixture monitor-update)"
mkdir -p "$monitor_update_dir/assets"
cat > "$monitor_update_dir/assets/lite-v1" <<'EOF'
#!/usr/bin/env bash
printf 'monitor fixture v1\n'
trap 'exit 0' TERM INT
while true; do sleep 1; done
EOF
cat > "$monitor_update_dir/assets/lite-v2" <<'EOF'
#!/usr/bin/env bash
printf 'monitor fixture v2\n'
trap 'exit 0' TERM INT
while true; do sleep 1; done
EOF
chmod +x "$monitor_update_dir/assets/lite-v1" "$monitor_update_dir/assets/lite-v2"
monitor_v1_sha="$(sha256sum "$monitor_update_dir/assets/lite-v1" | awk '{print $1}')"
monitor_v2_sha="$(sha256sum "$monitor_update_dir/assets/lite-v2" | awk '{print $1}')"
cat > "$monitor_update_dir/config.env" <<EOF
MIHOMO_ENABLED='0'
MONITOR_ENABLED='1'
MONITOR_TYPE='lite'
MONITOR_ENDPOINT='https://lite.example.com'
MONITOR_TOKEN='test-token'
MONITOR_REMOTE_CONTROL='false'
MONITOR_VERSION='fixture-v1'
MONITOR_URL='file://$monitor_update_dir/assets/lite-v1'
MONITOR_SHA256='$monitor_v1_sha'
EOF
run_for_startup "$monitor_update_dir" env
assert_contains 'monitor fixture v1' "$monitor_update_dir/logs/monitor.log"
cat > "$monitor_update_dir/config.env" <<EOF
MIHOMO_ENABLED='0'
MONITOR_ENABLED='1'
MONITOR_TYPE='lite'
MONITOR_ENDPOINT='https://lite.example.com'
MONITOR_TOKEN='test-token'
MONITOR_REMOTE_CONTROL='false'
MONITOR_VERSION='fixture-v2'
MONITOR_URL='file://$monitor_update_dir/assets/lite-v2'
MONITOR_SHA256='$monitor_v2_sha'
EOF
run_for_startup "$monitor_update_dir" env
assert_contains 'Monitor Agent installed (lite fixture-v2)' "$monitor_update_dir/output.log"
assert_contains 'monitor fixture v2' "$monitor_update_dir/logs/monitor.log"

proxy_dir="$(make_fixture proxy-only)"
cat > "$proxy_dir/config.env" <<'EOF'
# MIHOMO_ENABLED is intentionally omitted to verify backward compatibility.
MONITOR_ENABLED='0'
EOF
cat > "$proxy_dir/bin/mihomo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
    printf 'Mihomo Meta v1.19.31\n'
    exit 0
fi
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

# Mihomo archive checksums and install metadata must trigger an atomic upgrade.
mihomo_update_dir="$(make_fixture mihomo-update)"
mkdir -p "$mihomo_update_dir/assets"
make_mihomo_asset "$mihomo_update_dir/assets/mihomo-v1" 'fixture-v1'
make_mihomo_asset "$mihomo_update_dir/assets/mihomo-v2" 'fixture-v2'
gzip -c "$mihomo_update_dir/assets/mihomo-v1" > "$mihomo_update_dir/assets/mihomo-v1.gz"
gzip -c "$mihomo_update_dir/assets/mihomo-v2" > "$mihomo_update_dir/assets/mihomo-v2.gz"
mihomo_v1_sha="$(sha256sum "$mihomo_update_dir/assets/mihomo-v1.gz" | awk '{print $1}')"
mihomo_v2_sha="$(sha256sum "$mihomo_update_dir/assets/mihomo-v2.gz" | awk '{print $1}')"
cat > "$mihomo_update_dir/config.env" <<EOF
MIHOMO_ENABLED='1'
MONITOR_ENABLED='0'
MIHOMO_VERSION='fixture-v1'
MIHOMO_URL='file://$mihomo_update_dir/assets/mihomo-v1.gz'
MIHOMO_SHA256='$mihomo_v1_sha'
MIHOMO_FALLBACK_URL='file://$mihomo_update_dir/assets/mihomo-v1.gz'
MIHOMO_FALLBACK_SHA256='$mihomo_v1_sha'
EOF
run_for_startup "$mihomo_update_dir" env SERVER_IP=192.0.2.1 SERVER_PORT=443
assert_contains 'Mihomo Meta fixture-v1' "$mihomo_update_dir/output.log"
cat > "$mihomo_update_dir/config.env" <<EOF
MIHOMO_ENABLED='1'
MONITOR_ENABLED='0'
MIHOMO_VERSION='fixture-v2'
MIHOMO_URL='file://$mihomo_update_dir/assets/mihomo-v2.gz'
MIHOMO_SHA256='$mihomo_v2_sha'
MIHOMO_FALLBACK_URL='file://$mihomo_update_dir/assets/mihomo-v2.gz'
MIHOMO_FALLBACK_SHA256='$mihomo_v2_sha'
EOF
run_for_startup "$mihomo_update_dir" env SERVER_IP=192.0.2.1 SERVER_PORT=443
assert_contains 'Mihomo install metadata changed; downloading fixture-v2' "$mihomo_update_dir/output.log"
assert_contains 'Mihomo Meta fixture-v2' "$mihomo_update_dir/output.log"

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
printf "MONITOR_SHA256='%s'\n" "$(sha256sum "$both_dir/bin/lite-agent" | awk '{print $1}')" >> "$both_dir/config.env"
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

# Monitor crashes use exponential backoff and stop at the configured retry cap.
monitor_watchdog_dir="$(make_fixture monitor-watchdog)"
cat > "$monitor_watchdog_dir/config.env" <<'EOF'
MIHOMO_ENABLED='0'
MONITOR_ENABLED='1'
MONITOR_TYPE='lite'
MONITOR_ENDPOINT='https://lite.example.com'
MONITOR_TOKEN='test-token'
MONITOR_REMOTE_CONTROL='false'
WATCHDOG_MAX_RESTARTS='2'
WATCHDOG_BASE_DELAY_SECONDS='1'
WATCHDOG_STABLE_SECONDS='9999'
EOF
make_counted_crashing_monitor "$monitor_watchdog_dir/bin/lite-agent"
printf "MONITOR_SHA256='%s'\n" "$(sha256sum "$monitor_watchdog_dir/bin/lite-agent" | awk '{print $1}')" >> "$monitor_watchdog_dir/config.env"
run_until_output "$monitor_watchdog_dir" 'Monitor watchdog stopped after 2 restart attempts' env
assert_contains '^3$' "$monitor_watchdog_dir/bin/lite-agent.starts"
assert_contains 'Monitor crashed; watchdog restart 1/2 scheduled in 1s' "$monitor_watchdog_dir/output.log"
assert_contains 'Monitor crashed; watchdog restart 2/2 scheduled in 2s' "$monitor_watchdog_dir/output.log"

# Mihomo uses the same capped watchdog and remains recoverable through menu restart.
mihomo_watchdog_dir="$(make_fixture mihomo-watchdog)"
cat > "$mihomo_watchdog_dir/config.env" <<'EOF'
MIHOMO_ENABLED='1'
MONITOR_ENABLED='0'
MIHOMO_VERSION='v1.19.31'
MIHOMO_SHA256=''
MIHOMO_FALLBACK_SHA256=''
WATCHDOG_BASE_DELAY_SECONDS='0'
WATCHDOG_STABLE_SECONDS='9999'
EOF
cat > "$mihomo_watchdog_dir/bin/mihomo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then printf 'Mihomo Meta v1.19.31\n'; exit 0; fi
if [[ "${1:-}" == "generate" && "${2:-}" == "reality-keypair" ]]; then
    printf 'PrivateKey: test-private-key\nPublicKey: test-public-key\n'
    exit 0
fi
if [[ "${1:-}" == "generate" && "${2:-}" == "uuid" ]]; then
    printf '12345678-1234-4234-8234-123456789abc\n'
    exit 0
fi
if [[ "${1:-}" == "-t" ]]; then exit 0; fi
counter="${0}.starts"
count="$(cat "$counter" 2>/dev/null || printf '0')"
printf '%s\n' "$((count + 1))" > "$counter"
if [[ "$count" == '0' ]]; then sleep 2; fi
printf 'intentional mihomo crash\n'
exit 24
EOF
chmod +x "$mihomo_watchdog_dir/bin/mihomo"
run_until_output "$mihomo_watchdog_dir" 'Mihomo watchdog stopped after 5 restart attempts' env SERVER_IP=192.0.2.1 SERVER_PORT=443
assert_contains '^6$' "$mihomo_watchdog_dir/bin/mihomo.starts"
assert_contains 'Mihomo crashed; watchdog restart 1/5 scheduled in 0s' "$mihomo_watchdog_dir/output.log"

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
