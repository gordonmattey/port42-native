package main

import (
	"os"
	"path/filepath"
	"testing"
)

// The gateway log and the kept previous run's log are readable by this user only (GW-07), including
// when an older build left the log 0644.
func TestTheGatewayLogsArePrivate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gateway.log")
	if err := os.WriteFile(path, []byte("an older run"), 0644); err != nil {
		t.Fatal(err)
	}
	f, err := openGatewayLog(path)
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	for _, p := range []string{path, path + ".1"} {
		info, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0600 {
			t.Errorf("%s is %v, want 0600", filepath.Base(p), info.Mode().Perm())
		}
	}
	if kept, _ := os.ReadFile(path + ".1"); string(kept) != "an older run" {
		t.Fatalf("the previous run's log was not kept: %q", kept)
	}
}
