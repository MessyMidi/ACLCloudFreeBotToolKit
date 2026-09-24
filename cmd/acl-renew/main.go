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

const version = "0.5.0"

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
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()

	result, err := renew.Check(ctx, config)
	if err != nil {
		log.Printf("[renew] ERROR: %v", err)
		os.Exit(1)
	}
	log.Printf("[renew] %s", result.Message)
}
