#!/usr/bin/env bash
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

run_for_startup() {
    local dir="$1"
    shift
    (
        cd "$dir"
        exec "$@" bash launcher.sh </dev/null >output.log 2>&1
    ) &
    local pid=$!
    # Both-services mode performs two one-second health checks in sequence.
    # Leave headroom for slower CI and Git-for-Windows process startup.
    sleep 4
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
run_for_startup "$monitor_dir" env
assert_contains 'Monitor started (lite' "$monitor_dir/output.log"
assert_contains 'Mihomo : DISABLED' "$monitor_dir/output.log"
assert_contains '^change this part$' "$monitor_dir/output.log"
assert_after 'Startup completed' '^change this part$' "$monitor_dir/output.log"
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

disabled_dir="$(make_fixture all-disabled)"
cat > "$disabled_dir/config.env" <<'EOF'
MIHOMO_ENABLED='0'
MONITOR_ENABLED='0'
EOF
if (cd "$disabled_dir" && bash launcher.sh >output.log 2>&1); then
    printf 'all-disabled mode unexpectedly succeeded\n' >&2
    exit 1
fi
assert_contains 'At least one service must be enabled' "$disabled_dir/output.log"

printf 'launcher mode tests passed\n'
