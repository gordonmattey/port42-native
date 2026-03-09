package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// testKeyPair holds an RSA key pair and a key ID for test JWKS.
type testKeyPair struct {
	keyID      string
	privateKey *rsa.PrivateKey
}

func newTestKeyPair(t *testing.T) testKeyPair {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	return testKeyPair{keyID: "test-key-1", privateKey: key}
}

// jwksJSON returns a JSON JWKS containing the public key.
func (tk testKeyPair) jwksJSON(t *testing.T) []byte {
	t.Helper()
	pub := &tk.privateKey.PublicKey
	nBytes := pub.N.Bytes()
	eBytes := big.NewInt(int64(pub.E)).Bytes()

	jwks := map[string]interface{}{
		"keys": []map[string]interface{}{
			{
				"kty": "RSA",
				"kid": tk.keyID,
				"use": "sig",
				"alg": "RS256",
				"n":   base64.RawURLEncoding.EncodeToString(nBytes),
				"e":   base64.RawURLEncoding.EncodeToString(eBytes),
			},
		},
	}
	data, err := json.Marshal(jwks)
	if err != nil {
		t.Fatalf("marshal jwks: %v", err)
	}
	return data
}

// signToken creates a signed JWT with the given claims.
func (tk testKeyPair) signToken(t *testing.T, claims jwt.MapClaims) string {
	t.Helper()
	token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	token.Header["kid"] = tk.keyID
	signed, err := token.SignedString(tk.privateKey)
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}
	return signed
}

func hashedNonce(nonce string) string {
	h := sha256.Sum256([]byte(nonce))
	return hex.EncodeToString(h[:])
}

// startJWKSServer starts an HTTP server serving the JWKS JSON.
func startJWKSServer(t *testing.T, jwksData []byte) (*httptest.Server, *int) {
	t.Helper()
	fetchCount := new(int)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*fetchCount++
		w.Header().Set("Content-Type", "application/json")
		w.Write(jwksData)
	}))
	return srv, fetchCount
}

func validClaims(nonce string) jwt.MapClaims {
	return jwt.MapClaims{
		"iss":   "https://appleid.apple.com",
		"aud":   "com.port42.app",
		"sub":   "apple-user-001",
		"nonce": hashedNonce(nonce),
		"exp":   float64(time.Now().Add(time.Hour).Unix()),
		"iat":   float64(time.Now().Unix()),
	}
}

// --- Tests ---

func TestValidJWTPasses(t *testing.T) {
	kp := newTestKeyPair(t)
	jwksSrv, _ := startJWKSServer(t, kp.jwksJSON(t))
	defer jwksSrv.Close()

	v := NewAppleAuthVerifier("com.port42.app")
	v.jwksURL = jwksSrv.URL

	nonce := "test-nonce-abc"
	token := kp.signToken(t, validClaims(nonce))

	userID, err := v.Verify(token, nonce)
	if err != nil {
		t.Fatalf("expected valid, got error: %v", err)
	}
	if userID != "apple-user-001" {
		t.Fatalf("expected apple-user-001, got %s", userID)
	}
}

func TestWrongNonceRejects(t *testing.T) {
	kp := newTestKeyPair(t)
	jwksSrv, _ := startJWKSServer(t, kp.jwksJSON(t))
	defer jwksSrv.Close()

	v := NewAppleAuthVerifier("com.port42.app")
	v.jwksURL = jwksSrv.URL

	// Token has nonce for "real-nonce" but we verify with "different-nonce"
	claims := validClaims("real-nonce")
	token := kp.signToken(t, claims)

	_, err := v.Verify(token, "different-nonce")
	if err == nil {
		t.Fatal("expected error for wrong nonce")
	}
}

func TestWrongAudienceRejects(t *testing.T) {
	kp := newTestKeyPair(t)
	jwksSrv, _ := startJWKSServer(t, kp.jwksJSON(t))
	defer jwksSrv.Close()

	v := NewAppleAuthVerifier("com.port42.app")
	v.jwksURL = jwksSrv.URL

	nonce := "test-nonce"
	claims := validClaims(nonce)
	claims["aud"] = "com.evil.app"
	token := kp.signToken(t, claims)

	_, err := v.Verify(token, nonce)
	if err == nil {
		t.Fatal("expected error for wrong audience")
	}
}

func TestExpiredJWTRejects(t *testing.T) {
	kp := newTestKeyPair(t)
	jwksSrv, _ := startJWKSServer(t, kp.jwksJSON(t))
	defer jwksSrv.Close()

	v := NewAppleAuthVerifier("com.port42.app")
	v.jwksURL = jwksSrv.URL

	nonce := "test-nonce"
	claims := validClaims(nonce)
	claims["exp"] = float64(time.Now().Add(-time.Hour).Unix()) // expired
	token := kp.signToken(t, claims)

	_, err := v.Verify(token, nonce)
	if err == nil {
		t.Fatal("expected error for expired token")
	}
}

func TestWrongIssuerRejects(t *testing.T) {
	kp := newTestKeyPair(t)
	jwksSrv, _ := startJWKSServer(t, kp.jwksJSON(t))
	defer jwksSrv.Close()

	v := NewAppleAuthVerifier("com.port42.app")
	v.jwksURL = jwksSrv.URL

	nonce := "test-nonce"
	claims := validClaims(nonce)
	claims["iss"] = "https://evil.example.com"
	token := kp.signToken(t, claims)

	_, err := v.Verify(token, nonce)
	if err == nil {
		t.Fatal("expected error for wrong issuer")
	}
}

func TestMissingSubRejects(t *testing.T) {
	kp := newTestKeyPair(t)
	jwksSrv, _ := startJWKSServer(t, kp.jwksJSON(t))
	defer jwksSrv.Close()

	v := NewAppleAuthVerifier("com.port42.app")
	v.jwksURL = jwksSrv.URL

	nonce := "test-nonce"
	claims := validClaims(nonce)
	delete(claims, "sub")
	token := kp.signToken(t, claims)

	_, err := v.Verify(token, nonce)
	if err == nil {
		t.Fatal("expected error for missing sub claim")
	}
}

func TestInvalidSignatureRejects(t *testing.T) {
	kp := newTestKeyPair(t)
	otherKP := newTestKeyPair(t) // different key
	jwksSrv, _ := startJWKSServer(t, kp.jwksJSON(t)) // serves kp's public key
	defer jwksSrv.Close()

	v := NewAppleAuthVerifier("com.port42.app")
	v.jwksURL = jwksSrv.URL

	nonce := "test-nonce"
	// Sign with otherKP but JWKS has kp's public key
	otherKP.keyID = kp.keyID // same kid so it tries to verify
	token := otherKP.signToken(t, validClaims(nonce))

	_, err := v.Verify(token, nonce)
	if err == nil {
		t.Fatal("expected error for invalid signature")
	}
}

func TestJWKSCaching(t *testing.T) {
	kp := newTestKeyPair(t)
	jwksSrv, fetchCount := startJWKSServer(t, kp.jwksJSON(t))
	defer jwksSrv.Close()

	v := NewAppleAuthVerifier("com.port42.app")
	v.jwksURL = jwksSrv.URL

	nonce1 := "nonce-1"
	token1 := kp.signToken(t, validClaims(nonce1))
	if _, err := v.Verify(token1, nonce1); err != nil {
		t.Fatalf("first verify failed: %v", err)
	}

	nonce2 := "nonce-2"
	claims2 := validClaims(nonce2)
	claims2["sub"] = "apple-user-002"
	token2 := kp.signToken(t, claims2)
	if _, err := v.Verify(token2, nonce2); err != nil {
		t.Fatalf("second verify failed: %v", err)
	}

	if *fetchCount != 1 {
		t.Fatalf("expected JWKS fetched once (cached), got %d fetches", *fetchCount)
	}
}

func TestJWKSRefreshAfterExpiry(t *testing.T) {
	kp := newTestKeyPair(t)
	jwksSrv, fetchCount := startJWKSServer(t, kp.jwksJSON(t))
	defer jwksSrv.Close()

	v := NewAppleAuthVerifier("com.port42.app")
	v.jwksURL = jwksSrv.URL
	v.cacheTTL = 1 * time.Millisecond // expire immediately

	nonce1 := "nonce-1"
	token1 := kp.signToken(t, validClaims(nonce1))
	if _, err := v.Verify(token1, nonce1); err != nil {
		t.Fatalf("first verify failed: %v", err)
	}

	time.Sleep(5 * time.Millisecond) // let cache expire

	nonce2 := "nonce-2"
	claims2 := validClaims(nonce2)
	claims2["sub"] = "apple-user-002"
	token2 := kp.signToken(t, claims2)
	if _, err := v.Verify(token2, nonce2); err != nil {
		t.Fatalf("second verify failed: %v", err)
	}

	if *fetchCount != 2 {
		t.Fatalf("expected JWKS fetched twice (cache expired), got %d fetches", *fetchCount)
	}
}

func TestHashedNonce(t *testing.T) {
	// SHA256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
	h := hashedNonce("hello")
	expected := "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
	if h != expected {
		t.Fatalf("expected %s, got %s", expected, h)
	}
}

