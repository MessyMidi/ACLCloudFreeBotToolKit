// ACLCloudFreeBotToolKit
// Copyright (C) 2026 MessyMidi
// SPDX-License-Identifier: AGPL-3.0-only
// Additional terms under AGPLv3 Section 7: see /ADDITIONAL_TERMS.md

package renew

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

const hostingTestID = "11111111-1111-4111-8111-111111111111"
const hostingTestHost = "bot-abc12345.aclclouds.online"
const hostingBefore = "2026-10-31T08:00:00Z"
const hostingAfter = "2026-11-04T08:00:00Z"

func hostingConfig(t *testing.T, selector, hostname string) Config {
	t.Helper()
	for name, value := range map[string]string{
		"AUTO_RENEW_ENABLED": "1", "ACL_USERNAME": "test-user", "ACL_PASSWORD": "test-password",
		"ACL_SERVER_ID": selector, "P_SERVER_UUID": "", "P_SERVER_IDENTIFIER": "", "APP_HOSTNAME": hostname,
		"ACL_AUTH_STATE": filepath.Join(t.TempDir(), "auth.json"), "ACL_BASE_URL": "http://127.0.0.1",
		"TELEGRAM_BOT_TOKEN": "", "TELEGRAM_CHAT_ID": "",
	} {
		t.Setenv(name, value)
	}
	cfg, err := LoadConfigFromEnv()
	if err != nil {
		t.Fatalf("hosting configuration rejected: %v", err)
	}
	return cfg
}

func hostingList(appIDs ...string) map[string]any {
	items := []any{}
	for i, id := range appIDs {
		// Legacy can_renew is intentionally stale; the application detail is authoritative.
		items = append(items, map[string]any{"object": "server", "attributes": map[string]any{
			"identifier": "abc12345" + strings.Repeat("x", i), "uuid": "legacy-uuid" + strings.Repeat("x", i),
			"can_renew": false, "expires_at": hostingBefore, "hosting_app": map[string]any{"id": id},
		}})
	}
	return map[string]any{"data": items}
}

func hostingDetail(id, expires string, canRenew bool) map[string]any {
	return map[string]any{"object": "server", "attributes": map[string]any{
		"identifier": id, "uuid": id, "name": "test bot", "hosting_backed": true,
		"hosting_app": map[string]any{"id": id}, "expires_at": expires, "can_renew": canRenew,
	}}
}

func TestHostingConfigAcceptsHostnameWithoutLegacyUUID(t *testing.T) {
	hostingConfig(t, "", hostingTestHost)
}

func TestHostingHostnameSelectionAndNewRenewalEndpoint(t *testing.T) {
	for _, selector := range []string{"", "abc12345", "legacy-uuid", hostingTestID} {
		t.Run("selector-"+selector, func(t *testing.T) {
			cfg := hostingConfig(t, selector, hostingTestHost)
			posts, details, metadata := 0, 0, 0
			panel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/api/client":
					writeJSON(t, w, 200, hostingList(hostingTestID))
				case "/api/client/hosting/apps/" + hostingTestID:
					metadata++
					writeJSON(t, w, 200, map[string]any{"id": hostingTestID, "url": "https://" + hostingTestHost})
				case "/api/client/hosting/apps/" + hostingTestID + "/server":
					details++
					expires := hostingBefore
					if posts > 0 {
						expires = hostingAfter
					}
					writeJSON(t, w, 200, hostingDetail(hostingTestID, expires, true))
				case "/api/client/hosting/apps/" + hostingTestID + "/renew":
					if r.Method != http.MethodPost {
						t.Error("renew must be POST")
					}
					posts++
					writeJSON(t, w, 200, map[string]any{"success": true})
				default:
					t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
					http.NotFound(w, r)
				}
			}))
			defer panel.Close()
			cfg.BaseURL = panel.URL
			result, err := Check(context.Background(), cfg)
			if err != nil || !result.Renewed || posts != 1 || details != 2 {
				t.Fatalf("result=%+v err=%v posts=%d details=%d", result, err, posts, details)
			}
			if (selector == "" && metadata != 1) || (selector != "" && metadata != 0) {
				t.Fatal("explicit selector must bypass hostname discovery")
			}
		})
	}
}

func TestHostingExplicitAppIDWorksWithoutLegacyListEntry(t *testing.T) {
	cfg := hostingConfig(t, hostingTestID, "")
	panel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/client":
			writeJSON(t, w, 200, hostingList())
		case "/api/client/hosting/apps/" + hostingTestID + "/server":
			writeJSON(t, w, 200, hostingDetail(hostingTestID, hostingBefore, false))
		default:
			t.Errorf("unexpected request: %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer panel.Close()
	cfg.BaseURL = panel.URL
	r, err := Check(context.Background(), cfg)
	if err != nil || !r.Skipped {
		t.Fatalf("result=%+v err=%v", r, err)
	}
}

func TestHostingRefusesAmbiguousOrUnverifiedHostname(t *testing.T) {
	for _, scenario := range []string{"no-match", "duplicate", "bad-metadata-id", "userinfo", "detail-id-mismatch", "metadata-forbidden"} {
		t.Run(scenario, func(t *testing.T) {
			cfg := hostingConfig(t, "", hostingTestHost)
			secondID := "22222222-2222-4222-8222-222222222222"
			posts := 0
			panel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet {
					posts++
					http.Error(w, "must not renew", 500)
					return
				}
				if r.URL.Path == "/api/client" {
					ids := []string{hostingTestID}
					if scenario == "duplicate" {
						ids = append(ids, secondID)
					}
					writeJSON(t, w, 200, hostingList(ids...))
					return
				}
				if strings.HasSuffix(r.URL.Path, "/server") {
					writeJSON(t, w, 200, hostingDetail(secondID, hostingBefore, true))
					return
				}
				id := hostingTestID
				if strings.HasSuffix(r.URL.Path, secondID) {
					id = secondID
				}
				url := "https://" + hostingTestHost
				switch scenario {
				case "no-match":
					url += ".attacker.example"
				case "bad-metadata-id":
					id = secondID
				case "userinfo":
					url = "https://secret@" + hostingTestHost
				case "metadata-forbidden":
					http.Error(w, "Forbidden", 403)
					return
				}
				writeJSON(t, w, 200, map[string]any{"id": id, "url": url})
			}))
			defer panel.Close()
			cfg.BaseURL = panel.URL
			if _, err := Check(context.Background(), cfg); err == nil {
				t.Fatal("unverified/ambiguous target accepted")
			}
			if posts != 0 {
				t.Fatal("unsafe target triggered renewal")
			}
		})
	}
}

func TestHostingFailedOrUnconfirmedRenewalIsNeverReplayedOnLegacyRoute(t *testing.T) {
	for _, status := range []int{200, 404, 500} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			cfg := hostingConfig(t, hostingTestID, "")
			posts := 0
			panel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/api/client":
					writeJSON(t, w, 200, hostingList(hostingTestID))
				case "/api/client/hosting/apps/" + hostingTestID + "/server":
					writeJSON(t, w, 200, hostingDetail(hostingTestID, hostingBefore, true))
				case "/api/client/hosting/apps/" + hostingTestID + "/renew":
					posts++
					writeJSON(t, w, status, map[string]any{"success": true})
				default:
					if r.Method == http.MethodPost {
						posts++
					}
					t.Errorf("unexpected fallback: %s", r.URL.Path)
					http.NotFound(w, r)
				}
			}))
			defer panel.Close()
			cfg.BaseURL = panel.URL
			if _, err := Check(context.Background(), cfg); err == nil {
				t.Fatal("failed/unconfirmed renewal reported success")
			}
			if posts != 1 {
				t.Fatalf("renewal POST executed %d times", posts)
			}
		})
	}
}

func TestHostingHostnameValidationAndExplicitIDPriority(t *testing.T) {
	for _, host := range []string{"https://" + hostingTestHost, "user@" + hostingTestHost, "bad\nhost", strings.Repeat("a", 64) + ".example", ""} {
		t.Run(host, func(t *testing.T) {
			hostingConfig(t, "explicit-id", host)
			t.Setenv("ACL_SERVER_ID", "")
			if _, err := LoadConfigFromEnv(); err == nil {
				t.Fatal("invalid/missing hostname accepted without explicit ID")
			}
		})
	}
}

func TestHostingMetadataSessionRecoveryIsBounded(t *testing.T) {
	for _, persistent := range []bool{false, true} {
		t.Run(map[bool]string{false: "recovers", true: "persistent"}[persistent], func(t *testing.T) {
			cfg := hostingConfig(t, "", hostingTestHost)
			metadata, logins, renewals := 0, 0, 0
			panel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/api/client":
					writeJSON(t, w, 200, hostingList(hostingTestID))
				case "/auth/login":
					if r.Method == http.MethodGet {
						_, _ = w.Write([]byte(`<meta name="csrf-token" content="mock-csrf">`))
						return
					}
					logins++
					writeJSON(t, w, 200, map[string]any{"ok": true})
				case "/sanctum/csrf-cookie":
					http.NotFound(w, r)
				case "/api/client/hosting/apps/" + hostingTestID:
					metadata++
					if persistent || metadata == 1 {
						w.WriteHeader(401)
						return
					}
					writeJSON(t, w, 200, map[string]any{"id": hostingTestID, "url": "https://" + hostingTestHost})
				case "/api/client/hosting/apps/" + hostingTestID + "/server":
					writeJSON(t, w, 200, hostingDetail(hostingTestID, hostingBefore, false))
				default:
					if r.Method == http.MethodPost {
						renewals++
					}
					t.Errorf("unexpected request %s", r.URL.Path)
					http.NotFound(w, r)
				}
			}))
			defer panel.Close()
			cfg.BaseURL = panel.URL
			r, err := Check(context.Background(), cfg)
			if persistent && err == nil {
				t.Fatal("persistent expired session accepted")
			}
			if !persistent && (err != nil || !r.Skipped) {
				t.Fatalf("result=%+v err=%v", r, err)
			}
			if logins != 1 || metadata != 2 || renewals != 0 {
				t.Fatalf("logins=%d metadata=%d renewals=%d", logins, metadata, renewals)
			}
		})
	}
}

func TestHostingSkipsPaidApplicationWithoutRenewalPost(t *testing.T) {
	cfg := hostingConfig(t, hostingTestID, "")
	panel := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Error("paid application triggered a mutation")
			http.Error(w, "forbidden", 403)
			return
		}
		switch r.URL.Path {
		case "/api/client":
			writeJSON(t, w, 200, hostingList(hostingTestID))
		case "/api/client/hosting/apps/" + hostingTestID + "/server":
			detail := hostingDetail(hostingTestID, hostingBefore, true)
			detail["attributes"].(map[string]any)["is_free"] = false
			writeJSON(t, w, 200, detail)
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer panel.Close()
	cfg.BaseURL = panel.URL
	r, err := Check(context.Background(), cfg)
	if err != nil || !r.Skipped {
		t.Fatalf("result=%+v err=%v", r, err)
	}
}
