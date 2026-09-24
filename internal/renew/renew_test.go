// ACLCloudFreeBotToolKit
// Copyright (C) 2026 MessyMidi
//
// SPDX-License-Identifier: AGPL-3.0-only
// Additional terms under AGPLv3 Section 7:
// see /ADDITIONAL_TERMS.md

package renew

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
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
	var captchaPostCount int
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
		case r.URL.Path == "/auth/captcha/challenge" && r.Method == http.MethodGet:
			writeJSON(t, w, http.StatusOK, map[string]any{
				"id":      "ch-1",
				"ts":      1727172000,
				"sig":     "sig1",
				"context": "renewal_gate",
			})
		case r.URL.Path == "/auth/captcha" && r.Method == http.MethodPost:
			captchaPostCount++
			if captchaPostCount == 1 {
				// Challenge request — return valid options.
				writeJSON(t, w, http.StatusOK, map[string]any{
					"interactive": true,
					"options":     []string{"tok_a", "tok_b", "tok_c", "tok_d"},
					"answer_sig":  "asig",
					"target":      "NotFoundWord", // forces solver failure
					"id":          "ch-1",
					"ts":          1727172000,
					"sig":         "sig1",
					"context":     "renewal_gate",
				})
			} else {
				// Verify request — reject.
				writeJSON(t, w, http.StatusOK, map[string]any{"passed": false})
			}
		case strings.HasPrefix(r.URL.Path, "/auth/captcha/image"):
			// Return a minimal valid 46x200 black PNG.
			w.Header().Set("Content-Type", "image/png")
			w.WriteHeader(http.StatusOK)
			encodePNG(w, 200, 46)
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

	Check(context.Background(), testConfig(t, server.URL))
	if !strings.Contains(notification, "CAPTCHA solve failed") {
		t.Fatalf("solver failure notification missing: %q", notification)
	}
}

func TestCaptchaSolverReturnsVerifiedTokenWithoutLoggingSecrets(t *testing.T) {
	const optionToken = "option-secret+/="
	const verificationToken = "verification-secret"
	imageData := patternedCaptchaPNG(t)
	pixels, width, height, err := decodeCaptchaImage(imageData)
	if err != nil {
		t.Fatalf("decode reference image: %v", err)
	}
	cols, rows := extractProfiles(pixels, width, height)
	originalReferences := precomputedRef
	precomputedRef = []precomputedWord{{word: "ExpectedWord", colProfile: cols, rowProfile: rows}}
	t.Cleanup(func() { precomputedRef = originalReferences })

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/auth/captcha/challenge" && r.Method == http.MethodGet:
			writeJSON(t, w, http.StatusOK, map[string]any{
				"id":      "challenge-id",
				"ts":      1727172000,
				"sig":     "signature",
				"context": "renewal_gate",
			})
		case r.URL.Path == "/auth/captcha/image" && r.Method == http.MethodGet:
			if got := r.URL.Query().Get("t"); got != optionToken {
				t.Errorf("captcha option token = %q, want original token", got)
			}
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(imageData)
		case r.URL.Path == "/auth/captcha" && r.Method == http.MethodPost:
			var body map[string]any
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if _, verifying := body["answer"]; verifying {
				if body["answer"] != optionToken {
					t.Errorf("submitted answer = %q", body["answer"])
				}
				writeJSON(t, w, http.StatusOK, map[string]any{"passed": true, "token": verificationToken})
				return
			}
			writeJSON(t, w, http.StatusOK, map[string]any{
				"interactive": true,
				"options":     []string{optionToken},
				"answer_sig":  "answer-signature",
				"target":      "ExpectedWord",
				"id":          "challenge-id",
				"ts":          1727172000,
				"sig":         "signature",
				"context":     "renewal_gate",
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	s, err := newSession(testConfig(t, server.URL))
	if err != nil {
		t.Fatal(err)
	}
	var logs bytes.Buffer
	originalLogOutput := log.Writer()
	log.SetOutput(&logs)
	t.Cleanup(func() { log.SetOutput(originalLogOutput) })

	token, err := solveCaptcha(context.Background(), s, "renewal_gate")
	if err != nil {
		t.Fatalf("solveCaptcha returned error: %v", err)
	}
	if token != verificationToken {
		t.Fatalf("verification token = %q, want %q", token, verificationToken)
	}
	if strings.Contains(logs.String(), optionToken) || strings.Contains(logs.String(), verificationToken) {
		t.Fatalf("captcha secrets leaked to logs: %s", logs.String())
	}
}

func TestDecodeCaptchaImageRejectsUnexpectedDimensions(t *testing.T) {
	var data bytes.Buffer
	if err := png.Encode(&data, image.NewGray(image.Rect(0, 0, 10, 10))); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := decodeCaptchaImage(data.Bytes()); !errorsIs(err, errImageDecode) {
		t.Fatalf("decodeCaptchaImage error = %v, want errImageDecode", err)
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
			if r.Header.Get("X-XSRF-TOKEN") != "xsrf-value" || r.Header.Get("X-CSRF-TOKEN") != "csrf-value" {
				t.Fatalf("missing CSRF headers: %#v", r.Header)
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

// encodePNG encodes a uniform dark-gray PNG of the given width and height to w.
func encodePNG(w http.ResponseWriter, width, height int) {
	img := image.NewGray(image.Rect(0, 0, width, height))
	// Fill with dark gray so pixels are above zero.
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			img.SetGray(x, y, color.Gray{Y: 32})
		}
	}
	if err := png.Encode(w, img); err != nil {
		// Nothing we can do at this point.
	}
}

func patternedCaptchaPNG(t *testing.T) []byte {
	t.Helper()
	img := image.NewGray(image.Rect(0, 0, captchaCols, captchaRows))
	for y := 0; y < captchaRows; y++ {
		for x := 0; x < captchaCols; x++ {
			img.SetGray(x, y, color.Gray{Y: 255})
		}
	}
	for y := 9; y < 29; y++ {
		for x := 17; x < 37; x++ {
			img.SetGray(x, y, color.Gray{Y: 0})
		}
	}
	var data bytes.Buffer
	if err := png.Encode(&data, img); err != nil {
		t.Fatal(err)
	}
	return data.Bytes()
}

func errorsIs(err, target error) bool {
	for err != nil {
		if err == target {
			return true
		}
		type unwrapper interface{ Unwrap() error }
		unwrapped, ok := err.(unwrapper)
		if !ok {
			return false
		}
		err = unwrapped.Unwrap()
	}
	return false
}
