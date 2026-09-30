#!/usr/bin/env bash

# ACLCloudFreeBotToolKit
# Copyright (C) 2026 MessyMidi
#
# SPDX-License-Identifier: AGPL-3.0-only
# Additional terms under AGPLv3 Section 7:
# see /ADDITIONAL_TERMS.md

set -Eeuo pipefail
umask 077

LAUNCHER_VERSION='0.7.0'

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

# Settings stay exported for compatibility with configurations that pass extra
# variables to the agents, but credentials must never reach Mihomo or a
# monitor agent through their environment. The agent token is handed to the
# agent explicitly when it starts.
export -n ACL_USERNAME ACL_EMAIL ACL_PASSWORD TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID \
    MONITOR_TOKEN KOMARI_TOKEN CFSM_SECRET

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
MIHOMO_BLOCK_PRIVATE_NETWORKS="${MIHOMO_BLOCK_PRIVATE_NETWORKS:-1}"
WATCHDOG_MAX_RESTARTS="${WATCHDOG_MAX_RESTARTS:-5}"
WATCHDOG_BASE_DELAY_SECONDS="${WATCHDOG_BASE_DELAY_SECONDS:-1}"
WATCHDOG_STABLE_SECONDS="${WATCHDOG_STABLE_SECONDS:-300}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-5242880}"
CONSOLE_LANG="${CONSOLE_LANG:-zh}"

case "${AUTO_RENEW_ENABLED,,}" in
    1|true|yes|on|enable|enabled) RENEW_ENABLED=1 ;;
    0|false|no|off|disable|disabled|'') RENEW_ENABLED=0 ;;
    *) die "AUTO_RENEW_ENABLED must be a boolean value" ;;
esac

case "${CONSOLE_LANG,,}" in
    zh|zh-cn|zh_cn) CONSOLE_LANG='zh' ;;
    en|en-us|en_us) CONSOLE_LANG='en' ;;
    *)
        warn "CONSOLE_LANG must be zh or en; using zh"
        CONSOLE_LANG='zh'
        ;;
esac

valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# host:port with a DNS name or IPv4 address, or [address]:port for IPv6.
# Accepts at least everything the Web generator accepts.
valid_destination() {
    local name_pattern='^[A-Za-z0-9._-]+:([0-9]{1,5})$'
    local ipv6_pattern='^\[[0-9A-Fa-f:.]+\]:([0-9]{1,5})$'
    [[ "$1" =~ $name_pattern || "$1" =~ $ipv6_pattern ]] && valid_port "${BASH_REMATCH[1]}"
}

[[ "$MIHOMO_ENABLED" == "0" || "$MIHOMO_ENABLED" == "1" ]] || die "MIHOMO_ENABLED must be 0 or 1"
[[ "$MONITOR_ENABLED" == "0" || "$MONITOR_ENABLED" == "1" ]] || die "MONITOR_ENABLED must be 0 or 1"
[[ "$MIHOMO_BLOCK_PRIVATE_NETWORKS" == "0" || "$MIHOMO_BLOCK_PRIVATE_NETWORKS" == "1" ]] || die "MIHOMO_BLOCK_PRIVATE_NETWORKS must be 0 or 1"
[[ "$WATCHDOG_MAX_RESTARTS" =~ ^[0-9]+$ ]] && (( WATCHDOG_MAX_RESTARTS >= 1 && WATCHDOG_MAX_RESTARTS <= 10 )) || die "WATCHDOG_MAX_RESTARTS must be between 1 and 10"
[[ "$WATCHDOG_BASE_DELAY_SECONDS" =~ ^[0-9]+$ ]] && (( WATCHDOG_BASE_DELAY_SECONDS <= 60 )) || die "WATCHDOG_BASE_DELAY_SECONDS must be between 0 and 60"
[[ "$WATCHDOG_STABLE_SECONDS" =~ ^[0-9]+$ ]] && (( WATCHDOG_STABLE_SECONDS >= 1 && WATCHDOG_STABLE_SECONDS <= 86400 )) || die "WATCHDOG_STABLE_SECONDS must be between 1 and 86400"
[[ "$LOG_MAX_BYTES" =~ ^[0-9]+$ ]] && (( LOG_MAX_BYTES >= 1024 )) || die "LOG_MAX_BYTES must be at least 1024"
[[ "$MIHOMO_ENABLED" == "1" || "$MONITOR_ENABLED" == "1" || "$RENEW_ENABLED" == "1" ]] || \
    die "At least one of Mihomo, Monitor, or automatic renewal must be enabled"

if [[ "$MIHOMO_ENABLED" == "1" ]]; then
    : "${SERVER_IP:?ACLClouds did not provide SERVER_IP}"
    : "${SERVER_PORT:?ACLClouds did not provide SERVER_PORT}"
    valid_port "$SERVER_PORT" || die "SERVER_PORT is not a valid port: $SERVER_PORT"
    [[ "$REALITY_SNI" =~ ^[A-Za-z0-9._-]+$ ]] || die "REALITY_SNI contains unsupported characters"
    valid_destination "$REALITY_DEST" || die "REALITY_DEST must be host:port, or [address]:port for IPv6"
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
        # A transfer slower than 4 KiB/s for a whole minute is treated as
        # stalled instead of hanging the launcher indefinitely.
        if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 \
            --speed-limit 4096 --speed-time 60 --max-time 900 -o "$tmp" "$url"; then
            rm -f "$tmp"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget --timeout=60 --tries=3 -O "$tmp" "$url"; then
            rm -f "$tmp"
            return 1
        fi
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

# Services keep their log open in append mode for as long as they run, so an
# oversized log is rewritten in place, keeping only its newest part. Lines
# written while the copy is made may be lost.
trim_log() {
    local file="$1"
    local size temporary

    [[ -f "$file" ]] || return 0
    size="$(wc -c < "$file")"
    (( size > LOG_MAX_BYTES )) || return 0
    temporary="${file}.trim.$$"
    if tail -c "$((LOG_MAX_BYTES / 5))" "$file" > "$temporary"; then
        {
            printf '[launcher] --- older lines removed; the log exceeded %s bytes ---\n' "$LOG_MAX_BYTES"
            cat "$temporary"
        } > "$file"
    fi
    rm -f "$temporary"
}

NEXT_LOG_TRIM_AT=0

maintain_logs() {
    (( SECONDS >= NEXT_LOG_TRIM_AT )) || return 0
    NEXT_LOG_TRIM_AT=$((SECONDS + 10))
    trim_log "$MIHOMO_LOG"
    trim_log "$MONITOR_LOG"
}

# Bootstrap waits for the ready file to contain LAUNCHER_GENERATION. While
# runtime files are downloading it contains "installing <generation>", which
# bootstrap measures against a separate, longer timeout.
write_bootstrap_signal() {
    local ready_file="${LAUNCHER_READY_FILE:-}"
    local temporary

    [[ -n "$ready_file" && -n "${LAUNCHER_GENERATION:-}" ]] || return 0
    temporary="${ready_file}.tmp.$$"
    printf '%s\n' "$1" > "$temporary"
    chmod 600 "$temporary"
    mv -f "$temporary" "$ready_file"
}

signal_bootstrap_installing() {
    write_bootstrap_signal "installing ${LAUNCHER_GENERATION:-}"
}

signal_bootstrap_installed() {
    [[ -n "${LAUNCHER_READY_FILE:-}" ]] || return 0
    rm -f "$LAUNCHER_READY_FILE"
}

signal_bootstrap_ready() {
    write_bootstrap_signal "${LAUNCHER_GENERATION:-}"
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

signal_bootstrap_installing

if [[ "$MIHOMO_ENABLED" == "1" ]]; then
    install_mihomo
fi

if [[ "$MONITOR_ENABLED" == "1" ]]; then
    : "${MONITOR_ENDPOINT:?Set MONITOR_ENDPOINT in config.env}"
    : "${MONITOR_TOKEN:?Set MONITOR_TOKEN in config.env}"
    install_monitor
    generate_cfsm_config
fi

signal_bootstrap_installed

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
    local cidr

    {
        cat <<EOF
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
EOF
        if [[ "$MIHOMO_BLOCK_PRIVATE_NETWORKS" == "1" ]]; then
            # Proxy users must not reach the host's private networks, loopback
            # services, or cloud metadata endpoints through this node. Domains
            # are resolved first, so names pointing at such addresses are
            # rejected as well.
            for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16; do
                printf '  - IP-CIDR,%s,REJECT\n' "$cidr"
            done
            for cidr in ::1/128 fc00::/7 fe80::/10; do
                printf '  - IP-CIDR6,%s,REJECT\n' "$cidr"
            done
        fi
        printf '  - MATCH,DIRECT\n'
    } > "$MIHOMO_CONFIG"

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
# Watchdog state per service, keyed by MIHOMO or MONITOR.
declare -A STARTED_AT=([MIHOMO]=0 [MONITOR]=0)
declare -A WATCHDOG_RESTARTS=([MIHOMO]=0 [MONITOR]=0)
declare -A WATCHDOG_NEXT_AT=([MIHOMO]='' [MONITOR]='')
declare -A WATCHDOG_GAVE_UP=([MIHOMO]=0 [MONITOR]=0)

signal_pterodactyl_ready() {
    # ACLClouds uses the Parkervcp/Pelican "golang generic" Egg. Its
    # startup.done value is the exact text below; Wings remains in STARTING
    # until this line appears in Console output.
    printf '%s\n' 'change this part'
}

start_mihomo() {
    [[ "$MIHOMO_ENABLED" == "1" ]] || return 0

    printf '\n===== Mihomo start =====\n' >> "$MIHOMO_LOG"

    "$MIHOMO_BIN" -d "$MIHOMO_HOME" -f "$MIHOMO_CONFIG" >>"$MIHOMO_LOG" 2>&1 &
    MIHOMO_PID=$!

    sleep 1
    if ! is_alive "$MIHOMO_PID"; then
        printf '\n--- Mihomo startup log ---\n' >&2
        show_log_tail "$MIHOMO_LOG" 40 >&2 || true
        warn "Mihomo failed to start"
        wait "$MIHOMO_PID" 2>/dev/null || true
        MIHOMO_PID=""
        return 1
    fi

    STARTED_AT[MIHOMO]=$SECONDS
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
    reset_watchdog MIHOMO
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
        show_log_tail "$MONITOR_LOG" 40 >&2 || true
        MONITOR_PID=""
        return 1
    fi

    STARTED_AT[MONITOR]=$SECONDS
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
    reset_watchdog MONITOR
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

reset_watchdog() {
    local service="$1"
    WATCHDOG_RESTARTS[$service]=0
    WATCHDOG_NEXT_AT[$service]=''
    WATCHDOG_GAVE_UP[$service]=0
}

# Restarts a crashed service with exponential backoff and gives up after
# WATCHDOG_MAX_RESTARTS attempts until the Console restart option is used.
# SERVICE is MIHOMO or MONITOR; its PID is kept in <SERVICE>_PID.
supervise_service() {
    local service="$1"
    local name="$2"
    local console_option="$3"
    local start_function="$4"
    local pid_variable="${service}_PID"
    local pid="${!pid_variable}"
    local exit_status delay

    if is_alive "$pid"; then
        if (( WATCHDOG_RESTARTS[$service] > 0 && SECONDS - STARTED_AT[$service] >= WATCHDOG_STABLE_SECONDS )); then
            log "$name remained stable for ${WATCHDOG_STABLE_SECONDS}s; watchdog counter reset"
            reset_watchdog "$service"
        fi
        return 0
    fi

    if [[ -n "$pid" ]]; then
        exit_status=0
        wait "$pid" 2>/dev/null || exit_status=$?
        warn "$name exited unexpectedly (status $exit_status)"
        printf -v "$pid_variable" '%s' ''
    fi
    [[ "${WATCHDOG_GAVE_UP[$service]}" -eq 0 ]] || return 0

    if [[ -z "${WATCHDOG_NEXT_AT[$service]}" ]]; then
        if (( WATCHDOG_RESTARTS[$service] >= WATCHDOG_MAX_RESTARTS )); then
            WATCHDOG_GAVE_UP[$service]=1
            warn "$name watchdog stopped after ${WATCHDOG_MAX_RESTARTS} restart attempts; use Console option $console_option to retry manually"
            return 0
        fi
        WATCHDOG_RESTARTS[$service]=$((WATCHDOG_RESTARTS[$service] + 1))
        delay="$(watchdog_delay "${WATCHDOG_RESTARTS[$service]}")"
        WATCHDOG_NEXT_AT[$service]=$((SECONDS + delay))
        warn "$name crashed; watchdog restart ${WATCHDOG_RESTARTS[$service]}/${WATCHDOG_MAX_RESTARTS} scheduled in ${delay}s"
    fi

    if (( SECONDS >= WATCHDOG_NEXT_AT[$service] )); then
        WATCHDOG_NEXT_AT[$service]=''
        log "Watchdog restarting $name (${WATCHDOG_RESTARTS[$service]}/${WATCHDOG_MAX_RESTARTS})"
        "$start_function" || true
    fi
}

supervise_services() {
    if [[ "$MIHOMO_ENABLED" == "1" ]]; then
        supervise_service MIHOMO Mihomo 5 start_mihomo
    fi
    if [[ "$MONITOR_ENABLED" == "1" ]]; then
        supervise_service MONITOR Monitor 6 start_monitor
    fi
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
    elif [[ "${WATCHDOG_GAVE_UP[MIHOMO]}" -eq 1 ]]; then
        printf 'Mihomo : STOPPED (watchdog gave up after %s attempts)\n' "$WATCHDOG_MAX_RESTARTS"
    else
        printf 'Mihomo : STOPPED\n'
    fi

    if [[ "$MONITOR_ENABLED" != "1" ]]; then
        printf 'Monitor : DISABLED\n'
    elif is_alive "$MONITOR_PID"; then
        printf 'Monitor : RUNNING (%s, PID %s, %s)\n' "$MONITOR_TYPE" "$MONITOR_PID" "$(pid_rss "$MONITOR_PID")"
    elif [[ "${WATCHDOG_GAVE_UP[MONITOR]}" -eq 1 ]]; then
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

if [[ "$CONSOLE_LANG" == "en" ]]; then
    MENU_ITEMS=(
        '[1] Service status'
        '[2] Proxy link'
        '[3] Mihomo log (last 120 lines)'
        '[4] Monitor log (last 120 lines)'
        '[5] Restart Mihomo'
        '[6] Restart Monitor'
        '[7] Renewal log (last 120 lines)'
        '[0] Show menu'
    )
    MENU_PROMPT='Enter a number: '
    MENU_UNKNOWN='Unknown option:'
else
    MENU_ITEMS=(
        '[1] 服务状态'
        '[2] 代理链接'
        '[3] Mihomo 日志（最近 120 行）'
        '[4] Monitor 日志（最近 120 行）'
        '[5] 重启 Mihomo'
        '[6] 重启 Monitor'
        '[7] 自动延期日志（最近 120 行）'
        '[0] 显示菜单'
    )
    MENU_PROMPT='请输入数字: '
    MENU_UNKNOWN='未知选项:'
fi

show_menu() {
    printf '%s\n' '=========================================='
    printf '%s\n' ' ACLClouds Bot Toolkit'
    printf '%s\n' '=========================================='
    printf '%s\n' "${MENU_ITEMS[@]}"
    printf '%s\n' '------------------------------------------'
    printf '%s' "$MENU_PROMPT"
}

: > "$MIHOMO_LOG"
: > "$MONITOR_LOG"

if ! start_mihomo; then
    die "Mihomo failed during initial startup"
fi
start_monitor || true

log "Startup completed (launcher $LAUNCHER_VERSION)"
signal_pterodactyl_ready
signal_bootstrap_ready
show_status
if [[ "$MIHOMO_ENABLED" == "1" ]]; then
    show_link
fi
show_menu

while true; do
    supervise_services
    maintain_logs
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
            printf '%s %s\n' "$MENU_UNKNOWN" "$choice"
            ;;
    esac

    printf '%s' "$MENU_PROMPT"
done
