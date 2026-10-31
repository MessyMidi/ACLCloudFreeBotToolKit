// ACLCloudFreeBotToolKit
// Copyright (C) 2026 MessyMidi
// SPDX-License-Identifier: AGPL-3.0-only
// Additional terms under AGPLv3 Section 7: see /ADDITIONAL_TERMS.md

package renew

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

var errServerNotFound = errors.New("service not found")
var hostingUUIDPattern = regexp.MustCompile(`(?i)^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$`)
var hostnameLabelPattern = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`)

func normalizedHostname(value string) string {
	host := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(value), "."))
	if host == "" || len(host) > 253 {
		return ""
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) > 63 || !hostnameLabelPattern.MatchString(label) {
			return ""
		}
	}
	return host
}

func hostingAppPath(id string) string {
	return "/api/client/hosting/apps/" + url.PathEscape(id)
}

func serverFromAttributes(a map[string]any) server {
	target := server{
		Identifier: stringValue(a, "identifier", "uuid_short", "short_uuid", "server_id"),
		UUID:       stringValue(a, "uuid"), Name: stringValue(a, "name"),
		ExpiresAt: stringValue(a, "expires_at", "expire_at"), CanRenew: boolPointer(a, "can_renew"),
		IsFree:                boolPointer(a, "is_free"),
		FreeRenewalsRemaining: intPointer(a, "free_renewals_remaining"),
	}
	if app, ok := a["hosting_app"].(map[string]any); ok {
		target.HostingAppID = stringValue(app, "id")
	}
	return target
}

// Keep authentication recovery bounded to the same one re-login used by the
// legacy list request. Discovery only GETs data; it never tries renewal routes.
func (s *session) findTarget(ctx context.Context, config Config) (server, bool, error) {
	servers, unauthorized, err := s.listServers(ctx)
	if err != nil || unauthorized {
		return server{}, unauthorized, err
	}
	target, err := s.resolveTarget(ctx, servers, config)
	if errors.Is(err, errSessionExpired) {
		return server{}, true, nil
	}
	return target, false, err
}

func (s *session) resolveTarget(ctx context.Context, servers []server, config Config) (server, error) {
	if selector := strings.TrimSpace(config.ServerSelector); selector != "" {
		target, err := selectServer(servers, selector)
		if err != nil {
			// A newly created app need not have a legacy list entry. Only use
			// an explicitly supplied full UUID, never a guessed prefix.
			if errors.Is(err, errServerNotFound) && hostingUUIDPattern.MatchString(selector) {
				return s.hostingServer(ctx, selector)
			}
			return server{}, err
		}
		if target.HostingAppID != "" {
			return s.hostingServer(ctx, target.HostingAppID)
		}
		return target, nil
	}

	host := normalizedHostname(config.AppHostname)
	if host == "" {
		return server{}, errors.New("no valid service ID or APP_HOSTNAME; set ACL_SERVER_ID explicitly")
	}
	seen := make(map[string]bool)
	matchedID := ""
	for _, target := range servers {
		id := target.HostingAppID
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		if !hostingUUIDPattern.MatchString(id) {
			return server{}, errors.New("invalid hosting app ID in /api/client")
		}
		result, err := s.request(ctx, http.MethodGet, hostingAppPath(id), nil)
		if err != nil {
			return server{}, fmt.Errorf("read hosting app metadata: %w", err)
		}
		if sessionExpired(result.Status) {
			return server{}, errSessionExpired
		}
		if result.Status != http.StatusOK {
			return server{}, fmt.Errorf("read hosting app metadata: HTTP %d; set ACL_SERVER_ID explicitly", result.Status)
		}
		var app struct {
			ID  string `json:"id"`
			URL string `json:"url"`
		}
		if json.Unmarshal(result.Body, &app) != nil || app.ID != id {
			return server{}, errors.New("hosting app metadata did not confirm the requested ID")
		}
		// Compare the entire hostname returned by the API. Do not strip
		// "bot-" or infer a legacy identifier from the hostname's prefix.
		publicURL, parseErr := url.Parse(app.URL)
		if parseErr != nil || publicURL.User != nil || (publicURL.Scheme != "https" && publicURL.Scheme != "http") || normalizedHostname(publicURL.Hostname()) != host {
			continue
		}
		if matchedID != "" {
			return server{}, errors.New("APP_HOSTNAME matches multiple applications; set ACL_SERVER_ID explicitly")
		}
		matchedID = id
	}
	if matchedID == "" {
		return server{}, errors.New("APP_HOSTNAME did not match a verified application; set ACL_SERVER_ID explicitly")
	}
	return s.hostingServer(ctx, matchedID)
}

func (s *session) hostingServer(ctx context.Context, id string) (server, error) {
	if !hostingUUIDPattern.MatchString(id) {
		return server{}, errors.New("invalid hosting application UUID")
	}
	result, err := s.request(ctx, http.MethodGet, hostingAppPath(id)+"/server", nil)
	if err != nil {
		return server{}, fmt.Errorf("read hosting app server: %w", err)
	}
	if sessionExpired(result.Status) {
		return server{}, errSessionExpired
	}
	if result.Status != http.StatusOK {
		return server{}, fmt.Errorf("read hosting app server: HTTP %d", result.Status)
	}
	var detail struct {
		Attributes map[string]any `json:"attributes"`
	}
	if json.Unmarshal(result.Body, &detail) != nil || detail.Attributes == nil {
		return server{}, errors.New("invalid hosting app server response")
	}
	target := serverFromAttributes(detail.Attributes)
	if target.Identifier == "" || target.HostingAppID != id {
		return server{}, errors.New("hosting app server response did not confirm the requested application")
	}
	return target, nil
}
