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

# Git for Windows ships a native curl that cannot open MSYS paths such as
# /tmp/..., so file:// URLs are built from the Windows path there.
file_url() {
    local path="$1"
    if command -v cygpath >/dev/null 2>&1; then
        printf 'file:///%s\n' "$(cygpath -m "$path")"
    else
        printf 'file://%s\n' "$path"
    fi
}

run_for_startup() {
    local dir="$1"
    shift
    # The first prompt is printed only after status and the optional VLESS link,
    # so this is a deterministic completion signal even on slower CI hosts.
    run_until_output "$dir" '请输入数字' "$@"
}

run_for_startup_with_input() {
    local dir="$1"
    local input="$2"
    local expected="$3"
    shift 3
    : > "$dir/output.log"
    (
        cd "$dir"
        exec "$@" bash launcher.sh <"$input" >output.log 2>&1
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

run_until_output() {
    local dir="$1"
    local expected="$2"
    shift 2
    # Clear the previous launch's readiness before forking. Truncating only
    # inside the background process lets the parent observe stale output.
    : > "$dir/output.log"
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

# Exercise the real configuration/defaults boundary without starting services
# or contacting upstream. Old generated pins must not mask a launcher update.
pins_dir="$(make_fixture official-pins)"
sed '/^signal_bootstrap_installing$/,$d' "$PROJECT_DIR/launcher.sh" > "$pins_dir/pins.sh"
cat >> "$pins_dir/pins.sh" <<'EOF'
printf 'resolved-mihomo=%s|%s|%s|%s|%s\n' "$MIHOMO_VERSION" "$MIHOMO_URL" "$MIHOMO_SHA256" "$MIHOMO_FALLBACK_URL" "$MIHOMO_FALLBACK_SHA256"
printf 'resolved-monitor=%s|%s|%s\n' "$MONITOR_VERSION" "$MONITOR_URL" "$MONITOR_SHA256"
EOF
cat > "$pins_dir/old.env" <<'EOF'
MIHOMO_ENABLED='0'
MONITOR_ENABLED='1'
MONITOR_TYPE='lite'
MONITOR_ENDPOINT='https://monitor.example.com'
MONITOR_TOKEN='fixture-token'
MONITOR_AGENT_ID='fixture-id'
MIHOMO_VERSION='v1.19.31'
MIHOMO_URL='https://github.com/MetaCubeX/mihomo/releases/download/v1.19.31/mihomo-linux-amd64-v1-v1.19.31.gz'
MIHOMO_SHA256='d4304c546c3cddcb6fafd4b4fddb0ba1a95ffa36606fda56d75db2e59ad24114'
MIHOMO_FALLBACK_URL='https://github.com/MetaCubeX/mihomo/releases/download/v1.19.31/mihomo-linux-amd64-compatible-v1.19.31.gz'
MIHOMO_FALLBACK_SHA256='04cf9f09671704f839ddbee2e93069dc831a4123a75281e725d1d96ab9ac1afc'
MONITOR_VERSION='2.3.3.5'
MONITOR_URL='https://github.com/nuomiiiii/Lite-agent/releases/download/2.3.3.5/Lite-agent-linux-amd64'
MONITOR_SHA256='c39042e712bd204a5ea359b6d0f0f5b2c3e6bf6fa9bdcd8954e8fad30f32a6ed'
EOF
run_pins() {
    cp "$pins_dir/config.env" "$pins_dir/before.env"
    (cd "$pins_dir" && bash pins.sh >output.log 2>&1)
    cmp "$pins_dir/before.env" "$pins_dir/config.env"
}
cp "$pins_dir/old.env" "$pins_dir/config.env"
run_pins
assert_contains '^resolved-mihomo=v1.19.32|.*306f81e723e60ce6b828899a6fe83e1d00e9ecefb2dc8d4d849312a5bc00efdc.*ba3ce607747a07f948fc35780e108a4a7c7f552a38b9bd4d115f313ebcb89c20$' "$pins_dir/output.log"
assert_contains '^resolved-monitor=2.3.6.0|.*d973b48edba2c1be9faea959c231dc6a278fa40ad283d53a459f8ad7727ef15b$' "$pins_dir/output.log"
for field in MIHOMO_VERSION MIHOMO_URL MIHOMO_SHA256 MIHOMO_FALLBACK_URL MIHOMO_FALLBACK_SHA256 MONITOR_VERSION MONITOR_URL MONITOR_SHA256; do
    for value in custom ''; do
        cp "$pins_dir/old.env" "$pins_dir/config.env"
        printf "%s='%s'\n" "$field" "$value" >> "$pins_dir/config.env"
        run_pins
        if [[ "$field" == MIHOMO_* ]]; then
            assert_contains 'mihomo-linux-amd64-.*v1.19.31.gz' "$pins_dir/output.log"
        else
            assert_contains '^resolved-monitor=.*2.3.3.5' "$pins_dir/output.log"
        fi
    done
done
cp "$pins_dir/old.env" "$pins_dir/config.env"
printf "RUNTIME_VERSIONS_PINNED='1'\n" >> "$pins_dir/config.env"
run_pins
assert_contains '^resolved-mihomo=v1.19.31|' "$pins_dir/output.log"
assert_contains '^resolved-monitor=2.3.3.5|' "$pins_dir/output.log"
cp "$pins_dir/old.env" "$pins_dir/config.env"
cat >> "$pins_dir/config.env" <<'EOF'
MONITOR_TYPE='cfsm'
MONITOR_VERSION='v1.0.18'
MONITOR_URL='https://github.com/huilang-me/cfsm-agent/releases/download/v1.0.18/cf-probe-linux-amd64'
MONITOR_SHA256='757a88084ce62e69379d0f9726b42291c06bfd51bdfdd58b45311d7a89ba5daa'
EOF
cp "$pins_dir/config.env" "$pins_dir/cfsm.env"
run_pins
assert_contains '^resolved-monitor=v1.0.19|.*64cc6e2a34ac49a39fb04894a48262bc0b3221d97ba7314dde15ad108097d52c$' "$pins_dir/output.log"
for field in MONITOR_VERSION MONITOR_URL MONITOR_SHA256; do
    cp "$pins_dir/cfsm.env" "$pins_dir/config.env"
    printf "%s='custom'\n" "$field" >> "$pins_dir/config.env"
    run_pins
    assert_contains '^resolved-monitor=.*v1.0.18' "$pins_dir/output.log"
done
cp "$pins_dir/cfsm.env" "$pins_dir/config.env"
printf "RUNTIME_VERSIONS_PINNED='1'\n" >> "$pins_dir/config.env"
run_pins
assert_contains '^resolved-monitor=v1.0.18|' "$pins_dir/output.log"

# Legacy generated configs did not always include checksums. Leaving their
# old URLs in place must never attach a new release's digest to those URLs.
for pinned in 0 1; do
    for missing in primary fallback both; do
        cp "$pins_dir/old.env" "$pins_dir/config.env"
        case "$missing" in
            primary) sed -i '/^MIHOMO_SHA256=/d' "$pins_dir/config.env" ;;
            fallback) sed -i '/^MIHOMO_FALLBACK_SHA256=/d' "$pins_dir/config.env" ;;
            both) sed -i '/^MIHOMO_\(FALLBACK_\)\?SHA256=/d' "$pins_dir/config.env" ;;
        esac
        printf "RUNTIME_VERSIONS_PINNED='%s'\n" "$pinned" >> "$pins_dir/config.env"
        run_pins
        assert_contains '^resolved-mihomo=v1.19.31|.*d4304c546c3cddcb6fafd4b4fddb0ba1a95ffa36606fda56d75db2e59ad24114.*04cf9f09671704f839ddbee2e93069dc831a4123a75281e725d1d96ab9ac1afc$' "$pins_dir/output.log"
    done
    for monitor_type in lite cfsm; do
        base_env="$pins_dir/old.env"
        legacy_version='2.3.3.5'
        legacy_sha='c39042e712bd204a5ea359b6d0f0f5b2c3e6bf6fa9bdcd8954e8fad30f32a6ed'
        if [[ "$monitor_type" == cfsm ]]; then
            base_env="$pins_dir/cfsm.env"
            legacy_version='v1.0.18'
            legacy_sha='757a88084ce62e69379d0f9726b42291c06bfd51bdfdd58b45311d7a89ba5daa'
        fi
        for empty in omitted blank; do
            sed '/^MONITOR_SHA256=/d' "$base_env" > "$pins_dir/config.env"
            [[ "$empty" != blank ]] || printf "MONITOR_SHA256=''\n" >> "$pins_dir/config.env"
            printf "RUNTIME_VERSIONS_PINNED='%s'\n" "$pinned" >> "$pins_dir/config.env"
            run_pins
            assert_contains "^resolved-monitor=$legacy_version|.*$legacy_sha$" "$pins_dir/output.log"
        done
    done
done
# Version-only legacy overrides use that version's implicit official URLs.
sed '/^MIHOMO_\(FALLBACK_\)\?\(URL\|SHA256\)=/d; /^MONITOR_\(URL\|SHA256\)=/d' "$pins_dir/old.env" > "$pins_dir/config.env"
run_pins
assert_contains '^resolved-mihomo=v1.19.31|.*d4304c546c3cddcb6fafd4b4fddb0ba1a95ffa36606fda56d75db2e59ad24114.*04cf9f09671704f839ddbee2e93069dc831a4123a75281e725d1d96ab9ac1afc$' "$pins_dir/output.log"
assert_contains '^resolved-monitor=2.3.3.5|.*c39042e712bd204a5ea359b6d0f0f5b2c3e6bf6fa9bdcd8954e8fad30f32a6ed$' "$pins_dir/output.log"
# Filling a missing official digest must not overwrite a user-provided digest.
sed '/^MIHOMO_FALLBACK_SHA256=/d' "$pins_dir/old.env" > "$pins_dir/config.env"
printf "MIHOMO_SHA256='custom-checksum'\n" >> "$pins_dir/config.env"
run_pins
assert_contains '^resolved-mihomo=v1.19.31|.*|custom-checksum|.*04cf9f09671704f839ddbee2e93069dc831a4123a75281e725d1d96ab9ac1afc$' "$pins_dir/output.log"

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
MONITOR_VERSION='v1.0.19'
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
for monitor_type in lite komari cfsm; do
monitor_update_dir="$(make_fixture "monitor-update-$monitor_type")"
mkdir -p "$monitor_update_dir/assets"
cat > "$monitor_update_dir/assets/lite-v1" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == '--help' ]]; then exit 0; fi
printf 'monitor fixture v1\n'
trap 'exit 0' TERM INT
while true; do sleep 1; done
EOF
cat > "$monitor_update_dir/assets/lite-v2" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == '--help' ]]; then exit 0; fi
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
MONITOR_TYPE='$monitor_type'
MONITOR_AGENT_ID='fixture-id'
MONITOR_ENDPOINT='https://lite.example.com'
MONITOR_TOKEN='test-token'
MONITOR_REMOTE_CONTROL='false'
MONITOR_VERSION='fixture-v1'
MONITOR_URL='$(file_url "$monitor_update_dir/assets/lite-v1")'
MONITOR_SHA256='$monitor_v1_sha'
EOF
run_for_startup "$monitor_update_dir" env
assert_contains 'monitor fixture v1' "$monitor_update_dir/logs/monitor.log"
cat > "$monitor_update_dir/config.env" <<EOF
MIHOMO_ENABLED='0'
MONITOR_ENABLED='1'
MONITOR_TYPE='$monitor_type'
MONITOR_AGENT_ID='fixture-id'
MONITOR_ENDPOINT='https://lite.example.com'
MONITOR_TOKEN='test-token'
MONITOR_REMOTE_CONTROL='false'
MONITOR_VERSION='fixture-v2'
MONITOR_URL='$(file_url "$monitor_update_dir/assets/lite-v2")'
MONITOR_SHA256='$monitor_v2_sha'
EOF
# Delay the child before it redirects output to reproduce the stale-log race.
(
    cd() { sleep 0.3; builtin cd "$@"; }
    run_for_startup "$monitor_update_dir" env
)
assert_contains "Monitor Agent installed ($monitor_type fixture-v2)" "$monitor_update_dir/output.log"
assert_contains 'monitor fixture v2' "$monitor_update_dir/logs/monitor.log"
cp "$monitor_update_dir/data/monitor-$monitor_type.install-state" "$monitor_update_dir/installed.state"
run_for_startup "$monitor_update_dir" env
if grep -q 'Downloading:' "$monitor_update_dir/output.log"; then
    printf 'unchanged monitor spec downloaded again: %s\n' "$monitor_type" >&2
    exit 1
fi
# A failed replacement must keep both the old binary and its old metadata,
# otherwise the next launch would incorrectly consider the update installed.
printf "MONITOR_VERSION='fixture-v3'\nMONITOR_SHA256='%064d'\n" 0 >> "$monitor_update_dir/config.env"
for _ in 1 2; do
    run_for_startup "$monitor_update_dir" env
    assert_contains 'Monitor update failed; continuing with the existing binary' "$monitor_update_dir/output.log"
    assert_contains 'monitor fixture v2' "$monitor_update_dir/logs/monitor.log"
    cmp "$monitor_update_dir/installed.state" "$monitor_update_dir/data/monitor-$monitor_type.install-state"
done
printf "MONITOR_URL='%s'\n" "$(file_url "$monitor_update_dir/assets/missing")" >> "$monitor_update_dir/config.env"
run_for_startup "$monitor_update_dir" env
assert_contains 'Monitor update failed; continuing with the existing binary' "$monitor_update_dir/output.log"
cmp "$monitor_update_dir/installed.state" "$monitor_update_dir/data/monitor-$monitor_type.install-state"
# Even a checksummed asset may be incompatible with this host.
printf '#!/usr/bin/env bash\nexit 126\n' > "$monitor_update_dir/assets/unusable"
printf "MONITOR_URL='%s'\nMONITOR_SHA256='%s'\n" \
    "$(file_url "$monitor_update_dir/assets/unusable")" \
    "$(sha256sum "$monitor_update_dir/assets/unusable" | awk '{print $1}')" >> "$monitor_update_dir/config.env"
run_for_startup "$monitor_update_dir" env
assert_contains 'Downloaded Monitor Agent failed its smoke test; continuing with the existing binary' "$monitor_update_dir/output.log"
assert_contains 'monitor fixture v2' "$monitor_update_dir/logs/monitor.log"
cmp "$monitor_update_dir/installed.state" "$monitor_update_dir/data/monitor-$monitor_type.install-state"
done

proxy_dir="$(make_fixture proxy-only)"
cat > "$proxy_dir/config.env" <<'EOF'
# MIHOMO_ENABLED is intentionally omitted to verify backward compatibility.
MONITOR_ENABLED='0'
EOF
cat > "$proxy_dir/bin/mihomo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
    printf 'Mihomo Meta v1.19.32\n'
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
# Proxy users are kept away from private networks unless explicitly allowed.
assert_contains '^  - IP-CIDR,10.0.0.0/8,REJECT$' "$proxy_dir/config/mihomo.yaml"
assert_contains '^  - IP-CIDR,169.254.0.0/16,REJECT$' "$proxy_dir/config/mihomo.yaml"
assert_contains '^  - IP-CIDR6,fc00::/7,REJECT$' "$proxy_dir/config/mihomo.yaml"
assert_after 'IP-CIDR,127.0.0.0/8,REJECT' '^  - MATCH,DIRECT$' "$proxy_dir/config/mihomo.yaml"

# The launcher accepts every destination the Web generator accepts,
# including bracketed IPv6 addresses, and private networks can be allowed.
ipv6_dir="$(make_fixture proxy-ipv6)"
cat > "$ipv6_dir/config.env" <<'EOF'
MONITOR_ENABLED='0'
REALITY_DEST='[2001:db8::1]:443'
MIHOMO_BLOCK_PRIVATE_NETWORKS='0'
EOF
cp "$proxy_dir/bin/mihomo" "$ipv6_dir/bin/mihomo"
run_for_startup "$ipv6_dir" env SERVER_IP=192.0.2.1 SERVER_PORT=443
assert_contains 'Mihomo started' "$ipv6_dir/output.log"
assert_contains '^      dest: "\[2001:db8::1\]:443"$' "$ipv6_dir/config/mihomo.yaml"
if grep -q 'REJECT' "$ipv6_dir/config/mihomo.yaml"; then
    printf 'MIHOMO_BLOCK_PRIVATE_NETWORKS=0 still rejected private networks\n' >&2
    exit 1
fi

bad_port_dir="$(make_fixture proxy-bad-port)"
cat > "$bad_port_dir/config.env" <<'EOF'
MONITOR_ENABLED='0'
REALITY_DEST='www.example.com:70000'
EOF
cp "$proxy_dir/bin/mihomo" "$bad_port_dir/bin/mihomo"
if (cd "$bad_port_dir" && env SERVER_IP=192.0.2.1 SERVER_PORT=443 bash launcher.sh </dev/null >output.log 2>&1); then
    printf 'launcher accepted a destination port above 65535\n' >&2
    exit 1
fi
assert_contains 'REALITY_DEST must be host:port' "$bad_port_dir/output.log"

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
MIHOMO_URL='$(file_url "$mihomo_update_dir/assets/mihomo-v1.gz")'
MIHOMO_SHA256='$mihomo_v1_sha'
MIHOMO_FALLBACK_URL='$(file_url "$mihomo_update_dir/assets/mihomo-v1.gz")'
MIHOMO_FALLBACK_SHA256='$mihomo_v1_sha'
EOF
run_for_startup "$mihomo_update_dir" env SERVER_IP=192.0.2.1 SERVER_PORT=443
assert_contains 'Mihomo Meta fixture-v1' "$mihomo_update_dir/output.log"
cat > "$mihomo_update_dir/config.env" <<EOF
MIHOMO_ENABLED='1'
MONITOR_ENABLED='0'
MIHOMO_VERSION='fixture-v2'
MIHOMO_URL='$(file_url "$mihomo_update_dir/assets/mihomo-v2.gz")'
MIHOMO_SHA256='$mihomo_v2_sha'
MIHOMO_FALLBACK_URL='$(file_url "$mihomo_update_dir/assets/mihomo-v2.gz")'
MIHOMO_FALLBACK_SHA256='$mihomo_v2_sha'
EOF
run_for_startup "$mihomo_update_dir" env SERVER_IP=192.0.2.1 SERVER_PORT=443
assert_contains 'Mihomo install metadata changed; downloading fixture-v2' "$mihomo_update_dir/output.log"
assert_contains 'Mihomo Meta fixture-v2' "$mihomo_update_dir/output.log"
cp "$mihomo_update_dir/data/mihomo.install-state" "$mihomo_update_dir/installed.state"
run_for_startup "$mihomo_update_dir" env SERVER_IP=192.0.2.1 SERVER_PORT=443
if grep -q 'Downloading:' "$mihomo_update_dir/output.log"; then
    printf 'unchanged Mihomo spec downloaded again\n' >&2
    exit 1
fi
printf "MIHOMO_VERSION='fixture-v3'\nMIHOMO_SHA256='%064d'\nMIHOMO_FALLBACK_SHA256='%064d'\n" 0 0 >> "$mihomo_update_dir/config.env"
for _ in 1 2; do
    run_for_startup "$mihomo_update_dir" env SERVER_IP=192.0.2.1 SERVER_PORT=443
    assert_contains 'Mihomo update failed; continuing with the existing binary' "$mihomo_update_dir/output.log"
    assert_contains 'mihomo fixture fixture-v2' "$mihomo_update_dir/logs/mihomo.log"
    cmp "$mihomo_update_dir/installed.state" "$mihomo_update_dir/data/mihomo.install-state"
done
# Primary checksum failure must still permit a valid compatible build.
printf "MIHOMO_FALLBACK_SHA256='%s'\n" "$mihomo_v2_sha" >> "$mihomo_update_dir/config.env"
run_for_startup "$mihomo_update_dir" env SERVER_IP=192.0.2.1 SERVER_PORT=443
assert_contains 'trying compatible build' "$mihomo_update_dir/output.log"
assert_contains 'Mihomo installed:' "$mihomo_update_dir/output.log"

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
# Staying inside a log submenu must not pause watchdog restart attempts.
printf '4\n' > "$monitor_watchdog_dir/console.input"
run_for_startup_with_input "$monitor_watchdog_dir" console.input 'Monitor watchdog stopped after 2 restart attempts' env
assert_contains '输出全部已保留日志' "$monitor_watchdog_dir/output.log"
assert_contains '^3$' "$monitor_watchdog_dir/bin/lite-agent.starts"
assert_contains 'Monitor crashed; watchdog restart 1/2 scheduled in 1s' "$monitor_watchdog_dir/output.log"
assert_contains 'Monitor crashed; watchdog restart 2/2 scheduled in 2s' "$monitor_watchdog_dir/output.log"

# Mihomo uses the same capped watchdog and remains recoverable through menu restart.
mihomo_watchdog_dir="$(make_fixture mihomo-watchdog)"
cat > "$mihomo_watchdog_dir/config.env" <<'EOF'
MIHOMO_ENABLED='1'
MONITOR_ENABLED='0'
MIHOMO_VERSION='v1.19.32'
MIHOMO_SHA256=''
MIHOMO_FALLBACK_SHA256=''
WATCHDOG_BASE_DELAY_SECONDS='0'
WATCHDOG_STABLE_SECONDS='9999'
EOF
cat > "$mihomo_watchdog_dir/bin/mihomo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then printf 'Mihomo Meta v1.19.32\n'; exit 0; fi
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

# Credentials from config.env must not reach an agent's environment; the
# agent still receives its own token explicitly.
secrets_dir="$(make_fixture secret-isolation)"
cat > "$secrets_dir/bin/lite-agent" <<'EOF'
#!/usr/bin/env bash
env > "${0}.env"
trap 'exit 0' TERM INT
while true; do sleep 1; done
EOF
chmod +x "$secrets_dir/bin/lite-agent"
cat > "$secrets_dir/config.env" <<EOF
MIHOMO_ENABLED='0'
MONITOR_ENABLED='1'
MONITOR_TYPE='lite'
MONITOR_ENDPOINT='https://lite.example.com'
MONITOR_TOKEN='agent-token'
MONITOR_REMOTE_CONTROL='false'
MONITOR_SHA256='$(sha256sum "$secrets_dir/bin/lite-agent" | awk '{print $1}')'
AUTO_RENEW_ENABLED='1'
ACL_USERNAME='person@example.com'
ACL_PASSWORD='acl-password'
TELEGRAM_BOT_TOKEN='123:telegram-token'
TELEGRAM_CHAT_ID='42'
EOF
run_for_startup "$secrets_dir" env
assert_contains '^AGENT_TOKEN=agent-token$' "$secrets_dir/bin/lite-agent.env"
if grep -Eq 'acl-password|telegram-token|person@example.com|^MONITOR_TOKEN=' "$secrets_dir/bin/lite-agent.env"; then
    printf 'credentials leaked into the monitor agent environment\n' >&2
    exit 1
fi

# Service logs are trimmed while running so they cannot fill the disk.
log_trim_dir="$(make_fixture log-trim)"
cat > "$log_trim_dir/bin/lite-agent" <<'EOF'
#!/usr/bin/env bash
for line in $(seq 1 200); do
    printf 'agent log line %04d with padding to make the log grow quickly\n' "$line"
done
trap 'exit 0' TERM INT
while true; do sleep 1; done
EOF
chmod +x "$log_trim_dir/bin/lite-agent"
cat > "$log_trim_dir/config.env" <<EOF
MIHOMO_ENABLED='0'
MONITOR_ENABLED='1'
MONITOR_TYPE='lite'
MONITOR_ENDPOINT='https://lite.example.com'
MONITOR_TOKEN='test-token'
MONITOR_REMOTE_CONTROL='false'
MONITOR_SHA256='$(sha256sum "$log_trim_dir/bin/lite-agent" | awk '{print $1}')'
LOG_MAX_BYTES='2048'
EOF
(
    cd "$log_trim_dir"
    exec bash launcher.sh </dev/null >output.log 2>&1
) &
log_trim_pid=$!
if ! wait_for_output 'older lines removed' "$log_trim_dir/logs/monitor.log"; then
    printf 'oversized monitor log was not trimmed\n' >&2
    kill -TERM "$log_trim_pid" 2>/dev/null || true
    wait "$log_trim_pid" 2>/dev/null || true
    exit 1
fi
kill -TERM "$log_trim_pid" 2>/dev/null || true
wait "$log_trim_pid" 2>/dev/null || true
(( $(wc -c < "$log_trim_dir/logs/monitor.log") <= 2048 )) || { printf 'trimmed log is still too large\n' >&2; exit 1; }
assert_contains 'agent log line 0200' "$log_trim_dir/logs/monitor.log"

# The Console menu follows CONSOLE_LANG.
english_dir="$(make_fixture english-console)"
cat > "$english_dir/config.env" <<'EOF'
MIHOMO_ENABLED='0'
MONITOR_ENABLED='0'
AUTO_RENEW_ENABLED='1'
CONSOLE_LANG='en'
EOF
run_until_output "$english_dir" 'Enter a number: ' env
assert_contains '^\[7\] Renewal log (last 3 checks)$' "$english_dir/output.log"

printf 'launcher mode tests passed\n'
