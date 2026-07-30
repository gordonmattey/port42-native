package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The CLI has NO ANONYMOUS MODE (GM, 2026-07-30).
//
// An earlier version returned "" on every failure so an unenrolled CLI would "keep working exactly as
// it does today" — reasoning inherited from a backward-compatibility concern that does not exist,
// since this CLI has never shipped. It protected nobody and degraded quietly to an anonymous caller.
//
// These tests assert the LOUD behaviour, and that each message names the thing the user has to fix.

func withHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	return home
}

func writeInstance(t *testing.T, home, instance, port, token string) {
	t.Helper()
	dir := filepath.Join(home, ".port42", instance)
	if err := os.MkdirAll(filepath.Join(dir, "tokens"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "gateway-port"), []byte(port+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if token != "" {
		if err := os.WriteFile(filepath.Join(dir, "tokens", "port42-cli"), []byte(token+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestFindsTheCredentialForTheTargetedPort(t *testing.T) {
	home := withHome(t)
	// Two instances, as a dev machine actually has. Their tokens deliberately do not interoperate,
	// so picking the wrong one would present prod's credential to a dev build.
	writeInstance(t, home, "port42", "4242", "p42_port42-cli_PROD")
	writeInstance(t, home, "port42dev3", "4245", "p42_port42-cli_DEV3")

	got, err := tokenForPort(4245)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "p42_port42-cli_DEV3" {
		t.Fatalf("picked the wrong instance's credential: %q", got)
	}
}

func TestNoInstanceClaimsThePortIsAnError(t *testing.T) {
	home := withHome(t)
	writeInstance(t, home, "port42", "4242", "p42_port42-cli_PROD")

	_, err := tokenForPort(4245)
	if err == nil {
		t.Fatal("returned silently instead of reporting an unmapped port")
	}
	if !strings.Contains(err.Error(), "4245") {
		t.Errorf("the error must name the port it could not map: %v", err)
	}
}

func TestMissingTokenNamesTheFileAndTheFix(t *testing.T) {
	home := withHome(t)
	writeInstance(t, home, "port42dev3", "4245", "") // mapped, but never enrolled

	_, err := tokenForPort(4245)
	if err == nil {
		t.Fatal("a missing credential passed silently")
	}
	msg := err.Error()
	if !strings.Contains(msg, "tokens/port42-cli") {
		t.Errorf("the error must name the file it looked for: %v", err)
	}
	if !strings.Contains(strings.ToLower(msg), "relaunch") {
		t.Errorf("the error must say how to fix it (FR10): %v", err)
	}
}

func TestEmptyTokenFileIsAnErrorNotAnEmptyCredential(t *testing.T) {
	home := withHome(t)
	writeInstance(t, home, "port42dev3", "4245", "")
	// A zero-byte file: present, unreadable as a credential. Must not become `Bearer `.
	tokenPath := filepath.Join(home, ".port42", "port42dev3", "tokens", "port42-cli")
	if err := os.WriteFile(tokenPath, []byte("  \n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := tokenForPort(4245); err == nil {
		t.Fatal("an empty credential file was accepted")
	}
}
