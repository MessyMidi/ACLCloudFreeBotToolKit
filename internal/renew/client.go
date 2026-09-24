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
	"errors"
	"fmt"
	"html"
	"io"
	"log"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const maxResponseBytes = 2 << 20

var csrfMetaPattern = regexp.MustCompile(`(?i)<meta\s+name=["']csrf-token["']\s+content=["']([^"']+)["']`)

type session struct {
	baseURL   *url.URL
	client    *http.Client
	csrfToken string
}

type authState struct {
	Version int            `json:"version"`
	Cookies []*http.Cookie `json:"cookies"`
	SavedAt time.Time      `json:"saved_at"`
}

type httpResult struct {
	Status int
	Header http.Header
	Body   []byte
}

func newSession(config Config) (*session, error) {
	baseURL, err := url.Parse(config.BaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse ACL base URL: %w", err)
	}
	jar, err := cookiejar.New(nil)
	if err != nil {
		return nil, fmt.Errorf("create cookie jar: %w", err)
	}
	s := &session{
		baseURL: baseURL,
		client: &http.Client{
			Jar:     jar,
			Timeout: 30 * time.Second,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				if len(via) >= 5 {
					return errors.New("too many redirects")
				}
				return nil
			},
		},
	}
	if err := s.loadAuthState(config.AuthStatePath); err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Printf("[renew] WARNING: cached auth state is unusable and will be refreshed: %v", err)
	}
	return s, nil
}

func (s *session) endpoint(path string) string {
	reference, _ := url.Parse(path)
	return s.baseURL.ResolveReference(reference).String()
}

func (s *session) request(ctx context.Context, method, path string, payload any) (httpResult, error) {
	var body io.Reader
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return httpResult{}, fmt.Errorf("encode request body: %w", err)
		}
		body = bytes.NewReader(encoded)
	}
	req, err := http.NewRequestWithContext(ctx, method, s.endpoint(path), body)
	if err != nil {
		return httpResult{}, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "ACLCloudFreeBotToolKit/acl-renew")
	req.Header.Set("X-Requested-With", "XMLHttpRequest")
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token := s.xsrfToken(); token != "" {
		req.Header.Set("X-XSRF-TOKEN", token)
	} else if s.csrfToken != "" {
		req.Header.Set("X-CSRF-TOKEN", s.csrfToken)
	}
	response, err := s.client.Do(req)
	if err != nil {
		return httpResult{}, err
	}
	defer response.Body.Close()
	contents, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if err != nil {
		return httpResult{}, fmt.Errorf("read response: %w", err)
	}
	return httpResult{Status: response.StatusCode, Header: response.Header.Clone(), Body: contents}, nil
}

func (s *session) xsrfToken() string {
	for _, cookie := range s.client.Jar.Cookies(s.baseURL) {
		if cookie.Name == "XSRF-TOKEN" {
			if decoded, err := url.QueryUnescape(cookie.Value); err == nil {
				return decoded
			}
			return cookie.Value
		}
	}
	return ""
}

func (s *session) openLogin(ctx context.Context) error {
	result, err := s.request(ctx, http.MethodGet, "/auth/login?return_to=%2Fen%2F", nil)
	if err != nil {
		return fmt.Errorf("open login page: %w", err)
	}
	if result.Status != http.StatusOK {
		return fmt.Errorf("open login page: HTTP %d", result.Status)
	}
	if match := csrfMetaPattern.FindSubmatch(result.Body); len(match) == 2 {
		s.csrfToken = html.UnescapeString(string(match[1]))
	}
	if s.xsrfToken() == "" && s.csrfToken == "" {
		return errors.New("login page did not provide an XSRF or CSRF token")
	}
	return nil
}

func (s *session) login(ctx context.Context, username, password string) error {
	if err := s.openLogin(ctx); err != nil {
		return err
	}
	payload := map[string]string{"user": username, "username": username, "password": password}
	result, err := s.request(ctx, http.MethodPost, "/auth/login", payload)
	if err != nil {
		return fmt.Errorf("login request: %w", err)
	}
	if result.Status >= 200 && result.Status < 400 && !captchaRequired(result) {
		return nil
	}
	if !captchaRequired(result) {
		return fmt.Errorf("login rejected: HTTP %d %s", result.Status, responseMessage(result.Body))
	}

	token, err := solveCaptcha(ctx, s, "login")
	if err != nil {
		return fmt.Errorf("login CAPTCHA solve failed: %w", err)
	}
	if strings.TrimSpace(token) == "" {
		return errors.New("login CAPTCHA solver returned an empty token")
	}
	payload["captcha_data"] = token
	payload["captcha_token"] = token
	result, err = s.request(ctx, http.MethodPost, "/auth/login", payload)
	if err != nil {
		return fmt.Errorf("login retry: %w", err)
	}
	if result.Status < 200 || result.Status >= 400 {
		return fmt.Errorf("login retry rejected: HTTP %d %s", result.Status, responseMessage(result.Body))
	}
	return nil
}

func (s *session) loadAuthState(path string) error {
	contents, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var state authState
	if err := json.Unmarshal(contents, &state); err != nil {
		return fmt.Errorf("parse auth state: %w", err)
	}
	if state.Version != 1 {
		return fmt.Errorf("unsupported auth state version %d", state.Version)
	}
	s.client.Jar.SetCookies(s.baseURL, state.Cookies)
	return nil
}

func (s *session) saveAuthState(path string) error {
	state := authState{Version: 1, Cookies: s.client.Jar.Cookies(s.baseURL), SavedAt: time.Now().UTC()}
	contents, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("encode auth state: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create auth state directory: %w", err)
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, append(contents, '\n'), 0o600); err != nil {
		return fmt.Errorf("write auth state: %w", err)
	}
	if err := os.Chmod(temporary, 0o600); err != nil {
		_ = os.Remove(temporary)
		return fmt.Errorf("protect auth state: %w", err)
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return fmt.Errorf("replace auth state: %w", err)
	}
	return nil
}

func captchaRequired(result httpResult) bool {
	if result.Status != http.StatusForbidden && result.Status != http.StatusUnprocessableEntity {
		return false
	}
	return strings.Contains(strings.ToLower(string(result.Body)), "captcha_required") ||
		strings.Contains(strings.ToLower(string(result.Body)), "captcha")
}

func responseMessage(body []byte) string {
	var data map[string]any
	if json.Unmarshal(body, &data) == nil {
		for _, key := range []string{"message", "error", "code"} {
			if value, ok := data[key].(string); ok && value != "" {
				return value
			}
		}
	}
	message := strings.TrimSpace(string(body))
	if len(message) > 180 {
		message = message[:180]
	}
	return message
}
