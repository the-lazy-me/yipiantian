extends SceneTree
## Join codes: one credential that carries endpoint, pinned certificate and grant.
## Everything except the actual connection is pure, so the parser's rejections can
## be exercised directly; the TLS options it produces are checked by the client
## scene test that connects for real.

const WorldInvite = preload("res://world/world_invite.gd")
const JoinCode = preload("res://world/world_join_code.gd")

const URL: String = "wss://192.168.1.20:7777"
const SERVER_NAME: String = "localhost"
const WORLD: String = "world-join"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var crypto := Crypto.new()
	var key: CryptoKey = crypto.generate_rsa(2048)
	var certificate: X509Certificate = crypto.generate_self_signed_certificate(
		key, "CN=%s,O=farm,C=CN" % SERVER_NAME)
	_expect(key != null and certificate != null, "A test key and certificate are generated")
	if key == null or certificate == null:
		_finish()
		return
	var pem: String = certificate.save_to_string()
	_expect(pem.contains("-----BEGIN CERTIFICATE-----"), "The certificate serializes to PEM")
	var grant: Dictionary = WorldInvite.issue(WorldInvite.MEMBER, WORLD)
	_expect(not grant.is_empty(), "An invitation grant is issued")

	var code: String = JoinCode.encode(grant, URL, pem, SERVER_NAME)
	_expect(code.begins_with(JoinCode.PREFIX), "The join code carries a recognisable prefix")
	var decoded: Dictionary = JoinCode.decode(code)
	_expect(decoded.ok, "A well-formed join code decodes")
	_expect(decoded.get("url", "") == URL, "The endpoint survives the round trip")
	_expect(decoded.get("server_name", "") == SERVER_NAME, "The certificate name survives the round trip")
	_expect(decoded.get("certificate", "") == pem, "The pinned certificate survives byte for byte")
	var carried: Dictionary = decoded.get("grant", {})
	_expect(carried.get("id", "") == grant.id and carried.get("role", "") == grant.role
		and carried.get("secret", PackedByteArray()) == grant.secret,
		"The embedded grant is identical to the issued one")
	_expect(JoinCode.tls_options(str(decoded.certificate), str(decoded.server_name)) != null,
		"The code yields usable TLS options")

	# Codes are pasted through chat windows; wrapping must not break them.
	var wrapped: String = code.substr(0, 40) + "\n" + code.substr(40, 40) + "\r\n" + code.substr(80)
	_expect(JoinCode.decode(wrapped).ok, "A code wrapped across lines still decodes")
	_expect(JoinCode.decode("  " + code + "  ").ok, "Surrounding whitespace is ignored")

	# Rejections: each names what is wrong instead of failing later at connect.
	_expect(JoinCode.decode("").reason == "invalid_code", "An empty code is refused")
	_expect(JoinCode.decode("FARM1." + code.substr(JoinCode.PREFIX.length())).reason == "invalid_code",
		"A code with the wrong prefix is refused")
	_expect(JoinCode.decode(code.substr(0, code.length() / 2)).reason == "invalid_code",
		"A truncated code is refused")
	_expect(JoinCode.decode(code + "AAAA").reason in ["invalid_code", "protocol_version"],
		"Trailing bytes do not decode into a usable code")

	var wire := func(url: String, name: String, cert: String, grant_code: String) -> String:
		return JoinCode.PREFIX + Marshalls.raw_to_base64(JSON.stringify({
			"version": JoinCode.VERSION, "url": url, "server_name": name,
			"certificate": cert, "grant": grant_code,
		}, "", false, false).to_utf8_buffer())
	_expect(JoinCode.decode(wire.call("ws://192.168.1.20:7777", SERVER_NAME, pem,
		WorldInvite.encode(grant))).reason == "invalid_url", "An unencrypted endpoint is refused")
	_expect(JoinCode.decode(wire.call("wss://host with space:7777", SERVER_NAME, pem,
		WorldInvite.encode(grant))).reason == "invalid_url", "An endpoint with whitespace is refused")
	_expect(JoinCode.decode(wire.call("wss://:7777", SERVER_NAME, pem,
		WorldInvite.encode(grant))).reason == "invalid_url", "An endpoint without a host is refused")
	_expect(JoinCode.decode(wire.call("wss://host:0", SERVER_NAME, pem,
		WorldInvite.encode(grant))).reason == "invalid_url", "Port zero is refused")
	_expect(JoinCode.decode(wire.call("wss://host:99999", SERVER_NAME, pem,
		WorldInvite.encode(grant))).reason == "invalid_url", "An out-of-range port is refused")
	_expect(JoinCode.decode(wire.call("wss://host:abc", SERVER_NAME, pem,
		WorldInvite.encode(grant))).reason == "invalid_url", "A non-numeric port is refused")
	_expect(JoinCode.decode(wire.call(URL, "", pem, WorldInvite.encode(grant))).reason == "invalid_server_name",
		"A missing certificate name is refused")
	_expect(JoinCode.decode(wire.call(URL, "has space", pem, WorldInvite.encode(grant))).reason == "invalid_server_name",
		"A certificate name with whitespace is refused")
	_expect(JoinCode.decode(wire.call(URL, SERVER_NAME, "not a certificate",
		WorldInvite.encode(grant))).reason == "invalid_certificate", "A non-PEM certificate is refused")
	_expect(JoinCode.decode(wire.call(URL, SERVER_NAME, "x".repeat(JoinCode.MAX_CERTIFICATE_BYTES + 1),
		WorldInvite.encode(grant))).reason == "invalid_certificate", "An oversized certificate is refused")
	_expect(JoinCode.decode(wire.call(URL, SERVER_NAME, pem, "FARM1.notbase64"))
		.reason == "invalid_code", "A malformed embedded grant is refused")
	var bad_grant: Dictionary = grant.duplicate(true)
	bad_grant.role = "owner"
	var bad_code: String = WorldInvite.encode(bad_grant)
	_expect(bad_code.is_empty(), "An unknown role cannot be encoded as a grant")
	_expect(JoinCode.encode({}, URL, pem, SERVER_NAME).is_empty(),
		"Encoding refuses a code with no usable grant")
	_expect(JoinCode.encode(grant, "http://host", pem, SERVER_NAME).is_empty(),
		"Encoding refuses an unencrypted endpoint")
	_expect(JoinCode.encode(grant, URL, "not a certificate", SERVER_NAME).is_empty(),
		"Encoding refuses a certificate that cannot load")
	_finish()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("WORLD_JOIN_CODE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
