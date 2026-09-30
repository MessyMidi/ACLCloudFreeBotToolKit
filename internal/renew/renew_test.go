// ACLCloudFreeBotToolKit
// Copyright (C) 2026 MessyMidi
//
// SPDX-License-Identifier: AGPL-3.0-only
// Additional terms under AGPLv3 Section 7:
// see /ADDITIONAL_TERMS.md

package renew

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestCheckRenewsMatchingCurrentServiceAndNotifies(t *testing.T) {
	var mu sync.Mutex
	var renewedPath string
	var notification string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api/client":
			writeJSON(t, w, http.StatusOK, map[string]any{"data": []any{
				map[string]any{"object": "server", "attributes": map[string]any{
					"identifier": "real-id", "uuid": "full-uuid", "name": "My Bot",
					"can_renew": true, "auto_renew": false, "free_renewals_remaining": 1,
				}},
			}})
		case r.URL.Path == "/api/client/servers/real-id/upgrade/renew":
			mu.Lock()
			renewedPath = r.URL.Path
			mu.Unlock()
			writeJSON(t, w, http.StatusOK, map[string]any{"expires_at": "2026-10-01T00:00:00Z"})
		case r.URL.Path == "/botbot-token/sendMessage":
			if err := r.ParseForm(); err != nil {
				t.Fatal(err)
			}
			mu.Lock()
			notification = r.Form.Get("text")
			mu.Unlock()
			writeJSON(t, w, http.StatusOK, map[string]any{"ok": true})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	config := testConfig(t, server.URL)
	result, err := Check(context.Background(), config)
	if err != nil {
		t.Fatalf("Check returned error: %v", err)
	}
	if !result.Renewed || result.Skipped {
		t.Fatalf("unexpected result: %+v", result)
	}
	mu.Lock()
	defer mu.Unlock()
	if renewedPath == "" {
		t.Fatal("renew endpoint was not called")
	}
	if !strings.Contains(notification, "自动延期成功") || !strings.Contains(notification, "My Bot") {
		t.Fatalf("unexpected notification: %q", notification)
	}
}

func TestCheckRenewsEligibleServiceWhenPanelAutoRenewIsEnabled(t *testing.T) {
	renewCalls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api/client":
			writeJSON(t, w, http.StatusOK, map[string]any{"data": []any{
				map[string]any{"object": "server", "attributes": map[string]any{
					"identifier": "real-id", "uuid": "full-uuid", "name": "My Bot",
					"expires_at": "2026-09-25T08:00:00Z", "can_renew": true,
					"auto_renew": true, "free_renewals_remaining": 1,
				}},
			}})
		case r.URL.Path == "/api/client/servers/real-id/upgrade/renew":
			renewCalls++
			writeJSON(t, w, http.StatusOK, map[string]any{"expires_at": "2026-09-29T08:00:00Z"})
		case r.URL.Path == "/api/client/servers/real-id":
			writeJSON(t, w, http.StatusOK, map[string]any{
				"attributes": map[string]any{"expires_at": "2026-09-29T08:00:00Z"},
			})
		case r.URL.Path == "/botbot-token/sendMessage":
			writeJSON(t, w, http.StatusOK, map[string]any{"ok": true})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	result, err := Check(context.Background(), testConfig(t, server.URL))
	if err != nil {
		t.Fatalf("Check returned error: %v", err)
	}
	if renewCalls != 1 {
		t.Fatalf("renew endpoint calls = %d, want 1", renewCalls)
	}
	if !result.Renewed || result.Skipped {
		t.Fatalf("unexpected result: %+v", result)
	}
}

func TestCheckTreatsRenewalNotAvailableAsSuccessWithoutNotification(t *testing.T) {
	notified := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api/client":
			writeJSON(t, w, http.StatusOK, map[string]any{"data": []any{
				map[string]any{"object": "server", "attributes": map[string]any{
					"identifier": "real-id", "uuid": "full-uuid", "can_renew": true,
				}},
			}})
		case r.URL.Path == "/api/client/servers/real-id/upgrade/renew":
			writeJSON(t, w, http.StatusBadRequest, map[string]any{"error": "renewal_not_available"})
		case strings.HasPrefix(r.URL.Path, "/bot"):
			notified = true
			writeJSON(t, w, http.StatusOK, map[string]any{"ok": true})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	result, err := Check(context.Background(), testConfig(t, server.URL))
	if err != nil {
		t.Fatalf("Check returned error: %v", err)
	}
	if !result.Skipped || result.Renewed || !strings.Contains(result.Message, "normal state") {
		t.Fatalf("unexpected result: %+v", result)
	}
	if notified {
		t.Fatal("normal renewal_not_available result should not notify")
	}
}

func TestCaptchaSolverFailureTriggersNotification(t *testing.T) {
	notification := ""
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api/client":
			writeJSON(t, w, http.StatusOK, map[string]any{"data": []any{
				map[string]any{"object": "server", "attributes": map[string]any{
					"identifier": "real-id", "uuid": "full-uuid", "can_renew": true,
				}},
			}})
		case r.URL.Path == "/api/client/servers/real-id/upgrade/renew":
			writeJSON(t, w, http.StatusForbidden, map[string]any{"error": "captcha_required"})
		case strings.HasPrefix(r.URL.Path, "/bot"):
			if err := r.ParseForm(); err != nil {
				t.Fatal(err)
			}
			notification = r.Form.Get("text")
			writeJSON(t, w, http.StatusOK, map[string]any{"ok": true})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	config := testConfig(t, server.URL)
	config.captchaSolver = func(context.Context) (string, error) {
		return "", errors.New("offline solver failure")
	}
	Check(context.Background(), config)
	if !strings.Contains(notification, "CAPTCHA solve failed") {
		t.Fatalf("solver failure notification missing: %q", notification)
	}
}

func TestRenewAfterCaptchaUsesCurrentXsrfTokenWithoutStaleMetaToken(t *testing.T) {
	const verificationToken = "captcha-verification"

	authorized := false
	renewalCalls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api/client" && !authorized:
			writeJSON(t, w, http.StatusUnauthorized, map[string]any{"message": "Unauthenticated"})
		case r.URL.Path == "/auth/login" && r.Method == http.MethodGet:
			http.SetCookie(w, &http.Cookie{Name: "XSRF-TOKEN", Value: "xsrf-login", Path: "/"})
			w.Header().Set("Content-Type", "text/html")
			_, _ = w.Write([]byte(`<meta name="csrf-token" content="stale-meta-token">`))
		case r.URL.Path == "/auth/login" && r.Method == http.MethodPost:
			authorized = true
			http.SetCookie(w, &http.Cookie{Name: "XSRF-TOKEN", Value: "xsrf-active", Path: "/"})
			http.SetCookie(w, &http.Cookie{Name: "__Host-aclclouds_session", Value: "session", Path: "/"})
			writeJSON(t, w, http.StatusOK, map[string]any{"ok": true})
		case r.URL.Path == "/api/client":
			writeJSON(t, w, http.StatusOK, map[string]any{"data": []any{
				map[string]any{"object": "server", "attributes": map[string]any{
					"identifier": "real-id", "uuid": "full-uuid", "name": "My Bot",
					"expires_at": "2026-09-25T08:00:00Z", "can_renew": true,
				}},
			}})
		case r.URL.Path == "/api/client/servers/real-id/upgrade/renew":
			renewalCalls++
			if renewalCalls == 1 {
				writeJSON(t, w, http.StatusForbidden, map[string]any{"error": "captcha_required"})
				return
			}
			var body map[string]string
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if body["captcha_token"] != verificationToken {
				t.Errorf("renew captcha_token = %q, want configured Cap token", body["captcha_token"])
			}
			if r.Header.Get("X-XSRF-TOKEN") != "xsrf-active" || r.Header.Get("X-CSRF-TOKEN") != "" {
				writeJSON(t, w, 419, map[string]any{"errors": []any{map[string]any{
					"code": "HttpException", "status": "419", "detail": "CSRF token mismatch.",
				}}})
				return
			}
			writeJSON(t, w, http.StatusOK, map[string]any{"expires_at": "2026-09-29T08:00:00Z"})
		case r.URL.Path == "/api/client/servers/real-id":
			writeJSON(t, w, http.StatusOK, map[string]any{
				"attributes": map[string]any{"expires_at": "2026-09-29T08:00:00Z"},
			})
		case strings.HasPrefix(r.URL.Path, "/bot"):
			writeJSON(t, w, http.StatusOK, map[string]any{"ok": true})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	config := testConfig(t, server.URL)
	config.captchaSolver = func(context.Context) (string, error) { return verificationToken, nil }
	result, err := Check(context.Background(), config)
	if err != nil {
		t.Fatalf("Check returned error: %v", err)
	}
	if !result.Renewed || renewalCalls != 2 {
		t.Fatalf("unexpected result after CAPTCHA: %+v, renew calls=%d", result, renewalCalls)
	}
}

func TestFailureIsReportedAfterTheCheckRanOutOfTime(t *testing.T) {
	notification := ""
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/bot") {
			if err := r.ParseForm(); err != nil {
				t.Fatal(err)
			}
			notification = r.Form.Get("text")
			writeJSON(t, w, http.StatusOK, map[string]any{"ok": true})
			return
		}
		http.NotFound(w, r)
	}))
	defer server.Close()

	ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	if _, err := Check(ctx, testConfig(t, server.URL)); err == nil {
		t.Fatal("Check succeeded with an expired context")
	}
	if !strings.Contains(notification, "自动延期需要处理") {
		t.Fatalf("timeout failure was not reported: %q", notification)
	}
}

func TestInterruptedCheckIsNotReported(t *testing.T) {
	notified := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/bot") {
			notified = true
		}
		writeJSON(t, w, http.StatusOK, map[string]any{"ok": true})
	}))
	defer server.Close()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Check(ctx, testConfig(t, server.URL)); err == nil {
		t.Fatal("Check succeeded with a canceled context")
	}
	if notified {
		t.Fatal("a check interrupted by shutdown must not send a notification")
	}
}

func TestRenewalLogsInAgainWhenTheSessionExpiresMidway(t *testing.T) {
	loggedIn := false
	renewCalls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api/client":
			writeJSON(t, w, http.StatusOK, map[string]any{"data": []any{
				map[string]any{"object": "server", "attributes": map[string]any{
					"identifier": "real-id", "uuid": "full-uuid", "can_renew": true,
				}},
			}})
		case r.URL.Path == "/auth/login" && r.Method == http.MethodGet:
			http.SetCookie(w, &http.Cookie{Name: "XSRF-TOKEN", Value: "xsrf-fresh", Path: "/"})
			w.Header().Set("Content-Type", "text/html")
			_, _ = w.Write([]byte(`<html></html>`))
		case r.URL.Path == "/auth/login" && r.Method == http.MethodPost:
			loggedIn = true
			writeJSON(t, w, http.StatusOK, map[string]any{"ok": true})
		case r.URL.Path == "/api/client/servers/real-id/upgrade/renew":
			renewCalls++
			if !loggedIn {
				// Laravel answers an expired CSRF token with 419 Page Expired.
				writeJSON(t, w, 419, map[string]any{"message": "CSRF token mismatch."})
				return
			}
			writeJSON(t, w, http.StatusOK, map[string]any{"expires_at": "2026-10-01T00:00:00Z"})
		case strings.HasPrefix(r.URL.Path, "/bot"):
			writeJSON(t, w, http.StatusOK, map[string]any{"ok": true})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	result, err := Check(context.Background(), testConfig(t, server.URL))
	if err != nil {
		t.Fatalf("Check returned error: %v", err)
	}
	if !loggedIn || renewCalls != 2 || !result.Renewed {
		t.Fatalf("expected a login and a successful retry: loggedIn=%v renewCalls=%d result=%+v", loggedIn, renewCalls, result)
	}
}

func TestCaptchaRequiredLooksAtErrorFieldsOnly(t *testing.T) {
	cases := []struct {
		status int
		body   string
		want   bool
	}{
		{http.StatusForbidden, `{"error":"captcha_required"}`, true},
		{http.StatusUnprocessableEntity, `{"message":"The given data was invalid.","errors":{"captcha":["required"]}}`, true},
		{http.StatusUnprocessableEntity, `{"captcha_required":true}`, true},
		{http.StatusForbidden, `<html>Please solve the CAPTCHA</html>`, true},
		{http.StatusUnprocessableEntity, `{"message":"These credentials do not match our records.","captcha_site_key":"key"}`, false},
		{http.StatusUnprocessableEntity, `{"message":"Invalid password","captcha_enabled":false}`, false},
		{http.StatusBadRequest, `{"error":"captcha_required"}`, false},
	}
	for _, tc := range cases {
		if got := captchaRequired(httpResult{Status: tc.status, Body: []byte(tc.body)}); got != tc.want {
			t.Errorf("captchaRequired(%d, %s) = %v, want %v", tc.status, tc.body, got, tc.want)
		}
	}
}

func TestSelectServerNeverGuessesUUIDPrefix(t *testing.T) {
	servers := []server{{Identifier: "abc12345", UUID: "abc12345-full"}}
	if _, err := selectServer(servers, "abc123"); err == nil {
		t.Fatal("short prefix must not match a service")
	}
	if selected, err := selectServer(servers, "abc12345-full"); err != nil || selected.Identifier != "abc12345" {
		t.Fatalf("full UUID should select the API identifier: %+v, %v", selected, err)
	}
}

func TestExpiredSessionUsesPureHTTPLoginAndPersistsCookies(t *testing.T) {
	authorized := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/auth/login" && r.Method == http.MethodGet:
			http.SetCookie(w, &http.Cookie{Name: "XSRF-TOKEN", Value: "xsrf-value", Path: "/"})
			w.Header().Set("Content-Type", "text/html")
			_, _ = w.Write([]byte(`<html><head><meta name="csrf-token" content="csrf-value"></head></html>`))
		case r.URL.Path == "/auth/login" && r.Method == http.MethodPost:
			if r.Header.Get("X-XSRF-TOKEN") != "xsrf-value" || r.Header.Get("X-CSRF-TOKEN") != "" {
				t.Fatalf("request must prefer the current XSRF cookie over the meta CSRF token: %#v", r.Header)
			}
			var body map[string]string
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if body["user"] != "person@example.com" || body["password"] != "password" {
				t.Fatalf("unexpected login payload: %#v", body)
			}
			authorized = true
			http.SetCookie(w, &http.Cookie{Name: "__Host-aclclouds_session", Value: "session-value", Path: "/"})
			writeJSON(t, w, http.StatusOK, map[string]any{"ok": true})
		case r.URL.Path == "/api/client" && !authorized:
			writeJSON(t, w, http.StatusUnauthorized, map[string]any{"message": "Unauthenticated"})
		case r.URL.Path == "/api/client":
			writeJSON(t, w, http.StatusOK, map[string]any{"data": []any{
				map[string]any{"object": "server", "attributes": map[string]any{
					"identifier": "real-id", "uuid": "full-uuid", "can_renew": false,
				}},
			}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	config := testConfig(t, server.URL)
	config.TelegramBotToken = ""
	config.TelegramChatID = ""
	result, err := Check(context.Background(), config)
	if err != nil {
		t.Fatalf("Check returned error: %v", err)
	}
	if !result.Skipped {
		t.Fatalf("expected can_renew=false to skip: %+v", result)
	}
	info, err := os.Stat(config.AuthStatePath)
	if err != nil {
		t.Fatalf("auth state was not saved: %v", err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatalf("auth state mode = %o, want 600", info.Mode().Perm())
	}
}

func TestLoadConfigAllowsTelegramToBeOmitted(t *testing.T) {
	t.Setenv("AUTO_RENEW_ENABLED", "1")
	t.Setenv("ACL_USERNAME", "person@example.com")
	t.Setenv("ACL_PASSWORD", "password")
	t.Setenv("P_SERVER_UUID", "full-uuid")
	t.Setenv("TELEGRAM_BOT_TOKEN", "")
	t.Setenv("TELEGRAM_CHAT_ID", "")
	config, err := LoadConfigFromEnv()
	if err != nil {
		t.Fatalf("LoadConfigFromEnv rejected optional Telegram settings: %v", err)
	}
	if err := notifyTelegram(context.Background(), config, "not sent"); err != nil {
		t.Fatalf("disabled Telegram should be a no-op: %v", err)
	}
}

func TestLoadConfigRejectsPartialTelegramConfiguration(t *testing.T) {
	t.Setenv("AUTO_RENEW_ENABLED", "1")
	t.Setenv("ACL_USERNAME", "person@example.com")
	t.Setenv("ACL_PASSWORD", "password")
	t.Setenv("P_SERVER_UUID", "full-uuid")
	t.Setenv("TELEGRAM_BOT_TOKEN", "123:token")
	t.Setenv("TELEGRAM_CHAT_ID", "")
	if _, err := LoadConfigFromEnv(); err == nil || !strings.Contains(err.Error(), "configured together") {
		t.Fatalf("LoadConfigFromEnv error = %v, want paired Telegram validation", err)
	}
}

func testConfig(t *testing.T, baseURL string) Config {
	t.Helper()
	return Config{
		Enabled:          true,
		BaseURL:          baseURL,
		Username:         "person@example.com",
		Password:         "password",
		ServerSelector:   "full-uuid",
		AuthStatePath:    filepath.Join(t.TempDir(), "acl-auth.json"),
		TelegramBotToken: "bot-token",
		TelegramChatID:   "123",
		TelegramAPIBase:  baseURL,
	}
}

func writeJSON(t *testing.T, w http.ResponseWriter, status int, value any) {
	t.Helper()
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		t.Fatal(err)
	}
}
