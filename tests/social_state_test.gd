extends SceneTree
## Pure social rules and their storage boundary: contacts, invitations, blocks,
## private/public messages, visits. No transport is involved, so every rule can
## be exercised directly and the persisted document is checked for the same
## things a network caller could try to sneak in.

const SocialState = preload("res://social/social_state.gd")
const SocialStore = preload("res://social/social_store.gd")
const WorldHost = preload("res://world/world_host.gd")
const WorldInvite = preload("res://world/world_invite.gd")

const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"
const CAROL: String = "player_00000000000000000000000000000003"
const NOW: float = 1800000000.0

var checks: int = 0
var failures: Array[String] = []
var dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir() \
		.path_join(".local/verification/social-state-%d" % Time.get_ticks_usec())
	var state: Dictionary = SocialState.initial_state()
	_expect(SocialState.valid(state), "A fresh social document is valid")

	_expect(SocialState.ensure_player(state, ALICE, "阿青", NOW).ok, "A player joins the record")
	_expect(SocialState.ensure_player(state, BOB, "小满", NOW).ok, "A second player joins")
	_expect(SocialState.ensure_player(state, CAROL, "阿禾", NOW).ok, "A third player joins")
	_expect(SocialState.ensure_player(state, ALICE, "阿青改名", NOW).ok, "A player renames without losing identity")
	_expect(state.players[ALICE].name == "阿青改名", "The display name is a mutable label")
	_expect(SocialState.ensure_player(state, "bad id", "x", NOW).reason == "invalid_player",
		"A malformed player id is refused")
	_expect(SocialState.ensure_player(state, BOB, "  ", NOW).reason == "invalid_player",
		"A blank display name is refused")

	# Invitation: pending on both sides, then mutual contacts on acceptance.
	_expect(SocialState.invite(state, ALICE, BOB, "小满", NOW).ok,
		"An invitation is sent to a known player")
	_expect(state.players[ALICE].pending[BOB].direction == "out",
		"The inviter records an outgoing request")
	_expect(state.players[BOB].pending[ALICE].direction == "in",
		"The recipient records an incoming request")
	_expect(SocialState.invite(state, ALICE, BOB, "小满", NOW).reason == "pending_exists",
		"A second invitation is refused while one is pending")
	_expect(SocialState.invite(state, ALICE, ALICE, "阿青", NOW).reason == "invalid_player",
		"Inviting oneself is refused")
	_expect(SocialState.accept(state, BOB, ALICE, NOW).ok, "The recipient accepts the invitation")
	_expect(state.players[ALICE].contacts.has(BOB) and state.players[BOB].contacts.has(ALICE),
		"Acceptance creates a mutual contact")
	_expect(state.players[ALICE].pending.is_empty() and state.players[BOB].pending.is_empty(),
		"Acceptance clears both pending entries")
	_expect(SocialState.accept(state, BOB, ALICE, NOW).reason == "no_invitation",
		"Accepting twice is refused")
	_expect(SocialState.invite(state, ALICE, BOB, "小满", NOW).reason == "already_contact",
		"A contact cannot be invited again")
	_expect(SocialState.valid(state), "The document stays valid after contact changes")

	# Declining leaves no relationship behind.
	_expect(SocialState.invite(state, ALICE, CAROL, "阿禾", NOW).ok, "A second invitation is sent")
	_expect(SocialState.decline(state, CAROL, ALICE).ok, "The recipient declines")
	_expect(not state.players[ALICE].contacts.has(CAROL) and state.players[ALICE].pending.is_empty(),
		"Declining removes the request and adds no contact")
	_expect(SocialState.remove_contact(state, ALICE, BOB).ok, "A contact is removed")
	_expect(state.players[ALICE].contacts.is_empty() and state.players[BOB].contacts.is_empty(),
		"Removal is mutual")
	_expect(SocialState.remove_contact(state, ALICE, BOB).reason == "not_a_contact",
		"Removing a non-contact is refused")

	# Blocking: stops delivery both ways, hides history, keeps the record.
	_expect(SocialState.send(state, BOB, ALICE, _id(1), "门口放了两把小葱。", NOW).ok,
		"A private message is sent")
	_expect(SocialState.block(state, ALICE, BOB, NOW, "不想再收到").ok, "The recipient blocks the sender")
	_expect(state.players[ALICE].blocks.has(BOB), "The block is recorded on the blocker")
	_expect(SocialState.send(state, BOB, ALICE, _id(2), "再问一句。", NOW).reason == "blocked",
		"A blocked sender cannot send a private message")
	_expect(SocialState.send(state, ALICE, BOB, _id(3), "不必回了。", NOW).reason == "blocked",
		"The blocker cannot message the blocked player either")
	_expect(SocialState.inbox(state, ALICE).is_empty(),
		"Existing messages from a blocked player are hidden from the blocker")
	_expect(SocialState.inbox(state, BOB).size() == 1,
		"The sender still owns the message it sent")
	_expect(SocialState.valid(state), "A block and the stored message coexist validly")
	_expect(SocialState.unblock(state, ALICE, BOB).ok, "The blocker lifts the block")
	_expect(SocialState.inbox(state, ALICE).size() == 1, "The hidden message returns after unblocking")
	_expect(SocialState.unblock(state, ALICE, BOB).reason == "not_blocked",
		"Unblocking a player that was not blocked is refused")
	_expect(SocialState.invite(state, ALICE, BOB, "小满", NOW).ok,
		"A lifted block allows a new invitation")

	# Public and private visibility.
	_expect(SocialState.send(state, CAROL, "", _id(4), "今天湖上起雾了。", NOW).ok,
		"A public message is stored once")
	_expect(SocialState.send(state, CAROL, BOB, _id(5), "借了你的竹筐。", NOW).ok,
		"A private message reaches its recipient")
	var alice_view: Array = SocialState.inbox(state, ALICE)
	_expect(alice_view.size() == 2, "A player sees public messages and messages addressed to it")
	var sees_private: bool = false
	for row: Dictionary in alice_view:
		sees_private = sees_private or row.id == _id(5)
	_expect(not sees_private, "A player never sees someone else's private message")
	_expect(SocialState.send(state, CAROL, ALICE, _id(1), "重复编号。", NOW).reason == "duplicate_message",
		"Reusing a message id is refused")
	_expect(SocialState.send(state, CAROL, ALICE, _id(6), "   ", NOW).reason == "invalid_message",
		"A blank message is refused")
	_expect(SocialState.send(state, "player_missing", ALICE, _id(6), "你好。", NOW).reason == "invalid_player",
		"A message from an unregistered player is refused")

	_expect(SocialState.mark_read(state, BOB, _id(5)).ok, "A recipient marks a message read")
	_expect(state.messages[2].read.get(BOB, false) == true, "The read mark belongs to the viewer")
	_expect(SocialState.mark_read(state, ALICE, _id(5)).reason == "not_visible",
		"Someone else's private message cannot be marked read")
	_expect(SocialState.delete_message(state, BOB, _id(5)).ok, "A recipient deletes a message for itself")
	_expect(not _has_message(SocialState.inbox(state, BOB), _id(5)),
		"The deleted message leaves that viewer's inbox")
	_expect(_has_message(SocialState.inbox(state, CAROL), _id(5)),
		"Deleting for one viewer does not erase the sender's copy")

	# Visits are a bounded recent history.
	for index: int in SocialState.MAX_VISITS + 5:
		SocialState.record_visit(state, CAROL, NOW + index)
	_expect(state.visits.size() == SocialState.MAX_VISITS, "The visit list is bounded")
	_expect(float(state.visits[0].at) > NOW, "The oldest visits leave first")
	_expect(SocialState.valid(state), "The full document with every feature is valid")

	# Collaboration grants: scoped commands, expiry and issuer-only revocation.
	_expect(SocialState.grant(state, CAROL, ALICE, _gid(1), ["water", "weed"], [], 0.0, NOW).ok,
		"A grant issues scoped care commands")
	_expect(SocialState.allows(state, ALICE, "water", "field_01", NOW), "A granted command is allowed")
	_expect(not SocialState.allows(state, ALICE, "harvest", "field_01", NOW),
		"An ungranted command stays refused")
	_expect(SocialState.grant(state, CAROL, ALICE, _gid(2), ["harvest"], ["field_03"], 0.0, NOW).ok,
		"A field-scoped harvest grant is issued")
	_expect(SocialState.allows(state, ALICE, "harvest", "field_03", NOW), "The grant covers its field")
	_expect(not SocialState.allows(state, ALICE, "harvest", "field_04", NOW),
		"The grant does not cover other fields")
	_expect(SocialState.grant(state, CAROL, BOB, _gid(3), ["water"], [], NOW + 100.0, NOW).ok,
		"A time-limited grant is issued")
	_expect(SocialState.allows(state, BOB, "water", "field_01", NOW + 99.0), "The grant is active before expiry")
	_expect(not SocialState.allows(state, BOB, "water", "field_01", NOW + 100.0),
		"The grant expires at its deadline")
	_expect(SocialState.grant(state, CAROL, ALICE, _gid(4), [], [], 0.0, NOW).reason == "invalid_grant",
		"A grant with no commands is refused")
	_expect(SocialState.grant(state, CAROL, ALICE, _gid(5), ["fly"], [], 0.0, NOW).reason == "invalid_grant",
		"An unknown command in a grant is refused")
	_expect(SocialState.grant(state, CAROL, ALICE, _gid(6), ["water"], [], NOW - 1.0, NOW).reason == "invalid_expiry",
		"A grant that is already expired is refused")
	_expect(SocialState.revoke_grant(state, ALICE, _gid(1)).reason == "not_issuer",
		"Only the issuer can revoke a grant")
	_expect(SocialState.revoke_grant(state, CAROL, _gid(1)).ok, "The issuer revokes a grant")
	_expect(not SocialState.allows(state, ALICE, "water", "field_01", NOW),
		"Revocation takes effect immediately")
	_expect(SocialState.revoke_grant(state, CAROL, _gid(1)).reason == "missing_grant",
		"Revoking twice is refused")
	_expect((SocialState.grants_view(state, ALICE) as Array).size() == 1,
		"A grantee sees the grants addressed to it")
	_expect((SocialState.grants_view(state, CAROL) as Array).size() == 2,
		"The issuer sees every grant it issued")

	# A cell's real owner is the only issuer whose grant can cover it. The host
	# applies this with the cell's `planted_by`, which the pure document cannot
	# know, so the owner is passed in at resolution time.
	_expect(SocialState.allows(state, ALICE, "harvest", "field_03", NOW, CAROL),
		"A grant covering the cell's true owner is accepted")
	_expect(not SocialState.allows(state, ALICE, "harvest", "field_03", NOW, BOB),
		"A third party's grant cannot authorize another owner's cell")

	# A fractional expiry is a real deadline, not "permanent" because its integer
	# part is zero.
	var short_lived: Dictionary = SocialState.initial_state()
	SocialState.ensure_player(short_lived, ALICE, "阿青", NOW)
	SocialState.ensure_player(short_lived, BOB, "小满", NOW)
	_expect(SocialState.grant(short_lived, ALICE, BOB, _gid(70), ["harvest"], [], NOW + 0.5, NOW).ok,
		"A sub-second deadline is accepted")
	_expect(SocialState.allows(short_lived, BOB, "harvest", "field_03", NOW + 0.1),
		"The grant is active before a fractional deadline")
	_expect(not SocialState.allows(short_lived, BOB, "harvest", "field_03", NOW + 0.5),
		"A fractional deadline is not treated as permanent")

	# Ending a relationship ends the consent it carried, and a historical grant
	# left beside a block is ignored even before a cleanup pass.
	var consented: Dictionary = SocialState.initial_state()
	SocialState.ensure_player(consented, ALICE, "阿青", NOW)
	SocialState.ensure_player(consented, BOB, "小满", NOW)
	SocialState.ensure_player(consented, CAROL, "阿禾", NOW)
	SocialState.invite(consented, ALICE, BOB, "小满", NOW)
	SocialState.accept(consented, BOB, ALICE, NOW)
	_expect(SocialState.grant(consented, ALICE, BOB, _gid(71), ["harvest"], [], 0.0, NOW).ok,
		"A contact receives a harvest grant")
	_expect(SocialState.remove_contact(consented, ALICE, BOB).ok, "The contact is removed")
	_expect(consented.grants.is_empty() and not SocialState.allows(
		consented, BOB, "harvest", "field_03", NOW, ALICE),
		"Removing a contact revokes the grants in both directions")
	_expect(SocialState.grant(consented, ALICE, BOB, _gid(72), ["harvest"], [], 0.0, NOW).ok,
		"A new grant is issued before blocking")
	_expect(SocialState.block(consented, ALICE, BOB, NOW, "测试").ok, "The owner blocks the grantee")
	_expect(consented.grants.is_empty() and not SocialState.allows(
		consented, BOB, "harvest", "field_03", NOW, ALICE),
		"Blocking revokes the grant immediately")
	# A document written before block revocation may still hold a grant.
	var legacy: Dictionary = consented.duplicate(true)
	legacy.grants.append({"id": _gid(73), "from": ALICE, "to": BOB,
		"kinds": ["harvest"], "fields": [], "created": NOW, "expires_at": 0.0})
	_expect(SocialState.valid(legacy), "A legacy grant beside a block is still a valid document shape")
	_expect(not SocialState.allows(legacy, BOB, "harvest", "field_03", NOW, ALICE),
		"A blocked pair never matches a historical grant")
	_expect(SocialState.send(legacy, BOB, "", _id(30), "公开消息。", NOW).ok,
		"A public message is accepted from a blocked sender")
	_expect(not _has_message(SocialState.inbox(legacy, ALICE), _id(30)),
		"A blocked viewer does not see a public message")
	_expect(_has_message(SocialState.inbox(legacy, CAROL), _id(30)),
		"Other players still see the public message")

	# Contacts and invitations are symmetric records; a crafted one-sided row is
	# invalid and cannot let one side claim a relationship.
	var pair: Dictionary = SocialState.initial_state()
	SocialState.ensure_player(pair, ALICE, "阿青", NOW)
	SocialState.ensure_player(pair, BOB, "小满", NOW)
	SocialState.invite(pair, ALICE, BOB, "小满", NOW)
	_expect(SocialState.valid(pair), "A reciprocal invitation is valid")
	var one_way_pending: Dictionary = pair.duplicate(true)
	one_way_pending.players[BOB].pending.erase(ALICE)
	_expect(not SocialState.valid(one_way_pending), "A one-sided invitation is refused")
	var same_direction: Dictionary = pair.duplicate(true)
	same_direction.players[BOB].pending[ALICE].direction = SocialState.OUTGOING
	_expect(not SocialState.valid(same_direction), "Both sides cannot claim the same direction")
	SocialState.accept(pair, BOB, ALICE, NOW)
	_expect(SocialState.valid(pair), "A mutual contact pair is valid")
	var one_way_contact: Dictionary = pair.duplicate(true)
	one_way_contact.players[BOB].contacts.erase(ALICE)
	_expect(not SocialState.valid(one_way_contact), "A one-sided contact is refused")

	# A full grant table of expired rows must not permanently block consent.
	var exhausted: Dictionary = SocialState.initial_state()
	SocialState.ensure_player(exhausted, ALICE, "阿青", NOW)
	SocialState.ensure_player(exhausted, BOB, "小满", NOW)
	var filled_grants: bool = true
	for index: int in SocialState.MAX_GRANTS:
		filled_grants = filled_grants and SocialState.grant(
			exhausted, ALICE, BOB, _gid(1000 + index), ["harvest"], [], NOW + 1.0, NOW).ok
	_expect(filled_grants and exhausted.grants.size() == SocialState.MAX_GRANTS,
		"The grant table can be filled to its limit")
	_expect(SocialState.grant(exhausted, ALICE, BOB, _gid(2000), ["harvest"], [], 0.0, NOW).reason
		== "grant_limit", "A full grant table refuses another grant")
	_expect(SocialState.prune(exhausted, NOW + 2.0, [ALICE, BOB]) >= SocialState.MAX_GRANTS,
		"Every expired grant is pruned at the action boundary")
	_expect(SocialState.grant(exhausted, ALICE, BOB, _gid(2001), ["harvest"], [], 0.0, NOW).ok,
		"A grant can be issued after expired rows are pruned")

	# Soft-deleted messages are physically reclaimed once every viewer removed
	# them, so one sender cannot keep the whole inbox full forever.
	var flooded: Dictionary = SocialState.initial_state()
	var senders: Array[String] = []
	for index: int in 8:
		var sender: String = "player_%032d" % (index + 1)
		senders.append(sender)
		SocialState.ensure_player(flooded, sender, "玩家%d" % index, NOW)
	var sent_all: bool = true
	for sender_index: int in senders.size():
		for index: int in SocialState.MAX_MESSAGES_PER_SENDER:
			sent_all = sent_all and SocialState.send(flooded, senders[sender_index], "",
				_id(10000 + sender_index * 100 + index), "第%d条公开消息。" % index, NOW).ok
	_expect(sent_all and flooded.messages.size() == SocialState.MAX_MESSAGES,
		"Each sender fills only its quota and the table reaches its limit")
	_expect(SocialState.send(flooded, senders[0], "", _id(20000), "再一条。", NOW).reason
		== "inbox_full", "A full inbox refuses another message")
	for message: Dictionary in flooded.messages.duplicate(true):
		for viewer: String in senders:
			SocialState.delete_message(flooded, viewer, str(message.id))
	_expect(flooded.messages.is_empty(), "Messages deleted by every relevant viewer are reclaimed")
	_expect(SocialState.send(flooded, senders[0], "", _id(20001), "回收之后。", NOW).ok,
		"A message can be sent after deleted rows are reclaimed")

	# An invitation creates a temporary row; an unanswered one and its row leave
	# after the window, freeing the player table.
	var undecided: Dictionary = SocialState.initial_state()
	SocialState.ensure_player(undecided, ALICE, "阿青", NOW)
	var stranger: String = "player_00000000000000000000000000000099"
	_expect(SocialState.invite(undecided, ALICE, stranger, "路人", NOW).ok,
		"An invitation to an unregistered player is recorded")
	_expect(undecided.players.has(stranger), "The invitation creates a temporary row")
	SocialState.prune(undecided, NOW + SocialState.INVITE_TTL_SECONDS + 1.0, [ALICE])
	_expect(not undecided.players.has(stranger) and undecided.players[ALICE].pending.is_empty(),
		"An unanswered invitation and its temporary row are pruned")
	_expect(SocialState.ensure_player(undecided, stranger, "路人",
		NOW + SocialState.INVITE_TTL_SECONDS + 2.0).ok,
		"The player id can register normally after the stale row is gone")

	# A read path registers a new id but never renames an existing one; the name
	# is written on join or by a real write.
	var names: Dictionary = SocialState.initial_state()
	SocialState.ensure_player(names, ALICE, "旧名", NOW)
	_expect(SocialState.register_player(names, ALICE, "新名", NOW).ok,
		"A read path registers an existing id without failing")
	_expect(names.players[ALICE].name == "旧名", "A read path never rewrites the display name")
	_expect(SocialState.ensure_player(names, ALICE, "新名", NOW).ok, "A write path refreshes the name")
	_expect(names.players[ALICE].name == "新名", "A write path updates the display name")

	# Duplicate display names are disambiguated at registration by the stable id
	# suffix, so messages and the roster never show two identical labels.
	var duplicates: Dictionary = SocialState.initial_state()
	SocialState.ensure_player(duplicates, ALICE, "同名", NOW)
	SocialState.ensure_player(duplicates, BOB, "同名", NOW)
	_expect(duplicates.players[ALICE].name == "同名",
		"The first player keeps a unique display name")
	_expect(duplicates.players[BOB].name == "同名#" + BOB.right(6),
		"A duplicate display name gains the stable id suffix")
	_expect(SocialState.valid(duplicates), "Disambiguated names keep the document valid")
	var long_names: Dictionary = SocialState.initial_state()
	var long_name: String = "衣".repeat(SocialState.MAX_NAME)
	SocialState.ensure_player(long_names, ALICE, long_name, NOW)
	SocialState.ensure_player(long_names, BOB, long_name, NOW)
	_expect(SocialState.valid(long_names)
		and long_names.players[BOB].name.length() <= SocialState.MAX_NAME
		and long_names.players[BOB].name.ends_with("#" + BOB.right(6)),
		"A long duplicate name is truncated to fit the name limit")

	# Validation rejects what the rules would never write.
	_expect(not SocialState.valid({}), "An empty dictionary is refused")
	var bad: Dictionary = state.duplicate(true)
	bad.version = SocialState.VERSION + 1
	_expect(not SocialState.valid(bad), "An unknown document version is refused")
	bad = state.duplicate(true)
	bad.players[ALICE].blocks[BOB] = {"at": NOW, "reason": ""}
	bad.players[ALICE].contacts[BOB] = {"name": "小满", "since": NOW}
	_expect(not SocialState.valid(bad), "A player cannot be both contact and blocked")
	bad = state.duplicate(true)
	bad.messages[0].from = "player_missing"
	_expect(not SocialState.valid(bad), "A message from an unregistered player is refused")
	bad = state.duplicate(true)
	bad.messages[0].read = {ALICE: false}
	_expect(not SocialState.valid(bad), "A read mark that is not true is refused")
	bad = state.duplicate(true)
	bad.messages.append(bad.messages[0].duplicate(true))
	_expect(not SocialState.valid(bad), "Duplicate message ids are refused")
	bad = state.duplicate(true)
	bad.players[ALICE].pending[CAROL] = {"name": "阿禾", "at": NOW, "direction": "sideways"}
	_expect(not SocialState.valid(bad), "An unknown invitation direction is refused")
	bad = state.duplicate(true)
	bad.grants[0].kinds = []
	_expect(not SocialState.valid(bad), "A grant with no commands is invalid on disk")
	bad = state.duplicate(true)
	bad.grants[1].id = bad.grants[0].id
	_expect(not SocialState.valid(bad), "Duplicate grant ids are refused")

	# Storage: the same document round-trips, and the store refuses anything the
	# rules would refuse.
	DirAccess.make_dir_recursive_absolute(dir)
	var store := SocialStore.new(dir)
	var loaded: Dictionary = store.load_state()
	_expect(loaded.ok and loaded.kind == "missing",
		"A directory without a social document opens empty")
	_expect(SocialState.valid(loaded.state), "The empty document is the valid initial state")
	_expect(store.save_state(state).ok, "The social document is saved")
	var reopened := SocialStore.new(dir)
	var again: Dictionary = reopened.load_state()
	_expect(again.ok and again.kind == "loaded", "The social document reloads")
	_expect(again.state.players.keys().size() == 3 and again.state.visits.size() == SocialState.MAX_VISITS,
		"The reloaded document keeps players and visits")
	_expect(not reopened.save_state({}).ok, "The store refuses an invalid document")
	_expect(not FileAccess.file_exists(dir.path_join(SocialStore.PENDING)),
		"A completed save leaves no pending file behind")
	var broken := FileAccess.open(dir.path_join(SocialStore.MAIN), FileAccess.WRITE)
	broken.store_string("not json")
	broken.close()
	_expect(SocialStore.new(dir).load_state().kind == "corrupt", "A corrupt document is refused")
	_test_store_backup_and_recovery()
	_test_store_rejects_linked_paths()
	_test_world_social_paths()
	_test_social_request_replay()
	_test_social_receipts_outlive_effects()
	_test_worst_legal_document()
	_finish()


func _test_store_backup_and_recovery() -> void:
	var folder: String = dir.path_join("backup")
	var first: Dictionary = SocialState.initial_state()
	var second: Dictionary = first.duplicate(true)
	_expect(SocialState.ensure_player(second, ALICE, "阿青", NOW).ok,
		"The backup fixture has a second social generation")
	_expect(SocialStore.new(folder).save_state(first).ok, "The first social save is committed")
	_expect(not FileAccess.file_exists(folder.path_join(SocialStore.BACKUP)),
		"A first social save has no previous generation")
	_expect(SocialStore.new(folder).save_state(second).ok, "A second social save is committed")
	var backup_path: String = folder.path_join(SocialStore.BACKUP)
	_expect(FileAccess.file_exists(backup_path), "A second social save keeps the previous generation")
	var backup: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(backup_path))
	_expect(int(backup.version) == SocialStore.VERSION
		and backup.state is Dictionary
		and SocialState.canonical(backup.state) == SocialState.canonical(first),
		"The social backup holds the previous committed document")
	var main_path: String = folder.path_join(SocialStore.MAIN)
	_write_text(main_path, "not json")
	var offered: Dictionary = SocialStore.new(folder).load_state()
	_expect(not offered.ok and offered.kind == "recovery_available"
		and offered.source == SocialStore.BACKUP,
		"A damaged social main with a valid backup offers explicit recovery")
	_expect(FileAccess.get_file_as_string(main_path) == "not json",
		"Offering social recovery preserves the damaged main")
	# A save over a damaged main must not copy the damage over the good backup.
	_expect(SocialStore.new(folder).save_state(second).ok,
		"A social save over a damaged main still succeeds")
	_expect(FileAccess.get_file_as_string(backup_path) != "not json",
		"A social save over a damaged main never replaces the good backup with the damage")
	_write_text(main_path, "not json")
	var recovered: Dictionary = SocialStore.new(folder).recover()
	_expect(recovered.ok and recovered.kind == "recovered"
		and recovered.state == SocialState.canonical(first),
		"Explicit social recovery restores the previous generation")
	_expect(SocialStore.new(folder).load_state().state == SocialState.canonical(first),
		"The recovered social main loads as the previous document")
	var preserved: bool = false
	for name: String in DirAccess.get_files_at(folder):
		if name.begins_with("social.unreadable."):
			preserved = FileAccess.get_file_as_string(folder.path_join(name)) == "not json"
	_expect(preserved, "Social recovery retains the damaged bytes for diagnosis")
	var future_text: String = JSON.stringify({"version": SocialStore.VERSION + 1,
		"state": SocialState.canonical(second)})
	_write_text(main_path, future_text)
	_expect(SocialStore.new(folder).load_state().kind == "unsupported",
		"A newer social document is distinguished from damage")
	_expect(not SocialStore.new(folder).recover().ok,
		"Social recovery never crosses an unsupported version")
	_expect(FileAccess.get_file_as_string(main_path) == future_text,
		"A refused newer social recovery preserves the main bytes")


func _test_store_rejects_linked_paths() -> void:
	var base: String = dir.path_join("links")
	DirAccess.make_dir_recursive_absolute(base)
	var outside_path: String = base.path_join("outside.json")
	var outside_text: String = JSON.stringify({"version": SocialStore.VERSION,
		"state": SocialState.initial_state()})
	_write_text(outside_path, outside_text)
	for filename: String in [SocialStore.MAIN, SocialStore.PENDING, SocialStore.BACKUP]:
		var real: String = base.path_join("linked-" + filename)
		DirAccess.make_dir_recursive_absolute(real)
		if not _try_link(real, outside_path, real.path_join(filename)):
			print("SKIP social symlink guard for " + filename)
			continue
		var store := SocialStore.new(real)
		_expect(store.load_state().kind == "unsafe_path",
			"A linked social sidecar is refused on load: " + filename)
		_expect(store.save_state(SocialState.initial_state()).kind == "unsafe_path",
			"A linked social sidecar is refused on save: " + filename)
		_expect(FileAccess.get_file_as_string(outside_path) == outside_text,
			"A refused linked social sidecar leaves the outside file unchanged: " + filename)
	var real_dir: String = base.path_join("real-world")
	DirAccess.make_dir_recursive_absolute(real_dir)
	if _try_link(base, real_dir, base.path_join("alias-world")):
		var aliased: String = base.path_join("alias-world")
		_expect(SocialStore.new(aliased).load_state().kind == "unsafe_path",
			"A social save directory reached through a linked ancestor is refused on load")
		_expect(SocialStore.new(aliased).save_state(SocialState.initial_state()).kind == "unsafe_path",
			"A social save directory reached through a linked ancestor is refused on save")
	else:
		print("SKIP social symlink ancestor guard")


## The authority path: a state read must not rewrite the document, and a damaged
## main with a valid backup must be recoverable only by an explicit call.
func _test_world_social_paths() -> void:
	var folder: String = dir.path_join("world-host")
	DirAccess.make_dir_recursive_absolute(folder)
	var first: Dictionary = SocialState.initial_state()
	SocialState.ensure_player(first, ALICE, "旧名", NOW)
	_expect(SocialStore.new(folder).save_state(first).ok,
		"The world fixture writes the first social generation")
	var second: Dictionary = first.duplicate(true)
	second.players[ALICE].name = "第二版"
	_expect(SocialStore.new(folder).save_state(second).ok,
		"The world fixture writes the current social generation")
	var host := WorldHost.new()
	host.name = "SocialRulesHost"
	root.add_child(host)
	var opened: Dictionary = host.configure(folder, NOW, "world-social-fixture")
	_expect(bool(opened.get("ok", false)), "A world host opens with an existing social document")
	host._players[1] = {"id": ALICE, "name": "新名字"}
	var main_path: String = folder.path_join(SocialStore.MAIN)
	var before: String = FileAccess.get_sha256(main_path)
	var reply: Dictionary = host._apply_social(1, "state", {})
	_expect(bool(reply.get("ok", false)), "The state read succeeds")
	_expect(host.social.players[ALICE].name == "第二版",
		"A state read keeps the stored name instead of the session label")
	_expect(FileAccess.get_sha256(main_path) == before,
		"A state read does not rewrite social.json")
	# A damaged main with a valid backup is offered but never restored silently.
	_write_text(main_path, "not json")
	var broken := WorldHost.new()
	broken.name = "SocialRecoveryHost"
	root.add_child(broken)
	var refused: Dictionary = broken.configure(folder, NOW, "world-social-fixture")
	_expect(not bool(refused.get("ok", false))
		and str(refused.get("reason", "")) == "social_recovery_available",
		"A damaged main with a valid backup refuses to start the authority")
	var recovered: Dictionary = broken.recover_social()
	_expect(bool(recovered.get("ok", false)), "Explicit social recovery succeeds")
	_expect(str(recovered.get("kind", "")) == "social_recovered", "Recovery reports its kind")
	_expect(broken.social.players[ALICE].name == "旧名",
		"Recovery restores the previous committed generation")
	_expect(FileAccess.file_exists(folder.path_join(SocialStore.MAIN)),
		"Recovery leaves a loadable social main behind")
	host.queue_free()
	broken.queue_free()


## A reliable client RPC can be retried after a timeout or reconnect. The
## authority must answer the same request id as a duplicate without writing a
## second message/grant/visit, must refuse a reused id whose key arguments
## changed, and must still accept a genuinely new id.
func _test_social_request_replay() -> void:
	var folder: String = dir.path_join("social-replay")
	DirAccess.make_dir_recursive_absolute(folder)
	var host := WorldHost.new()
	host.name = "SocialReplayHost"
	root.add_child(host)
	var opened: Dictionary = host.configure(folder, NOW, "world-social-replay")
	_expect(bool(opened.get("ok", false)), "The replay host opens on a fresh social document")
	host._players[1] = {"id": ALICE, "name": "阿青"}
	host._players[2] = {"id": BOB, "name": "小满"}
	host._members[1] = WorldInvite.MEMBER
	# Register the recipient so a private send has a real target. Peer 2 is not a
	# member, which also keeps live delivery from reaching an RPC peer in the test.
	_expect(host._apply_social(2, "state", {}).ok, "The replay fixture registers the recipient")

	var first_send: Dictionary = host._apply_social(1, "send",
		{"to": BOB, "text": "早上好"}, "req-send-1")
	_expect(bool(first_send.get("ok", false)) and not bool(first_send.get("duplicate", true)),
		"A first send is applied and is not marked duplicate")
	_expect(host.social.messages.size() == 1, "A first send appends one message")
	var message_id: String = str(host.social.messages[0].id)
	_expect(message_id.begins_with("msg_") and SocialState.valid_identifier(message_id),
		"The deterministic message id keeps the msg_ rule and the shared id bounds")
	var after_send: String = _document_text(folder)
	var sent_again: Dictionary = host._apply_social(1, "send",
		{"to": BOB, "text": "早上好"}, "req-send-1")
	_expect(bool(sent_again.get("ok", false)) and bool(sent_again.get("duplicate", false)),
		"A send retry reports duplicate success")
	_expect(host.social.messages.size() == 1, "A send retry appends no second message")
	_expect(_document_text(folder) == after_send, "A send retry leaves social.json byte-identical")
	var send_text_conflict: Dictionary = host._apply_social(1, "send",
		{"to": BOB, "text": "晚上好"}, "req-send-1")
	_expect(not bool(send_text_conflict.get("ok", true))
		and str(send_text_conflict.get("reason", "")) == "command_conflict",
		"Reusing a request id with different text is refused as command_conflict")
	_expect(host.social.messages.size() == 1, "A conflicting send writes nothing")
	var send_to_conflict: Dictionary = host._apply_social(1, "send",
		{"to": "", "text": "早上好"}, "req-send-1")
	_expect(not bool(send_to_conflict.get("ok", true))
		and str(send_to_conflict.get("reason", "")) == "command_conflict",
		"Reusing a request id with a different recipient is refused as command_conflict")
	var second_send: Dictionary = host._apply_social(1, "send",
		{"to": BOB, "text": "早上好"}, "req-send-2")
	_expect(bool(second_send.get("ok", false)) and host.social.messages.size() == 2,
		"A different request id appends a new message")

	var grant_args: Dictionary = {"player_id": BOB, "kinds": ["water"],
		"fields": [], "expires_at": 0.0}
	var first_grant: Dictionary = host._apply_social(1, "grant", grant_args, "req-grant-1")
	_expect(bool(first_grant.get("ok", false)) and not bool(first_grant.get("duplicate", true)),
		"A first grant is applied and is not marked duplicate")
	_expect(host.social.grants.size() == 1, "A first grant appends one row")
	var grant_id: String = str(host.social.grants[0].id)
	_expect(grant_id.begins_with("grant_") and SocialState.valid_identifier(grant_id),
		"The deterministic grant id keeps the grant_ rule and the shared id bounds")
	var after_grant: String = _document_text(folder)
	var granted_again: Dictionary = host._apply_social(1, "grant", grant_args, "req-grant-1")
	_expect(bool(granted_again.get("ok", false)) and bool(granted_again.get("duplicate", false)),
		"A grant retry reports duplicate success")
	_expect(host.social.grants.size() == 1, "A grant retry appends no second row")
	_expect(_document_text(folder) == after_grant, "A grant retry leaves social.json byte-identical")
	var grant_conflict: Dictionary = host._apply_social(1, "grant",
		{"player_id": BOB, "kinds": ["harvest"], "fields": [], "expires_at": 0.0},
		"req-grant-1")
	_expect(not bool(grant_conflict.get("ok", true))
		and str(grant_conflict.get("reason", "")) == "command_conflict",
		"Reusing a request id with different grant arguments is refused as command_conflict")
	_expect(host.social.grants.size() == 1, "A conflicting grant writes nothing")
	var second_grant: Dictionary = host._apply_social(1, "grant", grant_args, "req-grant-2")
	_expect(bool(second_grant.get("ok", false)) and host.social.grants.size() == 2,
		"A different request id appends a new grant")

	var visits_before: int = host.social.visits.size()
	var first_visit: Dictionary = host._apply_social(1, "visit", {}, "req-visit-1")
	_expect(bool(first_visit.get("ok", false)) and host.social.visits.size() == visits_before + 1,
		"A first visit appends one row")
	var visit_row: Dictionary = host.social.visits[host.social.visits.size() - 1]
	_expect(visit_row.size() == 3 and str(visit_row.get("player", "")) == ALICE \
		and str(visit_row.get("kind", "")) == "visit",
		"A visit row keeps its existing three-field shape")
	var after_visit: String = _document_text(folder)
	var visited_again: Dictionary = host._apply_social(1, "visit", {}, "req-visit-1")
	_expect(bool(visited_again.get("ok", false)) and bool(visited_again.get("duplicate", false)),
		"A visit retry reports duplicate success")
	_expect(host.social.visits.size() == visits_before + 1,
		"A visit retry appends no second row")
	_expect(_document_text(folder) == after_visit, "A visit retry leaves social.json byte-identical")
	var second_visit: Dictionary = host._apply_social(1, "visit", {}, "req-visit-2")
	_expect(bool(second_visit.get("ok", false)) and not bool(second_visit.get("duplicate", true))
		and host.social.visits.size() == visits_before + 2,
		"A different request id appends a new visit")
	host.queue_free()


## 请求回执必须比它保护的行活得更久：撤销授权、删除并回收消息之后再收到同一
## 请求 id 的重投，只能得到 duplicate，不能重新写入授权或消息。
func _test_social_receipts_outlive_effects() -> void:
	var folder: String = dir.path_join("social-receipts")
	DirAccess.make_dir_recursive_absolute(folder)
	var host := WorldHost.new()
	host.name = "SocialReceiptHost"
	root.add_child(host)
	_expect(bool(host.configure(folder, NOW, "world-social-receipts").get("ok", false)),
		"The receipt host opens on a fresh social document")
	host._players[1] = {"id": ALICE, "name": "阿青"}
	host._players[2] = {"id": BOB, "name": "小满"}
	host._members[1] = WorldInvite.MEMBER
	_expect(host._apply_social(2, "state", {}).ok,
		"The receipt fixture registers the recipient")

	var grant_args: Dictionary = {"player_id": BOB, "kinds": ["water"],
		"fields": [], "expires_at": 0.0}
	var granted: Dictionary = host._apply_social(1, "grant", grant_args, "req-grant-r1")
	_expect(bool(granted.get("ok", false)) and host.social.grants.size() == 1,
		"The receipt fixture grants once")
	var grant_id: String = str(host.social.grants[0].id)
	_expect(host._apply_social(1, "revoke", {"id": grant_id}).ok,
		"The grant is revoked")
	_expect(host.social.grants.is_empty(), "The revoked grant leaves no row")
	var resurrect: Dictionary = host._apply_social(1, "grant", grant_args, "req-grant-r1")
	_expect(bool(resurrect.get("ok", false)) and bool(resurrect.get("duplicate", false)),
		"A late replay of the revoked grant is answered as duplicate")
	_expect(host.social.grants.is_empty(),
		"A late replay does not resurrect the revoked grant")

	var sent: Dictionary = host._apply_social(1, "send",
		{"to": BOB, "text": "早上好"}, "req-send-r1")
	_expect(bool(sent.get("ok", false)) and host.social.messages.size() == 1,
		"The receipt fixture sends once")
	var message_id: String = str(host.social.messages[0].id)
	_expect(host._apply_social(2, "delete", {"id": message_id}).ok,
		"The recipient deletes the message")
	_expect(host._apply_social(1, "delete", {"id": message_id}).ok,
		"The sender deletes the message")
	_expect(host.social.messages.is_empty(), "The fully deleted message is reclaimed")
	var resend: Dictionary = host._apply_social(1, "send",
		{"to": BOB, "text": "早上好"}, "req-send-r1")
	_expect(bool(resend.get("ok", false)) and bool(resend.get("duplicate", false)),
		"A late replay of the reclaimed message is answered as duplicate")
	_expect(host.social.messages.is_empty(),
		"A late replay does not re-create the deleted message")
	var stored: Dictionary = SocialStore.new(folder).load_state()
	_expect(stored.ok and (stored.state.requests as Dictionary).size() == 2,
		"The social document keeps one durable receipt per request")

	# 其它写动作也不按“当前状态”重放：删除联系人后再加回，迟到的旧 remove 不能
	# 把新联系人再删掉。
	var invite_args: Dictionary = {"player_id": BOB, "name": "小满"}
	_expect(host._apply_social(1, "invite", invite_args, "req-invite-r1").ok,
		"The receipt fixture invites once")
	_expect(host._apply_social(2, "accept", {"player_id": ALICE}, "req-accept-r1").ok,
		"The invitation is accepted")
	_expect(host._apply_social(1, "remove", {"player_id": BOB}, "req-remove-r1").ok,
		"The contact is removed")
	_expect(host._apply_social(1, "invite", invite_args, "req-invite-r2").ok,
		"The contact is invited again")
	_expect(host._apply_social(2, "accept", {"player_id": ALICE}, "req-accept-r2").ok,
		"The new invitation is accepted")
	var late_remove: Dictionary = host._apply_social(1, "remove",
		{"player_id": BOB}, "req-remove-r1")
	_expect(bool(late_remove.get("ok", false))
			and bool(late_remove.get("duplicate", false)),
		"A late replay of the old remove is answered as duplicate")
	_expect((host.social.players[ALICE].contacts as Dictionary).has(BOB),
		"The late remove replay leaves the new contact in place")
	host.queue_free()

	var reopened := WorldHost.new()
	reopened.name = "SocialReceiptReopen"
	root.add_child(reopened)
	_expect(bool(reopened.configure(folder, NOW + 60.0, "world-social-receipts")
		.get("ok", false)), "The receipt document reopens")
	reopened._players[1] = {"id": ALICE, "name": "阿青"}
	reopened._players[2] = {"id": BOB, "name": "小满"}
	reopened._members[1] = WorldInvite.MEMBER
	var after_restart: Dictionary = reopened._apply_social(1, "grant", grant_args,
		"req-grant-r1")
	_expect(bool(after_restart.get("ok", false))
			and bool(after_restart.get("duplicate", false)),
		"A receipt survives restart and still answers duplicate")
	_expect(reopened.social.grants.is_empty(),
		"A replayed grant after restart stays revoked")
	reopened.queue_free()


func _document_text(folder: String) -> String:
	return FileAccess.get_file_as_string(folder.path_join(SocialStore.MAIN))


## Builds the largest document `SocialState.valid()` accepts for the dominant
## dimensions and proves the storage cap covers it. Callers rely on `valid()` and
## `save_state()` agreeing; without this, a legal in-memory record could never be
## saved. The fixture fails if a future rule allows a bigger shape.
func _test_worst_legal_document() -> void:
	var wide: String = String.chr(0x20000)
	var name: String = wide.repeat(SocialState.MAX_NAME)
	var reason: String = wide.repeat(SocialState.MAX_REASON)
	var text: String = wide.repeat(SocialState.MAX_TEXT)
	var ids: Array[String] = []
	for index: int in SocialState.MAX_PLAYERS:
		ids.append("p%063d" % index)
	var document: Dictionary = SocialState.initial_state()
	for player_id: String in ids:
		document.players[player_id] = {"name": name, "contacts": {}, "pending": {}, "blocks": {}}
	# Blocks are the largest relationship row and may be one-way; every player
	# blocks every other player with the longest legal reason.
	for source: String in ids:
		for target: String in ids:
			if source == target:
				continue
			document.players[source].blocks[target] = {
				"at": SocialState.MAX_TIME, "reason": reason}
	for index: int in SocialState.MAX_GRANTS:
		var fields: Array = []
		for field_index: int in SocialState.MAX_GRANT_FIELDS:
			fields.append("f%063d" % (index * SocialState.MAX_GRANT_FIELDS + field_index))
		document.grants.append({"id": "g%063d" % index, "from": ids[index % ids.size()],
			"to": ids[(index + 1) % ids.size()], "kinds": SocialState.GRANT_KINDS.duplicate(),
			"fields": fields, "created": SocialState.MAX_TIME, "expires_at": 0.0})
	var per_sender: int = int(SocialState.MAX_MESSAGES / 8)
	for sender_index: int in 8:
		for index: int in per_sender:
			var seen: Dictionary = {}
			for viewer: String in ids:
				seen[viewer] = true
			document.messages.append({"id": "m%063d" % (sender_index * per_sender + index),
				"from": ids[sender_index], "to": "", "text": text,
				"at": SocialState.MAX_TIME, "read": seen.duplicate(true),
				"deleted": seen.duplicate(true)})
	for index: int in SocialState.MAX_VISITS:
		document.visits.append({"player": ids[index % ids.size()],
			"at": SocialState.MAX_TIME, "kind": "visit"})
	_expect(SocialState.valid(document), "The largest legal social document is valid")
	var encoded: int = JSON.stringify({"version": SocialState.VERSION,
		"state": SocialState.canonical(document)}, "\t").to_utf8_buffer().size()
	print("SOCIAL_WORST_BYTES %d cap %d" % [encoded, SocialStore.MAX_BYTES])
	_expect(encoded <= SocialStore.MAX_BYTES,
		"The storage cap covers the largest legal document (%d bytes)" % encoded)
	var worst: String = dir.path_join("worst")
	_expect(SocialStore.new(worst).save_state(document).ok,
		"The largest legal document saves")
	var loaded: Dictionary = SocialStore.new(worst).load_state()
	_expect(bool(loaded.get("ok", false)) and loaded.kind == "loaded",
		"The largest legal document reads back")
	if bool(loaded.get("ok", false)):
		_expect(loaded.state.players.size() == SocialState.MAX_PLAYERS
			and loaded.state.grants.size() == SocialState.MAX_GRANTS
			and loaded.state.messages.size() == SocialState.MAX_MESSAGES,
			"The largest legal document keeps its rows through a round trip")


func _try_link(parent: String, source: String, target: String) -> bool:
	# Windows only permits symbolic links with developer mode or elevation, so a
	# fixture that cannot create one prints SKIP instead of failing the rule.
	var access := DirAccess.open(parent)
	return access != null and access.create_link(source, target) == OK


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null)
	file.store_string(text)
	file.close()


func _id(index: int) -> String:
	return "msg_%032x" % index


func _gid(index: int) -> String:
	return "grant_%032x" % index


func _has_message(rows: Array, id: String) -> bool:
	for row: Dictionary in rows:
		if row.id == id:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("SOCIAL_STATE_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
