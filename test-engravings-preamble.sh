#!/bin/bash
# test-engravings-preamble.sh
#
# Seeds a fresh companion + known engravings directly into the DB.
# Zero swim history — so any context the companion shows came ONLY from the preamble.
#
# Usage: ./test-engravings-preamble.sh [seed|clean]
#   seed  — create companion + engravings (default)
#   clean — remove the test companion + engravings

DB="$HOME/Library/Application Support/Port42/port42.sqlite"
OWNER_ID="6FBE899E-480E-4771-8373-E9C63B0115C1"
COMPANION_ID="TEST-ENGRAVE-0000-0000-000000000001"
SWIM_ID="swim-${COMPANION_ID}"
NOW=$(date -u "+%Y-%m-%d %H:%M:%S")

seed() {
  echo "[seed] Creating test companion: testpilot ($COMPANION_ID)"
  sqlite3 "$DB" <<SQL
INSERT OR REPLACE INTO agents (id, ownerId, displayName, mode, trigger, systemPrompt, model, createdAt, thinkingEnabled, thinkingEffort, openInTerminal)
VALUES (
  '$COMPANION_ID',
  '$OWNER_ID',
  'testpilot',
  'llm',
  'mentionOnly',
  'You are testpilot. A sharp, direct advisor. No preamble, no padding.',
  'claude-sonnet-4-6',
  '$NOW',
  0,
  'low',
  0
);
SQL

  echo "[seed] Creating swim channel: $SWIM_ID"
  sqlite3 "$DB" <<SQL
INSERT OR IGNORE INTO channels (id, name, type, createdAt, syncEnabled, isSwim)
VALUES ('$SWIM_ID', 'testpilot', 'direct', '$NOW', 0, 1);
SQL

  echo "[seed] Assigning testpilot to swim channel"
  sqlite3 "$DB" <<SQL
INSERT OR IGNORE INTO agentChannels (agentId, channelId)
VALUES ('$COMPANION_ID', '$SWIM_ID');
SQL

  echo "[seed] Writing engravings"
  sqlite3 "$DB" <<SQL
INSERT INTO companion_engravings (id, companionId, channelId, content, category, weight, createdAt, touchedAt)
VALUES
  ('ENG-TEST-0001', '$COMPANION_ID', '$SWIM_ID',
   'Building a B2B invoicing tool for freelancers. Currently at MVP, 12 beta users.',
   'context', 1.0, '$NOW', '$NOW'),
  ('ENG-TEST-0002', '$COMPANION_ID', '$SWIM_ID',
   'Main constraint: 3-4 hours per week, solo, no runway pressure.',
   'constraint', 1.0, '$NOW', '$NOW'),
  ('ENG-TEST-0003', '$COMPANION_ID', '$SWIM_ID',
   'Goal: 10 paying customers within 6 weeks.',
   'goal', 1.0, '$NOW', '$NOW');
SQL

  echo ""
  echo "Done. Restart Port42, then open a swim with 'testpilot'."
  echo ""
  echo "Send this cold — no other messages:"
  echo "  What should I focus on this week?"
  echo ""
  echo "Expected: testpilot responds knowing about the invoicing tool, 3-4h constraint, and 10-customer goal."
  echo "If it asks 'what are you building?' — preamble injection is broken."
  echo ""
  echo "To clean up after: ./test-engravings-preamble.sh clean"
}

clean() {
  echo "[clean] Removing testpilot and its state"
  sqlite3 "$DB" <<SQL
DELETE FROM agents WHERE id = '$COMPANION_ID';
DELETE FROM channels WHERE id = '$SWIM_ID';
DELETE FROM agentChannels WHERE agentId = '$COMPANION_ID';
DELETE FROM companion_engravings WHERE companionId = '$COMPANION_ID';
DELETE FROM companion_creases WHERE companionId = '$COMPANION_ID';
DELETE FROM companion_folds WHERE companionId = '$COMPANION_ID';
DELETE FROM companion_positions WHERE companionId = '$COMPANION_ID';
SQL
  echo "[clean] Done."
}

case "${1:-seed}" in
  seed)  seed ;;
  clean) clean ;;
  *)     echo "Usage: $0 [seed|clean]" ;;
esac
