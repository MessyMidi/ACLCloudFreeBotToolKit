// ACLCloudFreeBotToolKit
// Copyright (C) 2026 MessyMidi
//
// SPDX-License-Identifier: AGPL-3.0-only
// Additional terms under AGPLv3 Section 7:
// see /ADDITIONAL_TERMS.md

package renew

import (
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

type Config struct {
	Enabled          bool
	BaseURL          string
	Username         string
	Password         string
	ServerSelector   string
	AuthStatePath    string
	TelegramBotToken string
	TelegramChatID   string
	TelegramAPIBase  string
}

func LoadConfigFromEnv() (Config, error) {
	baseDir := strings.TrimSpace(os.Getenv("ACL_BASE_DIR"))
	if baseDir == "" {
		baseDir = "."
	}
	config := Config{
		Enabled:          envBool("AUTO_RENEW_ENABLED"),
		BaseURL:          valueOrDefault("ACL_BASE_URL", "https://aclclouds.com"),
		Username:         firstNonEmpty(os.Getenv("ACL_USERNAME"), os.Getenv("ACL_EMAIL")),
		Password:         os.Getenv("ACL_PASSWORD"),
		ServerSelector:   firstNonEmpty(os.Getenv("ACL_SERVER_ID"), os.Getenv("P_SERVER_UUID"), os.Getenv("P_SERVER_IDENTIFIER")),
		AuthStatePath:    valueOrDefault("ACL_AUTH_STATE", filepath.Join(baseDir, "data", "acl-auth.json")),
		TelegramBotToken: strings.TrimSpace(os.Getenv("TELEGRAM_BOT_TOKEN")),
		TelegramChatID:   strings.TrimSpace(os.Getenv("TELEGRAM_CHAT_ID")),
		TelegramAPIBase:  valueOrDefault("TELEGRAM_API_BASE", "https://api.telegram.org"),
	}
	config.BaseURL = strings.TrimRight(strings.TrimSpace(config.BaseURL), "/")
	config.TelegramAPIBase = strings.TrimRight(strings.TrimSpace(config.TelegramAPIBase), "/")

	if !config.Enabled {
		return config, nil
	}
	if _, err := url.ParseRequestURI(config.BaseURL); err != nil {
		return Config{}, errors.New("ACL_BASE_URL is invalid")
	}
	if config.Username == "" || config.Password == "" {
		return Config{}, errors.New("AUTO_RENEW_ENABLED=1 requires ACL_USERNAME and ACL_PASSWORD")
	}
	if config.ServerSelector == "" {
		return Config{}, errors.New("ACLClouds did not provide P_SERVER_UUID; set ACL_SERVER_ID explicitly")
	}
	if (config.TelegramBotToken == "") != (config.TelegramChatID == "") {
		return Config{}, errors.New("TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be configured together")
	}
	return config, nil
}

func envBool(name string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(name))) {
	case "1", "true", "yes", "on", "enable", "enabled":
		return true
	default:
		return false
	}
}

func valueOrDefault(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}
