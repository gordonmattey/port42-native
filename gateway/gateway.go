package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"nhooyr.io/websocket"
)

// Envelope is the wire format for all messages between client and gateway.
type Envelope struct {
	Type      string          `json:"type"`
	ChannelID string          `json:"channel_id,omitempty"`
	SenderID  string          `json:"sender_id,omitempty"`
	SenderName string         `json:"sender_name,omitempty"`
	PeerID    string          `json:"peer_id,omitempty"` // authenticated peer who sent this
	MessageID string          `json:"message_id,omitempty"`
	Payload   json.RawMessage `json:"payload,omitempty"`
	Timestamp int64           `json:"timestamp,omitempty"`
	Error     string          `json:"error,omitempty"`
	Token     string          `json:"token,omitempty"`
	// Presence fields
	OnlineIDs    []string `json:"online_ids,omitempty"`
	Status       string   `json:"status,omitempty"` // "online" or "offline"
	CompanionIDs []string `json:"companion_ids,omitempty"`
}

// Peer represents a connected client.
type Peer struct {
	ID       string
	Name     string
	Conn     *websocket.Conn
	Channels map[string]bool
	mu       sync.Mutex
}

func (p *Peer) Send(ctx context.Context, env Envelope) error {
	data, err := json.Marshal(env)
	if err != nil {
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.Conn.Write(ctx, websocket.MessageText, data)
}

// StoredMessage is a message held for an offline peer.
type StoredMessage struct {
	Envelope  Envelope
	Timestamp time.Time
}

// Gateway manages all connected peers and channel routing.
type Gateway struct {
	mu       sync.RWMutex
	peers    map[string]*Peer
	channels map[string]map[string]bool
	store    map[string][]StoredMessage
	// companions tracks companion IDs registered by each peer per channel
	// key: channelID -> peerID -> []companionID
	companions map[string]map[string][]string
	// tokens: channelID -> set of valid single-use join tokens
	tokens map[string]map[string]bool
}

func NewGateway() *Gateway {
	return &Gateway{
		peers:      make(map[string]*Peer),
		channels:   make(map[string]map[string]bool),
		store:      make(map[string][]StoredMessage),
		companions: make(map[string]map[string][]string),
		tokens:     make(map[string]map[string]bool),
	}
}

func (g *Gateway) HandleWebSocket(w http.ResponseWriter, req *http.Request) {
	conn, err := websocket.Accept(w, req, &websocket.AcceptOptions{
		OriginPatterns: []string{"*"},
	})
	if err != nil {
		log.Printf("[gateway] accept error: %v", err)
		return
	}
	defer conn.CloseNow()

	ctx := req.Context()

	// First message must be identify
	_, data, err := conn.Read(ctx)
	if err != nil {
		log.Printf("[gateway] read identify error: %v", err)
		return
	}

	var ident Envelope
	if err := json.Unmarshal(data, &ident); err != nil || ident.Type != "identify" || ident.SenderID == "" {
		conn.Close(websocket.StatusPolicyViolation, "first message must be identify with sender_id")
		return
	}

	peer := &Peer{
		ID:       ident.SenderID,
		Name:     ident.SenderName,
		Conn:     conn,
		Channels: make(map[string]bool),
	}

	g.addPeer(peer)
	defer g.removePeer(peer)

	log.Printf("[gateway] peer connected: %s", peer.ID)

	peer.Send(ctx, Envelope{Type: "welcome", SenderID: peer.ID})
	g.flushStored(ctx, peer)

	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			if websocket.CloseStatus(err) != -1 {
				log.Printf("[gateway] peer %s disconnected: %v", peer.ID, websocket.CloseStatus(err))
			} else {
				log.Printf("[gateway] peer %s read error: %v", peer.ID, err)
			}
			return
		}

		var env Envelope
		if err := json.Unmarshal(data, &env); err != nil {
			log.Printf("[gateway] peer %s bad json: %v", peer.ID, err)
			continue
		}

		env.PeerID = peer.ID // authenticated peer identity
		if env.Timestamp == 0 {
			env.Timestamp = time.Now().UnixMilli()
		}

		switch env.Type {
		case "join":
			if err := g.joinChannel(ctx, peer, env.ChannelID, env.CompanionIDs, env.Token); err != nil {
				peer.Send(ctx, Envelope{Type: "error", Error: err.Error(), ChannelID: env.ChannelID})
			} else {
				g.flushStoredForChannel(ctx, peer, env.ChannelID)
			}
		case "leave":
			g.leaveChannel(peer, env.ChannelID)
		case "message":
			g.routeMessage(ctx, peer, env)
		case "typing":
			g.broadcastTyping(ctx, peer, env)
		case "create_token":
			g.handleCreateToken(ctx, peer, env.ChannelID)
		case "ack":
			// Client acknowledges receipt
		default:
			peer.Send(ctx, Envelope{Type: "error", Error: "unknown type: " + env.Type})
		}
	}
}

func (g *Gateway) addPeer(p *Peer) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if old, ok := g.peers[p.ID]; ok {
		old.Conn.Close(websocket.StatusGoingAway, "replaced by new connection")
	}
	g.peers[p.ID] = p
}

func (g *Gateway) removePeer(p *Peer) {
	g.mu.Lock()
	// Collect channels and their companions before removing
	channels := make([]string, 0, len(p.Channels))
	channelCompanions := make(map[string][]string)
	for ch := range p.Channels {
		channels = append(channels, ch)
		if peerCompanions, ok := g.companions[ch]; ok {
			channelCompanions[ch] = peerCompanions[p.ID]
			delete(peerCompanions, p.ID)
			if len(peerCompanions) == 0 {
				delete(g.companions, ch)
			}
		}
	}
	if current, ok := g.peers[p.ID]; ok && current == p {
		delete(g.peers, p.ID)
		// Keep channel membership so store-and-forward works
	}
	g.mu.Unlock()

	// Broadcast offline for peer and companions to all channels
	ctx := context.Background()
	for _, ch := range channels {
		g.broadcastPresence(ctx, ch, p.ID, "offline")
		for _, cID := range channelCompanions[ch] {
			g.broadcastPresence(ctx, ch, cID, "offline")
		}
	}

	log.Printf("[gateway] peer disconnected: %s", p.ID)
}

func (g *Gateway) joinChannel(ctx context.Context, p *Peer, channelID string, companionIDs []string, token string) error {
	if channelID == "" {
		return fmt.Errorf("missing channel_id")
	}
	g.mu.Lock()

	// Token validation: first member (creator) is auto-authorized,
	// existing members rejoining are allowed, everyone else needs a valid token.
	members := g.channels[channelID]
	isFirstMember := members == nil || len(members) == 0
	isExistingMember := members != nil && members[p.ID]

	if !isFirstMember && !isExistingMember {
		// Require a valid token
		tokenSet := g.tokens[channelID]
		if token == "" || tokenSet == nil || !tokenSet[token] {
			g.mu.Unlock()
			log.Printf("[gateway] peer %s rejected from channel %s: invalid or missing join token", p.ID, channelID)
			return fmt.Errorf("invalid or missing join token")
		}
		// Consume the token (single-use)
		delete(tokenSet, token)
		if len(tokenSet) == 0 {
			delete(g.tokens, channelID)
		}
	}

	p.Channels[channelID] = true
	if g.channels[channelID] == nil {
		g.channels[channelID] = make(map[string]bool)
	}
	g.channels[channelID][p.ID] = true

	// Track companions for this peer in this channel
	if g.companions[channelID] == nil {
		g.companions[channelID] = make(map[string][]string)
	}
	g.companions[channelID][p.ID] = companionIDs

	// Collect current online members + all companions for this channel
	onlineSet := make(map[string]bool)
	for memberID := range g.channels[channelID] {
		if _, online := g.peers[memberID]; online {
			onlineSet[memberID] = true
			// Add this member's companions
			for _, cID := range g.companions[channelID][memberID] {
				onlineSet[cID] = true
			}
		}
	}
	var onlineIDs []string
	for id := range onlineSet {
		onlineIDs = append(onlineIDs, id)
	}

	g.mu.Unlock()

	// Send the joiner the full online list (peers + all companions)
	p.Send(ctx, Envelope{
		Type:      "presence",
		ChannelID: channelID,
		OnlineIDs: onlineIDs,
	})

	// Broadcast this peer's online status to others (include companions)
	g.broadcastPresence(ctx, channelID, p.ID, "online")
	for _, cID := range companionIDs {
		g.broadcastPresence(ctx, channelID, cID, "online")
	}

	log.Printf("[gateway] peer %s joined channel %s with %d companions", p.ID, channelID, len(companionIDs))
	return nil
}

// handleCreateToken generates a single-use join token for a channel.
// Only existing members can create tokens.
func (g *Gateway) handleCreateToken(ctx context.Context, p *Peer, channelID string) {
	if channelID == "" {
		p.Send(ctx, Envelope{Type: "error", Error: "create_token requires channel_id"})
		return
	}

	g.mu.Lock()
	// Verify the requesting peer is a member
	members := g.channels[channelID]
	if members == nil || !members[p.ID] {
		g.mu.Unlock()
		p.Send(ctx, Envelope{Type: "error", Error: "not a member of this channel", ChannelID: channelID})
		return
	}

	// Generate a random token
	b := make([]byte, 16)
	rand.Read(b)
	token := hex.EncodeToString(b)

	if g.tokens[channelID] == nil {
		g.tokens[channelID] = make(map[string]bool)
	}
	g.tokens[channelID][token] = true
	g.mu.Unlock()

	p.Send(ctx, Envelope{Type: "token", ChannelID: channelID, Token: token})
	log.Printf("[gateway] created join token for channel %s (requested by %s)", channelID, p.ID)
}

func (g *Gateway) flushStoredForChannel(ctx context.Context, p *Peer, channelID string) {
	g.mu.Lock()
	stored := g.store[p.ID]
	var remaining []StoredMessage
	var toSend []StoredMessage
	for _, sm := range stored {
		if sm.Envelope.ChannelID == channelID {
			toSend = append(toSend, sm)
		} else {
			remaining = append(remaining, sm)
		}
	}
	if len(toSend) == 0 {
		g.mu.Unlock()
		return
	}
	g.store[p.ID] = remaining
	g.mu.Unlock()

	log.Printf("[gateway] flushing %d stored channel messages for %s", len(toSend), p.ID)
	for _, sm := range toSend {
		if err := p.Send(ctx, sm.Envelope); err != nil {
			log.Printf("[gateway] flush send error for %s: %v", p.ID, err)
			g.mu.Lock()
			g.store[p.ID] = append(g.store[p.ID], toSend...)
			g.mu.Unlock()
			return
		}
	}
}

func (g *Gateway) leaveChannel(p *Peer, channelID string) {
	if channelID == "" {
		return
	}
	g.mu.Lock()

	// Get companion IDs before removing
	var companionIDs []string
	if peerCompanions, ok := g.companions[channelID]; ok {
		companionIDs = peerCompanions[p.ID]
		delete(peerCompanions, p.ID)
		if len(peerCompanions) == 0 {
			delete(g.companions, channelID)
		}
	}

	delete(p.Channels, channelID)
	if members, ok := g.channels[channelID]; ok {
		delete(members, p.ID)
		if len(members) == 0 {
			delete(g.channels, channelID)
		}
	}

	g.mu.Unlock()

	ctx := context.Background()
	g.broadcastPresence(ctx, channelID, p.ID, "offline")
	for _, cID := range companionIDs {
		g.broadcastPresence(ctx, channelID, cID, "offline")
	}

	log.Printf("[gateway] peer %s left channel %s", p.ID, channelID)
}

// broadcastPresence sends a presence update for a single peer to all other online members of a channel.
func (g *Gateway) broadcastPresence(ctx context.Context, channelID, peerID, status string) {
	g.mu.RLock()
	members := g.channels[channelID]
	var targets []*Peer
	for memberID := range members {
		if memberID != peerID {
			if peer, online := g.peers[memberID]; online {
				targets = append(targets, peer)
			}
		}
	}
	// Look up the sender's display name
	var senderName string
	if peer, ok := g.peers[peerID]; ok {
		senderName = peer.Name
	}
	g.mu.RUnlock()

	env := Envelope{
		Type:       "presence",
		ChannelID:  channelID,
		SenderID:   peerID,
		SenderName: senderName,
		Status:     status,
	}
	for _, peer := range targets {
		peer.Send(ctx, env)
	}
}

// broadcastTyping sends a typing indicator to all other online peers in the channel (no storage).
func (g *Gateway) broadcastTyping(ctx context.Context, sender *Peer, env Envelope) {
	if env.ChannelID == "" {
		return
	}
	g.mu.RLock()
	members := g.channels[env.ChannelID]
	var targets []*Peer
	for id := range members {
		if id != sender.ID {
			if peer, online := g.peers[id]; online {
				targets = append(targets, peer)
			}
		}
	}
	g.mu.RUnlock()

	for _, peer := range targets {
		peer.Send(ctx, env)
	}
}

func (g *Gateway) routeMessage(ctx context.Context, sender *Peer, env Envelope) {
	if env.ChannelID == "" {
		sender.Send(ctx, Envelope{Type: "error", Error: "message requires channel_id"})
		return
	}

	g.mu.RLock()
	members := g.channels[env.ChannelID]
	var targetIDs []string
	for id := range members {
		if id != sender.ID {
			targetIDs = append(targetIDs, id)
		}
	}
	g.mu.RUnlock()

	for _, id := range targetIDs {
		g.mu.RLock()
		peer, online := g.peers[id]
		g.mu.RUnlock()

		if online {
			if err := peer.Send(ctx, env); err != nil {
				log.Printf("[gateway] failed to send to %s: %v", id, err)
				g.storeForPeer(id, env)
			}
		} else {
			g.storeForPeer(id, env)
		}
	}

	sender.Send(ctx, Envelope{
		Type:      "ack",
		MessageID: env.MessageID,
		ChannelID: env.ChannelID,
	})
}

func (g *Gateway) storeForPeer(peerID string, env Envelope) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.store[peerID] = append(g.store[peerID], StoredMessage{
		Envelope:  env,
		Timestamp: time.Now(),
	})
	if len(g.store[peerID]) > 1000 {
		g.store[peerID] = g.store[peerID][len(g.store[peerID])-1000:]
	}
}

func (g *Gateway) flushStored(ctx context.Context, p *Peer) {
	g.mu.Lock()
	stored := g.store[p.ID]
	delete(g.store, p.ID)
	g.mu.Unlock()

	if len(stored) == 0 {
		return
	}

	log.Printf("[gateway] flushing %d stored messages for %s", len(stored), p.ID)
	for _, sm := range stored {
		if err := p.Send(ctx, sm.Envelope); err != nil {
			log.Printf("[gateway] flush send error for %s: %v", p.ID, err)
			g.mu.Lock()
			g.store[p.ID] = append(g.store[p.ID], stored...)
			g.mu.Unlock()
			return
		}
	}
}
