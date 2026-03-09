package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// mockVerifier is a test AuthVerifier that accepts tokens matching a pattern.
type mockVerifier struct {
	wantNonce string // expected nonce (raw, not hashed)
	userID    string // Apple user ID to return
	failWith  error  // if set, Verify returns this error
}

func (m *mockVerifier) Verify(identityToken string, expectedNonce string) (string, error) {
	if m.failWith != nil {
		return "", m.failWith
	}
	// In tests, the identity token is just "valid-token"
	if identityToken != "valid-token" {
		return "", fmt.Errorf("invalid token")
	}
	return m.userID, nil
}

func setupTestServer(gw *Gateway) (*httptest.Server, string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", gw.HandleWebSocket)
	srv := httptest.NewServer(mux)
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	return srv, wsURL
}

func dialAndRead(t *testing.T, ctx context.Context, wsURL string) (*websocket.Conn, Envelope) {
	t.Helper()
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial failed: %v", err)
	}
	_, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read failed: %v", err)
	}
	var env Envelope
	if err := json.Unmarshal(data, &env); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	return conn, env
}

func sendEnvelope(t *testing.T, ctx context.Context, conn *websocket.Conn, env Envelope) {
	t.Helper()
	data, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatalf("write failed: %v", err)
	}
}

func readEnvelope(t *testing.T, ctx context.Context, conn *websocket.Conn) Envelope {
	t.Helper()
	_, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read failed: %v", err)
	}
	var env Envelope
	if err := json.Unmarshal(data, &env); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	return env
}

// --- Tests ---

func TestNoAuthChallenge(t *testing.T) {
	// Without an auth verifier, no challenge should be sent.
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial failed: %v", err)
	}
	defer conn.CloseNow()

	// Send identify immediately (no challenge expected)
	sendEnvelope(t, ctx, conn, Envelope{
		Type:     "identify",
		SenderID: "peer-1",
		SenderName: "Test",
	})

	// Should get welcome back
	env := readEnvelope(t, ctx, conn)
	if env.Type != "welcome" {
		t.Fatalf("expected welcome, got %s", env.Type)
	}
	if env.SenderID != "peer-1" {
		t.Fatalf("expected sender_id peer-1, got %s", env.SenderID)
	}
}

func TestChallengeSendsNonce(t *testing.T) {
	// With an auth verifier, a challenge should be sent first.
	gw := NewGateway()
	gw.authVerifier = &mockVerifier{userID: "apple-123"}
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, env := dialAndRead(t, ctx, wsURL)
	defer conn.CloseNow()

	if env.Type != "challenge" {
		t.Fatalf("expected challenge, got %s", env.Type)
	}
	if env.Nonce == "" {
		t.Fatal("challenge nonce is empty")
	}
	if len(env.Nonce) != 64 {
		t.Fatalf("expected 64-char hex nonce, got %d chars", len(env.Nonce))
	}
}

func TestTwoConnectionsGetDifferentNonces(t *testing.T) {
	gw := NewGateway()
	gw.authVerifier = &mockVerifier{userID: "apple-123"}
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn1, env1 := dialAndRead(t, ctx, wsURL)
	defer conn1.CloseNow()

	conn2, env2 := dialAndRead(t, ctx, wsURL)
	defer conn2.CloseNow()

	if env1.Nonce == env2.Nonce {
		t.Fatal("two connections got the same nonce")
	}
}

func TestAuthenticatedIdentify(t *testing.T) {
	gw := NewGateway()
	gw.authVerifier = &mockVerifier{userID: "apple-user-abc"}
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, challenge := dialAndRead(t, ctx, wsURL)
	defer conn.CloseNow()

	if challenge.Type != "challenge" {
		t.Fatalf("expected challenge, got %s", challenge.Type)
	}

	// Send identify with valid token
	sendEnvelope(t, ctx, conn, Envelope{
		Type:          "identify",
		SenderID:      "peer-1",
		SenderName:    "Test",
		IdentityToken: "valid-token",
		AuthType:      "apple",
	})

	// Should get welcome
	welcome := readEnvelope(t, ctx, conn)
	if welcome.Type != "welcome" {
		t.Fatalf("expected welcome, got %s", welcome.Type)
	}

	// Verify Apple ID mapping was stored
	gw.mu.RLock()
	mappedPeer := gw.appleIDs["apple-user-abc"]
	gw.mu.RUnlock()
	if mappedPeer != "peer-1" {
		t.Fatalf("expected apple ID mapped to peer-1, got %s", mappedPeer)
	}
}

func TestInvalidTokenRejected(t *testing.T) {
	gw := NewGateway()
	gw.authVerifier = &mockVerifier{failWith: fmt.Errorf("bad signature")}
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, challenge := dialAndRead(t, ctx, wsURL)
	defer conn.CloseNow()

	if challenge.Type != "challenge" {
		t.Fatalf("expected challenge, got %s", challenge.Type)
	}

	// Send identify with token that the verifier will reject
	sendEnvelope(t, ctx, conn, Envelope{
		Type:          "identify",
		SenderID:      "peer-1",
		SenderName:    "Evil",
		IdentityToken: "valid-token",
		AuthType:      "apple",
	})

	// Connection should be closed (read will fail)
	_, _, err := conn.Read(ctx)
	if err == nil {
		t.Fatal("expected connection to be closed after auth failure")
	}
}

func TestUnauthenticatedAllowedWithWarning(t *testing.T) {
	// Auth is enabled but client sends no token. Should be allowed (backward compat).
	gw := NewGateway()
	gw.authVerifier = &mockVerifier{userID: "apple-123"}
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, challenge := dialAndRead(t, ctx, wsURL)
	defer conn.CloseNow()

	if challenge.Type != "challenge" {
		t.Fatalf("expected challenge, got %s", challenge.Type)
	}

	// Send identify without any token
	sendEnvelope(t, ctx, conn, Envelope{
		Type:       "identify",
		SenderID:   "peer-noauth",
		SenderName: "Legacy",
	})

	// Should still get welcome (backward compat)
	welcome := readEnvelope(t, ctx, conn)
	if welcome.Type != "welcome" {
		t.Fatalf("expected welcome, got %s", welcome.Type)
	}
}

func TestNonceConsumedAfterUse(t *testing.T) {
	gw := NewGateway()

	// Generate a nonce
	nonce, err := gw.generateNonce()
	if err != nil {
		t.Fatalf("generateNonce failed: %v", err)
	}

	// First consume should succeed
	if !gw.consumeNonce(nonce) {
		t.Fatal("first consumeNonce should return true")
	}

	// Second consume should fail
	if gw.consumeNonce(nonce) {
		t.Fatal("second consumeNonce should return false (already consumed)")
	}
}

func TestNonceLength(t *testing.T) {
	gw := NewGateway()
	nonce, err := gw.generateNonce()
	if err != nil {
		t.Fatalf("generateNonce failed: %v", err)
	}
	// 32 bytes = 64 hex chars
	if len(nonce) != 64 {
		t.Fatalf("expected 64-char nonce, got %d", len(nonce))
	}
}

func TestEnvelopeAuthFieldsJSON(t *testing.T) {
	env := Envelope{
		Type:          "identify",
		SenderID:      "peer-1",
		IdentityToken: "jwt-token-here",
		AuthType:      "apple",
		Nonce:         "abc123",
	}
	data, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}

	var decoded Envelope
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}

	if decoded.IdentityToken != "jwt-token-here" {
		t.Fatalf("identity_token mismatch: %s", decoded.IdentityToken)
	}
	if decoded.AuthType != "apple" {
		t.Fatalf("auth_type mismatch: %s", decoded.AuthType)
	}
	if decoded.Nonce != "abc123" {
		t.Fatalf("nonce mismatch: %s", decoded.Nonce)
	}
}

func TestAppleIDMappingSurvivesDisconnect(t *testing.T) {
	gw := NewGateway()
	gw.authVerifier = &mockVerifier{userID: "apple-persist-123"}
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, challenge := dialAndRead(t, ctx, wsURL)
	if challenge.Type != "challenge" {
		t.Fatalf("expected challenge, got %s", challenge.Type)
	}

	sendEnvelope(t, ctx, conn, Envelope{
		Type:          "identify",
		SenderID:      "peer-persist",
		SenderName:    "Test",
		IdentityToken: "valid-token",
		AuthType:      "apple",
	})

	welcome := readEnvelope(t, ctx, conn)
	if welcome.Type != "welcome" {
		t.Fatalf("expected welcome, got %s", welcome.Type)
	}

	// Disconnect
	conn.Close(websocket.StatusNormalClosure, "bye")
	time.Sleep(50 * time.Millisecond) // let removePeer run

	// Apple ID mapping should still exist
	gw.mu.RLock()
	mappedPeer := gw.appleIDs["apple-persist-123"]
	gw.mu.RUnlock()
	if mappedPeer != "peer-persist" {
		t.Fatalf("apple ID mapping lost after disconnect, got %q", mappedPeer)
	}
}

func TestAppleIDMappingUpdatesOnReconnect(t *testing.T) {
	gw := NewGateway()
	gw.authVerifier = &mockVerifier{userID: "apple-reconnect-456"}
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// First connection with peer-old
	conn1, _ := dialAndRead(t, ctx, wsURL)
	sendEnvelope(t, ctx, conn1, Envelope{
		Type: "identify", SenderID: "peer-old", SenderName: "Old",
		IdentityToken: "valid-token", AuthType: "apple",
	})
	readEnvelope(t, ctx, conn1) // welcome
	conn1.Close(websocket.StatusNormalClosure, "bye")
	time.Sleep(50 * time.Millisecond)

	// Reconnect with same Apple ID but new peer ID
	conn2, _ := dialAndRead(t, ctx, wsURL)
	sendEnvelope(t, ctx, conn2, Envelope{
		Type: "identify", SenderID: "peer-new", SenderName: "New",
		IdentityToken: "valid-token", AuthType: "apple",
	})
	welcome := readEnvelope(t, ctx, conn2)
	if welcome.Type != "welcome" {
		t.Fatalf("expected welcome, got %s", welcome.Type)
	}
	conn2.CloseNow()

	// Mapping should be updated to the new peer ID
	gw.mu.RLock()
	mappedPeer := gw.appleIDs["apple-reconnect-456"]
	gw.mu.RUnlock()
	if mappedPeer != "peer-new" {
		t.Fatalf("expected mapping to peer-new, got %s", mappedPeer)
	}
}

func TestEnvelopeAuthFieldsOmitEmpty(t *testing.T) {
	// Auth fields should be omitted when empty (backward compat)
	env := Envelope{Type: "welcome", SenderID: "peer-1"}
	data, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	s := string(data)
	if strings.Contains(s, "nonce") {
		t.Fatalf("empty nonce should be omitted: %s", s)
	}
	if strings.Contains(s, "identity_token") {
		t.Fatalf("empty identity_token should be omitted: %s", s)
	}
	if strings.Contains(s, "auth_type") {
		t.Fatalf("empty auth_type should be omitted: %s", s)
	}
}
