package main

import (
	"bytes"
	"strings"
	"testing"
)

var testInstances = []Instance{
	{Port: 4242, Name: "gordon"},
	{Port: 4245, Name: "gordontest3"},
}

func TestChooseInstanceNoneRunning(t *testing.T) {
	var out bytes.Buffer
	if _, err := ChooseInstance(&out, strings.NewReader(""), nil, true); err != ErrNotRunning {
		t.Errorf("expected ErrNotRunning, got %v", err)
	}
}

func TestChooseInstanceSingleNeedsNoQuestion(t *testing.T) {
	var out bytes.Buffer
	one := []Instance{{Port: 4242, Name: "gordon"}}
	got, err := ChooseInstance(&out, strings.NewReader(""), one, true)
	if err != nil || got.Port != 4242 {
		t.Errorf("single instance = %+v, %v", got, err)
	}
	// The everyday case is one instance, and it must not ask anything.
	if out.Len() != 0 {
		t.Errorf("nothing should be printed for a single instance: %q", out.String())
	}
}

func TestChooseInstanceAsksWhenSeveral(t *testing.T) {
	var out bytes.Buffer
	got, err := ChooseInstance(&out, strings.NewReader("2\n"), testInstances, true)
	if err != nil || got.Port != 4245 {
		t.Errorf("answer 2 = %+v, %v; want port 4245", got, err)
	}
	if !strings.Contains(out.String(), "gordontest3 (port 4245)") {
		t.Errorf("menu should name each instance and its port:\n%s", out.String())
	}
}

func TestChooseInstanceRefusesToGuessWhenNotInteractive(t *testing.T) {
	// Dropping a live agent into the wrong instance is not a guess worth making, so a scripted
	// run with several instances must fail with the list rather than pick one.
	var out bytes.Buffer
	_, err := ChooseInstance(&out, strings.NewReader(""), testInstances, false)
	if err == nil {
		t.Fatal("expected an error rather than a silent choice")
	}
	if !strings.Contains(err.Error(), "--port 4242") || !strings.Contains(err.Error(), "--port 4245") {
		t.Errorf("error should show how to disambiguate, got: %v", err)
	}
}

func TestChooseInstanceRejectsOutOfRange(t *testing.T) {
	var out bytes.Buffer
	if _, err := ChooseInstance(&out, strings.NewReader("7\n"), testInstances, true); err == nil {
		t.Error("expected an error for a choice outside the menu")
	}
}

func TestChooseInstanceEOFDoesNotGuess(t *testing.T) {
	// An interactive prompt that gets EOF has no answer. Unlike the space picker there is no
	// safe default here, so it must not fall through to an arbitrary instance.
	var out bytes.Buffer
	if _, err := ChooseInstance(&out, strings.NewReader(""), testInstances, true); err == nil {
		t.Error("expected an error rather than picking an instance on EOF")
	}
}

func TestCandidatePortsCoverTheDefaults(t *testing.T) {
	want := map[int]bool{42: false, DefaultPort: false}
	for _, p := range candidatePorts {
		if _, tracked := want[p]; tracked {
			want[p] = true
		}
	}
	for port, found := range want {
		if !found {
			t.Errorf("candidatePorts is missing %d", port)
		}
	}
}
