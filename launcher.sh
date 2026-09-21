#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$BASE_DIR/bin"
CONFIG_DIR="$BASE_DIR/config"
DATA_DIR="$BASE_DIR/data"
LOG_DIR="$BASE_DIR/logs"
MIHOMO_HOME="$DATA_DIR/mihomo-home"

MIHOMO_BIN="$BIN_DIR/mihomo"
KOMARI_BIN="$BIN_DIR/komari-agent"
LITE_BIN="$BIN_DIR/lite-agent"
MIHOMO_CONFIG="$CONFIG_DIR/mihomo.yaml"
SECRETS_FILE="$DATA_DIR/mihomo-secrets.env"
MIHOMO_LOG="$LOG_DIR/mihomo.log"
MONITOR_LOG="$LOG_DIR/monitor.log"

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$MIHOMO_HOME"

log()  { printf '[launcher] %s\n' "$*"; }
warn() { printf '[launcher] WARNING: %s\n' "$*" >&2; }
die()  { printf '[launcher] ERROR: %s\n' "$*" >&2; exit 1; }

# ACLClouds' file manager does not conveniently create a bare ".env".
# Prefer config.env, but keep .env compatibility.
if [[ -f "$BASE_DIR/config.env" ]]; then
    ENV_FILE="$BASE_DIR/config.env"
elif [[ -f "$BASE_DIR/.env" ]]; then
    ENV_FILE="$BASE_DIR/.env"
else
    die "No config.env or .env found in $BASE_DIR"
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ---------------- Defaults ----------------

MIHOMO_ENABLED="${MIHOMO_ENABLED:-1}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.31}"
MIHOMO_URL="${MIHOMO_URL:-https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-amd64-v1-${MIHOMO_VERSION}.gz}"
MIHOMO_FALLBACK_URL="${MIHOMO_FALLBACK_URL:-https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-amd64-compatible-${MIHOMO_VERSION}.gz}"

MIHOMO_LOGLEVEL="${MIHOMO_LOGLEVEL:-info}"
MIHOMO_REMARK="${MIHOMO_REMARK:-ACLClouds-Free}"
REALITY_DEST="${REALITY_DEST:-www.cloudflare.com:443}"
REALITY_SNI="${REALITY_SNI:-www.cloudflare.com}"
CLIENT_FINGERPRINT="${CLIENT_FINGERPRINT:-chrome}"
VLESS_FLOW="${VLESS_FLOW:-xtls-rprx-vision}"

# MONITOR_* is the current schema. KOMARI_* remains supported so existing,
# already-tested deployments keep working without editing config.env.
MONITOR_ENABLED="${MONITOR_ENABLED:-${KOMARI_ENABLED:-1}}"
MONITOR_TYPE="${MONITOR_TYPE:-komari}"
MONITOR_ENDPOINT="${MONITOR_ENDPOINT:-${KOMARI_ENDPOINT:-}}"
MONITOR_TOKEN="${MONITOR_TOKEN:-${KOMARI_TOKEN:-}}"
MONITOR_REMOTE_CONTROL="${MONITOR_REMOTE_CONTROL:-false}"

[[ "$MIHOMO_ENABLED" == "0" || "$MIHOMO_ENABLED" == "1" ]] || die "MIHOMO_ENABLED must be 0 or 1"
[[ "$MONITOR_ENABLED" == "0" || "$MONITOR_ENABLED" == "1" ]] || die "MONITOR_ENABLED must be 0 or 1"
[[ "$MIHOMO_ENABLED" == "1" || "$MONITOR_ENABLED" == "1" ]] || die "At least one service must be enabled"

if [[ "$MIHOMO_ENABLED" == "1" ]]; then
    : "${SERVER_IP:?ACLClouds did not provide SERVER_IP}"
    : "${SERVER_PORT:?ACLClouds did not provide SERVER_PORT}"
    [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] || die "SERVER_PORT is not numeric: $SERVER_PORT"
    [[ "$REALITY_SNI" =~ ^[A-Za-z0-9._-]+$ ]] || die "REALITY_SNI contains unsupported characters"
    [[ "$REALITY_DEST" =~ ^[A-Za-z0-9._:-]+$ ]] || die "REALITY_DEST contains unsupported characters"
    [[ "$CLIENT_FINGERPRINT" =~ ^[A-Za-z0-9._-]+$ ]] || die "CLIENT_FINGERPRINT contains unsupported characters"
    [[ "$MIHOMO_REMARK" =~ ^[A-Za-z0-9._-]+$ ]] || die "MIHOMO_REMARK contains unsupported characters"
fi

if [[ "$MONITOR_ENABLED" == "1" ]]; then
    [[ "$MONITOR_REMOTE_CONTROL" == "true" || "$MONITOR_REMOTE_CONTROL" == "false" ]] || die "MONITOR_REMOTE_CONTROL must be true or false"
    case "$MONITOR_TYPE" in
        lite)
            MONITOR_VERSION="${MONITOR_VERSION:-2.3.3.5}"
            MONITOR_URL="${MONITOR_URL:-https://github.com/nuomiiiii/Lite-agent/releases/download/${MONITOR_VERSION}/Lite-agent-linux-amd64}"
            MONITOR_SHA256="${MONITOR_SHA256:-c39042e712bd204a5ea359b6d0f0f5b2c3e6bf6fa9bdcd8954e8fad30f32a6ed}"
            MONITOR_BIN="$LITE_BIN"
            ;;
        komari)
            MONITOR_VERSION="${MONITOR_VERSION:-${KOMARI_VERSION:-1.5.11}}"
            MONITOR_URL="${MONITOR_URL:-${KOMARI_URL:-https://github.com/komari-monitor/komari-agent/releases/download/${MONITOR_VERSION}/komari-agent-linux-amd64}}"
            MONITOR_SHA256="${MONITOR_SHA256:-${KOMARI_SHA256:-78c28d89e523816baea010c0ed0714f245f508ffdaca0540f5c9f230f7053c8c}}"
            MONITOR_BIN="$KOMARI_BIN"
            ;;
        *)
            die "MONITOR_TYPE must be lite or komari"
            ;;
    esac
fi

# ---------------- Helpers ----------------

download() {
    local url="$1"
    local out="$2"
    local tmp="${out}.tmp"

    rm -f "$tmp"
    log "Downloading: $url"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$tmp" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$tmp" "$url"
    else
        die "Neither curl nor wget is available"
    fi

    mv -f "$tmp" "$out"
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    [[ -n "$expected" ]] || return 0
    printf '%s  %s\n' "$expected" "$file" | sha256sum -c -
}

is_alive() {
    local pid="${1:-}"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

stop_pid() {
    local pid="${1:-}"
    [[ -z "$pid" ]] && return 0

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true

        for _ in 1 2 3 4 5; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done

        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

pid_rss() {
    local pid="${1:-}"
    if is_alive "$pid" && [[ -r "/proc/$pid/status" ]]; then
        grep '^VmRSS:' "/proc/$pid/status" 2>/dev/null | sed 's/^[[:space:]]*//' || true
    else
        printf 'N/A'
    fi
}

show_log_tail() {
    local file="$1"
    local lines="${2:-120}"

    [[ -f "$file" ]] || { printf 'No log file: %s\n' "$file"; return; }

    if command -v tail >/dev/null 2>&1; then
        tail -n "$lines" "$file"
    else
        cat "$file"
    fi
}

# ---------------- Install Mihomo ----------------

install_mihomo() {
    [[ -x "$MIHOMO_BIN" ]] && return 0

    command -v gzip >/dev/null 2>&1 || die "gzip is required but not available"

    local archive="$DATA_DIR/mihomo.gz"

    if ! download "$MIHOMO_URL" "$archive"; then
        warn "Primary Mihomo build download failed; trying compatible build"
        download "$MIHOMO_FALLBACK_URL" "$archive"
    fi

    gzip -dc "$archive" > "${MIHOMO_BIN}.tmp"
    chmod +x "${MIHOMO_BIN}.tmp"
    mv -f "${MIHOMO_BIN}.tmp" "$MIHOMO_BIN"
    rm -f "$archive"

    log "Mihomo installed: $("$MIHOMO_BIN" -v | sed -n '1p')"
}

# ---------------- Install Monitor ----------------

install_monitor() {
    [[ -x "$MONITOR_BIN" ]] && return 0

    download "$MONITOR_URL" "$MONITOR_BIN"
    verify_sha256 "$MONITOR_BIN" "$MONITOR_SHA256"
    chmod +x "$MONITOR_BIN"

    log "Monitor Agent installed ($MONITOR_TYPE $MONITOR_VERSION)"
}

if [[ "$MIHOMO_ENABLED" == "1" ]]; then
    install_mihomo
fi

if [[ "$MONITOR_ENABLED" == "1" ]]; then
    : "${MONITOR_ENDPOINT:?Set MONITOR_ENDPOINT in config.env}"
    : "${MONITOR_TOKEN:?Set MONITOR_TOKEN in config.env}"
    install_monitor
fi

# ---------------- Persistent credentials ----------------

generate_secrets() {
    [[ -f "$SECRETS_FILE" ]] && return 0

    log "Generating persistent VLESS/REALITY credentials"

    local uuid keys private_key public_key sid_seed short_id

    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        uuid="$(cat /proc/sys/kernel/random/uuid)"
    else
        uuid="$("$MIHOMO_BIN" generate uuid | sed -n '1p')"
    fi

    [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Failed to generate UUID"

    keys="$("$MIHOMO_BIN" generate reality-keypair)"
    private_key="$(printf '%s\n' "$keys" | sed -n 's/^PrivateKey:[[:space:]]*//p' | sed -n '1p')"
    public_key="$(printf '%s\n' "$keys" | sed -n 's/^PublicKey:[[:space:]]*//p' | sed -n '1p')"

    [[ -n "$private_key" ]] || die "Failed to parse Mihomo REALITY PrivateKey"
    [[ -n "$public_key" ]] || die "Failed to parse Mihomo REALITY PublicKey"

    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        sid_seed="$(cat /proc/sys/kernel/random/uuid)"
    else
        sid_seed="$("$MIHOMO_BIN" generate uuid | sed -n '1p')"
    fi
    sid_seed="${sid_seed//-/}"
    short_id="${sid_seed:0:16}"

    [[ "$short_id" =~ ^[0-9a-fA-F]{16}$ ]] || die "Failed to generate REALITY short-id"

    cat > "$SECRETS_FILE" <<EOF
VLESS_UUID='$uuid'
REALITY_PRIVATE_KEY='$private_key'
REALITY_PUBLIC_KEY='$public_key'
REALITY_SHORT_ID='$short_id'
EOF

    chmod 600 "$SECRETS_FILE"
}

if [[ "$MIHOMO_ENABLED" == "1" ]]; then
    generate_secrets
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
fi

# ---------------- Generate Mihomo config ----------------

generate_mihomo_config() {
    cat > "$MIHOMO_CONFIG" <<EOF
mode: rule
log-level: $MIHOMO_LOGLEVEL
allow-lan: true
bind-address: "*"

listeners:
  - name: aclclouds-vless
    type: vless
    port: $SERVER_PORT
    listen: 0.0.0.0
    users:
      - username: aclclouds
        uuid: "$VLESS_UUID"
        flow: "$VLESS_FLOW"
    reality-config:
      dest: "$REALITY_DEST"
      private-key: "$REALITY_PRIVATE_KEY"
      short-id:
        - "$REALITY_SHORT_ID"
      server-names:
        - "$REALITY_SNI"

rules:
  - MATCH,DIRECT
EOF

    if ! "$MIHOMO_BIN" -t -f "$MIHOMO_CONFIG" >"$LOG_DIR/mihomo-test.log" 2>&1; then
        cat "$LOG_DIR/mihomo-test.log" >&2 || true
        die "Mihomo config validation failed"
    fi
}

if [[ "$MIHOMO_ENABLED" == "1" ]]; then
    generate_mihomo_config
fi

# ---------------- Service management ----------------

MIHOMO_PID=""
MONITOR_PID=""

start_mihomo() {
    [[ "$MIHOMO_ENABLED" == "1" ]] || return 0

    printf '\n===== Mihomo start =====\n' >> "$MIHOMO_LOG"

    "$MIHOMO_BIN" -d "$MIHOMO_HOME" -f "$MIHOMO_CONFIG" >>"$MIHOMO_LOG" 2>&1 &
    MIHOMO_PID=$!

    sleep 1
    if ! is_alive "$MIHOMO_PID"; then
        printf '\n--- Mihomo startup log ---\n' >&2
        cat "$MIHOMO_LOG" >&2 || true
        die "Mihomo failed to start"
    fi

    log "Mihomo started (PID $MIHOMO_PID)"
}

restart_mihomo() {
    if [[ "$MIHOMO_ENABLED" != "1" ]]; then
        printf 'Mihomo is disabled in config.env\n'
        return
    fi

    log "Restarting Mihomo..."
    stop_pid "$MIHOMO_PID"
    MIHOMO_PID=""
    generate_mihomo_config
    start_mihomo
}

start_monitor() {
    [[ "$MONITOR_ENABLED" == "1" ]] || return 0

    printf '\n===== %s start =====\n' "$MONITOR_TYPE" >> "$MONITOR_LOG"

    if [[ "$MONITOR_TYPE" == "lite" ]]; then
        AGENT_ENDPOINT="$MONITOR_ENDPOINT" \
        AGENT_TOKEN="$MONITOR_TOKEN" \
        AGENT_DISABLE_AUTO_UPDATE=true \
        AGENT_REMOTE_CONTROL_ENABLED="$MONITOR_REMOTE_CONTROL" \
        "$MONITOR_BIN" >>"$MONITOR_LOG" 2>&1 &
    else
        local disable_web_ssh=true
        [[ "$MONITOR_REMOTE_CONTROL" == "true" ]] && disable_web_ssh=false

        AGENT_ENDPOINT="$MONITOR_ENDPOINT" \
        AGENT_TOKEN="$MONITOR_TOKEN" \
        AGENT_DISABLE_AUTO_UPDATE=true \
        AGENT_DISABLE_WEB_SSH="$disable_web_ssh" \
        "$MONITOR_BIN" >>"$MONITOR_LOG" 2>&1 &
    fi
    MONITOR_PID=$!

    sleep 1
    if ! is_alive "$MONITOR_PID"; then
        warn "Monitor Agent exited during startup"
        cat "$MONITOR_LOG" >&2 || true
        MONITOR_PID=""
        return 1
    fi

    log "Monitor started ($MONITOR_TYPE, PID $MONITOR_PID)"
}

restart_monitor() {
    if [[ "$MONITOR_ENABLED" != "1" ]]; then
        printf 'Monitor is disabled in config.env\n'
        return
    fi

    log "Restarting Monitor..."
    stop_pid "$MONITOR_PID"
    MONITOR_PID=""
    start_monitor || true
}

cleanup() {
    trap - EXIT TERM INT
    stop_pid "$MIHOMO_PID"
    stop_pid "$MONITOR_PID"
}
trap cleanup EXIT TERM INT

# ---------------- Display ----------------

vless_link() {
    printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp#%s\n' \
        "$VLESS_UUID" \
        "$SERVER_IP" \
        "$SERVER_PORT" \
        "$VLESS_FLOW" \
        "$REALITY_SNI" \
        "$CLIENT_FINGERPRINT" \
        "$REALITY_PUBLIC_KEY" \
        "$REALITY_SHORT_ID" \
        "$MIHOMO_REMARK"
}

show_link() {
    if [[ "$MIHOMO_ENABLED" != "1" ]]; then
        printf '\nMihomo is disabled in config.env; no proxy link is available.\n\n'
        return
    fi

    printf '\n'
    printf '%s\n' '================ VLESS + REALITY ================'
    vless_link
    printf '%s\n' '--------------------------------------------------'
    printf 'Core        : Mihomo %s\n' "$MIHOMO_VERSION"
    printf 'Address     : %s\n' "$SERVER_IP"
    printf 'Port        : %s\n' "$SERVER_PORT"
    printf 'UUID        : %s\n' "$VLESS_UUID"
    printf 'Flow        : %s\n' "$VLESS_FLOW"
    printf 'SNI         : %s\n' "$REALITY_SNI"
    printf 'Dest        : %s\n' "$REALITY_DEST"
    printf 'Fingerprint : %s\n' "$CLIENT_FINGERPRINT"
    printf 'PublicKey   : %s\n' "$REALITY_PUBLIC_KEY"
    printf 'ShortID     : %s\n' "$REALITY_SHORT_ID"
    printf '%s\n\n' '=================================================='
}

show_status() {
    printf '\n'

    if [[ "$MIHOMO_ENABLED" != "1" ]]; then
        printf 'Mihomo : DISABLED\n'
    elif is_alive "$MIHOMO_PID"; then
        printf 'Mihomo : RUNNING (PID %s, %s)\n' "$MIHOMO_PID" "$(pid_rss "$MIHOMO_PID")"
    else
        printf 'Mihomo : STOPPED\n'
    fi

    if [[ "$MONITOR_ENABLED" != "1" ]]; then
        printf 'Monitor : DISABLED\n'
    elif is_alive "$MONITOR_PID"; then
        printf 'Monitor : RUNNING (%s, PID %s, %s)\n' "$MONITOR_TYPE" "$MONITOR_PID" "$(pid_rss "$MONITOR_PID")"
    else
        printf 'Monitor : STOPPED (%s)\n' "$MONITOR_TYPE"
    fi

    if [[ "$MIHOMO_ENABLED" == "1" ]]; then
        printf 'Server : %s:%s\n' "$SERVER_IP" "$SERVER_PORT"
    fi

    if [[ -r /sys/fs/cgroup/memory.current && -r /sys/fs/cgroup/memory.max ]]; then
        printf 'cgroup : %s / %s bytes\n' \
            "$(cat /sys/fs/cgroup/memory.current)" \
            "$(cat /sys/fs/cgroup/memory.max)"
    fi

    printf '\n'
}

show_menu() {
    printf '%s\n' '=========================================='
    printf '%s\n' ' ACLClouds Mihomo + Monitor OneClick'
    printf '%s\n' '=========================================='
    printf '%s\n' '[1] 服务状态'
    printf '%s\n' '[2] 代理链接'
    printf '%s\n' '[3] Mihomo 日志（最近 120 行）'
    printf '%s\n' '[4] Monitor 日志（最近 120 行）'
    printf '%s\n' '[5] 重启 Mihomo'
    printf '%s\n' '[6] 重启 Monitor'
    printf '%s\n' '[0] 显示菜单'
    printf '%s\n' '------------------------------------------'
    printf '%s' '请输入数字: '
}

: > "$MIHOMO_LOG"
: > "$MONITOR_LOG"

start_mihomo
start_monitor || true

log "Startup completed"
show_status
if [[ "$MIHOMO_ENABLED" == "1" ]]; then
    show_link
fi
show_menu

while true; do
    if ! IFS= read -r choice; then
        sleep 2
        continue
    fi

    case "$choice" in
        1)
            show_status
            ;;
        2)
            show_link
            ;;
        3)
            printf '\n--- Mihomo log ---\n'
            show_log_tail "$MIHOMO_LOG" 120
            printf '\n'
            ;;
        4)
            printf '\n--- Monitor log ---\n'
            show_log_tail "$MONITOR_LOG" 120
            printf '\n'
            ;;
        5)
            restart_mihomo
            show_status
            ;;
        6)
            restart_monitor
            show_status
            ;;
        0)
            show_menu
            continue
            ;;
        *)
            printf '未知选项: %s\n' "$choice"
            ;;
    esac

    printf '%s' '请输入数字: '
done
