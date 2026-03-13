package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"path/filepath"
	"sync/atomic"

	_ "modernc.org/sqlite"
)

// MessageStore persists channel messages to SQLite for history replay.
type MessageStore struct {
	db          *sql.DB
	insertCount atomic.Int64
}

// NewMessageStore opens or creates the message database in dataDir.
func NewMessageStore(dataDir string) (*MessageStore, error) {
	dbPath := filepath.Join(dataDir, "gateway-messages.sqlite")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, err
	}

	// WAL mode for better concurrent read/write performance
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, err
	}

	// Create table and index
	if _, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS channel_messages (
			id         TEXT PRIMARY KEY,
			channel_id TEXT NOT NULL,
			envelope   TEXT NOT NULL,
			timestamp  INTEGER NOT NULL
		)
	`); err != nil {
		db.Close()
		return nil, err
	}
	if _, err := db.Exec(`
		CREATE INDEX IF NOT EXISTS idx_channel_ts ON channel_messages(channel_id, timestamp)
	`); err != nil {
		db.Close()
		return nil, err
	}

	return &MessageStore{db: db}, nil
}

// Store persists a message envelope. Skips duplicates by message ID.
func (s *MessageStore) Store(env Envelope) {
	if env.MessageID == "" || env.ChannelID == "" {
		return
	}

	data, err := json.Marshal(env)
	if err != nil {
		log.Printf("[store] marshal error: %v", err)
		return
	}

	_, err = s.db.Exec(
		"INSERT OR IGNORE INTO channel_messages (id, channel_id, envelope, timestamp) VALUES (?, ?, ?, ?)",
		env.MessageID, env.ChannelID, string(data), env.Timestamp,
	)
	if err != nil {
		log.Printf("[store] insert error: %v", err)
		return
	}

	// Prune every 100 inserts
	if s.insertCount.Add(1)%100 == 0 {
		s.Prune(env.ChannelID, 500)
	}
}

// GetHistory returns the last `limit` messages for a channel, ordered by timestamp ascending.
func (s *MessageStore) GetHistory(channelID string, limit int) ([]Envelope, error) {
	// Subquery gets the newest N, outer query re-orders ascending
	rows, err := s.db.Query(`
		SELECT envelope FROM (
			SELECT envelope, timestamp FROM channel_messages
			WHERE channel_id = ?
			ORDER BY timestamp DESC
			LIMIT ?
		) sub ORDER BY timestamp ASC
	`, channelID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result []Envelope
	for rows.Next() {
		var data string
		if err := rows.Scan(&data); err != nil {
			continue
		}
		var env Envelope
		if err := json.Unmarshal([]byte(data), &env); err != nil {
			continue
		}
		result = append(result, env)
	}
	return result, rows.Err()
}

// Prune removes old messages beyond keepLast for a channel.
func (s *MessageStore) Prune(channelID string, keepLast int) {
	_, err := s.db.Exec(`
		DELETE FROM channel_messages
		WHERE channel_id = ? AND id NOT IN (
			SELECT id FROM channel_messages
			WHERE channel_id = ?
			ORDER BY timestamp DESC
			LIMIT ?
		)
	`, channelID, channelID, keepLast)
	if err != nil {
		log.Printf("[store] prune error: %v", err)
	}
}

// Close closes the database connection.
func (s *MessageStore) Close() error {
	return s.db.Close()
}
