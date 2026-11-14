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

	# Validation rejects what the rules would never write.
	_expect(not SocialState.valid({}), "An empty dictionary is refused")
	var bad: Dictionary = state.duplicate(true)
	bad.version = 2
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
	_finish()


func _id(index: int) -> String:
	return "msg_%032x" % index


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
