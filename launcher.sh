#!/usr/bin/env bash

# ACLCloudFreeBotToolKit
# Copyright (C) 2026 MessyMidi
#
# SPDX-License-Identifier: AGPL-3.0-only
# Additional terms under AGPLv3 Section 7:
# see /ADDITIONAL_TERMS.md

set -Eeuo pipefail
umask 077

LAUNCHER_VERSION='0.6.0-beta.1'

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$BASE_DIR/bin"
CONFIG_DIR="$BASE_DIR/config"
DATA_DIR="$BASE_DIR/data"
LOG_DIR="$BASE_DIR/logs"
MIHOMO_HOME="$DATA_DIR/mihomo-home"

MIHOMO_BIN="$BIN_DIR/mihomo"
KOMARI_BIN="$BIN_DIR/komari-agent"
LITE_BIN="$BIN_DIR/lite-agent"
CFSM_BIN="$BIN_DIR/cf-probe"
MIHOMO_CONFIG="$CONFIG_DIR/mihomo.yaml"
CFSM_CONFIG="$CONFIG_DIR/cfsm.conf"
SECRETS_FILE="$DATA_DIR/mihomo-secrets.env"
MIHOMO_LOG="$LOG_DIR/mihomo.log"
MONITOR_LOG="$LOG_DIR/monitor.log"
RENEW_LOG="$LOG_DIR/renew.log"
MIHOMO_INSTALL_STATE="$DATA_DIR/mihomo.install-state"

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

normalize_env_line_endings() {
    local env_file="$1"
    local temporary="${env_file}.line-endings.$$"
    local backup_dir="$DATA_DIR/bootstrap/config-backups"
    local backup_file line changed=0

    : > "$temporary"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *$'\r' ]]; then
            line="${line%$'\r'}"
            changed=1
        fi
        if [[ "$line" == *$'\r'* ]]; then
            rm -f "$temporary"
            die "config.env contains an embedded carriage return; remove control characters and try again"
        fi
        printf '%s\n' "$line" >> "$temporary"
    done < "$env_file"

    if [[ "$changed" -eq 0 ]]; then
        rm -f "$temporary"
        return 0
    fi

    mkdir -p "$backup_dir" || {
        rm -f "$temporary"
        die "Unable to create the config.env backup directory"
    }
    backup_file="$backup_dir/$(basename "$env_file").line-endings.$$.bak"
    cp "$env_file" "$backup_file" || {
        rm -f "$temporary"
        die "Unable to back up config.env before line-ending normalization"
    }
    chmod 600 "$backup_file" "$temporary" || {
        rm -f "$temporary"
        die "Unable to protect the config.env backup"
    }
    bash -n "$temporary" || {
        rm -f "$temporary"
        die "config.env is not valid Bash syntax after line-ending normalization"
    }
    mv -f "$temporary" "$env_file" || {
        rm -f "$temporary"
        die "Unable to atomically normalize config.env line endings"
    }
    log 'Configuration line endings normalized to LF'
}

normalize_env_line_endings "$ENV_FILE"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ---------------- Defaults ----------------

MIHOMO_ENABLED="${MIHOMO_ENABLED:-1}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.31}"
MIHOMO_URL="${MIHOMO_URL:-https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-amd64-v1-${MIHOMO_VERSION}.gz}"
MIHOMO_SHA256="${MIHOMO_SHA256:-d4304c546c3cddcb6fafd4b4fddb0ba1a95ffa36606fda56d75db2e59ad24114}"
MIHOMO_FALLBACK_URL="${MIHOMO_FALLBACK_URL:-https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-amd64-compatible-${MIHOMO_VERSION}.gz}"
MIHOMO_FALLBACK_SHA256="${MIHOMO_FALLBACK_SHA256:-04cf9f09671704f839ddbee2e93069dc831a4123a75281e725d1d96ab9ac1afc}"

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
AUTO_RENEW_ENABLED="${AUTO_RENEW_ENABLED:-0}"
WATCHDOG_MAX_RESTARTS="${WATCHDOG_MAX_RESTARTS:-5}"
WATCHDOG_BASE_DELAY_SECONDS="${WATCHDOG_BASE_DELAY_SECONDS:-1}"
WATCHDOG_STABLE_SECONDS="${WATCHDOG_STABLE_SECONDS:-300}"

case "${AUTO_RENEW_ENABLED,,}" in
    1|true|yes|on|enable|enabled) RENEW_ENABLED=1 ;;
    0|false|no|off|disable|disabled|'') RENEW_ENABLED=0 ;;
    *) die "AUTO_RENEW_ENABLED must be a boolean value" ;;
esac

[[ "$MIHOMO_ENABLED" == "0" || "$MIHOMO_ENABLED" == "1" ]] || die "MIHOMO_ENABLED must be 0 or 1"
[[ "$MONITOR_ENABLED" == "0" || "$MONITOR_ENABLED" == "1" ]] || die "MONITOR_ENABLED must be 0 or 1"
[[ "$WATCHDOG_MAX_RESTARTS" =~ ^[0-9]+$ ]] && (( WATCHDOG_MAX_RESTARTS >= 1 && WATCHDOG_MAX_RESTARTS <= 10 )) || die "WATCHDOG_MAX_RESTARTS must be between 1 and 10"
[[ "$WATCHDOG_BASE_DELAY_SECONDS" =~ ^[0-9]+$ ]] && (( WATCHDOG_BASE_DELAY_SECONDS <= 60 )) || die "WATCHDOG_BASE_DELAY_SECONDS must be between 0 and 60"
[[ "$WATCHDOG_STABLE_SECONDS" =~ ^[0-9]+$ ]] && (( WATCHDOG_STABLE_SECONDS >= 1 && WATCHDOG_STABLE_SECONDS <= 86400 )) || die "WATCHDOG_STABLE_SECONDS must be between 1 and 86400"
[[ "$MIHOMO_ENABLED" == "1" || "$MONITOR_ENABLED" == "1" || "$RENEW_ENABLED" == "1" ]] || \
    die "At least one of Mihomo, Monitor, or automatic renewal must be enabled"

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
        cfsm)
            MONITOR_ENDPOINT="${MONITOR_ENDPOINT:-${CFSM_URL:-}}"
            MONITOR_TOKEN="${MONITOR_TOKEN:-${CFSM_SECRET:-}}"
            MONITOR_AGENT_ID="${MONITOR_AGENT_ID:-${CFSM_ID:-}}"
            MONITOR_VERSION="${MONITOR_VERSION:-v1.0.18}"
            MONITOR_URL="${MONITOR_URL:-https://github.com/huilang-me/cfsm-agent/releases/download/${MONITOR_VERSION}/cf-probe-linux-amd64}"
            MONITOR_SHA256="${MONITOR_SHA256:-757a88084ce62e69379d0f9726b42291c06bfd51bdfdd58b45311d7a89ba5daa}"
            MONITOR_BIN="$CFSM_BIN"
            CFSM_COLLECT_INTERVAL="${CFSM_COLLECT_INTERVAL:-0}"
            CFSM_REPORT_INTERVAL="${CFSM_REPORT_INTERVAL:-60}"
            CFSM_CONNECTION_MODE="${CFSM_CONNECTION_MODE:-auto}"
            CFSM_PING_MODE="${CFSM_PING_MODE:-tcp}"
            CFSM_RESET_DAY="${CFSM_RESET_DAY:-1}"
            CFSM_DEBUG="${CFSM_DEBUG:-0}"
            CFSM_CT_NODE="${CFSM_CT_NODE:-}"
            CFSM_CU_NODE="${CFSM_CU_NODE:-}"
            CFSM_CM_NODE="${CFSM_CM_NODE:-}"
            CFSM_BD_NODE="${CFSM_BD_NODE:-}"
            CFSM_NODE_1="${CFSM_NODE_1:-}"
            CFSM_NODE_2="${CFSM_NODE_2:-}"
            CFSM_NODE_3="${CFSM_NODE_3:-}"
            CFSM_NODE_4="${CFSM_NODE_4:-}"
            CFSM_INTERFACE="${CFSM_INTERFACE:-}"

            : "${MONITOR_AGENT_ID:?Set MONITOR_AGENT_ID in config.env}"
            [[ "$CFSM_COLLECT_INTERVAL" =~ ^[0-9]+$ ]] || die "CFSM_COLLECT_INTERVAL must be an integer"
            [[ "$CFSM_REPORT_INTERVAL" =~ ^[0-9]+$ ]] || die "CFSM_REPORT_INTERVAL must be an integer"
            [[ "$CFSM_RESET_DAY" =~ ^[0-9]+$ ]] || die "CFSM_RESET_DAY must be an integer"
            (( CFSM_REPORT_INTERVAL >= 1 )) || die "CFSM_REPORT_INTERVAL must be at least 1"
            (( CFSM_RESET_DAY <= 31 )) || die "CFSM_RESET_DAY must be between 0 and 31"
            [[ "$CFSM_CONNECTION_MODE" == "auto" || "$CFSM_CONNECTION_MODE" == "http" ]] || die "CFSM_CONNECTION_MODE must be auto or http"
            [[ "$CFSM_PING_MODE" == "tcp" || "$CFSM_PING_MODE" == "icmp" ]] || die "CFSM_PING_MODE must be tcp or icmp"
            [[ "$CFSM_DEBUG" == "0" || "$CFSM_DEBUG" == "1" ]] || die "CFSM_DEBUG must be 0 or 1"
            ;;
        *)
            die "MONITOR_TYPE must be lite, komari, or cfsm"
            ;;
    esac
    MONITOR_INSTALL_STATE="$DATA_DIR/monitor-${MONITOR_TYPE}.install-state"
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

file_sha256() {
    sha256sum "$1" | awk '{print $1}'
}

install_spec_sha256() {
    printf '%s\0' "$@" | sha256sum | awk '{print $1}'
}

install_state_value() {
    local state_file="$1"
    local key="$2"
    sed -n "s/^${key}=//p" "$state_file" 2>/dev/null | sed -n '1p'
}

write_install_state() {
    local state_file="$1"
    local spec_sha256="$2"
    local binary="$3"
    local temporary="${state_file}.tmp.$$"

    {
        printf 'SPEC_SHA256=%s\n' "$spec_sha256"
        printf 'BINARY_SHA256=%s\n' "$(file_sha256 "$binary")"
    } > "$temporary"
    chmod 600 "$temporary"
    mv -f "$temporary" "$state_file"
}

install_state_matches() {
    local state_file="$1"
    local spec_sha256="$2"
    local binary="$3"
    local expected_binary actual_binary

    [[ -x "$binary" && -f "$state_file" ]] || return 1
    [[ "$(install_state_value "$state_file" SPEC_SHA256)" == "$spec_sha256" ]] || return 1
    expected_binary="$(install_state_value "$state_file" BINARY_SHA256)"
    [[ -n "$expected_binary" ]] || return 1
    actual_binary="$(file_sha256 "$binary")"
    [[ "$actual_binary" == "$expected_binary" ]]
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
    command -v gzip >/dev/null 2>&1 || die "gzip is required but not available"

    local archive="$DATA_DIR/mihomo.gz.$$"
    local candidate="${MIHOMO_BIN}.candidate.$$"
    local spec_sha256 version_line
    local had_existing=0
    spec_sha256="$(install_spec_sha256 mihomo "$MIHOMO_VERSION" "$MIHOMO_URL" "$MIHOMO_SHA256" "$MIHOMO_FALLBACK_URL" "$MIHOMO_FALLBACK_SHA256")"

    if install_state_matches "$MIHOMO_INSTALL_STATE" "$spec_sha256" "$MIHOMO_BIN"; then
        return 0
    fi

    if [[ -x "$MIHOMO_BIN" ]]; then
        had_existing=1
        if [[ ! -f "$MIHOMO_INSTALL_STATE" ]]; then
            version_line="$("$MIHOMO_BIN" -v 2>/dev/null | sed -n '1p' || true)"
            if [[ "$version_line" == *"$MIHOMO_VERSION"* ]]; then
                write_install_state "$MIHOMO_INSTALL_STATE" "$spec_sha256" "$MIHOMO_BIN"
                log "Existing Mihomo matches $MIHOMO_VERSION; install state recorded"
                return 0
            fi
        fi
        log "Mihomo install metadata changed; downloading $MIHOMO_VERSION"
    fi

    if ! download "$MIHOMO_URL" "$archive" || ! verify_sha256 "$archive" "$MIHOMO_SHA256"; then
        rm -f "$archive"
        warn "Primary Mihomo build download or checksum failed; trying compatible build"
        if ! download "$MIHOMO_FALLBACK_URL" "$archive" || ! verify_sha256 "$archive" "$MIHOMO_FALLBACK_SHA256"; then
            rm -f "$archive" "$candidate"
            if [[ "$had_existing" -eq 1 ]]; then
                warn "Mihomo update failed; continuing with the existing binary and retrying next launch"
                return 0
            fi
            die "Unable to download and verify Mihomo"
        fi
    fi

    if ! gzip -dc "$archive" > "$candidate"; then
        rm -f "$archive" "$candidate"
        if [[ "$had_existing" -eq 1 ]]; then
            warn "Mihomo archive extraction failed; continuing with the existing binary"
            return 0
        fi
        die "Mihomo archive extraction failed"
    fi
    rm -f "$archive"
    chmod +x "$candidate"
    if ! "$candidate" -v >/dev/null 2>&1; then
        rm -f "$candidate"
        if [[ "$had_existing" -eq 1 ]]; then
            warn "Downloaded Mihomo failed its smoke test; continuing with the existing binary"
            return 0
        fi
        die "Downloaded Mihomo failed its smoke test"
    fi
    mv -f "$candidate" "$MIHOMO_BIN"
    write_install_state "$MIHOMO_INSTALL_STATE" "$spec_sha256" "$MIHOMO_BIN"

    log "Mihomo installed: $("$MIHOMO_BIN" -v | sed -n '1p')"
}

# ---------------- Install Monitor ----------------

install_monitor() {
    local candidate="${MONITOR_BIN}.candidate.$$"
    local spec_sha256 actual_sha256
    local had_existing=0
    spec_sha256="$(install_spec_sha256 monitor "$MONITOR_TYPE" "$MONITOR_VERSION" "$MONITOR_URL" "$MONITOR_SHA256")"

    if install_state_matches "$MONITOR_INSTALL_STATE" "$spec_sha256" "$MONITOR_BIN"; then
        return 0
    fi

    if [[ -x "$MONITOR_BIN" ]]; then
        had_existing=1
        if [[ ! -f "$MONITOR_INSTALL_STATE" ]]; then
            actual_sha256="$(file_sha256 "$MONITOR_BIN")"
            if [[ -z "$MONITOR_SHA256" || "$actual_sha256" == "$MONITOR_SHA256" ]]; then
                write_install_state "$MONITOR_INSTALL_STATE" "$spec_sha256" "$MONITOR_BIN"
                log "Existing Monitor Agent matches $MONITOR_TYPE $MONITOR_VERSION; install state recorded"
                return 0
            fi
        fi
        log "Monitor install metadata changed; downloading $MONITOR_TYPE $MONITOR_VERSION"
    fi

    if ! download "$MONITOR_URL" "$candidate" || ! verify_sha256 "$candidate" "$MONITOR_SHA256"; then
        rm -f "$candidate"
        if [[ "$had_existing" -eq 1 ]]; then
            warn "Monitor update failed; continuing with the existing binary and retrying next launch"
            return 0
        fi
        die "Unable to download and verify Monitor Agent"
    fi
    [[ -s "$candidate" ]] || die "Downloaded Monitor Agent is empty"
    chmod +x "$candidate"
    mv -f "$candidate" "$MONITOR_BIN"
    write_install_state "$MONITOR_INSTALL_STATE" "$spec_sha256" "$MONITOR_BIN"

    log "Monitor Agent installed ($MONITOR_TYPE $MONITOR_VERSION)"
}

generate_cfsm_config() {
    [[ "$MONITOR_ENABLED" == "1" && "$MONITOR_TYPE" == "cfsm" ]] || return 0

    local temporary="${CFSM_CONFIG}.tmp.$$"
    {
        printf 'SERVER_ID=%s\n' "$MONITOR_AGENT_ID"
        printf 'SECRET=%s\n' "$MONITOR_TOKEN"
        printf 'WORKER_URL=%s\n' "$MONITOR_ENDPOINT"
        printf 'COLLECT_INTERVAL=%s\n' "$CFSM_COLLECT_INTERVAL"
        printf 'REPORT_INTERVAL=%s\n' "$CFSM_REPORT_INTERVAL"
        printf 'CT_NODE=%s\n' "$CFSM_CT_NODE"
        printf 'CU_NODE=%s\n' "$CFSM_CU_NODE"
        printf 'CM_NODE=%s\n' "$CFSM_CM_NODE"
        printf 'BD_NODE=%s\n' "$CFSM_BD_NODE"
        printf 'NODE_1=%s\n' "$CFSM_NODE_1"
        printf 'NODE_2=%s\n' "$CFSM_NODE_2"
        printf 'NODE_3=%s\n' "$CFSM_NODE_3"
        printf 'NODE_4=%s\n' "$CFSM_NODE_4"
        printf 'INTERFACE=%s\n' "$CFSM_INTERFACE"
        printf 'RESET_DAY=%s\n' "$CFSM_RESET_DAY"
        printf 'CONNECTION_MODE=%s\n' "$CFSM_CONNECTION_MODE"
        printf 'PING_MODE=%s\n' "$CFSM_PING_MODE"
        printf 'AUTO_UPDATE=0\n'
        printf 'UPDATE_PROXY=\n'
        printf 'CONFIG_MD5=none\n'
    } > "$temporary"
    chmod 600 "$temporary"
    mv -f "$temporary" "$CFSM_CONFIG"
}

if [[ "$MIHOMO_ENABLED" == "1" ]]; then
    install_mihomo
fi

if [[ "$MONITOR_ENABLED" == "1" ]]; then
    : "${MONITOR_ENDPOINT:?Set MONITOR_ENDPOINT in config.env}"
    : "${MONITOR_TOKEN:?Set MONITOR_TOKEN in config.env}"
    install_monitor
    generate_cfsm_config
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
MIHOMO_WATCHDOG_RESTARTS=0
MONITOR_WATCHDOG_RESTARTS=0
MIHOMO_WATCHDOG_NEXT_AT=""
MONITOR_WATCHDOG_NEXT_AT=""
MIHOMO_WATCHDOG_GAVE_UP=0
MONITOR_WATCHDOG_GAVE_UP=0
MIHOMO_STARTED_AT=0
MONITOR_STARTED_AT=0

signal_pterodactyl_ready() {
    # ACLClouds uses the Parkervcp/Pelican "golang generic" Egg. Its
    # startup.done value is the exact text below; Wings remains in STARTING
    # until this line appears in Console output.
    printf '%s\n' 'change this part'
}

signal_bootstrap_ready() {
    local ready_file="${LAUNCHER_READY_FILE:-}"
    local generation="${LAUNCHER_GENERATION:-}"
    local temporary

    [[ -n "$ready_file" && -n "$generation" ]] || return 0
    temporary="${ready_file}.tmp.$$"
    printf '%s\n' "$generation" > "$temporary"
    chmod 600 "$temporary"
    mv -f "$temporary" "$ready_file"
}

start_mihomo() {
    [[ "$MIHOMO_ENABLED" == "1" ]] || return 0

    printf '\n===== Mihomo start =====\n' >> "$MIHOMO_LOG"

    "$MIHOMO_BIN" -d "$MIHOMO_HOME" -f "$MIHOMO_CONFIG" >>"$MIHOMO_LOG" 2>&1 &
    MIHOMO_PID=$!

    sleep 1
    if ! is_alive "$MIHOMO_PID"; then
        printf '\n--- Mihomo startup log ---\n' >&2
        cat "$MIHOMO_LOG" >&2 || true
        warn "Mihomo failed to start"
        wait "$MIHOMO_PID" 2>/dev/null || true
        MIHOMO_PID=""
        return 1
    fi

    MIHOMO_STARTED_AT=$SECONDS
    log "Mihomo started (PID $MIHOMO_PID)"
}

reset_mihomo_watchdog() {
    MIHOMO_WATCHDOG_RESTARTS=0
    MIHOMO_WATCHDOG_NEXT_AT=""
    MIHOMO_WATCHDOG_GAVE_UP=0
}

restart_mihomo() {
    if [[ "$MIHOMO_ENABLED" != "1" ]]; then
        printf 'Mihomo is disabled in config.env\n'
        return
    fi

    log "Restarting Mihomo..."
    stop_pid "$MIHOMO_PID"
    MIHOMO_PID=""
    reset_mihomo_watchdog
    generate_mihomo_config
    start_mihomo || warn "Mihomo manual restart failed; watchdog will retry"
}

start_monitor() {
    [[ "$MONITOR_ENABLED" == "1" ]] || return 0

    printf '\n===== %s start =====\n' "$MONITOR_TYPE" >> "$MONITOR_LOG"

    case "$MONITOR_TYPE" in
        lite)
            AGENT_ENDPOINT="$MONITOR_ENDPOINT" \
            AGENT_TOKEN="$MONITOR_TOKEN" \
            AGENT_DISABLE_AUTO_UPDATE=true \
            AGENT_REMOTE_CONTROL_ENABLED="$MONITOR_REMOTE_CONTROL" \
            "$MONITOR_BIN" >>"$MONITOR_LOG" 2>&1 &
            ;;
        komari)
            local disable_web_ssh=true
            [[ "$MONITOR_REMOTE_CONTROL" == "true" ]] && disable_web_ssh=false

            AGENT_ENDPOINT="$MONITOR_ENDPOINT" \
            AGENT_TOKEN="$MONITOR_TOKEN" \
            AGENT_DISABLE_AUTO_UPDATE=true \
            AGENT_DISABLE_WEB_SSH="$disable_web_ssh" \
            "$MONITOR_BIN" >>"$MONITOR_LOG" 2>&1 &
            ;;
        cfsm)
            generate_cfsm_config
            "$MONITOR_BIN" run -config="$CFSM_CONFIG" -debug="$CFSM_DEBUG" >>"$MONITOR_LOG" 2>&1 &
            ;;
    esac
    MONITOR_PID=$!

    sleep 1
    if ! is_alive "$MONITOR_PID"; then
        warn "Monitor Agent exited during startup"
        cat "$MONITOR_LOG" >&2 || true
        MONITOR_PID=""
        return 1
    fi

    MONITOR_STARTED_AT=$SECONDS
    log "Monitor started ($MONITOR_TYPE, PID $MONITOR_PID)"
}

reset_monitor_watchdog() {
    MONITOR_WATCHDOG_RESTARTS=0
    MONITOR_WATCHDOG_NEXT_AT=""
    MONITOR_WATCHDOG_GAVE_UP=0
}

restart_monitor() {
    if [[ "$MONITOR_ENABLED" != "1" ]]; then
        printf 'Monitor is disabled in config.env\n'
        return
    fi

    log "Restarting Monitor..."
    stop_pid "$MONITOR_PID"
    MONITOR_PID=""
    reset_monitor_watchdog
    start_monitor || true
}

watchdog_delay() {
    local attempt="$1"
    local delay="$WATCHDOG_BASE_DELAY_SECONDS"
    local index
    for ((index = 1; index < attempt; index += 1)); do
        delay=$((delay * 2))
    done
    printf '%s' "$delay"
}

supervise_mihomo() {
    [[ "$MIHOMO_ENABLED" == "1" ]] || return 0

    if is_alive "$MIHOMO_PID"; then
        if (( MIHOMO_WATCHDOG_RESTARTS > 0 && SECONDS - MIHOMO_STARTED_AT >= WATCHDOG_STABLE_SECONDS )); then
            log "Mihomo remained stable for ${WATCHDOG_STABLE_SECONDS}s; watchdog counter reset"
            reset_mihomo_watchdog
        fi
        return 0
    fi

    if [[ -n "$MIHOMO_PID" ]]; then
        local exit_status=0
        wait "$MIHOMO_PID" 2>/dev/null || exit_status=$?
        warn "Mihomo exited unexpectedly (status $exit_status)"
        MIHOMO_PID=""
    fi
    [[ "$MIHOMO_WATCHDOG_GAVE_UP" -eq 0 ]] || return 0

    if [[ -z "$MIHOMO_WATCHDOG_NEXT_AT" ]]; then
        if (( MIHOMO_WATCHDOG_RESTARTS >= WATCHDOG_MAX_RESTARTS )); then
            MIHOMO_WATCHDOG_GAVE_UP=1
            warn "Mihomo watchdog stopped after ${WATCHDOG_MAX_RESTARTS} restart attempts; use Console option 5 to retry manually"
            return 0
        fi
        MIHOMO_WATCHDOG_RESTARTS=$((MIHOMO_WATCHDOG_RESTARTS + 1))
        local delay
        delay="$(watchdog_delay "$MIHOMO_WATCHDOG_RESTARTS")"
        MIHOMO_WATCHDOG_NEXT_AT=$((SECONDS + delay))
        warn "Mihomo crashed; watchdog restart ${MIHOMO_WATCHDOG_RESTARTS}/${WATCHDOG_MAX_RESTARTS} scheduled in ${delay}s"
    fi

    if (( SECONDS >= MIHOMO_WATCHDOG_NEXT_AT )); then
        MIHOMO_WATCHDOG_NEXT_AT=""
        log "Watchdog restarting Mihomo (${MIHOMO_WATCHDOG_RESTARTS}/${WATCHDOG_MAX_RESTARTS})"
        start_mihomo || true
    fi
}

supervise_monitor() {
    [[ "$MONITOR_ENABLED" == "1" ]] || return 0

    if is_alive "$MONITOR_PID"; then
        if (( MONITOR_WATCHDOG_RESTARTS > 0 && SECONDS - MONITOR_STARTED_AT >= WATCHDOG_STABLE_SECONDS )); then
            log "Monitor remained stable for ${WATCHDOG_STABLE_SECONDS}s; watchdog counter reset"
            reset_monitor_watchdog
        fi
        return 0
    fi

    if [[ -n "$MONITOR_PID" ]]; then
        local exit_status=0
        wait "$MONITOR_PID" 2>/dev/null || exit_status=$?
        warn "Monitor exited unexpectedly (status $exit_status)"
        MONITOR_PID=""
    fi
    [[ "$MONITOR_WATCHDOG_GAVE_UP" -eq 0 ]] || return 0

    if [[ -z "$MONITOR_WATCHDOG_NEXT_AT" ]]; then
        if (( MONITOR_WATCHDOG_RESTARTS >= WATCHDOG_MAX_RESTARTS )); then
            MONITOR_WATCHDOG_GAVE_UP=1
            warn "Monitor watchdog stopped after ${WATCHDOG_MAX_RESTARTS} restart attempts; use Console option 6 to retry manually"
            return 0
        fi
        MONITOR_WATCHDOG_RESTARTS=$((MONITOR_WATCHDOG_RESTARTS + 1))
        local delay
        delay="$(watchdog_delay "$MONITOR_WATCHDOG_RESTARTS")"
        MONITOR_WATCHDOG_NEXT_AT=$((SECONDS + delay))
        warn "Monitor crashed; watchdog restart ${MONITOR_WATCHDOG_RESTARTS}/${WATCHDOG_MAX_RESTARTS} scheduled in ${delay}s"
    fi

    if (( SECONDS >= MONITOR_WATCHDOG_NEXT_AT )); then
        MONITOR_WATCHDOG_NEXT_AT=""
        log "Watchdog restarting Monitor (${MONITOR_WATCHDOG_RESTARTS}/${WATCHDOG_MAX_RESTARTS})"
        start_monitor || true
    fi
}

supervise_services() {
    supervise_mihomo
    supervise_monitor
}

cleanup() {
    trap - EXIT
    stop_pid "$MIHOMO_PID"
    stop_pid "$MONITOR_PID"
}

shutdown() {
    trap - TERM INT
    cleanup
    exit 0
}

trap cleanup EXIT
trap shutdown TERM INT

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
    elif [[ "$MIHOMO_WATCHDOG_GAVE_UP" -eq 1 ]]; then
        printf 'Mihomo : STOPPED (watchdog gave up after %s attempts)\n' "$WATCHDOG_MAX_RESTARTS"
    else
        printf 'Mihomo : STOPPED\n'
    fi

    if [[ "$MONITOR_ENABLED" != "1" ]]; then
        printf 'Monitor : DISABLED\n'
    elif is_alive "$MONITOR_PID"; then
        printf 'Monitor : RUNNING (%s, PID %s, %s)\n' "$MONITOR_TYPE" "$MONITOR_PID" "$(pid_rss "$MONITOR_PID")"
    elif [[ "$MONITOR_WATCHDOG_GAVE_UP" -eq 1 ]]; then
        printf 'Monitor : STOPPED (%s, watchdog gave up after %s attempts)\n' "$MONITOR_TYPE" "$WATCHDOG_MAX_RESTARTS"
    else
        printf 'Monitor : STOPPED (%s)\n' "$MONITOR_TYPE"
    fi

    if [[ "$MIHOMO_ENABLED" == "1" ]]; then
        printf 'Server : %s:%s\n' "$SERVER_IP" "$SERVER_PORT"
    fi

    if [[ "$RENEW_ENABLED" == "1" ]]; then
        printf 'Renewal : ENABLED (managed by bootstrap)\n'
    else
        printf 'Renewal : DISABLED\n'
    fi

    if [[ -r /sys/fs/cgroup/memory.current && -r /sys/fs/cgroup/memory.max ]]; then
        printf 'cgroup : %s / %s bytes\n' \
            "$(cat /sys/fs/cgroup/memory.current)" \
            "$(cat /sys/fs/cgroup/memory.max)"
    fi

    printf '\n'
}

show_renew_log() {
    if [[ "$RENEW_ENABLED" != "1" ]]; then
        printf '\nAutomatic renewal is disabled in config.env.\n\n'
        return
    fi
    printf '\n--- Automatic renewal log ---\n'
    if [[ -s "$RENEW_LOG" ]]; then
        show_log_tail "$RENEW_LOG" 120
    else
        printf 'No renewal check result is available yet.\n'
    fi
    printf '\n'
}

show_menu() {
    printf '%s\n' '=========================================='
    printf '%s\n' ' ACLClouds Bot Toolkit'
    printf '%s\n' '=========================================='
    printf '%s\n' '[1] 服务状态'
    printf '%s\n' '[2] 代理链接'
    printf '%s\n' '[3] Mihomo 日志（最近 120 行）'
    printf '%s\n' '[4] Monitor 日志（最近 120 行）'
    printf '%s\n' '[5] 重启 Mihomo'
    printf '%s\n' '[6] 重启 Monitor'
    printf '%s\n' '[7] 自动延期日志（最近 120 行）'
    printf '%s\n' '[0] 显示菜单'
    printf '%s\n' '------------------------------------------'
    printf '%s' '请输入数字: '
}

: > "$MIHOMO_LOG"
: > "$MONITOR_LOG"

if ! start_mihomo; then
    die "Mihomo failed during initial startup"
fi
start_monitor || true

log "Startup completed"
signal_pterodactyl_ready
signal_bootstrap_ready
show_status
if [[ "$MIHOMO_ENABLED" == "1" ]]; then
    show_link
fi
show_menu

while true; do
    supervise_services
    read_status=0
    IFS= read -r -t 1 choice || read_status=$?
    if (( read_status != 0 )); then
        # Closed stdin returns immediately, unlike a timeout. Avoid a busy loop
        # while still checking children frequently enough for the watchdog.
        if (( read_status == 1 )); then
            sleep 1
        fi
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
        7)
            show_renew_log
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
