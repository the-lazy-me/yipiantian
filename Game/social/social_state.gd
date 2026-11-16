extends RefCounted
## Player-to-player records owned by the authoritative world: contacts, pending
## contact invitations, blocks, messages and visits. Pure rules only — no scene,
## clock reading or disk I/O.
##
## Contacts are recorded by stable player id, never by display name; a name is a
## mutable label that travels with the contact only for display. Blocking stops
## delivery in both directions and hides the blocked player's messages from the
## blocker, but never erases a record the other side may still own.

const OwnerIds = preload("res://farm/owner_id.gd")

const VERSION: int = 2
const MAX_PLAYERS: int = 64
const MAX_CONTACTS: int = 128
const MAX_PENDING: int = 64
const MAX_BLOCKS: int = 128
const MAX_MESSAGES: int = 256
## A single sender cannot occupy the whole inbox table: deletion only frees a
## row when every viewer removed it, so one player could otherwise keep 256
## rows alive forever. Eight senders still fit the global limit.
const MAX_MESSAGES_PER_SENDER: int = 32
const MAX_VISITS: int = 128
const MAX_GRANTS: int = 128
## An unanswered invitation creates a temporary player row so the recipient can
## answer after joining. Without an expiry that row would occupy a limited slot
## forever, so invitations and their rows leave after this window.
const INVITE_TTL_SECONDS: float = 7.0 * 24.0 * 60.0 * 60.0
const MAX_GRANT_FIELDS: int = 32
const MAX_IDENTIFIER: int = 64
const MAX_NAME: int = 24
const MAX_TEXT: int = 200
const MAX_REASON: int = 64
const MAX_TIME: float = 253402300799.0
## The commands a collaboration grant may name.
const GRANT_KINDS: Array[String] = ["sow", "water", "weed", "till", "harvest"]
const INCOMING: String = "in"
const OUTGOING: String = "out"


static func initial_state() -> Dictionary:
	return {"version": VERSION, "players": {}, "grants": [], "messages": [], "visits": []}


static func valid(state: Dictionary) -> bool:
	if state.size() != 5 or not _integral(state.get("version")) or int(state.version) != VERSION:
		return false
	if not state.get("grants") is Array or state.grants.size() > MAX_GRANTS:
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
			if not valid_identifier(other) or other == player_id or not players.has(other):
				return false
			if not contact is Dictionary or contact.size() != 2 or not valid_name(contact.get("name")):
				return false
			if not _valid_time(contact.get("since")):
				return false
			# Contacts are mutual in this model. A one-sided row could be used to
			# fake a relationship the other player never accepted.
			if not players[other].contacts.has(player_id):
				return false
			# A block is the stronger statement; the two lists must not disagree.
			if player.blocks.has(other):
				return false
		for other: Variant in player.pending:
			var request: Variant = player.pending[other]
			if not valid_identifier(other) or other == player_id or not players.has(other):
				return false
			if not request is Dictionary or request.size() != 3 or not valid_name(request.get("name")):
				return false
			if not _valid_time(request.get("at")) or request.get("direction") not in [INCOMING, OUTGOING]:
				return false
			# An invitation exists on both sides, with opposite directions. A
			# one-sided request would let its author claim an answer that the
			# other party cannot give or decline.
			var reciprocal: Variant = players[other].pending.get(player_id)
			if not reciprocal is Dictionary or reciprocal.size() != 3:
				return false
			var expected: String = OUTGOING if request.get("direction") == INCOMING else INCOMING
			if reciprocal.get("direction") != expected:
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
	var grant_ids: Dictionary = {}
	for value: Variant in state.grants:
		if not value is Dictionary or value.size() != 7:
			return false
		var row: Dictionary = value
		if not valid_identifier(row.get("id")) or grant_ids.has(row.id):
			return false
		grant_ids[row.id] = true
		if not players.has(row.get("from")) or not players.has(row.get("to")):
			return false
		if row.get("from") == row.get("to"):
			return false
		if not row.get("kinds") is Array or row.kinds.is_empty():
			return false
		var kinds_seen: Dictionary = {}
		for kind: Variant in row.kinds:
			if kind not in GRANT_KINDS or kinds_seen.has(kind):
				return false
			kinds_seen[kind] = true
		if not row.get("fields") is Array or row.fields.size() > MAX_GRANT_FIELDS:
			return false
		var fields_seen: Dictionary = {}
		for field: Variant in row.fields:
			if not valid_identifier(field) or fields_seen.has(field):
				return false
			fields_seen[field] = true
		if not _valid_time(row.get("created")) or not _valid_time(row.get("expires_at")):
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


## Registers a player id on first contact without touching an existing record.
## A read path uses this so reading a player's state never rewrites the document
## just because the local profile was renamed.
static func register_player(state: Dictionary, player_id: String, name: String, now: float) -> Dictionary:
	if not valid_identifier(player_id) or not valid_name(name) or not _valid_time(now):
		return _refusal("invalid_player")
	var players: Dictionary = state.players
	if players.has(player_id):
		return _ok()
	if players.size() >= MAX_PLAYERS:
		return _refusal("player_limit")
	# Display names are made unique at registration, so two neighbours who pick
	# the same label stay distinguishable in messages and the roster. The id
	# itself is untouched.
	players[player_id] = {"name": unique_name(state, player_id, name),
		"contacts": {}, "pending": {}, "blocks": {}}
	return _ok()


## Registers a player id on first contact and updates the display name. A name is
## never used to identify anyone, so renaming is always safe.
static func ensure_player(state: Dictionary, player_id: String, name: String, now: float) -> Dictionary:
	var registered: Dictionary = register_player(state, player_id, name, now)
	if not registered.ok:
		return registered
	var current: String = str(state.players[player_id].name)
	if current != name:
		state.players[player_id].name = unique_name(state, player_id, name)
	return _ok()


## Returns `name`, or a stable disambiguated form when another player already
## uses it. The suffix comes from the player id, so the same pair of players
## always resolves the same way and a reconnect keeps the label it had.
static func unique_name(state: Dictionary, player_id: String, name: String) -> String:
	var used: Dictionary = {}
	for other: Variant in state.players:
		if str(other) == player_id:
			continue
		used[str(state.players[other].name)] = true
	if not used.has(name):
		return name
	var suffix: String = "#" + player_id.right(6)
	var candidate: String = name.substr(0, maxi(MAX_NAME - suffix.length(), 0)) + suffix
	if not used.has(candidate):
		return candidate
	var index: int = 2
	while true:
		var tail: String = "#%d" % index
		candidate = name.substr(0, maxi(MAX_NAME - tail.length(), 0)) + tail
		if not used.has(candidate):
			return candidate
		index += 1
	return name


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
	# A collaboration grant was consent from one of these players to the other;
	# ending the relationship ends that consent instead of leaving it behind.
	_revoke_pair_grants(state, from, to)
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
	# place and making every later read guess which one wins. Consent to work on
	# the blocker's land is part of that relationship and must not survive it.
	players[owner].contacts.erase(target)
	players[target].contacts.erase(owner)
	players[owner].pending.erase(target)
	players[target].pending.erase(owner)
	_revoke_pair_grants(state, owner, target)
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
## message (empty `to`) is stored once; delivery filters it per viewer. A public
## message is accepted while either side is blocked, but it is never delivered to
## (or shown in the inbox of) a viewer with a blocked relationship to its sender:
## a broadcast must not bypass a block.
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
	var sent: int = 0
	for message: Dictionary in state.messages:
		if message.id == id:
			return _refusal("duplicate_message")
		if message.from == from:
			sent += 1
	if sent >= MAX_MESSAGES_PER_SENDER:
		return _refusal("inbox_full")
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
	# Reclaim as soon as the last relevant viewer deletes it; a soft-deleted row
	# nobody can read must not keep occupying the table.
	if _everyone_deleted(state, found.message):
		for index: int in state.messages.size():
			if state.messages[index].id == found.message.id:
				state.messages.remove_at(index)
				break
	return _ok()


## Physical reclamation at an action boundary: a message whose whole audience has
## deleted it is removed. A private message's audience is sender and recipient; a
## public message's audience is every player registered at this moment (a later
## joiner was not an audience of that historical broadcast).
static func reclaim_messages(state: Dictionary) -> int:
	var kept: Array = []
	var removed: int = 0
	for message: Dictionary in state.messages:
		if _everyone_deleted(state, message):
			removed += 1
		else:
			kept.append(message)
	if removed > 0:
		state.messages = kept
	return removed


## Records a completed visit. The list is a bounded recent history, not an audit
## log, so the oldest entry leaves when it fills up.
static func record_visit(state: Dictionary, player_id: String, now: float) -> Dictionary:
	if not state.players.has(player_id) or not _valid_time(now):
		return _refusal("invalid_player")
	state.visits.append({"player": player_id, "at": now, "kind": "visit"})
	while state.visits.size() > MAX_VISITS:
		state.visits.remove_at(0)
	return _ok()


## Issues a collaboration grant: which commands another player may run, on
## which fields (empty means every field), until when (zero means no expiry).
static func grant(state: Dictionary, from: String, to: String, id: String,
		kinds: Array, fields: Array, expires_at: float, now: float) -> Dictionary:
	if not state.players.has(from) or not state.players.has(to) or from == to:
		return _refusal("invalid_player")
	if not valid_identifier(id) or not _valid_time(now) or not _valid_time(expires_at):
		return _refusal("invalid_grant")
	if expires_at != 0.0 and expires_at <= now:
		return _refusal("invalid_expiry")
	if kinds.is_empty() or kinds.size() > GRANT_KINDS.size():
		return _refusal("invalid_grant")
	var kinds_seen: Dictionary = {}
	for kind: Variant in kinds:
		if kind not in GRANT_KINDS or kinds_seen.has(kind):
			return _refusal("invalid_grant")
		kinds_seen[kind] = true
	if fields.size() > MAX_GRANT_FIELDS:
		return _refusal("invalid_grant")
	var fields_seen: Dictionary = {}
	for field: Variant in fields:
		if not valid_identifier(field) or fields_seen.has(field):
			return _refusal("invalid_grant")
		fields_seen[field] = true
	if state.grants.size() >= MAX_GRANTS:
		return _refusal("grant_limit")
	state.grants.append({"id": id, "from": from, "to": to, "kinds": kinds.duplicate(),
		"fields": fields.duplicate(), "created": now, "expires_at": expires_at})
	return _ok()


## Only the issuer may withdraw a grant. Removal takes effect on the next
## command: the permission gate reads the document every time.
static func revoke_grant(state: Dictionary, from: String, id: String) -> Dictionary:
	if not state.players.has(from):
		return _refusal("invalid_player")
	for index: int in state.grants.size():
		var row: Dictionary = state.grants[index]
		if row.id != id:
			continue
		if row.from != from:
			return _refusal("not_issuer")
		state.grants.remove_at(index)
		return _ok()
	return _refusal("missing_grant")


## Removes records that no longer serve a player, inside an existing action
## boundary rather than with a timer or background thread:
## - expired collaboration grants;
## - invitations that were never answered within INVITE_TTL_SECONDS;
## - player rows left with no relationship and no record pointing at them (the
##   temporary row an invitation creates). `keep` protects ids that are online.
static func prune(state: Dictionary, now: float, keep: Array = []) -> int:
	if not _valid_time(now):
		return 0
	var removed: int = 0
	var grants: Array = []
	for row: Dictionary in state.grants:
		if float(row.expires_at) != 0.0 and now >= float(row.expires_at):
			removed += 1
			continue
		grants.append(row)
	state.grants = grants
	var players: Dictionary = state.players
	# Only the recipient of an unanswered invitation is a temporary row. A real
	# player with no relationships yet is not an invitation placeholder and stays.
	var candidates: Dictionary = {}
	for player_id: String in players.keys():
		var player: Dictionary = players[player_id]
		for other: String in player.pending.keys():
			var request: Dictionary = player.pending[other]
			if now - float(request.at) < INVITE_TTL_SECONDS:
				continue
			if request.direction == INCOMING:
				candidates[player_id] = true
	for player_id: String in players.keys():
		var player: Dictionary = players[player_id]
		for other: String in player.pending.keys():
			var request: Dictionary = player.pending[other]
			if now - float(request.at) < INVITE_TTL_SECONDS:
				continue
			player.pending.erase(other)
			if players.has(other):
				players[other].pending.erase(player_id)
			removed += 1
	removed += reclaim_messages(state)
	removed += _drop_unreferenced_players(state, keep, candidates.keys())
	return removed


## True when an unexpired grant covers this player, command and field. For
## harvest the caller passes the cell's true owner: the grant's issuer must be
## that owner, so a third party's grant can never authorize taking their crop.
## Empty `owner_id` means the caller has no owner to compare (non-harvest work).
static func allows(state: Dictionary, player_id: String, kind: String,
		field_id: String, now: float, owner_id: String = "") -> bool:
	if not state.players.has(player_id) or kind not in GRANT_KINDS:
		return false
	for row: Dictionary in state.grants:
		if row.to != player_id or not (row.kinds as Array).has(kind):
			continue
		if not owner_id.is_empty() and str(row.from) != owner_id:
			continue
		# A block ends the relationship; a grant left in an older document must
		# not survive it even if that document predates grant revocation.
		if _blocked(state, player_id, str(row.from)):
			continue
		if float(row.expires_at) != 0.0 and now >= float(row.expires_at):
			continue
		if not (row.fields as Array).is_empty() and not (row.fields as Array).has(field_id):
			continue
		return true
	return false


## Public read of the block relationship, so transport filters use the same rule
## as the stored document.
static func blocked(state: Dictionary, first: String, second: String) -> bool:
	return _blocked(state, first, second)


static func grants_view(state: Dictionary, viewer: String) -> Array:
	var rows: Array = []
	for row: Dictionary in state.grants:
		if row.from != viewer and row.to != viewer:
			continue
		# An empty field list never means "any field of any owner": for harvest it
		# covers only cells the issuer planted, so the view states that scope
		# instead of advertising the whole farm.
		var scope: String = "fields"
		if (row.fields as Array).is_empty():
			scope = "owned" if (row.kinds as Array).has("harvest") else "whole"
		rows.append({"id": row.id, "from": row.from,
			"from_name": _name(state, row.from), "to": row.to,
			"to_name": _name(state, row.to), "kinds": row.kinds.duplicate(),
			"fields": row.fields.duplicate(), "created": row.created,
			"expires_at": row.expires_at, "scope": scope,
			"direction": "out" if row.from == viewer else "in"})
	return rows


## Everything one player may see about its own social record. Names are joined
## here so a client never has to resolve ids itself.
static func view(state: Dictionary, viewer: String) -> Dictionary:
	if not state.players.has(viewer):
		return {}
	var player: Dictionary = state.players[viewer]
	var contacts: Array = []
	for id: String in player.contacts:
		contacts.append({"player_id": id, "name": _name(state, id),
			"since": player.contacts[id].since})
	var pending: Array = []
	for id: String in player.pending:
		pending.append({"player_id": id, "name": _name(state, id),
			"at": player.pending[id].at, "direction": player.pending[id].direction})
	var blocks: Array = []
	for id: String in player.blocks:
		blocks.append({"player_id": id, "name": _name(state, id),
			"at": player.blocks[id].at, "reason": player.blocks[id].reason})
	var rows: Array = []
	for message: Dictionary in inbox(state, viewer):
		rows.append({"id": message.id, "from": message.from,
			"from_name": _name(state, message.from), "to": message.to,
			"to_name": _name(state, message.to), "text": message.text,
			"at": message.at, "read": message.read.get(viewer, false)})
	return {"player_id": viewer, "name": player.name, "contacts": contacts,
		"pending": pending, "blocks": blocks, "grants": grants_view(state, viewer),
		"inbox": rows}


static func display_name(state: Dictionary, player_id: String) -> String:
	return _name(state, player_id)


static func _name(state: Dictionary, player_id: String) -> String:
	if not state.players.has(player_id):
		return ""
	return str(state.players[player_id].name)


## The id an authority should stamp on a new message: random, so two senders
## cannot collide by choosing a sequence number.
static func new_message_id() -> String:
	return "msg_" + Crypto.new().generate_random_bytes(16).hex_encode()


## A normalized copy for storage and transport: JSON turns integers into floats
## on read, so every count and time is pinned to one representation. Without
## this, saving the same record twice would produce different bytes.
static func canonical(state: Dictionary) -> Dictionary:
	var copy: Dictionary = state.duplicate(true)
	copy.version = int(copy.version)
	for player: Dictionary in copy.players.values():
		for contact: Dictionary in player.contacts.values():
			contact.since = float(contact.since)
		for request: Dictionary in player.pending.values():
			request.at = float(request.at)
		for block: Dictionary in player.blocks.values():
			block.at = float(block.at)
	for message: Dictionary in copy.messages:
		message.at = float(message.at)
	for visit: Dictionary in copy.visits:
		visit.at = float(visit.at)
	for row: Dictionary in copy.grants:
		row.created = float(row.created)
		row.expires_at = float(row.expires_at)
	return copy


static func valid_identifier(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > MAX_IDENTIFIER:
		return false
	# 组织基金账户以 `org_` 派生。玩家 id 同时是口袋、经济账户与会员身份的键，
	# 若允许同名，成员就能以基金账户的身份付款、收款或领取开户赠款，绕过
	# 基金文档的余额不变量。两个命名空间必须在身份入口就保持不相交。
	if OwnerIds.is_organization_account(text):
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


## Removes every grant in either direction between two players. Ending a
## relationship must end the consent that relationship carried.
static func _revoke_pair_grants(state: Dictionary, first: String, second: String) -> void:
	var kept: Array = []
	for row: Dictionary in state.grants:
		var pair: bool = (row.from == first and row.to == second) \
			or (row.from == second and row.to == first)
		if not pair:
			kept.append(row)
	state.grants = kept


## The viewers for whom a message exists: sender and recipient for a private
## message, every registered player for a public one.
static func _audience(state: Dictionary, message: Dictionary) -> Array:
	if str(message.to).is_empty():
		return state.players.keys()
	if message.from == message.to:
		return [message.from]
	return [message.from, message.to]


static func _everyone_deleted(state: Dictionary, message: Dictionary) -> bool:
	for viewer: Variant in _audience(state, message):
		if not message.deleted.get(viewer, false):
			return false
	return true


## Drops fully empty invitation-recipient rows that nothing points at. `keep`
## holds ids with a live session; a block/pending/contact peer is referenced and
## therefore kept.
static func _drop_unreferenced_players(state: Dictionary, keep: Array,
		candidates: Array) -> int:
	var players: Dictionary = state.players
	var referenced: Dictionary = {}
	for row: Dictionary in state.grants:
		referenced[row.from] = true
		referenced[row.to] = true
	for message: Dictionary in state.messages:
		referenced[message.from] = true
		if not str(message.to).is_empty():
			referenced[message.to] = true
	for visit: Dictionary in state.visits:
		referenced[str(visit.player)] = true
	for player: Dictionary in players.values():
		for other: Variant in player.contacts:
			referenced[other] = true
		for other: Variant in player.pending:
			referenced[other] = true
		for other: Variant in player.blocks:
			referenced[other] = true
	for player_id: Variant in keep:
		referenced[player_id] = true
	var drop: Array[String] = []
	for value: Variant in candidates:
		var player_id: String = str(value)
		if not players.has(player_id) or referenced.has(player_id):
			continue
		var player: Dictionary = players[player_id]
		if not player.contacts.is_empty() or not player.pending.is_empty() \
				or not player.blocks.is_empty():
			continue
		drop.append(player_id)
	for player_id: String in drop:
		players.erase(player_id)
	return drop.size()


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
