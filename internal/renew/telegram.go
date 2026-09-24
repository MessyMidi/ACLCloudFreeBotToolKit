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
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

func notifyTelegram(ctx context.Context, config Config, message string) error {
	if config.TelegramBotToken == "" && config.TelegramChatID == "" {
		return nil
	}
	if config.TelegramBotToken == "" || config.TelegramChatID == "" {
		return fmt.Errorf("Telegram Bot Token and Chat ID must be configured together")
	}
	form := url.Values{
		"chat_id":                  {config.TelegramChatID},
		"text":                     {message},
		"disable_web_page_preview": {"true"},
	}
	endpoint := fmt.Sprintf("%s/bot%s/sendMessage", config.TelegramAPIBase, url.PathEscape(config.TelegramBotToken))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	client := &http.Client{Timeout: 15 * time.Second}
	response, err := client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(response.Body, 64<<10))
	var telegramResult struct {
		OK          bool   `json:"ok"`
		Description string `json:"description"`
	}
	_ = json.Unmarshal(body, &telegramResult)
	if response.StatusCode < 200 || response.StatusCode >= 300 || !telegramResult.OK {
		return fmt.Errorf("Telegram HTTP %d: %s", response.StatusCode, telegramResult.Description)
	}
	return nil
}
