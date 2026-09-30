#!/usr/bin/env bash

# ACLCloudFreeBotToolKit
# Copyright (C) 2026 MessyMidi
#
# SPDX-License-Identifier: AGPL-3.0-only
# Additional terms under AGPLv3 Section 7:
# see /ADDITIONAL_TERMS.md

set -Eeuo pipefail
umask 077

BOOTSTRAP_VERSION='0.7.0-pre2'
SUPPORTED_CONFIG_SCHEMA_VERSION=2
DEFAULT_UPDATE_BASE_URL='https://github.com/MessyMidi/ACLCloudFreeBotToolKit/releases/latest/download'
DEFAULT_RELEASES_API_URL='https://api.github.com/repos/MessyMidi/ACLCloudFreeBotToolKit/releases?per_page=20'
DEFAULT_RELEASE_DOWNLOAD_BASE_URL='https://github.com/MessyMidi/ACLCloudFreeBotToolKit/releases/download'
DEFAULT_UPDATE_INTERVAL=21600
DEFAULT_UPDATE_JITTER=1800
DEFAULT_READY_TIMEOUT=180
DEFAULT_READY_STABLE_SECONDS=10
DEFAULT_INSTALL_TIMEOUT=3600
DEFAULT_RENEW_INTERVAL=86400
DEFAULT_RENEW_JITTER=1800
DEFAULT_RENEW_RETRY_INTERVAL=1800

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER_PATH="$BASE_DIR/launcher.sh"
RENEW_BIN="$BASE_DIR/bin/acl-renew"
RENEW_ASSET='acl-renew-linux-amd64'
STATE_DIR="$BASE_DIR/data/bootstrap"
BACKUP_ROOT="$STATE_DIR/backups"
READY_FILE="$STATE_DIR/launcher.ready"
PENDING_FILE="$STATE_DIR/pending-update"
PENDING_STARTED_FILE="$STATE_DIR/pending-update.started"
PENDING_ACTIVATED_FILE="$STATE_DIR/pending-update.activated"
REJECTED_UPDATE_FILE="$STATE_DIR/rejected-update"
REJECTED_UPDATE_TTL=604800
LOG_DIR="$BASE_DIR/logs"
RENEW_LOG="$LOG_DIR/renew.log"

log()  { printf '[bootstrap] %s\n' "$*"; }
warn() { printf '[bootstrap] WARNING: %s\n' "$*" >&2; }
die()  { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

atomic_copy() {
    local source="$1"
    local destination="$2"
    local temporary="${destination}.tmp.$$"

    cp "$source" "$temporary"
    chmod 700 "$temporary"
    mv -f "$temporary" "$destination"
}

read_pending_backup() {
    local name=''
    [[ -f "$PENDING_FILE" ]] || return 1
    IFS= read -r name < "$PENDING_FILE" || true
    [[ "$name" =~ ^update-[A-Za-z0-9._-]+$ ]] || return 1
    [[ -d "$BACKUP_ROOT/$name" ]] || return 1
    printf '%s\n' "$BACKUP_ROOT/$name"
}

# Puts the files saved before an update back in place, closes the update
# transaction, and remembers the release so it is not installed again right
# away. The caller must restart bootstrap afterwards.
restore_backup_files() {
    local backup_dir="$1"
    local config_name config_path update_id=''

    [[ "$backup_dir" == "$BACKUP_ROOT/"* && -d "$backup_dir" ]] || die 'Refusing an invalid rollback path'
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
    if [[ -f "$backup_dir/update.id" ]]; then
        IFS= read -r update_id < "$backup_dir/update.id" || true
        printf '%s\n%s\n' "$update_id" "$(date +%s 2>/dev/null || printf '0')" > "$REJECTED_UPDATE_FILE"
    fi
    rm -f "$PENDING_FILE" "$PENDING_STARTED_FILE" "$PENDING_ACTIVATED_FILE"
    rm -rf -- "$backup_dir"
}

# ---------------- Update transaction guard ----------------
# An update replaces bootstrap.sh and immediately runs the new copy. This
# guard runs before anything else in that copy, so even a new bootstrap that
# crashes during startup is recovered: if an earlier start of the same pending
# update ended without committing, rolling back, or a normal shutdown, restore
# the previous version instead of starting the new one again.
guard_pending_update() {
    local argument backup_dir
    for argument in "$@"; do
        # The configuration migration an update runs is not a start.
        case "$argument" in --INTERNAL_MIGRATE_CONFIG=*) return 0 ;; esac
    done
    backup_dir="$(read_pending_backup)" || return 0
    # Transactions created by this version record their format in the backup.
    # If activation never completed, one or more runtime files may have been
    # replaced while the others are still old; never try to start that mix.
    # Backups made by older bootstraps have no transaction.version and remain
    # compatible with the original pending-update behavior.
    if [[ -f "$backup_dir/transaction.version" && ! -f "$PENDING_ACTIVATED_FILE" ]]; then
        warn 'The update was interrupted while switching files; rolling back to the previous version'
        restore_backup_files "$backup_dir"
        exec bash "$BASE_DIR/bootstrap.sh" "$@" --SKIP_INITIAL_UPDATE
    fi
    if [[ -f "$PENDING_STARTED_FILE" ]]; then
        warn 'The updated bootstrap stopped unexpectedly before the update was committed; rolling back to the previous version'
        restore_backup_files "$backup_dir"
        exec bash "$BASE_DIR/bootstrap.sh" "$@" --SKIP_INITIAL_UPDATE
    fi
    : > "$PENDING_STARTED_FILE"
}

guard_pending_update "$@"

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
INSTALL_TIMEOUT="${ACL_LAUNCHER_INSTALL_TIMEOUT:-$DEFAULT_INSTALL_TIMEOUT}"
RENEW_INTERVAL="${ACL_RENEW_CHECK_INTERVAL:-$DEFAULT_RENEW_INTERVAL}"
RENEW_JITTER="${ACL_RENEW_JITTER_MAX:-$DEFAULT_RENEW_JITTER}"
RENEW_RETRY_INTERVAL="${ACL_RENEW_RETRY_INTERVAL:-$DEFAULT_RENEW_RETRY_INTERVAL}"

AUTO_UPDATE_MODE='enable'
INTERNAL_MIGRATE_FILE=''
SKIP_INITIAL_UPDATE=0
CHILD_PID=''
RENEW_PID=''
SHUTTING_DOWN=0
STAGED_UPDATE_DIR=''
NEXT_RENEW_AT=0
RENEW_FAILURES=0

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
[[ "$INSTALL_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die 'ACL_LAUNCHER_INSTALL_TIMEOUT must be a positive integer'
[[ "$RENEW_INTERVAL" =~ ^[1-9][0-9]*$ ]] || die 'ACL_RENEW_CHECK_INTERVAL must be a positive integer'
[[ "$RENEW_JITTER" =~ ^[0-9]+$ ]] || die 'ACL_RENEW_JITTER_MAX must be a non-negative integer'
[[ "$RENEW_RETRY_INTERVAL" =~ ^[1-9][0-9]*$ ]] || die 'ACL_RENEW_RETRY_INTERVAL must be a positive integer'

mkdir -p "$STATE_DIR" "$BACKUP_ROOT" "$LOG_DIR"

is_alive() {
    local pid="${1:-}"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

download_asset() {
    local url="$1"
    local output="$2"
    local temporary="${output}.part"

    rm -f "$temporary"
    if command -v curl >/dev/null 2>&1; then
        # The renewal helper is several megabytes, so a slow link needs more
        # than a fixed short deadline; a transfer that stalls below 4 KiB/s
        # for 30 seconds is still abandoned quickly.
        if ! curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 10 \
            --speed-limit 4096 --speed-time 30 --max-time 600 -o "$temporary" "$url"; then
            rm -f "$temporary"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -q --timeout=30 --tries=2 -O "$temporary" "$url"; then
            rm -f "$temporary"
            return 1
        fi
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

# A release that was rolled back is identified by the digest of its
# SHA256SUMS and skipped for REJECTED_UPDATE_TTL seconds, so a broken release
# does not interrupt the services again at every update check.
update_was_rejected() {
    local update_id="$1"
    local rejected_id='' rejected_at='' now

    [[ -f "$REJECTED_UPDATE_FILE" ]] || return 1
    { IFS= read -r rejected_id; IFS= read -r rejected_at; } < "$REJECTED_UPDATE_FILE" || true
    [[ "$rejected_id" == "$update_id" ]] || return 1
    [[ "$rejected_at" =~ ^[0-9]+$ ]] && now="$(date +%s 2>/dev/null)" || return 0
    (( now - rejected_at < REJECTED_UPDATE_TTL ))
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
    local fields="${releases_file}.fields"
    local line tag='' draft='' prerelease=''

    # Put every JSON member on its own line so the scan below reads both the
    # pretty-printed and the minified form of the API response.
    tr ',{}' '\n\n\n' < "$releases_file" > "$fields"
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
    done < "$fields"
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
    if update_was_rejected "$(file_sha256 "$checksum_file")"; then
        log "Skipping the $UPDATE_CHANNEL release that was rolled back; it is retried after $((REJECTED_UPDATE_TTL / 86400)) days or when a newer release is published"
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
    # Keep the pending-start marker until the new launcher has proved ready.
    # ACLClouds may terminate a container that misses its startup deadline;
    # the next start must treat that as a failed update and restore the last
    # known-good files instead of retrying the same unverified release.
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

create_update_backup() {
    local config_file="$1"
    local update_id="$2"
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
    printf '%s\n' "$update_id" > "$backup_dir/update.id"
    printf '2\n' > "$backup_dir/transaction.version"
    chmod 600 "$backup_dir"/* 2>/dev/null || true
    rm -f "$PENDING_STARTED_FILE" "$PENDING_ACTIVATED_FILE"
    printf '%s\n' "$name" > "${PENDING_FILE}.tmp"
    mv -f "${PENDING_FILE}.tmp" "$PENDING_FILE"
    printf '%s\n' "$backup_dir"
}

restore_update_backup() {
    local backup_dir="$1"

    log 'Rolling back scripts and configuration'
    stop_launcher
    restore_backup_files "$backup_dir"
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
    backup_dir="$(create_update_backup "$config_file" "$(file_sha256 "$stage/SHA256SUMS")")"

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
    : > "${PENDING_ACTIVATED_FILE}.tmp"
    mv -f "${PENDING_ACTIVATED_FILE}.tmp" "$PENDING_ACTIVATED_FILE"
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

# The launcher writes "installing <generation>" to the ready file while it
# downloads runtime files and "<generation>" once its services run. Download
# time has its own, longer limit so a slow first install on a slow link is not
# killed and restarted from scratch forever.
wait_for_launcher_ready() {
    local waited=0 installing=0 generation ready_value stable=0
    IFS= read -r generation < "$STATE_DIR/expected-generation"

    while (( waited < READY_TIMEOUT )); do
        is_alive "$CHILD_PID" || return 1
        ready_value=''
        if [[ -f "$READY_FILE" ]]; then
            IFS= read -r ready_value < "$READY_FILE" || true
        fi
        if [[ "$ready_value" == "$generation" ]]; then
            while (( stable < READY_STABLE_SECONDS )); do
                sleep 1
                is_alive "$CHILD_PID" || return 1
                stable=$((stable + 1))
            done
            return 0
        fi
        if [[ "$ready_value" == "installing $generation" ]]; then
            if (( installing >= INSTALL_TIMEOUT )); then
                warn "Launcher was still downloading runtime files after ${INSTALL_TIMEOUT}s"
                return 1
            fi
            installing=$((installing + 1))
        else
            waited=$((waited + 1))
        fi
        sleep 1
    done
    return 1
}

commit_pending_update() {
    local backup_dir="$1"
    log 'Updated launcher reported ready; update committed'
    rm -f "$PENDING_FILE" "$PENDING_STARTED_FILE" "$PENDING_ACTIVATED_FILE"
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

# A failed check is retried sooner than the regular interval: after
# RENEW_RETRY_INTERVAL, then twice as long after every further failure,
# never later than the regular interval.
schedule_renew_retry() {
    local reason="$1"
    local delay="$RENEW_RETRY_INTERVAL" attempt

    RENEW_FAILURES=$((RENEW_FAILURES + 1))
    for (( attempt = 1; attempt < RENEW_FAILURES && delay < RENEW_INTERVAL; attempt += 1 )); do
        delay=$((delay * 2))
    done
    (( delay <= RENEW_INTERVAL )) || delay="$RENEW_INTERVAL"
    NEXT_RENEW_AT=$((SECONDS + delay))
    warn "$reason; retrying in ${delay}s (details in logs/renew.log)"
}

finish_renew_check() {
    local status="$1"
    if [[ "$status" -eq 0 ]]; then
        RENEW_FAILURES=0
        schedule_next_renew
    else
        schedule_renew_retry "Renewal check failed with exit code $status"
    fi
}

start_renew_check() {
    local config_file
    [[ -z "${RENEW_PID:-}" ]] || return 0
    if ! renew_is_enabled; then
        schedule_next_renew
        return 0
    fi
    if [[ ! -x "$RENEW_BIN" ]] && ! provision_renew_binary; then
        schedule_renew_retry 'Renewal helper could not be installed'
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
        set +a
        # shellcheck disable=SC1090
        if ! source "$config_file"; then
            printf '[renew] ERROR: unable to load config.env\n'
            exit 1
        fi
        # Export only the settings consumed by acl-renew. In particular,
        # Monitor credentials must not reach this unrelated process merely
        # because they live in the same config.env file.
        export AUTO_RENEW_ENABLED ACL_BASE_URL ACL_USERNAME ACL_EMAIL ACL_PASSWORD \
            ACL_SERVER_ID P_SERVER_UUID P_SERVER_IDENTIFIER ACL_AUTH_STATE \
            TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_API_BASE
        export -n MONITOR_TOKEN KOMARI_TOKEN CFSM_SECRET
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
    rm -f "$PENDING_FILE" "$PENDING_STARTED_FILE" "$PENDING_ACTIVATED_FILE"
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
        renew_status=0
        wait "$RENEW_PID" 2>/dev/null || renew_status=$?
        RENEW_PID=''
        finish_renew_check "$renew_status"
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
