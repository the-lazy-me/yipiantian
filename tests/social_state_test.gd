extends SceneTree
## Pure social rules and their storage boundary: contacts, invitations, blocks,
## private/public messages, visits. No transport is involved, so every rule can
## be exercised directly and the persisted document is checked for the same
## things a network caller could try to sneak in.

const SocialState = preload("res://social/social_state.gd")
const SocialStore = preload("res://social/social_store.gd")

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
