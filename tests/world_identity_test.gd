extends SceneTree
## M4-04: world identity continuity across a server move.
##
## Pure, headless and fast: builds a descriptor with the world key, verifies it
## as a client would, and checks every refusal path (stale generation, gap,
## wrong world, bad signature, expired, malformed). Also checks the digest does
## not depend on key order and does not include addresses.

const Identity = preload("res://world/world_identity.gd")
const Farm = preload("res://farm/farm_state.gd")

const START: float = 1800000000.0

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run()


func _run() -> void:
	var crypto := Crypto.new()
	var key: CryptoKey = crypto.generate_rsa(2048)
	var stranger: CryptoKey = crypto.generate_rsa(2048)
	_expect(key != null and stranger != null, "Two RSA keys generate")
	var snapshot: Dictionary = Farm.new(START).snapshot()
	var issued: float = START
	var expires: float = START + 86400.0

	var descriptor: Dictionary = Identity.sign(
		"world-alpha", 2, 1, 1, snapshot, ["wss://192.168.1.9:7000"], issued, expires, key)
	_expect(not descriptor.is_empty(), "A migration descriptor is signed")

	var verified: Dictionary = Identity.verify(descriptor, key, "world-alpha", 1, START + 60)
	_expect(verified.ok, "A client that trusted the world key accepts the move")
	_expect(int(verified.run_generation) == 2, "The accepted generation is the new one")
	_expect(int(verified.sequence) == 1, "The accepted descriptor carries the continuation sequence")
	_expect((verified.endpoints as Array).has("wss://192.168.1.9:7000"),
		"The accepted descriptor names the new endpoint")

	# The signature covers the address: an attacker cannot redirect the client.
	var redirected: Dictionary = descriptor.duplicate(true)
	redirected.endpoints = ["wss://evil.example:7000"]
	_expect(Identity.verify(redirected, key, "world-alpha", 1, START + 60).reason == "bad_signature",
		"Changing the endpoint invalidates the signature")

	# A descriptor signed by anyone else must not be accepted.
	var forged: Dictionary = Identity.sign(
		"world-alpha", 2, 1, 1, snapshot, ["wss://evil.example:7000"], issued, expires, stranger)
	_expect(Identity.verify(forged, key, "world-alpha", 1, START + 60).reason == "bad_signature",
		"A descriptor signed by another key is refused")

	# State continuity: a different snapshot breaks the digest commitment.
	var other: Dictionary = Farm.new(START).snapshot()
	other.inventory.greens = 99
	var tampered: Dictionary = descriptor.duplicate(true)
	tampered.content_digest = Identity.content_digest("world-alpha", 2, 1, other)
	_expect(Identity.verify(tampered, key, "world-alpha", 1, START + 60).reason == "bad_signature",
		"Committing to different state invalidates the signature")

	# Replay and ordering.
	_expect(Identity.verify(descriptor, key, "world-alpha", 2, START + 60).reason == "stale_generation",
		"A descriptor at or below the accepted generation is refused")
	_expect(Identity.verify(descriptor, key, "world-other", 1, START + 60).reason == "world_mismatch",
		"A descriptor for another world is refused")
	var forward: Dictionary = Identity.sign(
		"world-alpha", 5, 4, 1, snapshot, ["wss://h:1"], issued, expires, key)
	_expect(Identity.verify(forward, key, "world-alpha", 1, START + 60).reason == "generation_gap",
		"A generation that skips over the accepted one is refused")

	# Time bounds.
	_expect(Identity.verify(descriptor, key, "world-alpha", 1, expires + 3600.0).reason == "expired",
		"An expired descriptor is refused")
	_expect(Identity.verify(descriptor, key, "world-alpha", 1, issued - 3600.0).reason == "not_yet_valid",
		"A descriptor from the future is refused")

	# Malformed input.
	_expect(Identity.parse("").reason == "invalid_descriptor", "Empty text is not a descriptor")
	_expect(Identity.parse("[]").reason == "invalid_descriptor", "A JSON array is not a descriptor")
	_expect(Identity.parse("{bad").reason == "invalid_descriptor", "Broken JSON is rejected")
	var short: Dictionary = descriptor.duplicate(true)
	short.erase("expires_at")
	_expect(Identity.verify(short, key, "world-alpha", 1, START + 60).reason == "invalid_descriptor",
		"A descriptor missing a field is refused")
	var extra: Dictionary = descriptor.duplicate(true)
	extra.note = "x"
	_expect(Identity.verify(extra, key, "world-alpha", 1, START + 60).reason == "invalid_descriptor",
		"An unexpected extra field is refused")

	# Digest stability.
	_expect(Identity.content_digest("world-alpha", 2, 1, snapshot)
		== Identity.content_digest("world-alpha", 2, 1, snapshot),
		"The content digest is stable for the same input")
	# Canonical JSON sorts keys, so a differently built but equal snapshot keeps
	# the same digest; that is what lets two platforms agree on one world.
	var rebuilt = Farm.new()
	rebuilt.restore_snapshot(snapshot)
	_expect(Identity.content_digest("world-alpha", 2, 1, rebuilt.snapshot())
		== Identity.content_digest("world-alpha", 2, 1, snapshot),
		"A restored snapshot commits to the same digest")
	var moved: Dictionary = Identity.sign(
		"world-alpha", 2, 1, 1, snapshot, ["wss://elsewhere:1"], issued, expires, key)
	_expect(str(moved.content_digest) == str(descriptor.content_digest),
		"Moving the same state to another address keeps the same content digest")

	# A generation bump must change the digest, or a stale state could reuse it.
	_expect(Identity.content_digest("world-alpha", 3, 1, snapshot)
		!= Identity.content_digest("world-alpha", 2, 1, snapshot),
		"A different generation commits to a different digest")
	_expect(Identity.content_digest("world-alpha", 2, 2, snapshot)
		!= Identity.content_digest("world-alpha", 2, 1, snapshot),
		"A different sequence commits to a different digest")

	_finish()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("WORLD_IDENTITY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
