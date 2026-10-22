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
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestLoginInitializesSanctumAndRefreshesOnceOn419(t *testing.T) {
	csrfCalls, loginCalls := 0, 0
	panel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/auth/login":
			if r.Method == http.MethodGet {
				_, _ = w.Write([]byte(`<meta name="csrf-token" content="stale-meta">`))
				return
			}
			loginCalls++
			var payload map[string]string
			_ = json.NewDecoder(r.Body).Decode(&payload)
			if payload["user"] != "test-user" || payload["password"] != "test-password" {
				t.Error("login payload was not preserved")
			}
			if loginCalls == 1 {
				if r.Header.Get("X-XSRF-TOKEN") != "initial" {
					t.Error("login did not initialize Sanctum cookies")
				}
				w.WriteHeader(419)
				return
			}
			if r.Header.Get("X-XSRF-TOKEN") != "refreshed" || r.Header.Get("X-CSRF-TOKEN") != "" {
				t.Error("login retry used stale CSRF headers")
			}
			writeJSON(t, w, 200, map[string]any{"data": map[string]any{"complete": true}})
		case "/sanctum/csrf-cookie":
			csrfCalls++
			value := "initial"
			if csrfCalls > 1 {
				value = "refreshed"
			}
			http.SetCookie(w, &http.Cookie{Name: "XSRF-TOKEN", Value: value, Path: "/"})
			w.WriteHeader(204)
		default:
			http.NotFound(w, r)
		}
	}))
	defer panel.Close()
	s, err := newSession(testConfig(t, panel.URL))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.login(context.Background(), "test-user", "test-password"); err != nil {
		t.Fatal(err)
	}
	if loginCalls != 2 || csrfCalls != 2 {
		t.Fatalf("login=%d csrf=%d, want 2 each", loginCalls, csrfCalls)
	}
}

func TestCSRFRefreshRetainsSessionAndBoundsRequestRetries(t *testing.T) {
	for _, persistent := range []bool{false, true} {
		name := "recovers"
		if persistent {
			name = "persistent-419"
		}
		t.Run(name, func(t *testing.T) {
			posts, refreshes := 0, 0
			panel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/sanctum/csrf-cookie" {
					refreshes++
					cookie, err := r.Cookie("__Host-aclclouds_session")
					if err != nil || cookie.Value != "existing-session" {
						t.Error("refresh discarded the current session")
					}
					http.SetCookie(w, &http.Cookie{Name: "XSRF-TOKEN", Value: "new%2Btoken", Path: "/"})
					w.WriteHeader(204)
					return
				}
				posts++
				var payload map[string]string
				_ = json.NewDecoder(r.Body).Decode(&payload)
				if payload["captcha_token"] != "mock-only-token" {
					t.Error("CSRF retry lost the request payload")
				}
				if persistent || posts == 1 {
					w.WriteHeader(419)
					return
				}
				if r.Header.Get("X-XSRF-TOKEN") != "new+token" || r.Header.Get("X-CSRF-TOKEN") != "" {
					t.Error("retry did not use the refreshed cookie")
				}
				writeJSON(t, w, 200, map[string]any{"ok": true})
			}))
			defer panel.Close()
			s, err := newSession(testConfig(t, panel.URL))
			if err != nil {
				t.Fatal(err)
			}
			s.client.Jar.SetCookies(s.baseURL, []*http.Cookie{
				{Name: "__Host-aclclouds_session", Value: "existing-session", Path: "/"},
				{Name: "XSRF-TOKEN", Value: "old-token", Path: "/"},
			})
			s.csrfToken = "stale-meta"
			result, err := s.request(context.Background(), http.MethodPost, "/api/client/servers/test/upgrade/renew", map[string]string{"captcha_token": "mock-only-token"})
			if err != nil {
				t.Fatal(err)
			}
			wantStatus := 200
			if persistent {
				wantStatus = 419
			}
			if result.Status != wantStatus || posts != 2 || refreshes != 1 {
				t.Fatalf("status=%d posts=%d refreshes=%d", result.Status, posts, refreshes)
			}
		})
	}
}

func TestCSRFRefreshFailureDoesNotReplayPost(t *testing.T) {
	for _, refreshStatus := range []int{404, 503} {
		posts, refreshes := 0, 0
		panel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/sanctum/csrf-cookie" {
				refreshes++
				w.WriteHeader(refreshStatus)
				return
			}
			posts++
			w.WriteHeader(419)
		}))
		s, err := newSession(testConfig(t, panel.URL))
		if err != nil {
			t.Fatal(err)
		}
		result, err := s.request(context.Background(), http.MethodPost, "/test", map[string]any{})
		panel.Close()
		if err != nil || result.Status != 419 || posts != 1 || refreshes != 1 {
			t.Fatalf("refresh HTTP %d: result=%+v err=%v posts=%d refreshes=%d", refreshStatus, result, err, posts, refreshes)
		}
	}
}

func TestRequestsOutsideMutating419AreNotReplayed(t *testing.T) {
	for _, tc := range []struct {
		method string
		status int
	}{
		{http.MethodGet, 419},
		{http.MethodPost, 401},
		{http.MethodPost, 403},
		{http.MethodPost, 422},
		{http.MethodPost, 429},
		{http.MethodPost, 500},
	} {
		calls := 0
		panel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			calls++
			if r.URL.Path != "/test" {
				t.Error("unexpected refresh for a non-CSRF request")
			}
			w.WriteHeader(tc.status)
		}))
		s, err := newSession(testConfig(t, panel.URL))
		if err != nil {
			t.Fatal(err)
		}
		result, err := s.request(context.Background(), tc.method, "/test", nil)
		panel.Close()
		if err != nil || calls != 1 || result.Status != tc.status {
			t.Fatalf("%s HTTP %d: calls=%d status=%d err=%v", tc.method, tc.status, calls, result.Status, err)
		}
	}
}

func TestRenewalRequiresEvidenceAndRejectsPayment(t *testing.T) {
	const before = "2026-10-14T00:00:00Z"
	const after = "2026-10-18T00:00:00Z"
	cases := []struct {
		name         string
		before       string
		body         string
		detailStatus int
		detailBody   string
		wantRenewed  bool
		wantError    string
	}{
		{"advanced-detail", before, `{"message":"ok"}`, 200, `{"attributes":{"expires_at":"` + after + `"}}`, true, ""},
		{"advanced-response-detail-unavailable", before, `{"expires_at":"` + after + `"}`, 503, `{}`, true, ""},
		{"unchanged-detail-overrides-response", before, `{"expires_at":"` + after + `"}`, 200, `{"attributes":{"expires_at":"` + before + `"}}`, false, "did not advance"},
		{"payment", before, `{"requires_payment":true,"checkout_url":"https://payment.invalid/private"}`, 200, `{"attributes":{"expires_at":"` + after + `"}}`, false, "payment"},
		{"wrapped-payment", before, `{"data":{"requires_payment":true}}`, 503, `{}`, false, "payment"},
		{"checkout-only", before, `{"checkout_url":"https://payment.invalid/private"}`, 503, `{}`, false, "payment"},
		{"missing-new-expiry", before, `{"message":"ok"}`, 503, `{}`, false, "cannot confirm"},
		{"invalid-new-expiry", before, `{"expires_at":"not-a-date"}`, 404, `{}`, false, "cannot confirm"},
		{"missing-old-expiry", "", `{"expires_at":"` + after + `"}`, 404, `{}`, false, "cannot confirm"},
		{"invalid-old-expiry", "unknown", `{"expires_at":"` + after + `"}`, 404, `{}`, false, "cannot confirm"},
		{"false-success", before, `{"success":false}`, 200, `{"attributes":{"expires_at":"` + after + `"}}`, false, "did not confirm"},
		{"error-array", before, `{"errors":[{"detail":"Not renewed"}]}`, 200, `{"attributes":{"expires_at":"` + after + `"}}`, false, "did not confirm"},
		{"error-object", before, `{"errors":{"renew":["Not renewed"]}}`, 200, `{"attributes":{"expires_at":"` + after + `"}}`, false, "did not confirm"},
		{"no-error-flags", before, `{"success":true,"errors":[],"error":false,"expires_at":"` + after + `"}`, 503, `{}`, true, ""},
		{"html-response", before, `<html>Login</html>`, 200, `{"attributes":{"expires_at":"` + after + `"}}`, false, "cannot confirm"},
		{"detail-session-expired", before, `{"message":"ok"}`, 401, `{}`, false, "cannot confirm"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			posts := 0
			panel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodPost {
					posts++
					_, _ = w.Write([]byte(tc.body))
					return
				}
				w.WriteHeader(tc.detailStatus)
				_, _ = w.Write([]byte(tc.detailBody))
			}))
			defer panel.Close()
			s, err := newSession(testConfig(t, panel.URL))
			if err != nil {
				t.Fatal(err)
			}
			result, err := s.renew(context.Background(), server{Identifier: "test-id", ExpiresAt: tc.before})
			if result.Renewed != tc.wantRenewed || (tc.wantError == "" && err != nil) || (tc.wantError != "" && (err == nil || !strings.Contains(err.Error(), tc.wantError))) {
				t.Fatalf("result=%+v err=%v, want renewed=%v error containing %q", result, err, tc.wantRenewed, tc.wantError)
			}
			if posts != 1 {
				t.Fatalf("confirmation must not replay a successful POST: posts=%d", posts)
			}
			if err != nil && strings.Contains(err.Error(), "payment.invalid") {
				t.Fatal("error exposed a private checkout URL")
			}
		})
	}
}

func TestCheckConfirmationFailureDoesNotReloginOrReportSuccess(t *testing.T) {
	posts, logins := 0, 0
	notification := ""
	panel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/client":
			writeJSON(t, w, 200, map[string]any{"data": []any{
				map[string]any{"object": "server", "attributes": map[string]any{
					"identifier": "test-id", "uuid": "full-uuid", "can_renew": true,
					"expires_at": "2026-10-14T00:00:00Z",
				}},
			}})
		case "/api/client/servers/test-id/upgrade/renew":
			posts++
			writeJSON(t, w, 200, map[string]any{"message": "ok"})
		case "/api/client/servers/test-id":
			w.WriteHeader(401)
		case "/auth/login":
			logins++
			w.WriteHeader(500)
		case "/botbot-token/sendMessage":
			_ = r.ParseForm()
			notification = r.Form.Get("text")
			writeJSON(t, w, 200, map[string]any{"ok": true})
		default:
			http.NotFound(w, r)
		}
	}))
	defer panel.Close()
	result, err := Check(context.Background(), testConfig(t, panel.URL))
	if err == nil || result.Renewed || posts != 1 || logins != 0 {
		t.Fatalf("result=%+v err=%v posts=%d logins=%d", result, err, posts, logins)
	}
	if !strings.Contains(notification, "需要处理") || strings.Contains(notification, "自动延期成功") {
		t.Fatal("ambiguous confirmation must report attention, not success")
	}
}

func TestLoginCSRFRefreshPreservesMockVerificationToken(t *testing.T) {
	loginCalls, refreshes, providerCalls := 0, 0, 0
	panel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/sanctum/csrf-cookie" {
			refreshes++
			value := "initial"
			if refreshes > 1 {
				value = "fresh"
			}
			http.SetCookie(w, &http.Cookie{Name: "XSRF-TOKEN", Value: value, Path: "/"})
			w.WriteHeader(204)
			return
		}
		if r.Method == http.MethodGet {
			_, _ = w.Write([]byte(`<html></html>`))
			return
		}
		loginCalls++
		if loginCalls == 1 {
			writeJSON(t, w, 403, map[string]any{"error": "captcha_required"})
			return
		}
		var payload map[string]string
		_ = json.NewDecoder(r.Body).Decode(&payload)
		if payload["captcha_token"] != "mock-only-token" {
			t.Error("CSRF retry lost the mock verification token")
		}
		if loginCalls == 2 {
			w.WriteHeader(419)
			return
		}
		if r.Header.Get("X-XSRF-TOKEN") != "fresh" {
			t.Error("retry used stale cookies")
		}
		writeJSON(t, w, 200, map[string]any{"complete": true})
	}))
	defer panel.Close()
	config := testConfig(t, panel.URL)
	config.captchaSolver = func(context.Context) (string, error) {
		providerCalls++
		return "mock-only-token", nil
	}
	s, err := newSession(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.login(context.Background(), "test-user", "test-password"); err != nil {
		t.Fatal(err)
	}
	if loginCalls != 3 || refreshes != 2 || providerCalls != 1 {
		t.Fatalf("login=%d csrf=%d mock-provider=%d", loginCalls, refreshes, providerCalls)
	}
}

func TestCheckCSRFRefreshSavesLatestCookiesWithoutLogin(t *testing.T) {
	posts, logins := 0, 0
	panel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/client":
			writeJSON(t, w, 200, map[string]any{"data": []any{
				map[string]any{"object": "server", "attributes": map[string]any{
					"identifier": "test-id", "uuid": "full-uuid", "can_renew": true,
					"expires_at": "2026-10-14T00:00:00Z",
				}},
			}})
		case "/api/client/servers/test-id/upgrade/renew":
			posts++
			if posts == 1 {
				w.WriteHeader(419)
				return
			}
			writeJSON(t, w, 200, map[string]any{"expires_at": "2026-10-18T00:00:00Z"})
		case "/api/client/servers/test-id":
			writeJSON(t, w, 200, map[string]any{"attributes": map[string]any{"expires_at": "2026-10-18T00:00:00Z"}})
		case "/sanctum/csrf-cookie":
			http.SetCookie(w, &http.Cookie{Name: "XSRF-TOKEN", Value: "fresh-token", Path: "/"})
			http.SetCookie(w, &http.Cookie{Name: "__Host-aclclouds_session", Value: "refreshed-session", Path: "/"})
			w.WriteHeader(204)
		case "/auth/login":
			logins++
			w.WriteHeader(500)
		default:
			http.NotFound(w, r)
		}
	}))
	defer panel.Close()
	config := testConfig(t, panel.URL)
	config.TelegramBotToken, config.TelegramChatID = "", ""
	result, err := Check(context.Background(), config)
	if err != nil || !result.Renewed || posts != 2 || logins != 0 {
		t.Fatalf("result=%+v err=%v posts=%d logins=%d", result, err, posts, logins)
	}
	contents, err := os.ReadFile(config.AuthStatePath)
	if err != nil {
		t.Fatal(err)
	}
	var state authState
	if err := json.Unmarshal(contents, &state); err != nil {
		t.Fatal(err)
	}
	cookies := map[string]string{}
	for _, cookie := range state.Cookies {
		cookies[cookie.Name] = cookie.Value
	}
	if cookies["XSRF-TOKEN"] != "fresh-token" || cookies["__Host-aclclouds_session"] != "refreshed-session" {
		t.Fatal("auth cache retained stale cookies")
	}
}
