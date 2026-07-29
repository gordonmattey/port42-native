package main

import (
	"bytes"
	"strings"
	"testing"
)

var testSpaces = []Space{
	{ID: "3BE527C8", Name: "general"},
	{ID: "4B60409C", Name: "space-2"},
}

func TestMatchSpaceByIDAndName(t *testing.T) {
	got, err := MatchSpace(testSpaces, "4B60409C")
	if err != nil || got.Name != "space-2" {
		t.Errorf("by id = %+v, %v; want space-2", got, err)
	}

	got, err = MatchSpace(testSpaces, "GENERAL")
	if err != nil || got.ID != "3BE527C8" {
		t.Errorf("by name is case-insensitive: got %+v, %v", got, err)
	}
}

func TestMatchSpaceUnknownListsTheOptions(t *testing.T) {
	_, err := MatchSpace(testSpaces, "nope")
	if err == nil {
		t.Fatal("expected an error for an unknown space")
	}
	// The error has to be actionable, so it carries the available names.
	if !strings.Contains(err.Error(), "general") || !strings.Contains(err.Error(), "space-2") {
		t.Errorf("error should list the available spaces, got: %v", err)
	}
}

func TestMatchSpaceAmbiguousNameRefusesToGuess(t *testing.T) {
	dupes := []Space{{ID: "a", Name: "dev"}, {ID: "b", Name: "Dev"}}
	if _, err := MatchSpace(dupes, "dev"); err == nil {
		t.Error("two spaces share a name, so this must fail rather than pick one")
	}
}

func TestChooseSpaceDefaultsToCurrentOnEnter(t *testing.T) {
	var out bytes.Buffer
	got, err := ChooseSpace(&out, strings.NewReader("\n"), testSpaces, testSpaces[1])
	if err != nil || got.ID != "4B60409C" {
		t.Errorf("empty answer = %+v, %v; want the current space", got, err)
	}
	// The current space must be visibly marked, otherwise "just press enter" is a guess.
	if !strings.Contains(out.String(), "* 2) space-2") {
		t.Errorf("current space not marked in the menu:\n%s", out.String())
	}
}

func TestChooseSpaceByNumber(t *testing.T) {
	var out bytes.Buffer
	got, err := ChooseSpace(&out, strings.NewReader("1\n"), testSpaces, testSpaces[1])
	if err != nil || got.Name != "general" {
		t.Errorf("answer 1 = %+v, %v; want general", got, err)
	}
}

func TestChooseSpaceRejectsOutOfRange(t *testing.T) {
	var out bytes.Buffer
	if _, err := ChooseSpace(&out, strings.NewReader("9\n"), testSpaces, testSpaces[0]); err == nil {
		t.Error("expected an error for a choice outside the menu")
	}
	if _, err := ChooseSpace(&out, strings.NewReader("banana\n"), testSpaces, testSpaces[0]); err == nil {
		t.Error("expected an error for a non-numeric choice")
	}
}

func TestChooseSpaceEOFTakesTheDefault(t *testing.T) {
	// A closed stdin must not error out; it means nobody is there to answer.
	var out bytes.Buffer
	got, err := ChooseSpace(&out, strings.NewReader(""), testSpaces, testSpaces[0])
	if err != nil || got.ID != "3BE527C8" {
		t.Errorf("EOF = %+v, %v; want the current space", got, err)
	}
}

func TestChooseSpaceSkipsMenuForASingleSpace(t *testing.T) {
	var out bytes.Buffer
	one := []Space{{ID: "only", Name: "general"}}
	got, err := ChooseSpace(&out, strings.NewReader(""), one, one[0])
	if err != nil || got.ID != "only" {
		t.Errorf("single space = %+v, %v", got, err)
	}
	if out.Len() != 0 {
		t.Errorf("no menu should be shown when there is nothing to choose between: %q", out.String())
	}
}

func TestDecodeContentUnwrapsJSONString(t *testing.T) {
	// The gateway hands bridge values back either as JSON or as a JSON string holding JSON.
	var direct []Space
	if err := decodeContent([]byte(`[{"id":"a","name":"x"}]`), &direct); err != nil || len(direct) != 1 {
		t.Errorf("direct decode failed: %v %+v", err, direct)
	}
	var wrapped []Space
	if err := decodeContent([]byte(`"[{\"id\":\"a\",\"name\":\"x\"}]"`), &wrapped); err != nil || len(wrapped) != 1 {
		t.Errorf("wrapped decode failed: %v %+v", err, wrapped)
	}
}
