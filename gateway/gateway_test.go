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
	// Without an auth verifier, a no_auth hint is sent instead of a challenge.
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, noAuth := dialAndRead(t, ctx, wsURL)
	defer conn.CloseNow()

	if noAuth.Type != "no_auth" {
		t.Fatalf("expected no_auth, got %s", noAuth.Type)
	}

	// Send identify immediately
	sendEnvelope(t, ctx, conn, Envelope{
		Type:       "identify",
		SenderID:   "peer-1",
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

func TestUnauthenticatedRejectedWhenAuthEnabled(t *testing.T) {
	// Auth is enabled but client sends no token. Should be rejected.
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

	// Connection should be closed (auth required)
	_, _, err := conn.Read(ctx)
	if err == nil {
		t.Fatal("expected connection to be closed when auth required but no token provided")
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

// --- Security hardening tests ---

func TestJoinRequiresTokenForNewMemberWithAuth(t *testing.T) {
	// Token enforcement only active when authVerifier is set (public hosting)
	gw := NewGateway()
	gw.authVerifier = &mockVerifier{userID: "apple-a"}
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Peer A creates channel (first member, no token needed)
	connA, _ := dialAndRead(t, ctx, wsURL)
	defer connA.CloseNow()
	sendEnvelope(t, ctx, connA, Envelope{Type: "identify", SenderID: "peer-a", SenderName: "A", IdentityToken: "valid-token", AuthType: "apple"})
	readEnvelope(t, ctx, connA) // welcome
	sendEnvelope(t, ctx, connA, Envelope{Type: "join", ChannelID: "chan-1"})
	readEnvelope(t, ctx, connA) // presence

	// Peer B tries to join without token
	connB, _ := dialAndRead(t, ctx, wsURL)
	defer connB.CloseNow()
	sendEnvelope(t, ctx, connB, Envelope{Type: "identify", SenderID: "peer-b", SenderName: "B", IdentityToken: "valid-token", AuthType: "apple"})
	readEnvelope(t, ctx, connB) // welcome
	sendEnvelope(t, ctx, connB, Envelope{Type: "join", ChannelID: "chan-1"})
	env := readEnvelope(t, ctx, connB)
	if env.Type != "error" {
		t.Fatalf("expected error for join without token, got %s", env.Type)
	}
}

func TestJoinAllowedWithoutTokenOnLocalhost(t *testing.T) {
	// Without authVerifier (localhost mode), joins are permissive
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Peer A creates channel
	connA, _ := dialAndRead(t, ctx, wsURL)
	defer connA.CloseNow()
	sendEnvelope(t, ctx, connA, Envelope{Type: "identify", SenderID: "peer-a", SenderName: "A"})
	readEnvelope(t, ctx, connA) // welcome
	sendEnvelope(t, ctx, connA, Envelope{Type: "join", ChannelID: "chan-local"})
	readEnvelope(t, ctx, connA) // presence

	// Peer B joins without token (localhost mode allows it)
	connB, _ := dialAndRead(t, ctx, wsURL)
	defer connB.CloseNow()
	sendEnvelope(t, ctx, connB, Envelope{Type: "identify", SenderID: "peer-b", SenderName: "B"})
	readEnvelope(t, ctx, connB) // welcome
	sendEnvelope(t, ctx, connB, Envelope{Type: "join", ChannelID: "chan-local"})
	env := readEnvelope(t, ctx, connB)
	if env.Type != "presence" {
		t.Fatalf("expected presence (localhost allows tokenless join), got %s (error: %s)", env.Type, env.Error)
	}
}

func TestJoinWithValidToken(t *testing.T) {
	// Token-based join works in both modes; test with auth enabled
	gw := NewGateway()
	gw.authVerifier = &mockVerifier{userID: "apple-tok"}
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Peer A creates channel and generates token
	connA, _ := dialAndRead(t, ctx, wsURL)
	defer connA.CloseNow()
	sendEnvelope(t, ctx, connA, Envelope{Type: "identify", SenderID: "peer-a", SenderName: "A", IdentityToken: "valid-token", AuthType: "apple"})
	readEnvelope(t, ctx, connA) // welcome
	sendEnvelope(t, ctx, connA, Envelope{Type: "join", ChannelID: "chan-token"})
	readEnvelope(t, ctx, connA) // presence

	sendEnvelope(t, ctx, connA, Envelope{Type: "create_token", ChannelID: "chan-token"})
	tokenEnv := readEnvelope(t, ctx, connA)
	if tokenEnv.Type != "token" {
		t.Fatalf("expected token, got %s", tokenEnv.Type)
	}

	// Peer B joins with valid token
	connB, _ := dialAndRead(t, ctx, wsURL)
	defer connB.CloseNow()
	sendEnvelope(t, ctx, connB, Envelope{Type: "identify", SenderID: "peer-b", SenderName: "B", IdentityToken: "valid-token", AuthType: "apple"})
	readEnvelope(t, ctx, connB) // welcome
	sendEnvelope(t, ctx, connB, Envelope{Type: "join", ChannelID: "chan-token", Token: tokenEnv.Token})
	env := readEnvelope(t, ctx, connB)
	if env.Type != "presence" {
		t.Fatalf("expected presence after valid token join, got %s", env.Type)
	}
}

func TestRateLimiting(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _ := dialAndRead(t, ctx, wsURL)
	defer conn.CloseNow()
	sendEnvelope(t, ctx, conn, Envelope{Type: "identify", SenderID: "peer-flood", SenderName: "Flood"})
	readEnvelope(t, ctx, conn) // welcome
	sendEnvelope(t, ctx, conn, Envelope{Type: "join", ChannelID: "chan-flood"})
	readEnvelope(t, ctx, conn) // presence

	// Flood messages beyond rate limit
	gotRateLimited := false
	for i := 0; i < rateLimitPerSec+10; i++ {
		sendEnvelope(t, ctx, conn, Envelope{
			Type:      "message",
			ChannelID: "chan-flood",
			SenderID:  "peer-flood",
			MessageID: fmt.Sprintf("msg-%d", i),
		})
	}

	// Read responses, should see at least one rate limit error
	for i := 0; i < rateLimitPerSec+10; i++ {
		_, data, err := conn.Read(ctx)
		if err != nil {
			break
		}
		var env Envelope
		json.Unmarshal(data, &env)
		if env.Type == "error" && env.Error == "rate limit exceeded" {
			gotRateLimited = true
			break
		}
	}
	if !gotRateLimited {
		t.Fatal("expected rate limit error after flooding messages")
	}
}

func TestChannelIDTooLong(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _ := dialAndRead(t, ctx, wsURL)
	defer conn.CloseNow()
	sendEnvelope(t, ctx, conn, Envelope{Type: "identify", SenderID: "peer-1", SenderName: "A"})
	readEnvelope(t, ctx, conn) // welcome

	longID := strings.Repeat("x", maxChannelIDLen+1)
	sendEnvelope(t, ctx, conn, Envelope{Type: "join", ChannelID: longID})
	env := readEnvelope(t, ctx, conn)
	if env.Type != "error" {
		t.Fatalf("expected error for long channel ID, got %s", env.Type)
	}
}

func TestPeerIDTooLong(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _ := dialAndRead(t, ctx, wsURL)
	defer conn.CloseNow()

	longID := strings.Repeat("x", maxPeerIDLen+1)
	sendEnvelope(t, ctx, conn, Envelope{Type: "identify", SenderID: longID, SenderName: "A"})

	// Connection should be closed
	_, _, err := conn.Read(ctx)
	if err == nil {
		t.Fatal("expected connection to be closed for oversized peer ID")
	}
}

func TestExistingMemberRejoinsWithoutToken(t *testing.T) {
	// When a peer disconnects and reconnects (new WS connection), their channel
	// membership is preserved because removePeer keeps channel membership.
	// This simulates that by having peer disconnect and reconnect.
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Peer A creates channel
	connA, _ := dialAndRead(t, ctx, wsURL)
	sendEnvelope(t, ctx, connA, Envelope{Type: "identify", SenderID: "peer-rejoin", SenderName: "A"})
	readEnvelope(t, ctx, connA) // welcome
	sendEnvelope(t, ctx, connA, Envelope{Type: "join", ChannelID: "chan-rejoin"})
	readEnvelope(t, ctx, connA) // presence

	// Disconnect (removePeer keeps channel membership)
	connA.Close(websocket.StatusNormalClosure, "bye")
	time.Sleep(100 * time.Millisecond)

	// Reconnect with same peer ID
	connA2, _ := dialAndRead(t, ctx, wsURL)
	defer connA2.CloseNow()
	sendEnvelope(t, ctx, connA2, Envelope{Type: "identify", SenderID: "peer-rejoin", SenderName: "A"})
	readEnvelope(t, ctx, connA2) // welcome

	// Rejoin as existing member (no token needed)
	sendEnvelope(t, ctx, connA2, Envelope{Type: "join", ChannelID: "chan-rejoin"})
	env := readEnvelope(t, ctx, connA2)
	if env.Type != "presence" {
		t.Fatalf("expected presence on rejoin as existing member, got %s (error: %s)", env.Type, env.Error)
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

func TestRPCRouting(t *testing.T) {
	gw := NewGateway()
	srv, wsURL := setupTestServer(gw)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// 1. Setup Host peer
	connHost, _ := dialAndRead(t, ctx, wsURL)
	defer connHost.CloseNow()
	sendEnvelope(t, ctx, connHost, Envelope{
		Type: "identify", SenderID: "host-peer", SenderName: "Host App", IsHost: true,
	})
	readEnvelope(t, ctx, connHost) // welcome
	sendEnvelope(t, ctx, connHost, Envelope{Type: "join", ChannelID: "rpc-chan"})
	readEnvelope(t, ctx, connHost) // presence

	// 2. Setup CLI peer
	connCLI, _ := dialAndRead(t, ctx, wsURL)
	defer connCLI.CloseNow()
	sendEnvelope(t, ctx, connCLI, Envelope{
		Type: "identify", SenderID: "cli-peer", SenderName: "Test CLI", IsHost: false,
	})
	readEnvelope(t, ctx, connCLI) // welcome
	sendEnvelope(t, ctx, connCLI, Envelope{Type: "join", ChannelID: "rpc-chan"})
	readEnvelope(t, ctx, connCLI) // presence (cli joined)
	_ = readEnvelope(t, ctx, connHost) // presence (host saw cli join)

	// 3. CLI sends a call
	callID := "call-123"
	sendEnvelope(t, ctx, connCLI, Envelope{
		Type: "call", ChannelID: "rpc-chan", Method: "terminal.exec", CallID: callID,
	})

	// 4. Host should receive the call
	hostCall := readEnvelope(t, ctx, connHost)
	if hostCall.Type != "call" {
		t.Fatalf("expected call on host, got %s", hostCall.Type)
	}
	if hostCall.CallID != callID {
		t.Fatalf("expected call_id %s, got %s", callID, hostCall.CallID)
	}
	if hostCall.SenderID != "cli-peer" {
		t.Fatalf("expected sender_id cli-peer, got %s", hostCall.SenderID)
	}

	// 5. Host sends a response
	sendEnvelope(t, ctx, connHost, Envelope{
		Type: "response", CallID: callID, TargetID: "cli-peer",
		Payload: json.RawMessage(`{"content":"success"}`),
	})

	// 6. CLI should receive the response
	cliResp := readEnvelope(t, ctx, connCLI)
	if cliResp.Type != "response" {
		t.Fatalf("expected response on cli, got %s", cliResp.Type)
	}
	if cliResp.CallID != callID {
		t.Fatalf("expected call_id %s, got %s", callID, cliResp.CallID)
	}
	var payload map[string]string
	json.Unmarshal(cliResp.Payload, &payload)
	if payload["content"] != "success" {
		t.Fatalf("expected success payload, got %v", payload)
	}
}
