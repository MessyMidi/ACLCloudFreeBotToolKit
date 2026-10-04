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
ACTIVE_PID=''

cleanup() {
    if [[ -n "$ACTIVE_PID" ]]; then
        kill -TERM "$ACTIVE_PID" 2>/dev/null || true
        wait "$ACTIVE_PID" 2>/dev/null || true
    fi
    # Only this test's freshly allocated temporary directory is removed.
    rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

assert_count() {
    local expected="$1" pattern="$2" file="$3" actual
    actual="$(grep -cF -- "$pattern" "$file" || true)"
    if [[ "$actual" != "$expected" ]]; then
        printf 'expected %s occurrences of "%s", got %s\n' "$expected" "$pattern" "$actual" >&2
        cat "$file" >&2
        exit 1
    fi
}

make_fixture() {
    local name="$1" language="${2:-en}"
    local dir="$TEST_DIR/$name"
    mkdir -p "$dir/logs"
    cp "$PROJECT_DIR/launcher.sh" "$dir/launcher.sh"
    printf "MIHOMO_ENABLED='0'\nMONITOR_ENABLED='0'\nAUTO_RENEW_ENABLED='1'\nCONSOLE_LANG='%s'\n" \
        "$language" > "$dir/config.env"
}

run_console() {
    local dir="$TEST_DIR/$1"
    (
        cd "$dir"
        exec bash launcher.sh <input >output 2>&1
    ) &
    ACTIVE_PID=$!
    local attempt
    for ((attempt = 0; attempt < 300; attempt += 1)); do
        if grep -q 'Unknown option: 99999\|未知选项: 99999' "$dir/output" 2>/dev/null; then
            kill -TERM "$ACTIVE_PID" 2>/dev/null || true
            wait "$ACTIVE_PID" 2>/dev/null || true
            ACTIVE_PID=''
            return
        fi
        if ! kill -0 "$ACTIVE_PID" 2>/dev/null; then
            printf 'Launcher exited before completing Console input\n' >&2
            cat "$dir/output" >&2
            exit 1
        fi
        sleep 0.1
    done
    printf 'Console test timed out\n' >&2
    cat "$dir/output" >&2
    exit 1
}

# The default renew view must keep three complete checks, not truncate a check
# to a line count. The final check is still in progress and exceeds 120 lines.
make_fixture history
history_dir="$TEST_DIR/history"
{
    printf 'orphaned old log fragment\n'
    for check in 1 2 3 4 5; do
        printf '\n===== renewal check fixture-%s =====\n' "$check"
        printf 'check-%s-start\n' "$check"
        if [[ "$check" == '5' ]]; then
            for ((line = 1; line <= 140; line += 1)); do
                printf 'long-check-line-%s\n' "$line"
            done
        else
            printf 'check-%s-finished\n' "$check"
        fi
    done
} > "$history_dir/logs/renew.log"
printf '7\n42\n1\n0\n1\n3\n1\n0\n4\n1\n0\n7\n0\n99999\n' > "$history_dir/input"
run_console history
assert_count 1 'check-1-start' "$history_dir/output"
assert_count 1 'check-2-finished' "$history_dir/output"
assert_count 3 'check-3-start' "$history_dir/output"
assert_count 3 'check-4-finished' "$history_dir/output"
assert_count 3 'check-5-start' "$history_dir/output"
assert_count 3 'long-check-line-140' "$history_dir/output"
assert_count 1 'orphaned old log fragment' "$history_dir/output"
assert_count 1 'Unknown option: 42' "$history_dir/output"
# Initial menu plus a return from each of the four log views.
assert_count 5 'ACLClouds Bot Toolkit' "$history_dir/output"
# Input 1 after returning is service status, not another dump of renewal logs.
assert_count 2 'Renewal : ENABLED' "$history_dir/output"
assert_count 2 '--- Mihomo log ---' "$history_dir/output"
assert_count 2 '--- Monitor log ---' "$history_dir/output"
assert_count 4 'No log records are available yet.' "$history_dir/output"
assert_count 5 '[3] Mihomo log (last 20 lines)' "$history_dir/output"
assert_count 5 '[4] Monitor log (last 20 lines)' "$history_dir/output"

# Short, boundary-less, empty, and CRLF logs remain usable.
for fixture in short legacy empty crlf; do
    make_fixture "$fixture" zh
    dir="$TEST_DIR/$fixture"
    case "$fixture" in
        short)
            printf '\n===== renewal check one =====\nshort-one\n\n===== renewal check two =====\nshort-two\n' > "$dir/logs/renew.log"
            ;;
        legacy) printf 'legacy-old\nlegacy-a\nlegacy-b\nlegacy-c\n' > "$dir/logs/renew.log" ;;
        empty) : > "$dir/logs/renew.log" ;;
        crlf)
            for check in 1 2 3 4; do
                printf '\r\n===== renewal check crlf-%s =====\r\ncrlf-body-%s\r\n' "$check" "$check"
            done > "$dir/logs/renew.log"
            ;;
    esac
    printf '7\n0\n99999\n' > "$dir/input"
    run_console "$fixture"
    assert_count 1 '[1] 输出全部已保留日志' "$dir/output"
    assert_count 2 'ACLClouds Bot Toolkit' "$dir/output"
    assert_count 2 '[3] Mihomo 日志（最近 20 行）' "$dir/output"
    assert_count 2 '[4] Monitor 日志（最近 20 行）' "$dir/output"
done
assert_count 1 'short-one' "$TEST_DIR/short/output"
assert_count 1 'short-two' "$TEST_DIR/short/output"
assert_count 0 'legacy-old' "$TEST_DIR/legacy/output"
assert_count 1 'legacy-a' "$TEST_DIR/legacy/output"
assert_count 1 'legacy-c' "$TEST_DIR/legacy/output"
assert_count 1 '暂无日志记录。' "$TEST_DIR/empty/output"
assert_count 0 'crlf-body-1' "$TEST_DIR/crlf/output"
assert_count 1 'crlf-body-2' "$TEST_DIR/crlf/output"
assert_count 1 'crlf-body-4' "$TEST_DIR/crlf/output"

# Test the actual service-log renderer with populated files. Service logs are
# reset on launch, so load only the renderer definitions for this small seam.
source <(sed -n '/^show_log_tail() {/,/^# Services keep/{ /^# Services keep/d; p; }' "$PROJECT_DIR/launcher.sh")
source <(sed -n '/^show_recent_renew_log() {/,/^if \[\[ "\$CONSOLE_LANG" == "en" \]\]; then/{ /^if \[\[/d; p; }' "$PROJECT_DIR/launcher.sh")
CONSOLE_LANG='en'
MENU_PROMPT='Enter a number: '
MIHOMO_LOG="$TEST_DIR/mihomo.log"
MONITOR_LOG="$TEST_DIR/monitor.log"
for service in mihomo monitor; do
    {
        printf '%s\n' old-a old-b
        for ((line = 1; line <= 20; line += 1)); do
            printf 'recent-line-%02d\n' "$line"
        done
    } > "$TEST_DIR/$service.log"
    show_console_log "$service" > "$TEST_DIR/$service.recent"
    show_console_log "$service" all > "$TEST_DIR/$service.all"
    assert_count 0 'old-a' "$TEST_DIR/$service.recent"
    assert_count 0 'old-b' "$TEST_DIR/$service.recent"
    assert_count 20 'recent-line-' "$TEST_DIR/$service.recent"
    assert_count 1 'recent-line-01' "$TEST_DIR/$service.recent"
    assert_count 1 'recent-line-20' "$TEST_DIR/$service.recent"
    assert_count 1 'old-a' "$TEST_DIR/$service.all"
    assert_count 1 'old-b' "$TEST_DIR/$service.all"
    assert_count 20 'recent-line-' "$TEST_DIR/$service.all"
    printf '%s\n' short-a short-b > "$TEST_DIR/$service.log"
    show_console_log "$service" > "$TEST_DIR/$service.short"
    assert_count 1 'short-a' "$TEST_DIR/$service.short"
    assert_count 1 'short-b' "$TEST_DIR/$service.short"
done

printf 'launcher Console tests passed\n'
