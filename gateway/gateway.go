package main

import (
	"context"
	"encoding/json"
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
	MessageID string          `json:"message_id,omitempty"`
	Payload   json.RawMessage `json:"payload,omitempty"`
	Timestamp int64           `json:"timestamp,omitempty"`
	Error     string          `json:"error,omitempty"`
	// Presence fields
	OnlineIDs []string `json:"online_ids,omitempty"`
	Status    string   `json:"status,omitempty"` // "online" or "offline"
}

// Peer represents a connected client.
type Peer struct {
	ID       string
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
}

func NewGateway() *Gateway {
	return &Gateway{
		peers:    make(map[string]*Peer),
		channels: make(map[string]map[string]bool),
		store:    make(map[string][]StoredMessage),
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

		env.SenderID = peer.ID
		if env.Timestamp == 0 {
			env.Timestamp = time.Now().UnixMilli()
		}

		switch env.Type {
		case "join":
			g.joinChannel(peer, env.ChannelID)
			g.flushStoredForChannel(ctx, peer, env.ChannelID)
		case "leave":
			g.leaveChannel(peer, env.ChannelID)
		case "message":
			g.routeMessage(ctx, peer, env)
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
	// Collect channels before removing
	channels := make([]string, 0, len(p.Channels))
	for ch := range p.Channels {
		channels = append(channels, ch)
	}
	if current, ok := g.peers[p.ID]; ok && current == p {
		delete(g.peers, p.ID)
		// Keep channel membership so store-and-forward works
	}
	g.mu.Unlock()

	// Broadcast offline to all channels this peer was in
	for _, ch := range channels {
		g.broadcastPresence(context.Background(), ch, p.ID, "offline")
	}

	log.Printf("[gateway] peer disconnected: %s", p.ID)
}

func (g *Gateway) joinChannel(p *Peer, channelID string) {
	if channelID == "" {
		return
	}
	g.mu.Lock()

	p.Channels[channelID] = true
	if g.channels[channelID] == nil {
		g.channels[channelID] = make(map[string]bool)
	}
	g.channels[channelID][p.ID] = true

	// Collect current online members for this channel
	var onlineIDs []string
	for memberID := range g.channels[channelID] {
		if _, online := g.peers[memberID]; online {
			onlineIDs = append(onlineIDs, memberID)
		}
	}

	g.mu.Unlock()

	// Send the joiner the full online list
	ctx := context.Background()
	p.Send(ctx, Envelope{
		Type:      "presence",
		ChannelID: channelID,
		OnlineIDs: onlineIDs,
	})

	// Broadcast this peer's online status to others
	g.broadcastPresence(ctx, channelID, p.ID, "online")

	log.Printf("[gateway] peer %s joined channel %s", p.ID, channelID)
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

	delete(p.Channels, channelID)
	if members, ok := g.channels[channelID]; ok {
		delete(members, p.ID)
		if len(members) == 0 {
			delete(g.channels, channelID)
		}
	}

	g.mu.Unlock()

	g.broadcastPresence(context.Background(), channelID, p.ID, "offline")

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
	g.mu.RUnlock()

	env := Envelope{
		Type:      "presence",
		ChannelID: channelID,
		SenderID:  peerID,
		Status:    status,
	}
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
