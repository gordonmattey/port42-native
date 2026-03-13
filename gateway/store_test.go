package main

import (
	"os"
	"testing"
)

func tempStore(t *testing.T) *MessageStore {
	t.Helper()
	dir := t.TempDir()
	s, err := NewMessageStore(dir)
	if err != nil {
		t.Fatalf("NewMessageStore: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestStoreAndRetrieve(t *testing.T) {
	s := tempStore(t)

	s.Store(Envelope{Type: "message", ChannelID: "ch1", MessageID: "m1", Timestamp: 1000})
	s.Store(Envelope{Type: "message", ChannelID: "ch1", MessageID: "m2", Timestamp: 2000})

	history, err := s.GetHistory("ch1", 100)
	if err != nil {
		t.Fatalf("GetHistory: %v", err)
	}
	if len(history) != 2 {
		t.Fatalf("expected 2 messages, got %d", len(history))
	}
	if history[0].MessageID != "m1" || history[1].MessageID != "m2" {
		t.Errorf("wrong order: %s, %s", history[0].MessageID, history[1].MessageID)
	}
}

func TestDeduplication(t *testing.T) {
	s := tempStore(t)

	s.Store(Envelope{Type: "message", ChannelID: "ch1", MessageID: "m1", Timestamp: 1000})
	s.Store(Envelope{Type: "message", ChannelID: "ch1", MessageID: "m1", Timestamp: 1000}) // duplicate

	history, err := s.GetHistory("ch1", 100)
	if err != nil {
		t.Fatalf("GetHistory: %v", err)
	}
	if len(history) != 1 {
		t.Fatalf("expected 1 message after dedup, got %d", len(history))
	}
}

func TestHistoryOrdering(t *testing.T) {
	s := tempStore(t)

	// Insert out of order
	s.Store(Envelope{Type: "message", ChannelID: "ch1", MessageID: "m3", Timestamp: 3000})
	s.Store(Envelope{Type: "message", ChannelID: "ch1", MessageID: "m1", Timestamp: 1000})
	s.Store(Envelope{Type: "message", ChannelID: "ch1", MessageID: "m2", Timestamp: 2000})

	history, err := s.GetHistory("ch1", 100)
	if err != nil {
		t.Fatalf("GetHistory: %v", err)
	}
	if len(history) != 3 {
		t.Fatalf("expected 3, got %d", len(history))
	}
	// Should come back in ascending timestamp order
	if history[0].MessageID != "m1" || history[1].MessageID != "m2" || history[2].MessageID != "m3" {
		t.Errorf("wrong order: %s, %s, %s", history[0].MessageID, history[1].MessageID, history[2].MessageID)
	}
}

func TestPruning(t *testing.T) {
	s := tempStore(t)

	for i := 0; i < 10; i++ {
		s.Store(Envelope{
			Type:      "message",
			ChannelID: "ch1",
			MessageID: "m" + string(rune('a'+i)),
			Timestamp: int64(1000 + i),
		})
	}

	s.Prune("ch1", 3)

	history, err := s.GetHistory("ch1", 100)
	if err != nil {
		t.Fatalf("GetHistory: %v", err)
	}
	if len(history) != 3 {
		t.Fatalf("expected 3 after prune, got %d", len(history))
	}
	// Should keep the 3 most recent
	if history[0].MessageID != "mh" || history[1].MessageID != "mi" || history[2].MessageID != "mj" {
		t.Errorf("wrong messages after prune: %s, %s, %s", history[0].MessageID, history[1].MessageID, history[2].MessageID)
	}
}

func TestEmptyChannel(t *testing.T) {
	s := tempStore(t)

	history, err := s.GetHistory("nonexistent", 100)
	if err != nil {
		t.Fatalf("GetHistory: %v", err)
	}
	if len(history) != 0 {
		t.Errorf("expected empty, got %d", len(history))
	}
}

func TestChannelIsolation(t *testing.T) {
	s := tempStore(t)

	s.Store(Envelope{Type: "message", ChannelID: "ch1", MessageID: "m1", Timestamp: 1000})
	s.Store(Envelope{Type: "message", ChannelID: "ch2", MessageID: "m2", Timestamp: 2000})

	h1, _ := s.GetHistory("ch1", 100)
	h2, _ := s.GetHistory("ch2", 100)

	if len(h1) != 1 || h1[0].MessageID != "m1" {
		t.Errorf("ch1: expected m1, got %v", h1)
	}
	if len(h2) != 1 || h2[0].MessageID != "m2" {
		t.Errorf("ch2: expected m2, got %v", h2)
	}
}

func TestSurvivesRestart(t *testing.T) {
	dir := t.TempDir()

	// First session
	s1, err := NewMessageStore(dir)
	if err != nil {
		t.Fatalf("NewMessageStore: %v", err)
	}
	s1.Store(Envelope{Type: "message", ChannelID: "ch1", MessageID: "m1", Timestamp: 1000})
	s1.Close()

	// Second session (simulates restart)
	s2, err := NewMessageStore(dir)
	if err != nil {
		t.Fatalf("NewMessageStore after restart: %v", err)
	}
	defer s2.Close()

	history, err := s2.GetHistory("ch1", 100)
	if err != nil {
		t.Fatalf("GetHistory: %v", err)
	}
	if len(history) != 1 || history[0].MessageID != "m1" {
		t.Errorf("message not preserved across restart: %v", history)
	}
}

func TestHistoryLimit(t *testing.T) {
	s := tempStore(t)

	for i := 0; i < 10; i++ {
		s.Store(Envelope{
			Type:      "message",
			ChannelID: "ch1",
			MessageID: "m" + string(rune('a'+i)),
			Timestamp: int64(1000 + i),
		})
	}

	// Request only last 3
	history, err := s.GetHistory("ch1", 3)
	if err != nil {
		t.Fatalf("GetHistory: %v", err)
	}
	if len(history) != 3 {
		t.Fatalf("expected 3, got %d", len(history))
	}
	// Should be the 3 most recent, in ascending order
	if history[0].MessageID != "mh" || history[1].MessageID != "mi" || history[2].MessageID != "mj" {
		t.Errorf("wrong messages: %s, %s, %s", history[0].MessageID, history[1].MessageID, history[2].MessageID)
	}
}

func TestSkipsEmptyFields(t *testing.T) {
	s := tempStore(t)

	// No message ID should be skipped
	s.Store(Envelope{Type: "message", ChannelID: "ch1", Timestamp: 1000})
	// No channel ID should be skipped
	s.Store(Envelope{Type: "message", MessageID: "m1", Timestamp: 1000})

	h, _ := s.GetHistory("ch1", 100)
	if len(h) != 0 {
		t.Errorf("expected 0, got %d", len(h))
	}

	// Suppress unused variable warning
	_ = os.DevNull
}
