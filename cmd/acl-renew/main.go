// ACLCloudFreeBotToolKit
// Copyright (C) 2026 MessyMidi
//
// SPDX-License-Identifier: AGPL-3.0-only
// Additional terms under AGPLv3 Section 7:
// see /ADDITIONAL_TERMS.md

package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/MessyMidi/ACLCloudFreeBotToolKit/internal/renew"
)

// version is set at build time from package.json (see scripts/build-renew.mjs).
var version = "dev"

func main() {
	log.SetFlags(0)
	if len(os.Args) == 2 && os.Args[1] == "version" {
		fmt.Printf("acl-renew %s\n", version)
		return
	}
	if len(os.Args) != 2 || os.Args[1] != "check" {
		fmt.Fprintln(os.Stderr, "usage: acl-renew check|version")
		os.Exit(2)
	}

	config, err := renew.LoadConfigFromEnv()
	if err != nil {
		log.Printf("[renew] ERROR: %v", err)
		os.Exit(1)
	}
	if !config.Enabled {
		log.Print("[renew] Automatic renewal is disabled")
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	// One check can solve Cap twice -- once for the login, once for the renewal
	// gate -- and a third time when the cached session turns out to be expired.
	// Each round is three HTTP calls plus a concurrent proof of work, so the
	// budget has to cover several solves, not one.
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()

	result, err := renew.Check(ctx, config)
	if err != nil {
		log.Printf("[renew] ERROR: %v", err)
		os.Exit(1)
	}
	log.Printf("[renew] %s", result.Message)
}
