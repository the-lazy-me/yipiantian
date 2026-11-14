extends RefCounted
## Player-to-player records owned by the authoritative world: contacts, pending
## contact invitations, blocks, messages and visits. Pure rules only — no scene,
## clock reading or disk I/O.
##
## Contacts are recorded by stable player id, never by display name; a name is a
## mutable label that travels with the contact only for display. Blocking stops
## delivery in both directions and hides the blocked player's messages from the
## blocker, but never erases a record the other side may still own.

const VERSION: int = 1
const MAX_PLAYERS: int = 64
const MAX_CONTACTS: int = 128
const MAX_PENDING: int = 64
const MAX_BLOCKS: int = 128
const MAX_MESSAGES: int = 256
const MAX_VISITS: int = 128
const MAX_IDENTIFIER: int = 64
const MAX_NAME: int = 24
const MAX_TEXT: int = 200
const MAX_REASON: int = 64
const MAX_TIME: float = 253402300799.0
const INCOMING: String = "in"
const OUTGOING: String = "out"


static func initial_state() -> Dictionary:
	return {"version": VERSION, "players": {}, "messages": [], "visits": []}


static func valid(state: Dictionary) -> bool:
	if state.size() != 4 or not _integral(state.get("version")) or int(state.version) != VERSION:
		return false
	if not state.get("players") is Dictionary or not state.get("messages") is Array:
		return false
	if not state.get("visits") is Array:
		return false
	var players: Dictionary = state.players
	if players.size() > MAX_PLAYERS:
		return false
	for player_id: Variant in players:
		if not valid_identifier(player_id) or not players[player_id] is Dictionary:
			return false
		var player: Dictionary = players[player_id]
		if player.size() != 4 or not valid_name(player.get("name")):
			return false
		for key: String in ["contacts", "pending", "blocks"]:
			if not player.get(key) is Dictionary:
				return false
		if player.contacts.size() > MAX_CONTACTS or player.pending.size() > MAX_PENDING \
				or player.blocks.size() > MAX_BLOCKS:
			return false
		for other: Variant in player.contacts:
			var contact: Variant = player.contacts[other]
			if not valid_identifier(other) or other == player_id:
				return false
			if not contact is Dictionary or contact.size() != 2 or not valid_name(contact.get("name")):
				return false
			if not _valid_time(contact.get("since")):
				return false
			# A block is the stronger statement; the two lists must not disagree.
			if player.blocks.has(other):
				return false
		for other: Variant in player.pending:
			var request: Variant = player.pending[other]
			if not valid_identifier(other) or other == player_id:
				return false
			if not request is Dictionary or request.size() != 3 or not valid_name(request.get("name")):
				return false
			if not _valid_time(request.get("at")) or request.get("direction") not in [INCOMING, OUTGOING]:
				return false
			if player.contacts.has(other) or player.blocks.has(other):
				return false
		for other: Variant in player.blocks:
			var block: Variant = player.blocks[other]
			if not valid_identifier(other) or other == player_id:
				return false
			if not block is Dictionary or block.size() != 2 or not _valid_time(block.get("at")):
				return false
			if not block.get("reason") is String or block.reason.length() > MAX_REASON:
				return false
	var ids: Dictionary = {}
	for message: Variant in state.messages:
		if not message is Dictionary or message.size() != 7:
			return false
		if not valid_identifier(message.get("id")) or ids.has(message.id):
			return false
		ids[message.id] = true
		if not players.has(message.get("from")) or not valid_identifier(message.get("from")):
			return false
		var to: Variant = message.get("to")
		if not to is String or (not to.is_empty() and (not valid_identifier(to) or not players.has(to))):
			return false
		if not valid_text(message.get("text")) or not _valid_time(message.get("at")):
			return false
		for key: String in ["read", "deleted"]:
			if not message.get(key) is Dictionary:
				return false
			for viewer: Variant in message[key]:
				if not players.has(viewer) or message[key][viewer] != true:
					return false
	if state.messages.size() > MAX_MESSAGES or state.visits.size() > MAX_VISITS:
		return false
	for visit: Variant in state.visits:
		if not visit is Dictionary or visit.size() != 3:
			return false
		if not players.has(visit.get("player")) or not _valid_time(visit.get("at")):
			return false
		if visit.get("kind") != "visit":
			return false
	return true


## Registers a player id on first contact and updates the display name. A name is
## never used to identify anyone, so renaming is always safe.
static func ensure_player(state: Dictionary, player_id: String, name: String, now: float) -> Dictionary:
	if not valid_identifier(player_id) or not valid_name(name) or not _valid_time(now):
		return _refusal("invalid_player")
	var players: Dictionary = state.players
	if not players.has(player_id) and players.size() >= MAX_PLAYERS:
		return _refusal("player_limit")
	if players.has(player_id):
		players[player_id].name = name
		return _ok()
	players[player_id] = {"name": name, "contacts": {}, "pending": {}, "blocks": {}}
	return _ok()


static func invite(state: Dictionary, from: String, to: String, to_name: String, now: float) -> Dictionary:
	if not state.players.has(from) or not valid_identifier(to) or from == to:
		return _refusal("invalid_player")
	if not _valid_time(now) or not valid_name(to_name):
		return _refusal("invalid_name")
	var players: Dictionary = state.players
	# The recipient may not have joined yet; the invitation creates the record so
	# it can be answered when they do. An existing name is never overwritten.
	if not players.has(to):
		var named: Dictionary = ensure_player(state, to, to_name, now)
		if not named.ok:
			return named
	if players[from].contacts.has(to):
		return _refusal("already_contact")
	if players[from].pending.has(to):
		return _refusal("pending_exists")
	if _blocked(state, from, to):
		return _refusal("blocked")
	if players[from].pending.size() >= MAX_PENDING or players[to].pending.size() >= MAX_PENDING:
		return _refusal("pending_limit")
	players[from].pending[to] = {"name": players[to].name, "at": now, "direction": OUTGOING}
	players[to].pending[from] = {"name": players[from].name, "at": now, "direction": INCOMING}
	# The inviter reaches the recipient's list through a real pending entry, so an
	# invitation is never a notification the recipient cannot answer.
	return _ok()


## Accepts an invitation addressed to `from`. Contacts are mutual in this model:
## both sides record the other, so the relationship does not become one-sided.
static func accept(state: Dictionary, from: String, to: String, now: float) -> Dictionary:
	var refused: Dictionary = _pair(state, from, to, now)
	if not refused.is_empty():
		return refused
	var players: Dictionary = state.players
	var request: Variant = players[from].pending.get(to)
	if not request is Dictionary or request.direction != INCOMING:
		return _refusal("no_invitation")
	if players[from].contacts.size() >= MAX_CONTACTS or players[to].contacts.size() >= MAX_CONTACTS:
		return _refusal("contact_limit")
	players[from].contacts[to] = {"name": players[to].name, "since": now}
	players[to].contacts[from] = {"name": players[from].name, "since": now}
	players[from].pending.erase(to)
	players[to].pending.erase(from)
	return _ok()


static func decline(state: Dictionary, from: String, to: String) -> Dictionary:
	var refused: Dictionary = _pair(state, from, to, 0.0, false)
	if not refused.is_empty():
		return refused
	var players: Dictionary = state.players
	var request: Variant = players[from].pending.get(to)
	if not request is Dictionary or request.direction != INCOMING:
		return _refusal("no_invitation")
	players[from].pending.erase(to)
	players[to].pending.erase(from)
	return _ok()


static func remove_contact(state: Dictionary, from: String, to: String) -> Dictionary:
	var refused: Dictionary = _pair(state, from, to, 0.0, false)
	if not refused.is_empty():
		return refused
	var players: Dictionary = state.players
	if not players[from].contacts.has(to):
		return _refusal("not_a_contact")
	players[from].contacts.erase(to)
	players[to].contacts.erase(from)
	return _ok()


## Blocks stop future contact and hide the blocked player's messages from the
## blocker. Existing messages stay stored: the other side may still own them.
static func block(state: Dictionary, owner: String, target: String, now: float, reason: String = "") -> Dictionary:
	var refused: Dictionary = _pair(state, owner, target, now)
	if not refused.is_empty():
		return refused
	if reason.length() > MAX_REASON:
		return _refusal("invalid_reason")
	var players: Dictionary = state.players
	if not players[owner].blocks.has(target) and players[owner].blocks.size() >= MAX_BLOCKS:
		return _refusal("block_limit")
	players[owner].blocks[target] = {"at": now, "reason": reason}
	# Blocking ends the relationship it contradicts instead of leaving both in
	# place and making every later read guess which one wins.
	players[owner].contacts.erase(target)
	players[target].contacts.erase(owner)
	players[owner].pending.erase(target)
	players[target].pending.erase(owner)
	return _ok()


static func unblock(state: Dictionary, owner: String, target: String) -> Dictionary:
	var refused: Dictionary = _pair(state, owner, target, 0.0, false)
	if not refused.is_empty():
		return refused
	if not state.players[owner].blocks.has(target):
		return _refusal("not_blocked")
	state.players[owner].blocks.erase(target)
	return _ok()


## A private message needs both a real sender and a real recipient. A public
## message (empty `to`) is stored once; delivery filters it per viewer.
static func send(state: Dictionary, from: String, to: String, id: String, text: String, now: float) -> Dictionary:
	if not valid_identifier(from) or not state.players.has(from):
		return _refusal("invalid_player")
	if not valid_identifier(id) or not valid_text(text) or not _valid_time(now):
		return _refusal("invalid_message")
	if not to.is_empty():
		if not valid_identifier(to) or not state.players.has(to) or to == from:
			return _refusal("invalid_recipient")
		if _blocked(state, from, to):
			return _refusal("blocked")
	for message: Dictionary in state.messages:
		if message.id == id:
			return _refusal("duplicate_message")
	if state.messages.size() >= MAX_MESSAGES:
		return _refusal("inbox_full")
	state.messages.append({"id": id, "from": from, "to": to, "text": text, "at": now,
		"read": {}, "deleted": {}})
	return _ok()


## Messages this player may see, oldest first. Public messages and messages the
## player sent are visible; a block hides the other side's messages without
## destroying them for anyone else.
static func inbox(state: Dictionary, viewer: String) -> Array:
	if not state.players.has(viewer):
		return []
	var rows: Array = []
	for message: Dictionary in state.messages:
		if message.deleted.get(viewer, false):
			continue
		if not message.to.is_empty() and message.to != viewer and message.from != viewer:
			continue
		if _blocked(state, viewer, message.from):
			continue
		rows.append(message.duplicate(true))
	return rows


static func mark_read(state: Dictionary, viewer: String, id: String) -> Dictionary:
	var found: Dictionary = _message(state, viewer, id)
	if not found.ok:
		return found
	found.message.read[viewer] = true
	return _ok()


static func delete_message(state: Dictionary, viewer: String, id: String) -> Dictionary:
	var found: Dictionary = _message(state, viewer, id)
	if not found.ok:
		return found
	found.message.deleted[viewer] = true
	return _ok()


## Records a completed visit. The list is a bounded recent history, not an audit
## log, so the oldest entry leaves when it fills up.
static func record_visit(state: Dictionary, player_id: String, now: float) -> Dictionary:
	if not state.players.has(player_id) or not _valid_time(now):
		return _refusal("invalid_player")
	state.visits.append({"player": player_id, "at": now, "kind": "visit"})
	while state.visits.size() > MAX_VISITS:
		state.visits.remove_at(0)
	return _ok()


## The id an authority should stamp on a new message: random, so two senders
## cannot collide by choosing a sequence number.
static func new_message_id() -> String:
	return "msg_" + Crypto.new().generate_random_bytes(16).hex_encode()


static func valid_identifier(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > MAX_IDENTIFIER:
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		var letter: bool = (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		var digit: bool = code >= 48 and code <= 57
		if not letter and not digit and code != 95 and code != 45 and code != 46 and code != 58:
			return false
	return true


static func valid_name(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.length() > MAX_NAME:
		return false
	if value != value.strip_edges():
		return false
	for index: int in value.length():
		if value.unicode_at(index) < 32 or value.unicode_at(index) == 127:
			return false
	return true


static func valid_text(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.length() > MAX_TEXT:
		return false
	# A message of nothing but whitespace is not a message.
	if value.strip_edges().is_empty():
		return false
	for index: int in value.length():
		if value.unicode_at(index) < 32 or value.unicode_at(index) == 127:
			return false
	return true


static func _pair(state: Dictionary, from: String, to: String, now: float, check_time: bool = true) -> Dictionary:
	if not state.players.has(from) or not state.players.has(to):
		return _refusal("invalid_player")
	if from == to:
		return _refusal("invalid_player")
	if check_time and not _valid_time(now):
		return _refusal("invalid_time")
	return {}


static func _blocked(state: Dictionary, first: String, second: String) -> bool:
	if not state.players.has(first) or not state.players.has(second):
		return false
	return state.players[first].blocks.has(second) or state.players[second].blocks.has(first)


static func _message(state: Dictionary, viewer: String, id: String) -> Dictionary:
	if not state.players.has(viewer):
		return _refusal("invalid_player")
	for message: Dictionary in state.messages:
		if message.id != id:
			continue
		if not message.to.is_empty() and message.to != viewer and message.from != viewer:
			return _refusal("not_visible")
		return {"ok": true, "reason": "", "message": message}
	return _refusal("missing_message")


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and float(value) >= 0.0 and float(value) <= MAX_TIME


static func _integral(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value))


static func _ok() -> Dictionary:
	return {"ok": true, "reason": ""}


static func _refusal(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
