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
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type Result struct {
	Renewed bool
	Skipped bool
	Message string
}

// notificationTimeout gives each Telegram delivery its own deadline, so a
// check that ran out of time can still report that it needs attention.
const notificationTimeout = 15 * time.Second

// errSessionExpired marks a renewal request rejected because the login or the
// CSRF token expired. Both are rejected before the renewal runs, so logging in
// again and retrying cannot renew twice.
var errSessionExpired = errors.New("ACLClouds session expired during renewal")

type server struct {
	Identifier            string
	UUID                  string
	Name                  string
	ExpiresAt             string
	CanRenew              *bool
	FreeRenewalsRemaining *int
}

type attentionError struct {
	message string
	cause   error
}

func (e *attentionError) Error() string { return e.message }
func (e *attentionError) Unwrap() error { return e.cause }

func Check(ctx context.Context, config Config) (Result, error) {
	s, err := newSession(config)
	if err != nil {
		return fail(ctx, config, fmt.Errorf("create HTTP session: %w", err))
	}
	servers, unauthorized, err := s.listServers(ctx)
	if err != nil {
		return fail(ctx, config, err)
	}
	if unauthorized {
		if err := s.login(ctx, config.Username, config.Password); err != nil {
			return fail(ctx, config, err)
		}
		servers, unauthorized, err = s.listServers(ctx)
		if err != nil {
			return fail(ctx, config, err)
		}
		if unauthorized {
			return fail(ctx, config, errors.New("ACLClouds session is still unauthorized after login"))
		}
	}
	// Renewal/CSRF refresh may rotate cookies after the initial list request.
	// Persist the final jar, including when confirmation remains uncertain.
	defer func() {
		if err := s.saveAuthState(config.AuthStatePath); err != nil {
			log.Printf("[renew] WARNING: %v", err)
		}
	}()

	target, err := selectServer(servers, config.ServerSelector)
	if err != nil {
		return fail(ctx, config, err)
	}
	if target.CanRenew != nil && !*target.CanRenew {
		return Result{Skipped: true, Message: fmt.Sprintf("%s: renewal is not available yet%s", target.displayName(), expirySuffix(target.ExpiresAt))}, nil
	}
	if target.FreeRenewalsRemaining != nil && *target.FreeRenewalsRemaining <= 0 {
		return Result{Skipped: true, Message: fmt.Sprintf("%s: no free renewals remain", target.displayName())}, nil
	}

	result, err := s.renew(ctx, target)
	if errors.Is(err, errSessionExpired) {
		log.Print("[renew] Session expired during renewal; logging in again")
		if err := s.login(ctx, config.Username, config.Password); err != nil {
			return fail(ctx, config, err)
		}
		result, err = s.renew(ctx, target)
	}
	if err != nil {
		return fail(ctx, config, err)
	}
	if result.Renewed {
		message := fmt.Sprintf("ACLClouds 自动延期成功\n服务：%s\n%s", target.displayName(), result.Message)
		if notifyErr := notify(ctx, config, message); notifyErr != nil {
			log.Printf("[renew] WARNING: success notification failed: %v", notifyErr)
		}
	}
	return result, nil
}

func fail(ctx context.Context, config Config, err error) (Result, error) {
	if errors.Is(ctx.Err(), context.Canceled) {
		// Interrupted by a signal because the container is stopping; there is
		// nothing for the user to act on.
		return Result{}, err
	}
	message := fmt.Sprintf("ACLClouds 自动延期需要处理\n%s", err.Error())
	if notifyErr := notify(ctx, config, message); notifyErr != nil {
		log.Printf("[renew] WARNING: failure notification failed: %v", notifyErr)
	}
	return Result{}, err
}

func notify(ctx context.Context, config Config, message string) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), notificationTimeout)
	defer cancel()
	return notifyTelegram(ctx, config, message)
}

func (s *session) listServers(ctx context.Context) ([]server, bool, error) {
	result, err := s.request(ctx, http.MethodGet, "/api/client", nil)
	if err != nil {
		return nil, false, fmt.Errorf("GET /api/client: %w", err)
	}
	if sessionExpired(result.Status) {
		return nil, true, nil
	}
	if result.Status != http.StatusOK {
		return nil, false, fmt.Errorf("GET /api/client: HTTP %d %s", result.Status, responseMessage(result.Body))
	}
	var collection struct {
		Data []struct {
			Object     string         `json:"object"`
			Attributes map[string]any `json:"attributes"`
		} `json:"data"`
	}
	if err := json.Unmarshal(result.Body, &collection); err != nil {
		return nil, false, fmt.Errorf("parse /api/client: %w", err)
	}
	servers := make([]server, 0, len(collection.Data))
	for _, item := range collection.Data {
		if item.Object != "" && item.Object != "server" {
			continue
		}
		identifier := stringValue(item.Attributes, "identifier", "uuid_short", "short_uuid", "server_id")
		if identifier == "" {
			continue
		}
		servers = append(servers, server{
			Identifier:            identifier,
			UUID:                  stringValue(item.Attributes, "uuid"),
			Name:                  stringValue(item.Attributes, "name"),
			ExpiresAt:             stringValue(item.Attributes, "expires_at", "expire_at"),
			CanRenew:              boolPointer(item.Attributes, "can_renew"),
			FreeRenewalsRemaining: intPointer(item.Attributes, "free_renewals_remaining"),
		})
	}
	return servers, false, nil
}

func selectServer(servers []server, selector string) (server, error) {
	selector = strings.TrimSpace(selector)
	for _, candidate := range servers {
		if selector == candidate.Identifier || selector == candidate.UUID {
			return candidate, nil
		}
	}
	return server{}, fmt.Errorf("current ACLClouds service %q was not found in /api/client", selector)
}

func (s *session) renew(ctx context.Context, target server) (Result, error) {
	path := "/api/client/servers/" + url.PathEscape(target.Identifier) + "/upgrade/renew"
	result, err := s.request(ctx, http.MethodPost, path, map[string]any{})
	if err != nil {
		return Result{}, fmt.Errorf("renew %s: %w", target.displayName(), err)
	}
	if sessionExpired(result.Status) {
		return Result{}, errSessionExpired
	}
	if result.Status == http.StatusOK {
		return s.confirmRenewal(ctx, target, result.Body)
	}
	if renewalNotAvailable(result) {
		return Result{Skipped: true, Message: fmt.Sprintf("%s: renewal_not_available is a normal state%s", target.displayName(), expirySuffix(target.ExpiresAt))}, nil
	}
	if captchaRequired(result) {
		// Log the refusal verbatim: whether the renewal gate really demands a
		// CAPTCHA, or merely returned something that mentions one, is the
		// difference between a working solver and a wasted solve.
		log.Printf("[renew] %s: renewal refused pending a CAPTCHA (HTTP %d %s)",
			target.displayName(), result.Status, responseMessage(result.Body))
		token, solveErr := solveCaptcha(ctx, s)
		if solveErr != nil {
			return Result{}, &attentionError{message: fmt.Sprintf("%s: renewal CAPTCHA solve failed: %v", target.displayName(), solveErr), cause: solveErr}
		}
		if strings.TrimSpace(token) == "" {
			return Result{}, &attentionError{message: fmt.Sprintf("%s: renewal CAPTCHA solver returned an empty token", target.displayName())}
		}
		result, err = s.request(ctx, http.MethodPost, path, map[string]any{"captcha_token": token})
		if err != nil {
			return Result{}, fmt.Errorf("retry renewal after CAPTCHA: %w", err)
		}
		if sessionExpired(result.Status) {
			return Result{}, errSessionExpired
		}
		if result.Status == http.StatusOK {
			return s.confirmRenewal(ctx, target, result.Body)
		}
		if renewalNotAvailable(result) {
			return Result{Skipped: true, Message: fmt.Sprintf("%s: renewal_not_available after CAPTCHA", target.displayName())}, nil
		}
	}
	return Result{}, fmt.Errorf("renew %s: HTTP %d %s", target.displayName(), result.Status, responseMessage(result.Body))
}

func (s *session) confirmRenewal(ctx context.Context, target server, renewBody []byte) (Result, error) {
	var response map[string]any
	if json.Unmarshal(renewBody, &response) != nil || response == nil {
		return Result{}, fmt.Errorf("cannot confirm renewal of %s: response is not a JSON object", target.displayName())
	}
	responseObjects := []map[string]any{response}
	if wrapped, ok := response["data"].(map[string]any); ok {
		responseObjects = append(responseObjects, wrapped)
	}
	for _, object := range responseObjects {
		payment := boolPointer(object, "requires_payment")
		if (payment != nil && *payment) || stringValue(object, "checkout_url") != "" {
			// Do not open a checkout, follow its URL, or include that private
			// URL in logs/Telegram. Payment is never an automatic renewal.
			return Result{}, fmt.Errorf("renew %s requires payment; manual action is needed", target.displayName())
		}
		success := boolPointer(object, "success")
		failed := success != nil && !*success
		for _, key := range []string{"error", "errors"} {
			switch value := object[key].(type) {
			case string:
				failed = failed || strings.TrimSpace(value) != ""
			case bool:
				failed = failed || value
			case []any:
				failed = failed || len(value) != 0
			case map[string]any:
				failed = failed || len(value) != 0
			}
		}
		if failed {
			return Result{}, fmt.Errorf("server did not confirm renewal of %s", target.displayName())
		}
	}
	newExpiry := expirationFromBody(renewBody)
	path := "/api/client/servers/" + url.PathEscape(target.Identifier)
	detail, err := s.request(ctx, http.MethodGet, path, nil)
	if err == nil && detail.Status == http.StatusOK {
		if expiry := expirationFromBody(detail.Body); expiry != "" {
			newExpiry = expiry
		}
	}
	before, beforeErr := time.Parse(time.RFC3339, target.ExpiresAt)
	after, afterErr := time.Parse(time.RFC3339, newExpiry)
	if beforeErr != nil || afterErr != nil {
		// A 200/message alone is not evidence of an extension. Do not signal
		// errSessionExpired here: the POST may already have succeeded, so
		// confirmation failure must not trigger re-login and another POST.
		return Result{}, fmt.Errorf("cannot confirm renewal of %s: previous or new expires_at is missing or invalid", target.displayName())
	}
	if !after.After(before) {
		return Result{}, fmt.Errorf("renew %s returned success but expires_at did not advance (%s)", target.displayName(), newExpiry)
	}
	return Result{Renewed: true, Message: "新到期时间：" + newExpiry}, nil
}

func (s server) displayName() string {
	if s.Name != "" {
		return fmt.Sprintf("%s (%s)", s.Name, s.Identifier)
	}
	return s.Identifier
}

func renewalNotAvailable(result httpResult) bool {
	if result.Status != http.StatusBadRequest && result.Status != http.StatusConflict && result.Status != http.StatusUnprocessableEntity {
		return false
	}
	body := strings.ToLower(string(result.Body))
	return strings.Contains(body, "renewal_not_available")
}

func expirationFromBody(body []byte) string {
	var data map[string]any
	if json.Unmarshal(body, &data) != nil {
		return ""
	}
	if expires := stringValue(data, "expires_at", "expire_at"); expires != "" {
		return expires
	}
	if attributes, ok := data["attributes"].(map[string]any); ok {
		if expires := stringValue(attributes, "expires_at", "expire_at"); expires != "" {
			return expires
		}
	}
	if wrapped, ok := data["data"].(map[string]any); ok {
		if expires := stringValue(wrapped, "expires_at", "expire_at"); expires != "" {
			return expires
		}
		if attributes, ok := wrapped["attributes"].(map[string]any); ok {
			return stringValue(attributes, "expires_at", "expire_at")
		}
	}
	return ""
}

func expirySuffix(value string) string {
	if value == "" {
		return ""
	}
	return "，到期时间 " + value
}

func stringValue(values map[string]any, keys ...string) string {
	for _, key := range keys {
		if value, ok := values[key]; ok {
			switch typed := value.(type) {
			case string:
				if typed != "" {
					return typed
				}
			case json.Number:
				return typed.String()
			}
		}
	}
	return ""
}

func boolPointer(values map[string]any, key string) *bool {
	value, ok := values[key]
	if !ok || value == nil {
		return nil
	}
	switch typed := value.(type) {
	case bool:
		return &typed
	case string:
		parsed, err := strconv.ParseBool(typed)
		if err == nil {
			return &parsed
		}
	}
	return nil
}

func intPointer(values map[string]any, key string) *int {
	value, ok := values[key]
	if !ok || value == nil {
		return nil
	}
	var parsed int
	var err error
	switch typed := value.(type) {
	case float64:
		parsed = int(typed)
	case json.Number:
		var number int64
		number, err = typed.Int64()
		parsed = int(number)
	case string:
		parsed, err = strconv.Atoi(typed)
	default:
		return nil
	}
	if err != nil {
		return nil
	}
	return &parsed
}
