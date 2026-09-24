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
	"image"
	"image/draw"
	_ "image/png"
	"io"
	"log"
	"math"
	"net/http"
	"net/url"
	"sort"
	"time"
)

var errImageDecode = errors.New("decode captcha image")

const (
	captchaCols      = 200 // captcha image width  (46x200)
	captchaRows      = 46  // captcha image height
	captchaMaxShift  = 15  // max alignment shift for correlation
	captchaMinSegLen = 10  // minimum segment length for correlation
	captchaWeightCol = 0.6 // column correlation weight
	captchaWeightRow = 0.4 // row correlation weight
	captchaMinStd    = 1e-6
)

// captchaChallenge is the JSON response from POST /auth/captcha.
type captchaChallenge struct {
	Interactive bool        `json:"interactive"`
	Options     []string    `json:"options"`
	AnswerSig   string      `json:"answer_sig"`
	Target      string      `json:"target"`
	ID          string      `json:"id"`
	TS          json.Number `json:"ts"`
	Sig         string      `json:"sig"`
	Context     string      `json:"context"`
	Passed      bool        `json:"passed,omitempty"`
	Token       string      `json:"token,omitempty"`
}

// extractProfiles extracts column (vertical) and row (horizontal) profiles
// from a binarized grayscale image. It returns the column profile (length = width)
// and row profile (length = height).
func extractProfiles(pixels []float64, width, height int) ([]float64, []float64) {
	// Flatten and sort for binarization threshold (top 1/8 percentile).
	sorted := make([]float64, len(pixels))
	copy(sorted, pixels)
	sort.Float64s(sorted)
	threshold := sorted[len(sorted)/8]

	// Binarize and compute column/row sums.
	colProfile := make([]float64, width)
	rowProfile := make([]float64, height)
	for y := 0; y < height; y++ {
		base := y * width
		var rowSum float64
		for x := 0; x < width; x++ {
			if pixels[base+x] < threshold {
				colProfile[x]++
				rowSum++
			}
		}
		rowProfile[y] = rowSum
	}
	return colProfile, rowProfile
}

// alignCorr slides profile against reference, computing Pearson correlation
// at each offset, and returns the best score.
func alignCorr(profile, reference []float64) float64 {
	if len(profile) == 0 || len(profile) != len(reference) {
		return -9999.0
	}
	n := len(profile)
	best := -9999.0

	for shift := -captchaMaxShift; shift <= captchaMaxShift; shift++ {
		start := max(0, shift)
		end := min(n, n+shift)
		rStart := max(0, -shift)
		rEnd := min(n, n-shift)

		segP := profile[start:end]
		segR := reference[rStart:rEnd]
		if len(segP) < captchaMinSegLen {
			continue
		}

		pMean, rMean := mean(segP), mean(segR)
		pStd, rStd := std(segP, pMean), std(segR, rMean)
		if pStd < captchaMinStd || rStd < captchaMinStd {
			continue
		}

		cov := covariance(segP, segR, pMean, rMean)
		corr := cov / (pStd * rStd)
		if corr > best {
			best = corr
		}
	}
	return best
}

func mean(v []float64) float64 {
	sum := 0.0
	for _, x := range v {
		sum += x
	}
	return sum / float64(len(v))
}

func std(v []float64, m float64) float64 {
	sum := 0.0
	for _, x := range v {
		d := x - m
		sum += d * d
	}
	return math.Sqrt(sum / float64(len(v)))
}

func covariance(a, b []float64, aMean, bMean float64) float64 {
	sum := 0.0
	for i := range a {
		sum += (a[i] - aMean) * (b[i] - bMean)
	}
	return sum / float64(len(a))
}

// matchImage matches the column and row profiles against all precomputed
// reference words and returns the best-matching word and its score.
func matchImage(colP, rowP []float64) (string, float64) {
	bestWord := ""
	bestScore := -9999.0

	for _, ref := range precomputedRef {
		cScore := alignCorr(colP, ref.colProfile)
		rScore := alignCorr(rowP, ref.rowProfile)
		score := cScore*captchaWeightCol + rScore*captchaWeightRow

		if score > bestScore {
			bestScore = score
			bestWord = ref.word
		}
	}
	return bestWord, bestScore
}

// decodeCaptchaImage decodes a PNG image from raw bytes, converts it to
// grayscale, and returns pixel values as float64.
func decodeCaptchaImage(data []byte) ([]float64, int, int, error) {
	src, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, 0, 0, fmt.Errorf("%w: %v", errImageDecode, err)
	}
	bounds := src.Bounds()
	width, height := bounds.Dx(), bounds.Dy()
	if width != captchaCols || height != captchaRows {
		return nil, 0, 0, fmt.Errorf("%w: unexpected dimensions %dx%d (want %dx%d)", errImageDecode, width, height, captchaCols, captchaRows)
	}
	gray := image.NewGray(bounds)
	draw.Draw(gray, bounds, src, bounds.Min, draw.Src)

	pixels := make([]float64, width*height)
	for y := 0; y < height; y++ {
		base := y * width
		for x := 0; x < width; x++ {
			g := gray.GrayAt(x+bounds.Min.X, y+bounds.Min.Y)
			pixels[base+x] = float64(g.Y)
		}
	}
	return pixels, width, height, nil
}

// solveCaptcha is the extension point for automated captcha solving.
// It fetches a challenge from the ACLClouds API, downloads the option images,
// matches them against precomputed reference profiles, selects the correct
// answer, and returns the one-time verification token.
func solveCaptcha(ctx context.Context, s *session, captchaContext string) (string, error) {
	// Step 1: POST /auth/captcha to get a challenge.
	chal, err := fetchChallenge(ctx, s, captchaContext)
	if err != nil {
		return "", fmt.Errorf("fetch captcha challenge: %w", err)
	}
	log.Printf("[captcha] challenge received: target=%q options=%d", chal.Target, len(chal.Options))

	// Step 2: Download and match each option image.
	type match struct {
		word  string
		score float64
		token string
	}
	var matches []match

	for _, token := range chal.Options {
		imgData, err := fetchCaptchaImage(ctx, s, token)
		if err != nil {
			log.Printf("[captcha] WARNING: failed to download an option image: %v", err)
			continue
		}
		pixels, width, height, err := decodeCaptchaImage(imgData)
		if err != nil {
			log.Printf("[captcha] WARNING: failed to decode option image: %v", err)
			continue
		}
		colP, rowP := extractProfiles(pixels, width, height)
		word, score := matchImage(colP, rowP)
		matches = append(matches, match{word: word, score: score, token: token})
		log.Printf("[captcha] option[%d]: matched=%q score=%.3f", len(matches)-1, word, score)
	}

	if len(matches) == 0 {
		return "", errors.New("no captcha option images could be processed")
	}

	// Step 3: Select the option whose matched word equals the target.
	var selected *match
	for i := range matches {
		if matches[i].word == chal.Target {
			selected = &matches[i]
			break
		}
	}
	if selected == nil {
		// Log all matches for debugging.
		for _, m := range matches {
			log.Printf("[captcha] available: word=%q score=%.3f", m.word, m.score)
		}
		return "", fmt.Errorf("no option matched target %q", chal.Target)
	}
	log.Printf("[captcha] selected: option word=%q score=%.3f", selected.word, selected.score)

	// Step 4: Submit the answer.
	verifyBody := map[string]any{
		"context":    chal.Context,
		"id":         chal.ID,
		"ts":         chal.TS,
		"sig":        chal.Sig,
		"answer":     selected.token,
		"answer_sig": chal.AnswerSig,
		"target":     chal.Target,
	}
	result, err := s.request(ctx, "POST", "/auth/captcha", verifyBody)
	if err != nil {
		return "", fmt.Errorf("submit captcha answer: %w", err)
	}
	if result.Status < http.StatusOK || result.Status >= http.StatusMultipleChoices {
		return "", fmt.Errorf("submit captcha answer: HTTP %d", result.Status)
	}

	var verifyResp captchaChallenge
	if err := json.Unmarshal(result.Body, &verifyResp); err != nil {
		return "", fmt.Errorf("parse captcha verification response: %w", err)
	}
	if !verifyResp.Passed {
		return "", errors.New("captcha verification rejected")
	}
	if verifyResp.Token == "" {
		return "", errors.New("captcha passed but token is empty")
	}
	log.Printf("[captcha] verification passed")
	return verifyResp.Token, nil
}

// fetchChallenge performs the two-step captcha challenge handshake:
//  1. GET /auth/captcha/challenge  → receives {id, ts, sig, context}
//  2. POST /auth/captcha {context, id, ts, sig, elapsed} → receives interactive challenge with options
func fetchChallenge(ctx context.Context, s *session, captchaContext string) (*captchaChallenge, error) {
	// Step 1: GET the non-interactive challenge parameters.
	// Try with context parameter so the handshake is bound to the right scope.
	chalPath := "/auth/captcha/challenge"
	if captchaContext != "" {
		chalPath += "?context=" + url.QueryEscape(captchaContext)
	}
	result, err := s.request(ctx, "GET", chalPath, nil)
	if err != nil {
		return nil, fmt.Errorf("challenge handshake: %w", err)
	}
	if result.Status < http.StatusOK || result.Status >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("challenge handshake: HTTP %d", result.Status)
	}
	var handshake struct {
		ID      string      `json:"id"`
		TS      json.Number `json:"ts"`
		Sig     string      `json:"sig"`
		Context string      `json:"context"`
	}
	if err := json.Unmarshal(result.Body, &handshake); err != nil {
		return nil, fmt.Errorf("parse challenge handshake: %w", err)
	}
	if handshake.ID == "" || handshake.Sig == "" {
		return nil, errors.New("challenge handshake missing id or sig")
	}

	// Step 2: POST back with the handshake parameters and captcha context.
	// NOTE: The handshake returns context="generic". Using any other context triggers
	// "bad_challenge". The verify step will use whatever context the challenge response
	// contains; if the login endpoint is strict about ctx, we adjust there.
	elapsed := 1000 + (time.Now().UnixMilli() % 4000) // random 1000–4999 ms
	body := map[string]any{
		"context": handshake.Context,
		"id":      handshake.ID,
		"ts":      handshake.TS,
		"sig":     handshake.Sig,
		"elapsed": elapsed,
	}
	result, err = s.request(ctx, "POST", "/auth/captcha", body)
	if err != nil {
		return nil, fmt.Errorf("captcha challenge: %w", err)
	}
	if result.Status < http.StatusOK || result.Status >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("captcha challenge: HTTP %d", result.Status)
	}
	var chal captchaChallenge
	if err := json.Unmarshal(result.Body, &chal); err != nil {
		return nil, fmt.Errorf("parse challenge: %w", err)
	}
	if !chal.Interactive {
		return nil, errors.New("captcha challenge is not interactive")
	}
	if len(chal.Options) == 0 {
		return nil, errors.New("captcha challenge has no options")
	}
	return &chal, nil
}

// fetchCaptchaImage downloads a captcha image by token and returns the raw bytes.
func fetchCaptchaImage(ctx context.Context, s *session, token string) ([]byte, error) {
	path := "/auth/captcha/image?t=" + url.QueryEscape(token)
	req, err := http.NewRequestWithContext(ctx, "GET", s.endpoint(path), nil)
	if err != nil {
		return nil, errors.New("create captcha image request")
	}
	req.Header.Set("User-Agent", "ACLCloudFreeBotToolKit/acl-renew")

	resp, err := s.client.Do(req)
	if err != nil {
		return nil, errors.New("captcha image request failed")
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return nil, fmt.Errorf("read captcha image: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("GET captcha image: HTTP %d", resp.StatusCode)
	}
	return data, nil
}
