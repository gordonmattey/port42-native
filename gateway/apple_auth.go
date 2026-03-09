package main

import (
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	appleJWKSURL = "https://appleid.apple.com/auth/keys"
	appleIssuer  = "https://appleid.apple.com"
	defaultTTL   = 24 * time.Hour
)

// jwksKey is a single key from Apple's JWKS response.
type jwksKey struct {
	KID string `json:"kid"`
	KTY string `json:"kty"`
	Alg string `json:"alg"`
	Use string `json:"use"`
	N   string `json:"n"`
	E   string `json:"e"`
}

// jwksResponse is the JSON structure returned by Apple's JWKS endpoint.
type jwksResponse struct {
	Keys []jwksKey `json:"keys"`
}

// AppleAuthVerifier verifies Apple identity tokens (JWTs) against Apple's JWKS.
type AppleAuthVerifier struct {
	bundleID string
	jwksURL  string        // overridable for testing
	cacheTTL time.Duration // overridable for testing

	mu      sync.RWMutex
	keys    map[string]*rsa.PublicKey // kid -> public key
	fetched time.Time
}

// NewAppleAuthVerifier creates a verifier for the given bundle ID.
func NewAppleAuthVerifier(bundleID string) *AppleAuthVerifier {
	return &AppleAuthVerifier{
		bundleID: bundleID,
		jwksURL:  appleJWKSURL,
		cacheTTL: defaultTTL,
		keys:     make(map[string]*rsa.PublicKey),
	}
}

// Verify checks an Apple identity token JWT.
// It verifies the signature, issuer, audience, expiry, and nonce.
// Returns the Apple user ID (sub claim) on success.
func (v *AppleAuthVerifier) Verify(identityToken string, expectedNonce string) (string, error) {
	// Ensure we have keys
	if err := v.refreshKeysIfNeeded(); err != nil {
		return "", fmt.Errorf("fetch JWKS: %w", err)
	}

	// Parse and verify the JWT
	token, err := jwt.Parse(identityToken, func(token *jwt.Token) (interface{}, error) {
		// Ensure signing method is RSA
		if _, ok := token.Method.(*jwt.SigningMethodRSA); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}

		// Look up the key by kid
		kid, ok := token.Header["kid"].(string)
		if !ok {
			return nil, fmt.Errorf("missing kid in token header")
		}

		v.mu.RLock()
		key, exists := v.keys[kid]
		v.mu.RUnlock()
		if !exists {
			return nil, fmt.Errorf("unknown key ID: %s", kid)
		}

		return key, nil
	},
		jwt.WithIssuer(appleIssuer),
		jwt.WithAudience(v.bundleID),
		jwt.WithExpirationRequired(),
	)
	if err != nil {
		return "", fmt.Errorf("token validation: %w", err)
	}

	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok || !token.Valid {
		return "", fmt.Errorf("invalid token claims")
	}

	// Verify nonce: SHA256(expectedNonce) must match the nonce claim
	expectedHash := sha256Hex(expectedNonce)
	nonceClaim, ok := claims["nonce"].(string)
	if !ok || nonceClaim != expectedHash {
		return "", fmt.Errorf("nonce mismatch")
	}

	// Extract sub (Apple user ID)
	sub, ok := claims["sub"].(string)
	if !ok || sub == "" {
		return "", fmt.Errorf("missing sub claim")
	}

	return sub, nil
}

// refreshKeysIfNeeded fetches Apple's JWKS if the cache is expired or empty.
func (v *AppleAuthVerifier) refreshKeysIfNeeded() error {
	v.mu.RLock()
	needsRefresh := len(v.keys) == 0 || time.Since(v.fetched) > v.cacheTTL
	v.mu.RUnlock()

	if !needsRefresh {
		return nil
	}

	resp, err := http.Get(v.jwksURL)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}

	var jwks jwksResponse
	if err := json.Unmarshal(body, &jwks); err != nil {
		return err
	}

	keys := make(map[string]*rsa.PublicKey)
	for _, k := range jwks.Keys {
		if k.KTY != "RSA" {
			continue
		}
		pub, err := parseRSAPublicKey(k.N, k.E)
		if err != nil {
			continue
		}
		keys[k.KID] = pub
	}

	v.mu.Lock()
	v.keys = keys
	v.fetched = time.Now()
	v.mu.Unlock()

	return nil
}

// parseRSAPublicKey constructs an RSA public key from base64url-encoded N and E.
func parseRSAPublicKey(nStr, eStr string) (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(nStr)
	if err != nil {
		return nil, err
	}
	eBytes, err := base64.RawURLEncoding.DecodeString(eStr)
	if err != nil {
		return nil, err
	}

	n := new(big.Int).SetBytes(nBytes)
	e := new(big.Int).SetBytes(eBytes)

	return &rsa.PublicKey{
		N: n,
		E: int(e.Int64()),
	}, nil
}

// sha256Hex returns the hex-encoded SHA256 hash of a string.
func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}
