extends RefCounted
## Shared owner identifier format for farm bags, theft records, buildings and
## economy accounts. One authority keeps a snapshot's keys and the ids sent over
## the wire from drifting apart.

const MAX_LENGTH: int = 64


static func valid(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > MAX_LENGTH:
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		var letter: bool = (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		var digit: bool = code >= 48 and code <= 57
		if not letter and not digit and code != 95 and code != 45 and code != 46 and code != 58:
			return false
	return true
