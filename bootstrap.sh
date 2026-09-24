#!/usr/bin/env bash

# ACLCloudFreeBotToolKit
# Copyright (C) 2026 MessyMidi
#
# SPDX-License-Identifier: AGPL-3.0-only
# Additional terms under AGPLv3 Section 7:
# see /ADDITIONAL_TERMS.md

set -Eeuo pipefail
umask 077

BOOTSTRAP_VERSION='0.5.0'
SUPPORTED_CONFIG_SCHEMA_VERSION=2
DEFAULT_UPDATE_BASE_URL='https://github.com/MessyMidi/ACLCloudFreeBotToolKit/releases/latest/download'
DEFAULT_RELEASES_API_URL='https://api.github.com/repos/MessyMidi/ACLCloudFreeBotToolKit/releases?per_page=20'
DEFAULT_RELEASE_DOWNLOAD_BASE_URL='https://github.com/MessyMidi/ACLCloudFreeBotToolKit/releases/download'
DEFAULT_UPDATE_INTERVAL=21600
DEFAULT_UPDATE_JITTER=1800
DEFAULT_READY_TIMEOUT=180
DEFAULT_READY_STABLE_SECONDS=10
DEFAULT_RENEW_INTERVAL=86400
DEFAULT_RENEW_JITTER=1800

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER_PATH="$BASE_DIR/launcher.sh"
RENEW_BIN="$BASE_DIR/bin/acl-renew"
RENEW_ASSET='acl-renew-linux-amd64'
STATE_DIR="$BASE_DIR/data/bootstrap"
BACKUP_ROOT="$STATE_DIR/backups"
READY_FILE="$STATE_DIR/launcher.ready"
PENDING_FILE="$STATE_DIR/pending-update"
LOG_DIR="$BASE_DIR/logs"
RENEW_LOG="$LOG_DIR/renew.log"

UPDATE_BASE_URL_OVERRIDE="${ACL_UPDATE_BASE_URL:-}"
UPDATE_BASE_URL="$DEFAULT_UPDATE_BASE_URL"
RELEASES_API_URL="${ACL_RELEASES_API_URL:-$DEFAULT_RELEASES_API_URL}"
RELEASE_DOWNLOAD_BASE_URL="${ACL_RELEASE_DOWNLOAD_BASE_URL:-$DEFAULT_RELEASE_DOWNLOAD_BASE_URL}"
UPDATE_CHANNEL="${ACL_UPDATE_CHANNEL:-}"
UPDATE_CHANNEL_EXPLICIT=0
[[ -n "$UPDATE_CHANNEL" ]] && UPDATE_CHANNEL_EXPLICIT=1
UPDATE_INTERVAL="${ACL_UPDATE_CHECK_INTERVAL:-$DEFAULT_UPDATE_INTERVAL}"
UPDATE_JITTER="${ACL_UPDATE_JITTER_MAX:-$DEFAULT_UPDATE_JITTER}"
READY_TIMEOUT="${ACL_LAUNCHER_READY_TIMEOUT:-$DEFAULT_READY_TIMEOUT}"
READY_STABLE_SECONDS="${ACL_LAUNCHER_READY_STABLE_SECONDS:-$DEFAULT_READY_STABLE_SECONDS}"
RENEW_INTERVAL="${ACL_RENEW_CHECK_INTERVAL:-$DEFAULT_RENEW_INTERVAL}"
RENEW_JITTER="${ACL_RENEW_JITTER_MAX:-$DEFAULT_RENEW_JITTER}"

AUTO_UPDATE_MODE='enable'
INTERNAL_MIGRATE_FILE=''
SKIP_INITIAL_UPDATE=0
CHILD_PID=''
RENEW_PID=''
SHUTTING_DOWN=0
STAGED_UPDATE_DIR=''
NEXT_RENEW_AT=0

log()  { printf '[bootstrap] %s\n' "$*"; }
warn() { printf '[bootstrap] WARNING: %s\n' "$*" >&2; }
die()  { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

for argument in "$@"; do
    case "$argument" in
        --AUTO_UPDATE=enable|--auto-update=enable)
            AUTO_UPDATE_MODE='enable'
            ;;
        --AUTO_UPDATE=disable|--auto-update=disable)
            AUTO_UPDATE_MODE='disable'
            ;;
        --UPDATE_CHANNEL=stable|--update-channel=stable)
            UPDATE_CHANNEL='stable'
            UPDATE_CHANNEL_EXPLICIT=1
            ;;
        --UPDATE_CHANNEL=prerelease|--update-channel=prerelease)
            UPDATE_CHANNEL='prerelease'
            UPDATE_CHANNEL_EXPLICIT=1
            ;;
        --INTERNAL_MIGRATE_CONFIG=*)
            INTERNAL_MIGRATE_FILE="${argument#*=}"
            ;;
        --SKIP_INITIAL_UPDATE|--skip-initial-update)
            SKIP_INITIAL_UPDATE=1
            ;;
        *)
            die "Unknown argument: $argument"
            ;;
    esac
done

[[ "$UPDATE_INTERVAL" =~ ^[0-9]+$ ]] || die 'ACL_UPDATE_CHECK_INTERVAL must be a non-negative integer'
[[ "$UPDATE_JITTER" =~ ^[0-9]+$ ]] || die 'ACL_UPDATE_JITTER_MAX must be a non-negative integer'
[[ "$READY_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die 'ACL_LAUNCHER_READY_TIMEOUT must be a positive integer'
[[ "$READY_STABLE_SECONDS" =~ ^[0-9]+$ ]] || die 'ACL_LAUNCHER_READY_STABLE_SECONDS must be a non-negative integer'
[[ "$RENEW_INTERVAL" =~ ^[1-9][0-9]*$ ]] || die 'ACL_RENEW_CHECK_INTERVAL must be a positive integer'
[[ "$RENEW_JITTER" =~ ^[0-9]+$ ]] || die 'ACL_RENEW_JITTER_MAX must be a non-negative integer'

mkdir -p "$STATE_DIR" "$BACKUP_ROOT" "$LOG_DIR"

is_alive() {
    local pid="${1:-}"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

atomic_copy() {
    local source="$1"
    local destination="$2"
    local temporary="${destination}.tmp.$$"

    cp "$source" "$temporary"
    chmod 700 "$temporary"
    mv -f "$temporary" "$destination"
}

download_asset() {
    local url="$1"
    local output="$2"
    local temporary="${output}.part"

    rm -f "$temporary"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 1 --retry-delay 1 --connect-timeout 5 --max-time 20 -o "$temporary" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 --tries=2 -O "$temporary" "$url"
    else
        warn 'Neither curl nor wget is available; update check skipped'
        return 1
    fi
    mv -f "$temporary" "$output"
}

file_sha256() {
    local file="$1"
    sha256sum "$file" | sed -n 's/[[:space:]].*$//p'
}

checksum_for() {
    local checksum_file="$1"
    local wanted="$2"
    local line digest filename found=''

    while IFS= read -r line; do
        if [[ "$line" =~ ^([[:xdigit:]]{64})[[:space:]]+\*?([^[:space:]]+)$ ]]; then
            digest="${BASH_REMATCH[1],,}"
            filename="${BASH_REMATCH[2]}"
            if [[ "$filename" == "$wanted" ]]; then
                [[ -z "$found" ]] || return 1
                found="$digest"
            fi
        fi
    done < "$checksum_file"

    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

verify_asset() {
    local file="$1"
    local expected="$2"
    printf '%s  %s\n' "$expected" "$file" | sha256sum -c - >/dev/null 2>&1
}

find_config_file() {
    if [[ -f "$BASE_DIR/config.env" ]]; then
        printf '%s\n' "$BASE_DIR/config.env"
    elif [[ -f "$BASE_DIR/.env" ]]; then
        printf '%s\n' "$BASE_DIR/.env"
    else
        return 1
    fi
}

read_config_update_channel() {
    local config_file="$1"
    local line raw value='' count=0

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*BOOTSTRAP_UPDATE_CHANNEL[[:space:]]*= ]] || continue
        raw="${line#*=}"
        raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        if [[ "$raw" =~ ^\'(stable|prerelease)\'$ || "$raw" =~ ^\"(stable|prerelease)\"$ || "$raw" =~ ^(stable|prerelease)$ ]]; then
            value="${BASH_REMATCH[1]}"
            count=$((count + 1))
            continue
        fi
        return 2
    done < "$config_file"

    [[ "$count" -le 1 ]] || return 2
    [[ "$count" -eq 1 ]] || return 1
    printf '%s\n' "$value"
}

if [[ "$UPDATE_CHANNEL_EXPLICIT" -eq 0 ]]; then
    config_channel=''
    if config_file="$(find_config_file)"; then
        if config_channel="$(read_config_update_channel "$config_file")"; then
            UPDATE_CHANNEL="$config_channel"
        else
            config_channel_status=$?
            [[ "$config_channel_status" -eq 1 ]] || die 'BOOTSTRAP_UPDATE_CHANNEL must be stable or prerelease and defined only once'
        fi
    fi
fi
UPDATE_CHANNEL="${UPDATE_CHANNEL:-stable}"
[[ "$UPDATE_CHANNEL" == 'stable' || "$UPDATE_CHANNEL" == 'prerelease' ]] || \
    die 'ACL_UPDATE_CHANNEL must be stable or prerelease'

read_schema_version() {
    local config_file="$1"
    local line raw value='' count=0

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*CONFIG_SCHEMA_VERSION[[:space:]]*= ]] || continue
        raw="${line#*=}"
        raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        if [[ "$raw" =~ ^\'([0-9]+)\'$ || "$raw" =~ ^\"([0-9]+)\"$ || "$raw" =~ ^([0-9]+)$ ]]; then
            value="${BASH_REMATCH[1]}"
            count=$((count + 1))
            continue
        fi
        die 'CONFIG_SCHEMA_VERSION must be a single integer assignment'
    done < "$config_file"

    [[ "$count" -le 1 ]] || die 'CONFIG_SCHEMA_VERSION is defined more than once'
    if [[ "$count" -eq 0 ]]; then
        return 1
    fi
    printf '%s\n' "$value"
}

backup_config() {
    local config_file="$1"
    local reason="$2"
    local backup_dir="$BASE_DIR/data/bootstrap/config-backups"
    local stamp

    mkdir -p "$backup_dir"
    stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf '%s' "$$")"
    cp "$config_file" "$backup_dir/$(basename "$config_file").${reason}.${stamp}.bak"
    chmod 600 "$backup_dir/$(basename "$config_file").${reason}.${stamp}.bak"
}

write_config_atomically() {
    local source="$1"
    local destination="$2"
    local temporary="${destination}.tmp.$$"

    cp "$source" "$temporary"
    chmod 600 "$temporary"
    bash -n "$temporary"
    mv -f "$temporary" "$destination"
}

normalize_config_line_endings() {
    local config_file="$1"
    local temporary="${config_file}.line-endings.$$"
    local line changed=0

    : > "$temporary"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *$'\r' ]]; then
            line="${line%$'\r'}"
            changed=1
        fi
        if [[ "$line" == *$'\r'* ]]; then
            warn 'Configuration contains an embedded carriage return; remove control characters and try again'
            rm -f "$temporary"
            return 1
        fi
        printf '%s\n' "$line" >> "$temporary"
    done < "$config_file"

    if [[ "$changed" -eq 0 ]]; then
        rm -f "$temporary"
        return 0
    fi

    if ! backup_config "$config_file" 'line-endings'; then
        warn 'Unable to back up the CRLF configuration'
        rm -f "$temporary"
        return 1
    fi
    if ! write_config_atomically "$temporary" "$config_file"; then
        warn 'Unable to atomically normalize configuration line endings'
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
    log 'Configuration line endings normalized to LF'
}

migrate_config_step() {
    local from_version="$1"
    local config_file="$2"

    case "$from_version" in
        1) migrate_config_1_to_2 "$config_file" ;;
        *)
            warn "No migration is registered from config schema $from_version"
            return 1
            ;;
    esac
}

migrate_config_1_to_2() {
    local config_file="$1"
    local temporary="${config_file}.v2.$$"

    sed -E "s/^[[:space:]]*CONFIG_SCHEMA_VERSION[[:space:]]*=.*$/CONFIG_SCHEMA_VERSION='2'/" \
        "$config_file" > "$temporary"
    if ! grep -Eq '^[[:space:]]*AUTO_RENEW_ENABLED[[:space:]]*=' "$temporary"; then
        cat >> "$temporary" <<'EOF'

# ---------------- ACLClouds automatic renewal ----------------
# Existing deployments remain opt-in after migration.
AUTO_RENEW_ENABLED='0'
ACL_USERNAME=''
ACL_PASSWORD=''
ACL_SERVER_ID=''
TELEGRAM_BOT_TOKEN=''
TELEGRAM_CHAT_ID=''
EOF
    fi
    write_config_atomically "$temporary" "$config_file"
    rm -f "$temporary"
    log 'Configuration migrated from schema 1 to 2 (automatic renewal remains disabled)'
}

migrate_config() {
    local config_file="$1"
    local current_version temporary

    [[ -f "$config_file" ]] || die "Configuration file not found: $config_file"

    normalize_config_line_endings "$config_file" || return 1

    if current_version="$(read_schema_version "$config_file")"; then
        :
    else
        current_version=1
        backup_config "$config_file" 'schema-marker'
        temporary="${config_file}.schema.$$"
        {
            cat "$config_file"
            printf "\nCONFIG_SCHEMA_VERSION='1'\n"
        } > "$temporary"
        write_config_atomically "$temporary" "$config_file"
        rm -f "$temporary"
        log 'Legacy configuration identified as schema 1 and marked in place'
    fi

    (( current_version <= SUPPORTED_CONFIG_SCHEMA_VERSION )) || \
        die "Config schema $current_version is newer than bootstrap supports ($SUPPORTED_CONFIG_SCHEMA_VERSION)"

    while (( current_version < SUPPORTED_CONFIG_SCHEMA_VERSION )); do
        backup_config "$config_file" "v${current_version}"
        migrate_config_step "$current_version" "$config_file" || return 1
        current_version=$((current_version + 1))
        if [[ "$(read_schema_version "$config_file")" != "$current_version" ]]; then
            warn "Migration did not produce config schema $current_version"
            return 1
        fi
    done
}

if [[ -n "$INTERNAL_MIGRATE_FILE" ]]; then
    migrate_config "$INTERNAL_MIGRATE_FILE"
    exit 0
fi

find_latest_prerelease_tag() {
    local releases_file="$1"
    local line tag='' draft='' prerelease=''

    while IFS= read -r line; do
        if [[ "$line" =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9._-]+)\" ]]; then
            tag="${BASH_REMATCH[1]}"
            draft=''
            prerelease=''
            continue
        fi
        [[ -n "$tag" ]] || continue
        if [[ "$line" =~ \"draft\"[[:space:]]*:[[:space:]]*(true|false) ]]; then
            draft="${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "$line" =~ \"prerelease\"[[:space:]]*:[[:space:]]*(true|false) ]]; then
            prerelease="${BASH_REMATCH[1]}"
            if [[ "$draft" == 'false' ]]; then
                if [[ "$prerelease" == 'true' ]]; then
                    printf '%s\n' "$tag"
                    return 0
                fi
                # GitHub returns releases newest first. Once the newest
                # published release is Stable, older prereleases must not
                # replace it and accidentally downgrade a test container.
                return 1
            fi
            tag=''
        fi
    done < "$releases_file"
    return 1
}

resolve_update_base_url() {
    local stage="$1"
    local releases_file tag

    if [[ -n "$UPDATE_BASE_URL_OVERRIDE" ]]; then
        UPDATE_BASE_URL="${UPDATE_BASE_URL_OVERRIDE%/}"
        return 0
    fi
    if [[ "$UPDATE_CHANNEL" == 'stable' ]]; then
        UPDATE_BASE_URL="$DEFAULT_UPDATE_BASE_URL"
        return 0
    fi

    releases_file="$stage/releases.json"
    if ! download_asset "$RELEASES_API_URL" "$releases_file"; then
        warn 'Prerelease metadata is unavailable; continuing with local files'
        return 1
    fi
    if ! tag="$(find_latest_prerelease_tag "$releases_file")"; then
        warn 'No active prerelease newer than the latest Stable release was found; continuing with local files'
        return 1
    fi
    UPDATE_BASE_URL="${RELEASE_DOWNLOAD_BASE_URL%/}/$tag"
    log "Selected prerelease $tag"
}

prepare_update() {
    local stage checksum_file expected_bootstrap expected_launcher expected_renew
    local local_bootstrap='' local_launcher='' local_renew=''

    stage="$STATE_DIR/stage.$$"
    rm -rf -- "$stage"
    mkdir -p "$stage"
    checksum_file="$stage/SHA256SUMS"

    if ! resolve_update_base_url "$stage"; then
        rm -rf -- "$stage"
        return 1
    fi
    log "Checking $UPDATE_CHANNEL channel for updates..."
    if ! download_asset "$UPDATE_BASE_URL/SHA256SUMS" "$checksum_file"; then
        warn 'Update metadata is unavailable; continuing with local files'
        rm -rf -- "$stage"
        return 1
    fi

    if ! expected_bootstrap="$(checksum_for "$checksum_file" 'bootstrap.sh')" || \
       ! expected_launcher="$(checksum_for "$checksum_file" 'launcher.sh')" || \
       ! expected_renew="$(checksum_for "$checksum_file" "$RENEW_ASSET")"; then
        warn 'SHA256SUMS is missing a unique bootstrap.sh, launcher.sh, or acl-renew entry'
        rm -rf -- "$stage"
        return 1
    fi

    [[ -f "$BASE_DIR/bootstrap.sh" ]] && local_bootstrap="$(file_sha256 "$BASE_DIR/bootstrap.sh")"
    [[ -f "$LAUNCHER_PATH" ]] && local_launcher="$(file_sha256 "$LAUNCHER_PATH")"
    [[ -f "$RENEW_BIN" ]] && local_renew="$(file_sha256 "$RENEW_BIN")"
    if [[ "$local_bootstrap" == "$expected_bootstrap" && "$local_launcher" == "$expected_launcher" && "$local_renew" == "$expected_renew" ]]; then
        log "The $UPDATE_CHANNEL channel is already current"
        rm -rf -- "$stage"
        return 1
    fi

    if ! download_asset "$UPDATE_BASE_URL/bootstrap.sh" "$stage/bootstrap.sh" || \
       ! download_asset "$UPDATE_BASE_URL/launcher.sh" "$stage/launcher.sh" || \
       ! download_asset "$UPDATE_BASE_URL/$RENEW_ASSET" "$stage/$RENEW_ASSET"; then
        warn 'Update download failed; continuing with the current launcher'
        rm -rf -- "$stage"
        return 1
    fi

    if ! verify_asset "$stage/bootstrap.sh" "$expected_bootstrap" || \
       ! verify_asset "$stage/launcher.sh" "$expected_launcher" || \
       ! verify_asset "$stage/$RENEW_ASSET" "$expected_renew"; then
        warn 'Update checksum verification failed; current files were not changed'
        rm -rf -- "$stage"
        return 1
    fi

    if ! bash -n "$stage/bootstrap.sh" || ! bash -n "$stage/launcher.sh"; then
        warn 'Downloaded script failed bash syntax validation; current files were not changed'
        rm -rf -- "$stage"
        return 1
    fi
    chmod 700 "$stage/$RENEW_ASSET"
    if ! "$stage/$RENEW_ASSET" version >/dev/null 2>&1; then
        warn 'Downloaded acl-renew binary failed its smoke test; current files were not changed'
        rm -rf -- "$stage"
        return 1
    fi

    STAGED_UPDATE_DIR="$stage"
    return 0
}

stop_launcher() {
    local pid="${CHILD_PID:-}"
    [[ -n "$pid" ]] || return 0

    if is_alive "$pid"; then
        kill -TERM "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            is_alive "$pid" || break
            sleep 1
        done
        if is_alive "$pid"; then
            warn "Launcher PID $pid did not stop in time; sending SIGKILL"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    wait "$pid" 2>/dev/null || true
    CHILD_PID=''
}

stop_renew() {
    local pid="${RENEW_PID:-}"
    [[ -n "$pid" ]] || return 0
    if is_alive "$pid"; then
        kill -TERM "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            is_alive "$pid" || break
            sleep 1
        done
        if is_alive "$pid"; then
            warn "Renewal helper PID $pid did not stop in time; sending SIGKILL"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    wait "$pid" 2>/dev/null || true
    RENEW_PID=''
}

shutdown() {
    SHUTTING_DOWN=1
    trap - TERM INT EXIT
    log 'Shutdown requested; stopping renewal check and launcher'
    stop_renew
    stop_launcher
    exit 0
}

cleanup_on_exit() {
    local status=$?
    trap - EXIT
    if [[ "$SHUTTING_DOWN" -eq 0 && ( -n "${CHILD_PID:-}" || -n "${RENEW_PID:-}" ) ]]; then
        warn 'Bootstrap is exiting unexpectedly; stopping child processes'
        stop_renew
        stop_launcher
    fi
    exit "$status"
}

trap shutdown TERM INT
trap cleanup_on_exit EXIT

read_pending_backup() {
    local name=''
    [[ -f "$PENDING_FILE" ]] || return 1
    IFS= read -r name < "$PENDING_FILE" || true
    [[ "$name" =~ ^update-[A-Za-z0-9._-]+$ ]] || return 1
    [[ -d "$BACKUP_ROOT/$name" ]] || return 1
    printf '%s\n' "$BACKUP_ROOT/$name"
}

create_update_backup() {
    local config_file="$1"
    local name backup_dir

    name="update-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf '%s' "$$")-$$"
    backup_dir="$BACKUP_ROOT/$name"
    mkdir -p "$backup_dir"
    [[ -f "$BASE_DIR/bootstrap.sh" ]] && cp "$BASE_DIR/bootstrap.sh" "$backup_dir/bootstrap.sh"
    [[ -f "$LAUNCHER_PATH" ]] && cp "$LAUNCHER_PATH" "$backup_dir/launcher.sh"
    [[ -f "$RENEW_BIN" ]] && cp "$RENEW_BIN" "$backup_dir/$RENEW_ASSET"
    [[ -f "$RENEW_BIN" ]] && printf '1\n' > "$backup_dir/renew.existed" || printf '0\n' > "$backup_dir/renew.existed"
    cp "$config_file" "$backup_dir/config.snapshot"
    printf '%s\n' "$(basename "$config_file")" > "$backup_dir/config.name"
    chmod 600 "$backup_dir"/* 2>/dev/null || true
    printf '%s\n' "$name" > "${PENDING_FILE}.tmp"
    mv -f "${PENDING_FILE}.tmp" "$PENDING_FILE"
    printf '%s\n' "$backup_dir"
}

restore_update_backup() {
    local backup_dir="$1"
    local config_name config_path

    [[ "$backup_dir" == "$BACKUP_ROOT/"* && -d "$backup_dir" ]] || die 'Refusing an invalid rollback path'
    log 'Rolling back scripts and configuration'
    stop_launcher

    [[ -f "$backup_dir/bootstrap.sh" ]] && atomic_copy "$backup_dir/bootstrap.sh" "$BASE_DIR/bootstrap.sh"
    if [[ -f "$backup_dir/launcher.sh" ]]; then
        atomic_copy "$backup_dir/launcher.sh" "$LAUNCHER_PATH"
    else
        rm -f "$LAUNCHER_PATH"
    fi
    if [[ -f "$backup_dir/$RENEW_ASSET" ]]; then
        mkdir -p "$(dirname "$RENEW_BIN")"
        atomic_copy "$backup_dir/$RENEW_ASSET" "$RENEW_BIN"
    elif [[ "$(cat "$backup_dir/renew.existed" 2>/dev/null || printf '0')" == '0' ]]; then
        rm -f "$RENEW_BIN"
    fi
    IFS= read -r config_name < "$backup_dir/config.name"
    [[ "$config_name" == 'config.env' || "$config_name" == '.env' ]] || die 'Rollback contains an invalid config filename'
    config_path="$BASE_DIR/$config_name"
    cp "$backup_dir/config.snapshot" "${config_path}.rollback.$$"
    chmod 600 "${config_path}.rollback.$$"
    mv -f "${config_path}.rollback.$$" "$config_path"
    rm -f "$PENDING_FILE"
    rm -rf -- "$backup_dir"

    exec bash "$BASE_DIR/bootstrap.sh" "--AUTO_UPDATE=$AUTO_UPDATE_MODE" "--UPDATE_CHANNEL=$UPDATE_CHANNEL" --SKIP_INITIAL_UPDATE
}

apply_update() {
    local stage="$1"
    local config_file backup_dir

    config_file="$(find_config_file)" || {
        warn 'No config.env or .env exists; update was staged but cannot be applied'
        rm -rf -- "$stage"
        return 1
    }
    backup_dir="$(create_update_backup "$config_file")"

    if ! bash "$stage/bootstrap.sh" "--INTERNAL_MIGRATE_CONFIG=$config_file"; then
        warn 'New bootstrap could not migrate the configuration; update cancelled'
        rm -f "$PENDING_FILE"
        rm -rf -- "$backup_dir" "$stage"
        return 1
    fi

    log 'Update verified; switching launcher under supervision'
    stop_renew
    stop_launcher
    mkdir -p "$(dirname "$RENEW_BIN")"
    atomic_copy "$stage/launcher.sh" "$LAUNCHER_PATH"
    atomic_copy "$stage/$RENEW_ASSET" "$RENEW_BIN"
    atomic_copy "$stage/bootstrap.sh" "$BASE_DIR/bootstrap.sh"
    rm -rf -- "$stage"

    exec bash "$BASE_DIR/bootstrap.sh" "--AUTO_UPDATE=$AUTO_UPDATE_MODE" "--UPDATE_CHANNEL=$UPDATE_CHANNEL"
}

start_launcher() {
    local generation
    [[ -f "$LAUNCHER_PATH" ]] || return 1

    generation="${BOOTSTRAP_VERSION}-$$-${RANDOM}-${SECONDS}"
    rm -f "$READY_FILE"
    log "Starting launcher (bootstrap $BOOTSTRAP_VERSION)"
    LAUNCHER_READY_FILE="$READY_FILE" LAUNCHER_GENERATION="$generation" \
        bash "$LAUNCHER_PATH" <&0 &
    CHILD_PID=$!
    printf '%s\n' "$generation" > "$STATE_DIR/expected-generation"
}

wait_for_launcher_ready() {
    local waited=0 generation ready_value stable=0
    IFS= read -r generation < "$STATE_DIR/expected-generation"

    while (( waited < READY_TIMEOUT )); do
        is_alive "$CHILD_PID" || return 1
        if [[ -f "$READY_FILE" ]]; then
            IFS= read -r ready_value < "$READY_FILE" || true
            if [[ "$ready_value" == "$generation" ]]; then
                while (( stable < READY_STABLE_SECONDS )); do
                    sleep 1
                    is_alive "$CHILD_PID" || return 1
                    stable=$((stable + 1))
                done
                return 0
            fi
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

commit_pending_update() {
    local backup_dir="$1"
    log 'Updated launcher reported ready; update committed'
    rm -f "$PENDING_FILE"
    rm -rf -- "$backup_dir"
}

schedule_next_update() {
    local jitter=0
    if (( UPDATE_JITTER > 0 )); then
        jitter=$((RANDOM % (UPDATE_JITTER + 1)))
    fi
    NEXT_UPDATE_AT=$((SECONDS + UPDATE_INTERVAL + jitter))
}

renew_is_enabled() {
    local config_file
    config_file="$(find_config_file)" || return 1
    (
        set +u
        # shellcheck disable=SC1090
        source "$config_file"
        case "${AUTO_RENEW_ENABLED:-0}" in
            1|true|TRUE|yes|YES|on|ON|enable|enabled) exit 0 ;;
            *) exit 1 ;;
        esac
    )
}

provision_renew_binary() {
    local stage checksum_file expected
    stage="$STATE_DIR/renew-provision.$$"
    rm -rf -- "$stage"
    mkdir -p "$stage"
    checksum_file="$stage/SHA256SUMS"

    log 'Provisioning the verified ACLClouds renewal helper...'
    if ! resolve_update_base_url "$stage" || \
       ! download_asset "$UPDATE_BASE_URL/SHA256SUMS" "$checksum_file" || \
       ! expected="$(checksum_for "$checksum_file" "$RENEW_ASSET")" || \
       ! download_asset "$UPDATE_BASE_URL/$RENEW_ASSET" "$stage/$RENEW_ASSET" || \
       ! verify_asset "$stage/$RENEW_ASSET" "$expected"; then
        warn 'Renewal helper is unavailable or failed checksum verification; automatic renewal is deferred'
        rm -rf -- "$stage"
        return 1
    fi
    chmod 700 "$stage/$RENEW_ASSET"
    if ! "$stage/$RENEW_ASSET" version >/dev/null 2>&1; then
        warn 'Renewal helper failed its smoke test; automatic renewal is deferred'
        rm -rf -- "$stage"
        return 1
    fi
    mkdir -p "$(dirname "$RENEW_BIN")"
    atomic_copy "$stage/$RENEW_ASSET" "$RENEW_BIN"
    rm -rf -- "$stage"
    log 'Renewal helper installed'
}

schedule_next_renew() {
    local jitter=0
    if (( RENEW_JITTER > 0 )); then
        jitter=$((RANDOM % (RENEW_JITTER + 1)))
    fi
    NEXT_RENEW_AT=$((SECONDS + RENEW_INTERVAL + jitter))
}

start_renew_check() {
    local config_file
    [[ -z "${RENEW_PID:-}" ]] || return 0
    if ! renew_is_enabled; then
        schedule_next_renew
        return 0
    fi
    if [[ ! -x "$RENEW_BIN" ]] && ! provision_renew_binary; then
        schedule_next_renew
        return 0
    fi
    config_file="$(find_config_file)" || return 1
    log 'Starting scheduled ACLClouds renewal check'
    if [[ -f "$RENEW_LOG" ]]; then
        tail -n 1000 "$RENEW_LOG" > "${RENEW_LOG}.tmp.$$" 2>/dev/null || true
        mv -f "${RENEW_LOG}.tmp.$$" "$RENEW_LOG" 2>/dev/null || true
    fi
    (
        set +e
        set -a
        # shellcheck disable=SC1090
        if ! source "$config_file"; then
            printf '[renew] ERROR: unable to load config.env\n'
            exit 1
        fi
        set +a
        printf '\n===== renewal check %s =====\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'started')"
        ACL_BASE_DIR="$BASE_DIR" "$RENEW_BIN" check
        renew_status=$?
        printf '[renew] Check finished with exit code %s\n' "$renew_status"
        exit "$renew_status"
    ) </dev/null >>"$RENEW_LOG" 2>&1 &
    chmod 600 "$RENEW_LOG" 2>/dev/null || true
    RENEW_PID=$!
    NEXT_RENEW_AT=0
}

ensure_running_launcher() {
    local delay="$1"
    if ! start_launcher || ! wait_for_launcher_ready; then
        warn "Launcher did not become ready; retrying in ${delay}s"
        stop_launcher
        sleep "$delay"
        return 1
    fi
    return 0
}

pending_backup=''
if pending_backup="$(read_pending_backup)"; then
    config_file="$(find_config_file)" || restore_update_backup "$pending_backup"
    if ! migrate_config "$config_file" || ! ensure_running_launcher 2; then
        restore_update_backup "$pending_backup"
    fi
    commit_pending_update "$pending_backup"
else
    rm -f "$PENDING_FILE"
    if [[ "$SKIP_INITIAL_UPDATE" -eq 0 && ( "$AUTO_UPDATE_MODE" == 'enable' || ! -f "$LAUNCHER_PATH" ) ]]; then
        if prepare_update; then
            apply_update "$STAGED_UPDATE_DIR"
        fi
    fi

    [[ -f "$LAUNCHER_PATH" ]] || die "No local launcher is available and the $UPDATE_CHANNEL channel could not be downloaded"
    config_file="$(find_config_file)" || die "No config.env or .env found in $BASE_DIR"
    migrate_config "$config_file"

    restart_delay=2
    until ensure_running_launcher "$restart_delay"; do
        (( restart_delay < 30 )) && restart_delay=$((restart_delay * 2))
        (( restart_delay > 30 )) && restart_delay=30
    done
fi

restart_delay=2
schedule_next_update
start_renew_check

while [[ "$SHUTTING_DOWN" -eq 0 ]]; do
    if ! is_alive "$CHILD_PID"; then
        wait "$CHILD_PID" 2>/dev/null || true
        CHILD_PID=''
        warn "Launcher exited unexpectedly; restarting in ${restart_delay}s"
        sleep "$restart_delay"
        until ensure_running_launcher "$restart_delay"; do
            (( restart_delay < 30 )) && restart_delay=$((restart_delay * 2))
            (( restart_delay > 30 )) && restart_delay=30
        done
        restart_delay=2
    fi

    if [[ -n "${RENEW_PID:-}" ]] && ! is_alive "$RENEW_PID"; then
        wait "$RENEW_PID" 2>/dev/null || true
        RENEW_PID=''
        schedule_next_renew
    elif [[ -z "${RENEW_PID:-}" && "$NEXT_RENEW_AT" -gt 0 && "$SECONDS" -ge "$NEXT_RENEW_AT" ]]; then
        start_renew_check
    fi

    if [[ "$AUTO_UPDATE_MODE" == 'enable' && "$UPDATE_INTERVAL" -gt 0 && "$SECONDS" -ge "$NEXT_UPDATE_AT" ]]; then
        if prepare_update; then
            apply_update "$STAGED_UPDATE_DIR"
        fi
        schedule_next_update
    fi
    sleep 1
done
