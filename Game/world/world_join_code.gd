extends RefCounted
## Join codes: one pasteable string that carries everything a client needs to
## reach a world.
##
## An invitation grant proves membership but says nothing about where the server
## is or which certificate to trust. Handing someone a grant plus an address plus
## a certificate file is three steps that each can go wrong, and a self-signed
## LAN server cannot be reached at all without pinning its certificate. A join
## code binds those three together: the endpoint, the pinned certificate and the
## grant travel as one value, so a holder cannot be redirected to another server
## without the code itself changing.
##
## The code is a credential (it contains the invitation secret). It is not
## encrypted and must not be published; the host prints it once when the invite
## is created.

const WorldInvite = preload("res://world/world_invite.gd")

const VERSION: int = 1
const PREFIX: String = "FARMJ1."
## A grant code is ~300 bytes and a 2048-bit certificate ~1.7 KB of PEM, so a
## whole code stays well under this even after base64 wrapping.
const MAX_CODE_BYTES: int = 16384
const MAX_URL_LENGTH: int = 256
const MAX_CERTIFICATE_BYTES: int = 8192
const MAX_SERVER_NAME_LENGTH: int = 255
const KEYS: Array[String] = [
	"version", "url", "server_name", "certificate", "grant",
]


## Builds the shareable code. Returns "" when any part would not be usable, so a
## caller never hands out a code that only fails on the friend's machine.
static func encode(grant: Dictionary, url: String, certificate_pem: String,
		server_name: String = "localhost") -> String:
	var grant_code: String = WorldInvite.encode(grant)
	if grant_code.is_empty():
		return ""
	var checked: Dictionary = _valid(url, server_name, certificate_pem)
	if not checked.ok:
		return ""
	var wire: Dictionary = {
		"version": VERSION, "url": url.strip_edges(), "server_name": server_name.strip_edges(),
		"certificate": certificate_pem, "grant": grant_code,
	}
	return PREFIX + Marshalls.raw_to_base64(
		JSON.stringify(wire, "", false, false).to_utf8_buffer())


## Parses a pasted code. Nothing here trusts the input: the size is bounded, the
## certificate must actually load, and the embedded grant goes through the same
## validation as a code typed on its own.
static func decode(code: String) -> Dictionary:
	var body: String = code.strip_edges()
	if body.is_empty() or body.length() > MAX_CODE_BYTES * 2:
		return _failure("invalid_code")
	if not body.begins_with(PREFIX):
		return _failure("invalid_code")
	# Tolerate a code that a chat window wrapped across lines.
	body = body.substr(PREFIX.length()).replace("\n", "").replace("\r", "").replace(" ", "")
	# Reject non-base64 before decoding: the engine decoder logs an error for
	# malformed input, and a pasted-code typo is a normal event, not a fault.
	if not _is_base64(body):
		return _failure("invalid_code")
	var raw: PackedByteArray = Marshalls.base64_to_raw(body)
	if raw.is_empty() or raw.size() > MAX_CODE_BYTES:
		return _failure("invalid_code")
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if not parsed is Dictionary:
		return _failure("invalid_code")
	var wire: Dictionary = parsed
	if wire.size() != KEYS.size():
		return _failure("invalid_code")
	for key: String in KEYS:
		if not wire.has(key):
			return _failure("invalid_code")
	if not (wire.version is int or wire.version is float) or int(wire.version) != VERSION:
		return _failure("protocol_version")
	if not wire.url is String or not wire.server_name is String or not wire.grant is String \
			or not wire.certificate is String:
		return _failure("invalid_code")
	var checked: Dictionary = _valid(str(wire.url), str(wire.server_name), str(wire.certificate))
	if not checked.ok:
		return checked
	var grant: Dictionary = WorldInvite.decode(str(wire.grant))
	if not grant.ok:
		return grant
	return {
		"ok": true, "reason": "", "url": str(wire.url).strip_edges(),
		"server_name": str(wire.server_name).strip_edges(),
		"certificate": str(wire.certificate), "grant": grant.grant,
	}


## The TLS options a client needs for this code. Kept next to the parser so the
## certificate that was validated is the one the connection trusts.
static func tls_options(certificate_pem: String, server_name: String) -> TLSOptions:
	var certificate := X509Certificate.new()
	if certificate.load_from_string(certificate_pem) != OK:
		return null
	return TLSOptions.client(certificate, server_name)


static func _valid(url: String, server_name: String, certificate_pem: String) -> Dictionary:
	if not _valid_url(url):
		return _failure("invalid_url")
	var name: String = server_name.strip_edges()
	if name.is_empty() or name.length() > MAX_SERVER_NAME_LENGTH:
		return _failure("invalid_server_name")
	for forbidden: String in ["/", ":", " ", "\t", "\n"]:
		if name.contains(forbidden):
			return _failure("invalid_server_name")
	if certificate_pem.is_empty() or certificate_pem.length() > MAX_CERTIFICATE_BYTES:
		return _failure("invalid_certificate")
	if not certificate_pem.contains("-----BEGIN CERTIFICATE-----") \
			or not certificate_pem.contains("-----END CERTIFICATE-----"):
		return _failure("invalid_certificate")
	# A string that merely looks like PEM still has to parse, or the client would
	# carry a code it cannot connect with.
	var certificate := X509Certificate.new()
	if certificate.load_from_string(certificate_pem) != OK:
		return _failure("invalid_certificate")
	return {"ok": true, "reason": ""}


static func _valid_url(url: String) -> bool:
	var text: String = url.strip_edges()
	if text.is_empty() or text.length() > MAX_URL_LENGTH or text != url:
		return false
	if not text.begins_with("wss://"):
		return false
	var rest: String = text.trim_prefix("wss://")
	if rest.is_empty():
		return false
	for forbidden: String in [" ", "\t", "\n", "\r"]:
		if rest.contains(forbidden):
			return false
	var authority: String = rest
	var slash: int = authority.find("/")
	if slash >= 0:
		authority = authority.substr(0, slash)
	if authority.is_empty():
		return false
	var colon: int = authority.rfind(":")
	if colon >= 0:
		var port_text: String = authority.substr(colon + 1)
		if port_text.is_empty() or not port_text.is_valid_int():
			return false
		var port: int = int(port_text)
		if port <= 0 or port > 65535:
			return false
		authority = authority.substr(0, colon)
	if authority.is_empty():
		return false
	# A bare "[::1]:7777" form is accepted by the engine; anything else with
	# brackets left over is malformed rather than a host.
	if authority.contains("[") != authority.contains("]"):
		return false
	return true


static func _is_base64(text: String) -> bool:
	if text.is_empty() or text.length() % 4 != 0:
		return false
	var padding: int = 0
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		var alphabet: bool = (code >= 65 and code <= 90) or (code >= 97 and code <= 122) \
			or (code >= 48 and code <= 57) or code == 43 or code == 47
		if code == 61:
			padding += 1
			if padding > 2:
				return false
			continue
		# Padding is only valid at the end of the value.
		if padding > 0 or not alphabet:
			return false
	return true


static func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
