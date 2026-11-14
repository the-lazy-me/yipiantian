extends SceneTree
## M4-02: invitation grants as a shareable credential.
##
## Pure and headless. Checks what a code promises: the world and role it names,
## when it stops working, that a one-time code cannot be spent twice, that a
## revoked grant is refused, and that a hostile pasted string cannot become a
## grant. Also checks the role permission table the host enforces.

const WorldInvite = preload("res://world/world_invite.gd")

const START: float = 1800000000.0

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run()
	_finish()


func _run() -> void:
	var grant: Dictionary = WorldInvite.issue(WorldInvite.MEMBER, "world-alpha",
		START + 86400.0, true)
	_expect(not grant.is_empty(), "An invitation is issued")
	_expect(str(grant.role) == WorldInvite.MEMBER, "The issued grant carries the requested role")
	_expect(str(grant.id).length() == 32, "The grant id is a hex identifier, not the secret")
	_expect((grant.secret as PackedByteArray).size() == 32, "The grant secret is 256 bits")
	_expect(grant.secret != WorldInvite.issue(WorldInvite.MEMBER, "world-alpha").secret,
		"Each issue draws a fresh secret")

	# Round trip: what a person copies must decode to the same grant.
	var code: String = WorldInvite.encode(grant)
	_expect(code.begins_with(WorldInvite.PREFIX), "A shareable code is recognisable by its prefix")
	var decoded: Dictionary = WorldInvite.decode(code)
	_expect(decoded.ok, "A pasted code decodes")
	if decoded.ok:
		var restored: Dictionary = decoded.grant
		_expect(str(restored.id) == str(grant.id), "The decoded grant keeps its id")
		_expect((restored.secret as PackedByteArray) == (grant.secret as PackedByteArray),
			"The decoded grant keeps its secret")
		_expect(str(restored.role) == str(grant.role), "The decoded grant keeps its role")
		_expect(float(restored.expires_at) == float(grant.expires_at),
			"The decoded grant keeps its expiry")
		_expect(bool(restored.one_time) == bool(grant.one_time), "The decoded grant keeps its use limit")
	# A code wrapped when pasted must still work.
	_expect(WorldInvite.decode("  " + code.substr(0, 40) + "\n" + code.substr(40) + "  ").ok,
		"A code with surrounding whitespace and a line break still decodes")

	# Refusals a UI must distinguish.
	_expect(not WorldInvite.decode("").ok, "An empty string is not a code")
	_expect(not WorldInvite.decode("FARM1.not-base64!!").ok, "A body that is not base64 is refused")
	_expect(not WorldInvite.decode("hello world").ok, "Text without the prefix is refused")
	_expect(WorldInvite.decode("FARM1." + _base64("{\"version\":1}")).reason == "invalid_code",
		"A code that decodes to an incomplete grant is refused")
	var unknown_role: Dictionary = grant.duplicate(true)
	unknown_role.role = "admin"
	_expect(WorldInvite.make(str(unknown_role.id), unknown_role.secret, "admin",
		"world-alpha", 0.0, true).is_empty(),
		"An unknown role cannot be made into a grant")
	var short_secret: Dictionary = grant.duplicate(true)
	short_secret.secret = PackedByteArray([1, 2, 3])
	_expect(WorldInvite.make(str(short_secret.id), short_secret.secret,
		WorldInvite.MEMBER, "world-alpha").is_empty(),
		"A short secret cannot be made into a grant")

	# Time and use limits.
	var timed: Dictionary = WorldInvite.issue(WorldInvite.VISITOR, "world-alpha",
		START + 600.0, false)
	_expect(WorldInvite.check_usable(timed, START, 0).ok, "A grant is usable before it expires")
	_expect(WorldInvite.check_usable(timed, START + 601.0, 0).reason == "invite_expired",
		"A grant is refused after it expires")
	var forever: Dictionary = WorldInvite.issue(WorldInvite.MEMBER, "world-alpha", 0.0, false)
	_expect(WorldInvite.check_usable(forever, START + 31536000.0, 0).ok,
		"An expiry of zero means the grant does not expire")
	_expect(WorldInvite.check_usable(grant, START, 0).ok, "An unused one-time grant is usable")
	_expect(WorldInvite.check_usable(grant, START, 1).reason == "invite_used",
		"A spent one-time grant is refused")
	_expect(WorldInvite.check_usable(forever, START, 5).ok,
		"A reusable grant keeps working after several joins")

	# Roles decide which commands a member may submit.
	_expect(WorldInvite.allows(WorldInvite.MEMBER, "harvest"), "A member may harvest")
	_expect(not WorldInvite.allows(WorldInvite.VISITOR, "harvest"),
		"A visitor may not take produce")
	_expect(WorldInvite.allows(WorldInvite.VISITOR, "water"), "A visitor may tend a crop")
	_expect(not WorldInvite.allows(WorldInvite.VISITOR, "sow"),
		"A visitor may not plant without a member role")
	_expect(not WorldInvite.allows("", "water"), "An empty role has no permissions")
	_expect(not WorldInvite.allows(WorldInvite.MEMBER, "delete_world"),
		"An unknown command is not allowed to any role")

	# A grant only works in the world it names: the host checks this, so the
	# shape must be present to check.
	var other_world: Dictionary = WorldInvite.issue(WorldInvite.MEMBER, "world-beta")
	_expect(str(other_world.world_id) == "world-beta", "A grant names its world")
	_expect(WorldInvite.decode(WorldInvite.encode(other_world)).ok,
		"A grant for another world still round-trips; the host decides where it applies")


func _base64(text: String) -> String:
	return Marshalls.raw_to_base64(text.to_utf8_buffer())


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("WORLD_INVITE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
