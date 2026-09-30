// ACLCloudFreeBotToolKit
// Copyright (C) 2026 MessyMidi
//
// SPDX-License-Identifier: AGPL-3.0-only
// Additional terms under AGPLv3 Section 7:
// see /ADDITIONAL_TERMS.md

package renew

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestCapClientChallengeAndRedeemProtocolOffline(t *testing.T) {
	const (
		challengeToken = "challenge-secret"
		redeemToken    = "redeem-secret"
	)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Origin") != capSiteOrigin || r.Header.Get("Referer") != capSiteOrigin+"/" {
			t.Errorf("unexpected Cap request origin headers: %#v", r.Header)
		}
		switch r.URL.Path {
		case "/challenge":
			writeJSON(t, w, http.StatusOK, map[string]any{
				"token":  challengeToken,
				"format": 2,
				"challenges": []any{
					map[string]any{"protocol": "hashwx", "payload": map[string]any{"c": "first", "d": 10, "n": 20}},
					map[string]any{"protocol": "hashwx", "payload": map[string]any{"c": "second", "d": 30, "n": 40}},
				},
			})
		case "/redeem":
			var body struct {
				Token     string        `json:"token"`
				Solutions []capSolution `json:"solutions"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if body.Token != challengeToken {
				t.Errorf("challenge token changed: %q", body.Token)
			}
			if len(body.Solutions) != 2 || body.Solutions[0].Nonce != "101" || body.Solutions[1].Nonce != "202" {
				t.Errorf("unexpected ordered solutions: %#v", body.Solutions)
			}
			writeJSON(t, w, http.StatusOK, map[string]any{"success": true, "token": redeemToken})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	solver := func(_ context.Context, payload hashwxPayload) (capSolution, error) {
		switch payload.Challenge {
		case "first":
			return capSolution{Nonce: "101"}, nil
		case "second":
			return capSolution{Nonce: "202"}, nil
		default:
			return capSolution{}, errors.New("unexpected synthetic challenge")
		}
	}
	client := newCapClient(server.Client(), server.URL, solver)
	token, err := client.fetchToken(context.Background())
	if err != nil {
		t.Fatalf("fetchToken returned error: %v", err)
	}
	if token != redeemToken {
		t.Fatalf("redeem token = %q, want %q", token, redeemToken)
	}
}

func TestCapClientRejectsUnsupportedProtocolWithoutSolving(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(t, w, http.StatusOK, map[string]any{
			"token":  "challenge-token",
			"format": 2,
			"challenges": []any{
				map[string]any{"protocol": "unknown", "payload": map[string]any{"c": "unused", "d": 1, "n": 1}},
			},
		})
	}))
	defer server.Close()

	client := newCapClient(server.Client(), server.URL, func(context.Context, hashwxPayload) (capSolution, error) {
		calls.Add(1)
		return capSolution{}, nil
	})
	_, err := client.fetchToken(context.Background())
	if err == nil || !strings.Contains(err.Error(), "unsupported protocol") {
		t.Fatalf("fetchToken error = %v, want unsupported protocol", err)
	}
	if calls.Load() != 0 {
		t.Fatalf("solver called %d times for unsupported protocol", calls.Load())
	}
}

func TestCapClientDoesNotExposeResponseSecretsInErrors(t *testing.T) {
	const secret = "one-time-secret-material"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, secret, http.StatusUnprocessableEntity)
	}))
	defer server.Close()

	client := newCapClient(server.Client(), server.URL, func(context.Context, hashwxPayload) (capSolution, error) {
		return capSolution{}, nil
	})
	_, err := client.fetchToken(context.Background())
	if err == nil {
		t.Fatal("fetchToken unexpectedly succeeded")
	}
	if strings.Contains(err.Error(), secret) {
		t.Fatalf("response secret leaked through error: %v", err)
	}
}

func TestSolveCaptchaUsesConfiguredProviderWithoutLoggingToken(t *testing.T) {
	const token = "private-cap-token"
	s := &session{captchaSolver: func(context.Context) (string, error) { return token, nil }}
	got, err := solveCaptcha(context.Background(), s, "login")
	if err != nil {
		t.Fatalf("solveCaptcha returned error: %v", err)
	}
	if got != token {
		t.Fatalf("solveCaptcha token = %q, want configured token", got)
	}
}

func TestLoginRetriesWithCapTokenOnly(t *testing.T) {
	const token = "private-cap-token"
	postCount := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/auth/login" && r.Method == http.MethodGet:
			http.SetCookie(w, &http.Cookie{Name: "XSRF-TOKEN", Value: "xsrf", Path: "/"})
			_, _ = w.Write([]byte(`<meta name="csrf-token" content="csrf">`))
		case r.URL.Path == "/auth/login" && r.Method == http.MethodPost:
			postCount++
			var body map[string]string
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if postCount == 1 {
				writeJSON(t, w, http.StatusUnprocessableEntity, map[string]any{"error": "captcha_required"})
				return
			}
			if body["captcha_token"] != token {
				t.Errorf("captcha_token = %q, want configured Cap token", body["captcha_token"])
			}
			if _, exists := body["captcha_data"]; exists {
				t.Error("legacy captcha_data must not be sent")
			}
			writeJSON(t, w, http.StatusOK, map[string]any{"ok": true})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	config := testConfig(t, server.URL)
	config.captchaSolver = func(context.Context) (string, error) { return token, nil }
	s, err := newSession(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.login(context.Background(), config.Username, config.Password); err != nil {
		t.Fatalf("login returned error: %v", err)
	}
	if postCount != 2 {
		t.Fatalf("login POST count = %d, want 2", postCount)
	}
}

func TestEmbeddedHashwxArtifactAndInputValidation(t *testing.T) {
	const expectedSHA256 = "b1a0dbb3ef444d3c7069e0a5e0a0273ffa4cf8fef62cbbe43761c02f7cd6aff5"
	sum := sha256.Sum256(embeddedHashwxWASM)
	if got := hex.EncodeToString(sum[:]); got != expectedSHA256 {
		t.Fatalf("embedded hashwx.wasm SHA-256 = %s, want %s", got, expectedSHA256)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	solver, err := newHashwxSolver(ctx, embeddedHashwxWASM)
	if err != nil {
		t.Fatalf("instantiate embedded hashwx.wasm: %v", err)
	}
	defer solver.close()
	if _, _, err := solver.solve(hashwxPayload{Challenge: "not-hex", Difficulty: 1, BlockSize: 1}); err == nil {
		t.Fatal("invalid synthetic payload unexpectedly reached hash computation")
	}
}
