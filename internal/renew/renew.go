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
	if err := s.saveAuthState(config.AuthStatePath); err != nil {
		log.Printf("[renew] WARNING: %v", err)
	}

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
	if err != nil {
		return fail(ctx, config, err)
	}
	if result.Renewed {
		message := fmt.Sprintf("ACLClouds 自动延期成功\n服务：%s\n%s", target.displayName(), result.Message)
		if notifyErr := notifyTelegram(ctx, config, message); notifyErr != nil {
			log.Printf("[renew] WARNING: success notification failed: %v", notifyErr)
		}
	}
	return result, nil
}

func fail(ctx context.Context, config Config, err error) (Result, error) {
	message := fmt.Sprintf("ACLClouds 自动延期需要处理\n%s", err.Error())
	if notifyErr := notifyTelegram(ctx, config, message); notifyErr != nil {
		log.Printf("[renew] WARNING: failure notification failed: %v", notifyErr)
	}
	return Result{}, err
}

func (s *session) listServers(ctx context.Context) ([]server, bool, error) {
	result, err := s.request(ctx, http.MethodGet, "/api/client", nil)
	if err != nil {
		return nil, false, fmt.Errorf("GET /api/client: %w", err)
	}
	if result.Status == http.StatusUnauthorized {
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
	if result.Status == http.StatusUnauthorized {
		return Result{}, errors.New("ACLClouds session expired during renewal; it will be refreshed on the next check")
	}
	if result.Status == http.StatusOK {
		return s.confirmRenewal(ctx, target, result.Body)
	}
	if renewalNotAvailable(result) {
		return Result{Skipped: true, Message: fmt.Sprintf("%s: renewal_not_available is a normal state%s", target.displayName(), expirySuffix(target.ExpiresAt))}, nil
	}
	if captchaRequired(result) {
		token, solveErr := solveCaptcha(ctx, s, "renewal_gate")
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
	newExpiry := expirationFromBody(renewBody)
	path := "/api/client/servers/" + url.PathEscape(target.Identifier)
	detail, err := s.request(ctx, http.MethodGet, path, nil)
	if err == nil && detail.Status == http.StatusOK {
		if expiry := expirationFromBody(detail.Body); expiry != "" {
			newExpiry = expiry
		}
	}
	if target.ExpiresAt != "" && newExpiry != "" {
		before, beforeErr := time.Parse(time.RFC3339, target.ExpiresAt)
		after, afterErr := time.Parse(time.RFC3339, newExpiry)
		if beforeErr == nil && afterErr == nil && !after.After(before) {
			return Result{}, fmt.Errorf("renew %s returned success but expires_at did not advance (%s)", target.displayName(), newExpiry)
		}
	}
	if newExpiry != "" {
		return Result{Renewed: true, Message: "新到期时间：" + newExpiry}, nil
	}
	return Result{Renewed: true, Message: renewalMessage(renewBody)}, nil
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

func renewalMessage(body []byte) string {
	var data map[string]any
	if json.Unmarshal(body, &data) == nil {
		if message := stringValue(data, "message"); message != "" {
			return message
		}
	}
	return "服务端已确认续期"
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
