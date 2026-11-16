extends RefCounted
## M12-02 conflict participation rules. Pure rules: no RNG, no system clock, no
## disk, no scene, no network and no `FarmState` access. Every command receives
## an explicit UTC time and the same input yields the same output.
##
## The document models one room/world conflict declaration:
##
##   {
##     "world_id": "world-...",
##     "host": "player id",
##     "sequence": 0,
##     "regime": {
##       "tier": "peace" | "limited",
##       "revision": 0,
##       "declaration_id": "",
##       "declared_by": "",
##       "declared_utc": 0.0,
##       "effective_utc": 0.0,
##       "higher_risk": false,
##       "area_ids": [],
##       "window_ids": [],
##       "loss_cap": 0,
##       "offline_loss_cap": 0,
##       "command_id": "",
##     },
##     "areas":    { "area_id": {"id", "min_x", "min_z", "max_x", "max_z"} },
##     "windows":  { "window_id": {"id", "start_utc", "end_utc"} },
##     "caps":     { "revision": {"loss_cap", "offline_loss_cap"} },
##     "participants": { "player": participant },
##     "losses":   { "target|window_id": {"target", "window_id", "amount"} },
##     "engagements": { "command_id": engagement },
##     "command_results": { "command_id": {"payload", "result"} },
##   }
##
## Invariants this slice owns:
## - `peace` is the default and refuses every engagement.
## - `limited` never opens risk by itself: the host must publish an explicit,
##   durable higher-risk declaration with declarer, time, zones and windows.
##   A new declaration bumps the revision, so every participant must consent
##   again; the host cannot silently enlarge the risk for people who already
##   signed up. Consent and withdrawal are therefore tied to a revision.
## - Declared rectangles are inclusive integer grid cells and the live scope is
##   never self-overlapping, so one point maps to at most one declared area.
##   Rows kept only for audit stay in the registry but grant nothing.
## - Declared windows are half-open `[start_utc, end_utc)` and the live scope is
##   never self-overlapping, so one instant maps to at most one window and a
##   target cannot be raided twice "in the same window" by overlapping scopes.
## - Losses are cumulative per target and window. An offline defender uses the
##   smaller offline cap and can never be drained past it.
## - Withdrawal is delayed: it is declared at T and effective at
##   `T + WITHDRAWAL_DELAY_SECONDS`. Before that, new engagements still settle;
##   at or after it, new commands from or against the participant are refused.
##   Engagements already recorded are durable facts and are never rolled back.
## - Engagement settlement is idempotent by command id, even after the bounded
##   command-result window evicts the row: the engagement row itself is the
##   durable guard. The current consent / withdrawal / regime command id is
##   durable the same way. An id that was already superseded and then evicted
##   from the window is no longer recognised and runs as a new command.

const OwnerIds = preload("res://farm/owner_id.gd")

const TIER_PEACE: String = "peace"
const TIER_LIMITED: String = "limited"
const TIERS: Array[String] = [TIER_PEACE, TIER_LIMITED]

const ROLE_ATTACKER: String = "attacker"
const ROLE_DEFENDER: String = "defender"
const ROLES: Array[String] = [ROLE_ATTACKER, ROLE_DEFENDER]

## A withdrawal is a notice, not an instant exit. Both sides still see the
## consequences of engagements confirmed during this delay.
const WITHDRAWAL_DELAY_SECONDS: float = 3600.0

const MAX_SAFE_INTEGER: int = 9007199254740991
## Inclusive grid coordinate bound, matching the land cadastre semantics.
const MAX_COORD: int = 4096
const MAX_AREAS: int = 32
const MAX_WINDOWS: int = 32
const MAX_PARTICIPANTS: int = 64
const MAX_ENGAGEMENTS: int = 1024
## One cap row per revision that either is live or still owns a durable
## engagement. The engagement bound therefore bounds this map too.
const MAX_CAPS: int = MAX_ENGAGEMENTS + 1
const MAX_COMMAND_RESULTS: int = 64
const MAX_ENTRY_ID_LENGTH: int = 64
const MAX_COMMAND_ID_LENGTH: int = 128
const MAX_WORLD_ID_LENGTH: int = 128
const MAX_PAYLOAD_LENGTH: int = 8192

const STATE_KEYS: Array[String] = [
	"world_id", "host", "sequence", "regime", "areas", "windows", "caps",
	"participants", "losses", "engagements", "command_results",
]
const REGIME_KEYS: Array[String] = [
	"tier", "revision", "declaration_id", "declared_by", "declared_utc",
	"effective_utc", "higher_risk", "area_ids", "window_ids", "loss_cap",
	"offline_loss_cap", "command_id",
]
const DECLARATION_KEYS: Array[String] = [
	"tier", "declaration_id", "effective_utc", "higher_risk", "areas",
	"windows", "loss_cap", "offline_loss_cap",
]
const AREA_KEYS: Array[String] = ["id", "min_x", "min_z", "max_x", "max_z"]
const WINDOW_KEYS: Array[String] = ["id", "start_utc", "end_utc"]
const PARTICIPANT_KEYS: Array[String] = [
	"participant", "attacker", "defender", "consent_revision", "consent_utc",
	"consent_command_id", "withdraw_utc", "withdraw_effective_utc",
	"withdraw_command_id",
]
const LOSS_KEYS: Array[String] = ["target", "window_id", "amount"]
const CAP_KEYS: Array[String] = ["loss_cap", "offline_loss_cap"]
const ENGAGEMENT_KEYS: Array[String] = [
	"attacker", "target", "x", "z", "area_id", "window_id", "revision",
	"at_utc", "amount", "defender_online", "cap", "loss_total_after",
]
const RESULT_KEYS: Array[String] = [
	"ok", "reason", "duplicate", "subject", "window_id", "loss_total", "cap",
]

const KIND_REGIME: String = "conflict_regime"
const KIND_PARTICIPATE: String = "conflict_participate"
const KIND_WITHDRAW: String = "conflict_withdraw"
const KIND_ENGAGE: String = "conflict_engage"


static func initial_state(world_id: String, host: String) -> Dictionary:
	return {
		"world_id": world_id,
		"host": host,
		"sequence": 0,
		"regime": {
			"tier": TIER_PEACE,
			"revision": 0,
			"declaration_id": "",
			"declared_by": "",
			"declared_utc": 0.0,
			"effective_utc": 0.0,
			"higher_risk": false,
			"area_ids": [],
			"window_ids": [],
			"loss_cap": 0,
			"offline_loss_cap": 0,
			"command_id": "",
		},
		"areas": {},
		"windows": {},
		"caps": {},
		"participants": {},
		"losses": {},
		"engagements": {},
		"command_results": {},
	}


## Publishes a new room conflict regime. Only the document host may do it, and
## every change is a durable record carrying declarer, declaration time, scope
## and the originating command id. A new declaration increments the revision,
## which makes every earlier consent stale; participants must opt in again
## before the enlarged risk applies to them.
static func declare_regime(state: Dictionary, world_id: String, actor: Variant,
		declaration: Variant, command_id: String, declared_utc: float) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", "")
	if not _valid_command_id(command_id):
		return _error("invalid_command", "")
	if not _valid_time(declared_utc):
		return _error("invalid_time", "")
	if not _valid_world_id(world_id) or str(state.get("world_id", "")) != world_id:
		return _error("wrong_world", "")
	if not _valid_player(actor):
		return _error("invalid_player", "")
	if str(actor) != str(state.get("host", "")):
		return _error("not_host", "")
	var canonical: Variant = _canonical_declaration(declaration)
	if not canonical is Dictionary:
		return _error("invalid_declaration", "")
	var payload: String = JSON.stringify([
		KIND_REGIME, world_id, str(actor), float(declared_utc), canonical,
	])
	var replayed: Dictionary = _replay(state, command_id, payload)
	if not replayed.is_empty():
		return replayed
	var regime: Dictionary = state.regime
	# A retry of the declaration that already owns the regime replays without
	# re-adding zones or windows. This guard survives the command window.
	if str(regime.get("command_id", "")) == command_id and int(regime.get("revision", 0)) > 0:
		if _canonical_regime_declaration(state, regime) == canonical:
			return _ok_regime(str(canonical.get("declaration_id", "")), true)
		return _error("command_conflict", str(canonical.get("declaration_id", "")))
	var parsed: Dictionary = _parse_declaration(state, declaration, declared_utc)
	if not parsed.ok:
		return _error(str(parsed.reason), "")
	if str(canonical.get("declaration_id", "")) == str(regime.get("declaration_id", "")):
		return _error("declaration_conflict", str(canonical.get("declaration_id", "")))
	# A new declaration must be strictly later than the one it replaces. This
	# keeps the durable declaration timeline ordered and makes a stale retry
	# that survived the bounded command window fail instead of re-applying.
	if int(regime.get("revision", 0)) > 0 \
			and declared_utc <= float(regime.get("declared_utc", 0.0)):
		return _error("time_regression", str(canonical.get("declaration_id", "")))
	# A declaration id may not collide with a durable consent, withdrawal or
	# engagement id, or the resulting document would fail its own validation.
	if _command_id_taken(state, command_id, str(state.host), "regime"):
		return _error("command_conflict", str(canonical.get("declaration_id", "")))
	for area: Dictionary in parsed.areas:
		state.areas[str(area.id)] = area
	for window: Dictionary in parsed.windows:
		state.windows[str(window.id)] = window
	var next: Dictionary = parsed.regime
	next.revision = int(regime.get("revision", 0)) + 1
	next.command_id = command_id
	# Caps are recorded per revision, so an old engagement's cap can still be
	# verified after a later declaration changed the budget.
	state.regime = next
	# Only a higher-risk revision has a budget to remember. A peace revision
	# stores no cap row, so de-escalation cannot leave a zero-cap row behind.
	if bool(next.higher_risk):
		state.caps[str(next.revision)] = {
			"loss_cap": int(next.loss_cap),
			"offline_loss_cap": int(next.offline_loss_cap),
		}
	_prune_history(state)
	var result: Dictionary = _ok_regime(str(next.declaration_id), false)
	_record_command(state, command_id, payload, result)
	return result


## Declares participation in the currently declared risk scope. Attackers must
## do it before any engagement; defenders use it to accept being a legal target
## (people who never opt in keep their peace standing). Consent is tied to the
## current regime revision, so a new host declaration requires a fresh opt-in.
static func declare_participation(state: Dictionary, world_id: String, actor: Variant,
		role: String, command_id: String, at_utc: float) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", str(actor))
	if not _valid_command_id(command_id):
		return _error("invalid_command", str(actor))
	if not _valid_time(at_utc):
		return _error("invalid_time", str(actor))
	if not _valid_world_id(world_id) or str(state.get("world_id", "")) != world_id:
		return _error("wrong_world", str(actor))
	if not _valid_player(actor):
		return _error("invalid_player", "")
	if not ROLES.has(role):
		return _error("invalid_role", str(actor))
	var payload: String = JSON.stringify([
		KIND_PARTICIPATE, world_id, str(actor), role, float(at_utc),
	])
	var replayed: Dictionary = _replay(state, command_id, payload)
	if not replayed.is_empty():
		return replayed
	var regime: Dictionary = state.regime
	var tier: String = str(regime.get("tier", ""))
	if tier == TIER_PEACE:
		return _error("peace", str(actor))
	if tier != TIER_LIMITED:
		return _error("invalid_state", str(actor))
	if not bool(regime.get("higher_risk", false)) \
			or str(regime.get("declaration_id", "")).is_empty():
		return _error("risk_not_declared", str(actor))
	var participants: Dictionary = state.participants
	var existing: Variant = participants.get(str(actor))
	var participant: Dictionary = _new_participant(str(actor)) if not existing is Dictionary \
		else existing.duplicate(true)
	if not existing is Dictionary and participants.size() >= MAX_PARTICIPANTS:
		return _error("capacity", str(actor))
	var withdrawal_pending: bool = float(participant.get("withdraw_utc", 0.0)) > 0.0 \
		and at_utc < float(participant.get("withdraw_effective_utc", 0.0))
	# A withdrawal already in flight cannot be undone by re-joining; it must
	# finish its delay first. After it is effective, joining again is a new
	# consent and resets the old flags.
	if withdrawal_pending:
		return _error("withdrawal_pending", str(actor))
	var withdrawal_done: bool = float(participant.get("withdraw_utc", 0.0)) > 0.0
	# The latest accepted consent keeps its command id, so a retry still replays
	# after the bounded command-result window evicted the row. This is checked
	# before any state is written.
	if str(participant.get("consent_command_id", "")) == command_id:
		var same: bool = (role == ROLE_ATTACKER and bool(participant.get("attacker", false))) \
			or (role == ROLE_DEFENDER and bool(participant.get("defender", false)))
		if same and float(participant.get("consent_utc", 0.0)) == at_utc \
				and int(participant.get("consent_revision", 0)) == int(regime.get("revision", 0)):
			return _ok_subject(str(actor), true)
		return _error("command_conflict", str(actor))
	if at_utc < float(participant.get("consent_utc", 0.0)):
		return _error("time_regression", str(actor))
	if at_utc < float(regime.get("declared_utc", 0.0)):
		return _error("regime_not_effective", str(actor))
	if _command_id_taken(state, command_id, str(actor), "consent"):
		return _error("command_conflict", str(actor))	# A consent only covers the roles declared at the revision it names. When the
	# revision changes, any earlier role flag is stale and must not silently
	# revive: the participant declares each role again explicitly.
	if int(participant.get("consent_revision", 0)) != int(regime.get("revision", 0)):
		participant.attacker = false
		participant.defender = false
	if withdrawal_done:
		participant.attacker = false
		participant.defender = false
		participant.withdraw_utc = 0.0
		participant.withdraw_effective_utc = 0.0
		participant.withdraw_command_id = ""
	participant.consent_revision = int(regime.get("revision", 0))
	participant.consent_utc = float(at_utc)
	participant.consent_command_id = command_id
	if role == ROLE_ATTACKER:
		participant.attacker = true
	else:
		participant.defender = true
	participants[str(actor)] = participant
	var result: Dictionary = _ok_subject(str(actor), false)
	_record_command(state, command_id, payload, result)
	return result


## Declares withdrawal. It becomes effective only after the fixed delay; the
## declaration is durable and is not cancelable while pending.
static func withdraw(state: Dictionary, world_id: String, actor: Variant,
		command_id: String, at_utc: float) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", str(actor))
	if not _valid_command_id(command_id):
		return _error("invalid_command", str(actor))
	if not _valid_time(at_utc):
		return _error("invalid_time", str(actor))
	if at_utc + WITHDRAWAL_DELAY_SECONDS > float(MAX_SAFE_INTEGER):
		return _error("invalid_time", str(actor))
	if not _valid_world_id(world_id) or str(state.get("world_id", "")) != world_id:
		return _error("wrong_world", str(actor))
	if not _valid_player(actor):
		return _error("invalid_player", "")
	var payload: String = JSON.stringify([KIND_WITHDRAW, world_id, str(actor), float(at_utc)])
	var replayed: Dictionary = _replay(state, command_id, payload)
	if not replayed.is_empty():
		return replayed
	var participant: Variant = state.participants.get(str(actor))
	if not participant is Dictionary \
			or (not bool(participant.get("attacker", false)) \
			and not bool(participant.get("defender", false))):
		return _error("not_participating", str(actor))
	# The withdrawal command id is durable, so a retry still replays after the
	# bounded command-result window evicted the row.
	if str(participant.get("withdraw_command_id", "")) == command_id:
		if float(participant.get("withdraw_utc", 0.0)) == at_utc:
			return _ok_subject(str(actor), true)
		return _error("command_conflict", str(actor))
	if at_utc < float(participant.get("consent_utc", 0.0)):
		return _error("time_regression", str(actor))
	if float(participant.get("withdraw_utc", 0.0)) > 0.0:
		if at_utc < float(participant.get("withdraw_effective_utc", 0.0)):
			return _error("withdrawal_pending", str(actor))
		return _error("already_withdrawn", str(actor))
	if _command_id_taken(state, command_id, str(actor), "withdraw"):
		return _error("command_conflict", str(actor))
	participant.withdraw_utc = float(at_utc)
	participant.withdraw_effective_utc = float(at_utc) + WITHDRAWAL_DELAY_SECONDS
	participant.withdraw_command_id = command_id
	var result: Dictionary = _ok_subject(str(actor), false)
	_record_command(state, command_id, payload, result)
	return result


## Settles one single engagement. The attacker and the target owner must both
## be consenting participants of the current regime revision; the point must be
## inside a declared area and the time inside a declared window; the amount must
## fit the remaining cumulative cap for that target and window. Offline targets
## use the smaller offline cap. Success records exactly one durable engagement
## and adds its amount to the target/window total.
static func engage(state: Dictionary, world_id: String, attacker: Variant, target: Variant,
		x: int, z: int, at_utc: float, amount: int, defender_online: bool,
		command_id: String) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", str(target))
	if not _valid_command_id(command_id):
		return _error("invalid_command", str(target))
	if not _valid_time(at_utc):
		return _error("invalid_time", str(target))
	if amount <= 0:
		return _error("invalid_amount", str(target))
	if not _valid_player(attacker) or not _valid_player(target):
		return _error("invalid_player", "")
	if str(attacker) == str(target):
		return _error("same_player", str(target))
	if not _valid_coord(x) or not _valid_coord(z):
		return _error("invalid_position", str(target))
	if not _valid_world_id(world_id) or str(state.get("world_id", "")) != world_id:
		return _error("wrong_world", str(target))
	var online: bool = bool(defender_online)
	var payload: String = JSON.stringify([
		KIND_ENGAGE, world_id, str(attacker), str(target), int(x), int(z),
		float(at_utc), int(amount), online,
	])
	var replayed: Dictionary = _replay(state, command_id, payload)
	if not replayed.is_empty():
		return replayed
	var durable: Dictionary = _replay_engagement(state, command_id, attacker, target,
		x, z, at_utc, amount, online)
	if not durable.is_empty():
		return durable
	if _command_id_taken(state, command_id, "", ""):
		return _error("command_conflict", str(target))
	var regime: Dictionary = state.regime
	var tier: String = str(regime.get("tier", ""))
	if tier == TIER_PEACE:
		return _error("peace", str(target))
	if tier != TIER_LIMITED:
		return _error("invalid_state", str(target))
	if not bool(regime.get("higher_risk", false)) \
			or str(regime.get("declaration_id", "")).is_empty():
		return _error("risk_not_declared", str(target))
	var declared_utc: float = float(regime.get("declared_utc", 0.0))
	var effective_utc: float = float(regime.get("effective_utc", 0.0))
	if at_utc < declared_utc or at_utc < effective_utc:
		return _error("regime_not_effective", str(target))
	var area_id: String = area_at(state, x, z)
	if area_id.is_empty():
		return _error("area_not_declared", str(target))
	var window_id: String = window_at(state, at_utc)
	if window_id.is_empty():
		return _error("outside_window", str(target))
	var attacker_reason: String = _inactive_reason(state, attacker, ROLE_ATTACKER, at_utc)
	if attacker_reason == "withdrawn":
		return _error("attacker_withdrawn", str(target))
	if not attacker_reason.is_empty():
		return _error("attacker_not_consented", str(target))
	var target_reason: String = _inactive_reason(state, target, ROLE_DEFENDER, at_utc)
	if target_reason == "withdrawn":
		return _error("target_withdrawn", str(target))
	if not target_reason.is_empty():
		return _error("target_not_participating", str(target))
	var cap: int = int(regime.get("loss_cap", 0)) if online \
		else int(regime.get("offline_loss_cap", 0))
	var total: int = loss_total(state, str(target), window_id)
	if total + int(amount) > cap:
		# The refusal still reports the stable window, saturated total and cap,
		# so a caller can show exactly where the budget stopped.
		return _result(false, "loss_cap_exceeded", false, str(target), window_id,
			total, cap)
	if state.engagements.size() >= MAX_ENGAGEMENTS:
		return _error("capacity", str(target))
	var after: int = total + int(amount)
	state.losses[str(target) + "|" + window_id] = {
		"target": str(target),
		"window_id": window_id,
		"amount": after,
	}
	state.engagements[command_id] = {
		"attacker": str(attacker),
		"target": str(target),
		"x": int(x),
		"z": int(z),
		"area_id": area_id,
		"window_id": window_id,
		"revision": int(regime.get("revision", 0)),
		"at_utc": float(at_utc),
		"amount": int(amount),
		"defender_online": online,
		"cap": cap,
		"loss_total_after": after,
	}
	var result: Dictionary = _ok_engage(str(target), window_id, after, cap, false)
	_record_command(state, command_id, payload, result)
	return result


## Cumulative settled losses for one target inside one declared window.
static func loss_total(state: Dictionary, target: String, window_id: String) -> int:
	var losses: Variant = state.get("losses")
	if not losses is Dictionary:
		return 0
	var row: Variant = losses.get(target + "|" + window_id)
	if not row is Dictionary:
		return 0
	return int(row.get("amount", 0))


## Returns the current declared area containing the inclusive grid cell, or "".
static func area_at(state: Dictionary, x: int, z: int) -> String:
	var regime: Variant = state.get("regime")
	var areas: Variant = state.get("areas")
	if not regime is Dictionary or not areas is Dictionary:
		return ""
	for area_id: Variant in regime.get("area_ids", []):
		var key: String = str(area_id)
		var area: Variant = areas.get(key)
		if not area is Dictionary:
			continue
		if x >= int(area.min_x) and x <= int(area.max_x) \
				and z >= int(area.min_z) and z <= int(area.max_z):
			return key
	return ""


## Returns the current declared half-open window containing `at_utc`, or "".
static func window_at(state: Dictionary, at_utc: float) -> String:
	var regime: Variant = state.get("regime")
	var windows: Variant = state.get("windows")
	if not regime is Dictionary or not windows is Dictionary:
		return ""
	for window_id: Variant in regime.get("window_ids", []):
		var key: String = str(window_id)
		var window: Variant = windows.get(key)
		if not window is Dictionary:
			continue
		if at_utc >= float(window.start_utc) and at_utc < float(window.end_utc):
			return key
	return ""


## True when `player` consented to `role` for the current regime revision and
## has no effective withdrawal at `at_utc`.
static func consent_active(state: Dictionary, player: Variant, role: String,
		at_utc: float) -> bool:
	return _inactive_reason(state, player, role, at_utc).is_empty()


## Strict document validator. Every durable row must agree with every other row:
## registries only hold well-formed non-overlapping zones/windows, regime ids
## resolve, participant revisions never exceed the regime revision, withdrawal
## delays are exactly the rule constant, engagement sums reproduce the loss
## rows, and stored command results match their payloads.
static func valid(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	if value.size() != STATE_KEYS.size():
		return false
	for key: String in STATE_KEYS:
		if not value.has(key):
			return false
	if not _valid_world_id(value.world_id):
		return false
	if not _valid_player(value.host):
		return false
	if not _is_count(value.sequence) or int(value.sequence) >= MAX_SAFE_INTEGER:
		return false
	if not value.regime is Dictionary:
		return false
	if not value.areas is Dictionary or value.areas.size() > MAX_AREAS:
		return false
	if not value.windows is Dictionary or value.windows.size() > MAX_WINDOWS:
		return false
	if not value.caps is Dictionary or value.caps.size() > MAX_CAPS:
		return false
	if not value.participants is Dictionary or value.participants.size() > MAX_PARTICIPANTS:
		return false
	if not value.losses is Dictionary:
		return false
	if not value.engagements is Dictionary or value.engagements.size() > MAX_ENGAGEMENTS:
		return false
	if not value.command_results is Dictionary \
			or value.command_results.size() > MAX_COMMAND_RESULTS:
		return false
	if not _valid_regime(value):
		return false
	if int(value.regime.revision) == 0:
		if not value.participants.is_empty() or not value.engagements.is_empty() \
				or not value.losses.is_empty() or not value.caps.is_empty():
			return false
	if not _valid_areas(value):
		return false
	if not _valid_windows(value):
		return false
	if not _valid_caps(value):
		return false
	if not _valid_participants(value):
		return false
	if not _valid_participant_replays(value):
		return false
	if not _valid_engagements(value):
		return false
	if not _valid_losses(value):
		return false
	if not _valid_command_results(value):
		return false
	# The regime's durable command id must name the declaration it currently
	# holds, so a forged document cannot claim a scope no host ever declared.
	var regime_command: String = str(value.regime.command_id)
	if not regime_command.is_empty() and value.command_results.has(regime_command):
		var entry: Variant = value.command_results[regime_command]
		var parts: Variant = _parse_payload(str(entry.get("payload", "")))
		if not parts is Array or parts.is_empty() or str(parts[0]) != KIND_REGIME:
			return false
		if parts.size() != 5 or not parts[4] is Dictionary:
			return false
		if _canonical_declaration(parts[4]) \
				!= _canonical_regime_declaration(value, value.regime):
			return false
	# At least every engagement incremented the sequence, even after the
	# bounded command-result window evicted older rows.
	if int(value.sequence) < value.engagements.size():
		return false
	return true


## Restores JSON numbers to the integer/float/bool types the rules use. Only
## called on a document that passed `valid()`.
static func normalize(state: Dictionary) -> void:
	state.world_id = str(state.get("world_id", ""))
	state.host = str(state.get("host", ""))
	state.sequence = int(state.get("sequence", 0))
	var regime: Variant = state.get("regime")
	if regime is Dictionary:
		regime.tier = str(regime.get("tier", ""))
		regime.revision = int(regime.get("revision", 0))
		regime.declaration_id = str(regime.get("declaration_id", ""))
		regime.declared_by = str(regime.get("declared_by", ""))
		regime.declared_utc = float(regime.get("declared_utc", 0.0))
		regime.effective_utc = float(regime.get("effective_utc", 0.0))
		regime.higher_risk = bool(regime.get("higher_risk", false))
		regime.area_ids = _string_array(regime.get("area_ids"))
		regime.window_ids = _string_array(regime.get("window_ids"))
		regime.loss_cap = int(regime.get("loss_cap", 0))
		regime.offline_loss_cap = int(regime.get("offline_loss_cap", 0))
		regime.command_id = str(regime.get("command_id", ""))
	var areas: Variant = state.get("areas")
	if areas is Dictionary:
		for area_id: Variant in areas:
			var area: Variant = areas[area_id]
			if not area is Dictionary:
				continue
			area.id = str(area.get("id", ""))
			area.min_x = int(area.get("min_x", 0))
			area.min_z = int(area.get("min_z", 0))
			area.max_x = int(area.get("max_x", 0))
			area.max_z = int(area.get("max_z", 0))
	var windows: Variant = state.get("windows")
	if windows is Dictionary:
		for window_id: Variant in windows:
			var window: Variant = windows[window_id]
			if not window is Dictionary:
				continue
			window.id = str(window.get("id", ""))
			window.start_utc = float(window.get("start_utc", 0.0))
			window.end_utc = float(window.get("end_utc", 0.0))
	var caps: Variant = state.get("caps")
	if caps is Dictionary:
		var normalized_caps: Dictionary = {}
		for revision_key: Variant in caps:
			var entry: Variant = caps[revision_key]
			if not entry is Dictionary:
				continue
			normalized_caps[str(int(revision_key))] = {
				"loss_cap": int(entry.get("loss_cap", 0)),
				"offline_loss_cap": int(entry.get("offline_loss_cap", 0)),
			}
		state.caps = normalized_caps
	var participants: Variant = state.get("participants")
	if participants is Dictionary:
		for player_id: Variant in participants:
			var participant: Variant = participants[player_id]
			if not participant is Dictionary:
				continue
			participant.participant = str(participant.get("participant", ""))
			participant.attacker = bool(participant.get("attacker", false))
			participant.defender = bool(participant.get("defender", false))
			participant.consent_revision = int(participant.get("consent_revision", 0))
			participant.consent_utc = float(participant.get("consent_utc", 0.0))
			participant.consent_command_id = str(participant.get("consent_command_id", ""))
			participant.withdraw_utc = float(participant.get("withdraw_utc", 0.0))
			participant.withdraw_effective_utc = float(
				participant.get("withdraw_effective_utc", 0.0))
			participant.withdraw_command_id = str(
				participant.get("withdraw_command_id", ""))
	var losses: Variant = state.get("losses")
	if losses is Dictionary:		for key: Variant in losses:
			var loss: Variant = losses[key]
			if not loss is Dictionary:
				continue
			loss.target = str(loss.get("target", ""))
			loss.window_id = str(loss.get("window_id", ""))
			loss.amount = int(loss.get("amount", 0))
	var engagements: Variant = state.get("engagements")
	if engagements is Dictionary:
		for command_id: Variant in engagements:
			var engagement: Variant = engagements[command_id]
			if not engagement is Dictionary:
				continue
			engagement.attacker = str(engagement.get("attacker", ""))
			engagement.target = str(engagement.get("target", ""))
			engagement.x = int(engagement.get("x", 0))
			engagement.z = int(engagement.get("z", 0))
			engagement.area_id = str(engagement.get("area_id", ""))
			engagement.window_id = str(engagement.get("window_id", ""))
			engagement.revision = int(engagement.get("revision", 0))
			engagement.at_utc = float(engagement.get("at_utc", 0.0))
			engagement.amount = int(engagement.get("amount", 0))
			engagement.defender_online = bool(engagement.get("defender_online", false))
			engagement.cap = int(engagement.get("cap", 0))
			engagement.loss_total_after = int(engagement.get("loss_total_after", 0))
	var results: Variant = state.get("command_results")
	if results is Dictionary:
		for command_id: Variant in results:
			var entry: Variant = results[command_id]
			if not entry is Dictionary or not entry.get("result") is Dictionary:
				continue
			entry.payload = str(entry.get("payload", ""))
			entry.result.ok = bool(entry.result.get("ok", false))
			entry.result.reason = str(entry.result.get("reason", ""))
			entry.result.duplicate = bool(entry.result.get("duplicate", false))
			entry.result.subject = str(entry.result.get("subject", ""))
			entry.result.window_id = str(entry.result.get("window_id", ""))
			entry.result.loss_total = int(entry.result.get("loss_total", 0))
			entry.result.cap = int(entry.result.get("cap", 0))


static func _valid_regime(state: Dictionary) -> bool:
	var regime: Dictionary = state.regime
	if regime.size() != REGIME_KEYS.size():
		return false
	for key: String in REGIME_KEYS:
		if not regime.has(key):
			return false
	if not regime.tier is String or not TIERS.has(str(regime.tier)):
		return false
	if not _is_count(regime.revision):
		return false
	if not regime.declaration_id is String or not regime.declared_by is String:
		return false
	if not _valid_time(regime.declared_utc) or not _valid_time(regime.effective_utc):
		return false
	if not regime.higher_risk is bool:
		return false
	if not regime.area_ids is Array or not regime.window_ids is Array:
		return false
	if not _is_count(regime.loss_cap) or not _is_count(regime.offline_loss_cap):
		return false
	if not regime.command_id is String:
		return false
	var revision: int = int(regime.revision)
	if revision == 0:
		if str(regime.tier) != TIER_PEACE:
			return false
		if not str(regime.declaration_id).is_empty() or not str(regime.declared_by).is_empty():
			return false
		if float(regime.declared_utc) != 0.0 or float(regime.effective_utc) != 0.0:
			return false
		if bool(regime.higher_risk):
			return false
		if not regime.area_ids.is_empty() or not regime.window_ids.is_empty():
			return false
		if int(regime.loss_cap) != 0 or int(regime.offline_loss_cap) != 0:
			return false
		if not str(regime.command_id).is_empty():
			return false
		return state.areas.is_empty() and state.windows.is_empty()
	if not _valid_entry_id(regime.declaration_id):
		return false
	if not _valid_player(regime.declared_by) or str(regime.declared_by) != str(state.host):
		return false
	if float(regime.effective_utc) < float(regime.declared_utc):
		return false
	if not _valid_command_id(regime.command_id):
		return false
	if not _valid_id_list(regime.area_ids, state.areas):
		return false
	if not _valid_id_list(regime.window_ids, state.windows):
		return false
	var tier: String = str(regime.tier)
	var higher: bool = bool(regime.higher_risk)
	var area_ids: Array = regime.area_ids
	var window_ids: Array = regime.window_ids
	var loss_cap: int = int(regime.loss_cap)
	var offline_cap: int = int(regime.offline_loss_cap)
	if higher:
		if tier != TIER_LIMITED:
			return false
		if area_ids.is_empty() or window_ids.is_empty():
			return false
		return loss_cap > 0 and offline_cap > 0 and offline_cap <= loss_cap
	if not area_ids.is_empty() or not window_ids.is_empty():
		return false
	return loss_cap == 0 and offline_cap == 0


## Every registered area must be well formed, and the currently live scope must
## be unambiguous: two live areas may not overlap, so one cell maps to at most
## one area. Earlier revisions' areas stay in the registry as durable history;
## they do not grant anything unless the current regime lists them.
static func _valid_areas(state: Dictionary) -> bool:
	var areas: Dictionary = state.areas
	for area_id: Variant in areas:
		var key: String = str(area_id)
		var area: Variant = areas[area_id]
		if not _valid_entry_id(key):
			return false
		if not area is Dictionary or area.size() != AREA_KEYS.size():
			return false
		for field: String in AREA_KEYS:
			if not area.has(field):
				return false
		if not area.id is String or str(area.id) != key:
			return false
		if not _valid_rect(area):
			return false
	var live: Array = state.regime.area_ids
	for left: int in range(live.size()):
		for right: int in range(left + 1, live.size()):
			if _rects_overlap(areas[live[left]], areas[live[right]]):
				return false
	return true


## Windows are half-open `[start_utc, end_utc)`; two live windows may not
## overlap, so one instant maps to at most one window.
static func _valid_windows(state: Dictionary) -> bool:
	var windows: Dictionary = state.windows
	for window_id: Variant in windows:
		var key: String = str(window_id)
		var window: Variant = windows[window_id]
		if not _valid_entry_id(key):
			return false
		if not window is Dictionary or window.size() != WINDOW_KEYS.size():
			return false
		for field: String in WINDOW_KEYS:
			if not window.has(field):
				return false
		if not window.id is String or str(window.id) != key:
			return false
		if not _valid_time(window.start_utc) or not _valid_time(window.end_utc):
			return false
		if float(window.end_utc) <= float(window.start_utc):
			return false
	var live: Array = state.regime.window_ids
	for left: int in range(live.size()):
		for right: int in range(left + 1, live.size()):
			if _windows_overlap(windows[live[left]], windows[live[right]]):
				return false
	return true


static func _valid_participants(state: Dictionary) -> bool:
	var participants: Dictionary = state.participants
	var revision: int = int(state.regime.revision)
	for player_id: Variant in participants:
		if not _valid_player(player_id):
			return false
		var participant: Variant = participants[player_id]
		if not participant is Dictionary or participant.size() != PARTICIPANT_KEYS.size():
			return false
		for field: String in PARTICIPANT_KEYS:
			if not participant.has(field):
				return false
		if not participant.participant is String \
				or str(participant.participant) != str(player_id):
			return false
		if not participant.attacker is bool or not participant.defender is bool:
			return false
		if not bool(participant.attacker) and not bool(participant.defender):
			return false
		if not _is_count(participant.consent_revision):
			return false
		var consent_revision: int = int(participant.consent_revision)
		if consent_revision < 1 or consent_revision > revision:
			return false
		if not _valid_time(participant.consent_utc):
			return false
		if not _valid_command_id(participant.consent_command_id):
			return false
		if not _valid_time(participant.withdraw_utc) \
				or not _valid_time(participant.withdraw_effective_utc):
			return false
		if not participant.withdraw_command_id is String:
			return false
		var withdraw_utc: float = float(participant.withdraw_utc)
		var effective_utc: float = float(participant.withdraw_effective_utc)
		if withdraw_utc == 0.0:
			if effective_utc != 0.0 or not str(participant.withdraw_command_id).is_empty():
				return false
			continue
		if not _valid_command_id(participant.withdraw_command_id):
			return false
		if withdraw_utc < float(participant.consent_utc):
			return false
		if effective_utc != withdraw_utc + WITHDRAWAL_DELAY_SECONDS:
			return false
	return true


static func _valid_participant_replays(state: Dictionary) -> bool:
	var participants: Dictionary = state.participants
	var seen: Dictionary = {}
	for player_id: Variant in participants:
		var participant: Dictionary = participants[player_id]
		var consent_id: String = str(participant.consent_command_id)
		if state.engagements.has(consent_id) or seen.has(consent_id) \
				or consent_id == str(state.regime.command_id):
			return false
		seen[consent_id] = true
		var results: Dictionary = state.command_results
		if results.has(consent_id):
			var entry: Variant = results[consent_id]
			if not entry is Dictionary or not entry.get("result") is Dictionary:
				return false
			if str(entry.result.get("subject", "")) != str(player_id):
				return false
			var parts: Variant = _parse_payload(str(entry.get("payload", "")))
			if not parts is Array or parts.size() != 5 or str(parts[0]) != KIND_PARTICIPATE:
				return false
			if float(parts[4]) != float(participant.consent_utc):
				return false
		var withdraw_id: String = str(participant.withdraw_command_id)
		if withdraw_id.is_empty():
			continue
		if state.engagements.has(withdraw_id) \
				or withdraw_id == consent_id \
				or withdraw_id == str(state.regime.command_id) \
				or seen.has(withdraw_id):
			return false
		seen[withdraw_id] = true
		if results.has(withdraw_id):
			var entry: Variant = results[withdraw_id]
			if not entry is Dictionary or not entry.get("result") is Dictionary:
				return false
			if str(entry.result.get("subject", "")) != str(player_id):
				return false
			var parts: Variant = _parse_payload(str(entry.get("payload", "")))
			if not parts is Array or parts.size() != 4 or str(parts[0]) != KIND_WITHDRAW:
				return false
			if float(parts[3]) != float(participant.withdraw_utc):
				return false
	return true


static func _valid_engagements(state: Dictionary) -> bool:
	var engagements: Dictionary = state.engagements
	var revision: int = int(state.regime.revision)
	var caps: Dictionary = state.caps
	for command_id: Variant in engagements:
		if not _valid_command_id(command_id):
			return false
		var engagement: Variant = engagements[command_id]
		if not engagement is Dictionary or engagement.size() != ENGAGEMENT_KEYS.size():
			return false
		for field: String in ENGAGEMENT_KEYS:
			if not engagement.has(field):
				return false
		if not _valid_player(engagement.attacker) or not _valid_player(engagement.target):
			return false
		if str(engagement.attacker) == str(engagement.target):
			return false
		if not _valid_entry_id(engagement.area_id) or not state.areas.has(engagement.area_id):
			return false
		if not _valid_entry_id(engagement.window_id) or not state.windows.has(engagement.window_id):
			return false
		if not _is_count(engagement.x) or not _is_count(engagement.z):
			return false
		if not _valid_coord(int(engagement.x)) or not _valid_coord(int(engagement.z)):
			return false
		var area: Dictionary = state.areas[engagement.area_id]
		if int(engagement.x) < int(area.min_x) or int(engagement.x) > int(area.max_x) \
				or int(engagement.z) < int(area.min_z) or int(engagement.z) > int(area.max_z):
			return false
		if not _valid_time(engagement.at_utc):
			return false
		var window: Dictionary = state.windows[engagement.window_id]
		if float(engagement.at_utc) < float(window.start_utc) \
				or float(engagement.at_utc) >= float(window.end_utc):
			return false
		if not _is_count(engagement.revision):
			return false
		if int(engagement.revision) < 1 or int(engagement.revision) > revision:
			return false
		if not engagement.defender_online is bool:
			return false
		for field: String in ["amount", "cap", "loss_total_after"]:
			if not _is_count(engagement[field]):
				return false
		if int(engagement.amount) <= 0 or int(engagement.amount) > MAX_SAFE_INTEGER:
			return false
		var cap_key: String = str(int(engagement.revision))
		if not caps.has(cap_key):
			return false
		var recorded: Dictionary = caps[cap_key]
		var expected_cap: int = int(recorded.loss_cap) if bool(engagement.defender_online) \
			else int(recorded.offline_loss_cap)
		if int(engagement.cap) != expected_cap:
			return false
		if int(engagement.cap) < int(engagement.amount):
			return false
		if int(engagement.loss_total_after) < int(engagement.amount) \
				or int(engagement.loss_total_after) > int(engagement.cap):
			return false
	return true


static func _valid_revision_key(value: Variant) -> bool:
	# JSON object keys are always strings, so the durable cap map uses decimal
	# revision numbers as keys.
	if value is int:
		return int(value) >= 1 and int(value) <= MAX_SAFE_INTEGER
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > 18:
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		if code < 48 or code > 57:
			return false
	return int(text) >= 1 and int(text) <= MAX_SAFE_INTEGER


static func _valid_caps(state: Dictionary) -> bool:
	var caps: Dictionary = state.caps
	var revision: int = int(state.regime.revision)
	for revision_key: Variant in caps:
		var key: String = str(revision_key)
		if not _valid_revision_key(revision_key):
			return false
		if key != str(int(revision_key)):
			return false
		var entry: Variant = caps[revision_key]
		if not entry is Dictionary or entry.size() != CAP_KEYS.size():
			return false
		for field: String in CAP_KEYS:
			if not entry.has(field):
				return false
		if not _is_count(entry.loss_cap) or not _is_count(entry.offline_loss_cap):
			return false
		if int(entry.loss_cap) <= 0 or int(entry.offline_loss_cap) <= 0 \
				or int(entry.offline_loss_cap) > int(entry.loss_cap):
			return false
		if int(revision_key) > revision:
			return false
	# The live regime's caps must be the ones recorded for its revision. A peace
	# revision carries no budget, so it has no live cap row.
	if bool(state.regime.higher_risk):
		if revision < 1 or not caps.has(str(revision)):
			return false
		var live: Dictionary = caps[str(revision)]
		if int(live.loss_cap) != int(state.regime.loss_cap) \
				or int(live.offline_loss_cap) != int(state.regime.offline_loss_cap):
			return false
	return true


static func _valid_losses(state: Dictionary) -> bool:
	var losses: Dictionary = state.losses
	var sums: Dictionary = {}
	var peaks: Dictionary = {}
	for command_id: Variant in state.engagements:
		var engagement: Dictionary = state.engagements[command_id]
		var key: String = str(engagement.target) + "|" + str(engagement.window_id)
		sums[key] = int(sums.get(key, 0)) + int(engagement.amount)
		peaks[key] = maxi(int(peaks.get(key, 0)), int(engagement.loss_total_after))
	if sums.size() != losses.size():
		return false
	for key: Variant in losses:
		var loss: Variant = losses[key]
		var parts: PackedStringArray = str(key).split("|")
		if parts.size() != 2:
			return false
		if not _valid_player(parts[0]) or not _valid_entry_id(parts[1]):
			return false
		if not state.windows.has(parts[1]):
			return false
		if not loss is Dictionary or loss.size() != LOSS_KEYS.size():
			return false
		for field: String in LOSS_KEYS:
			if not loss.has(field):
				return false
		if not loss.target is String or str(loss.target) != parts[0]:
			return false
		if not loss.window_id is String or str(loss.window_id) != parts[1]:
			return false
		if not _is_count(loss.amount) or int(loss.amount) <= 0:
			return false
		if not sums.has(key) or int(sums[key]) != int(loss.amount):
			return false
		# The peak running total must be the final total; otherwise the durable
		# engagement rows and the loss row describe different progress.
		if int(peaks[key]) != int(loss.amount):
			return false
	return true


static func _valid_command_results(state: Dictionary) -> bool:
	var results: Dictionary = state.command_results
	for command_id: Variant in results:
		if not _valid_command_id(command_id):
			return false
		var entry: Variant = results[command_id]
		if not entry is Dictionary or entry.size() != 2 \
				or not entry.has("payload") or not entry.has("result"):
			return false
		if not entry.payload is String or not entry.result is Dictionary:
			return false
		var payload: String = entry.payload
		if payload.length() > MAX_PAYLOAD_LENGTH:
			return false
		var parsed: Variant = _parse_payload(payload)
		if not parsed is Array:
			return false
		var parts: Array = parsed
		if parts.is_empty():
			return false
		var kind: String = str(parts[0])
		if not _valid_result(entry.result):
			return false
		var result: Dictionary = entry.result
		match kind:
			KIND_REGIME:
				if parts.size() != 5:
					return false
				if not _valid_world_id(parts[1]) or str(parts[1]) != str(state.world_id):
					return false
				if not _valid_player(parts[2]) or str(parts[2]) != str(state.host):
					return false
				if not _valid_time(parts[3]):
					return false
				if not parts[4] is Dictionary:
					return false
				var declaration: Dictionary = parts[4]
				if not _valid_entry_id(declaration.get("declaration_id")):
					return false
				if str(result.subject) != str(declaration.declaration_id):
					return false
				# Only the row that still owns the live regime must describe it
				# exactly; older declaration rows in the window are history.
				if command_id == str(state.regime.command_id) \
						and _canonical_declaration(declaration) \
						!= _canonical_regime_declaration(state, state.regime):
					return false
				if not str(result.window_id).is_empty() \
						or int(result.loss_total) != 0 or int(result.cap) != 0:
					return false
			KIND_PARTICIPATE:
				if parts.size() != 5:
					return false
				if not _valid_world_id(parts[1]) or str(parts[1]) != str(state.world_id):
					return false
				if not _valid_player(parts[2]) or str(result.subject) != str(parts[2]):
					return false
				if not parts[3] is String or not ROLES.has(str(parts[3])):
					return false
				if not _valid_time(parts[4]):
					return false
				if not str(result.window_id).is_empty() \
						or int(result.loss_total) != 0 or int(result.cap) != 0:
					return false
			KIND_WITHDRAW:
				if parts.size() != 4:
					return false
				if not _valid_world_id(parts[1]) or str(parts[1]) != str(state.world_id):
					return false
				if not _valid_player(parts[2]) or str(result.subject) != str(parts[2]):
					return false
				if not _valid_time(parts[3]):
					return false
				if not str(result.window_id).is_empty() \
						or int(result.loss_total) != 0 or int(result.cap) != 0:
					return false
			KIND_ENGAGE:
				if parts.size() != 9:
					return false
				if not _valid_world_id(parts[1]) or str(parts[1]) != str(state.world_id):
					return false
				if not _valid_player(parts[2]) or not _valid_player(parts[3]):
					return false
				if str(parts[2]) == str(parts[3]) or str(result.subject) != str(parts[3]):
					return false
				if not _is_count(parts[4]) or not _is_count(parts[5]):
					return false
				if not _valid_coord(int(parts[4])) or not _valid_coord(int(parts[5])):
					return false
				if not _valid_time(parts[6]):
					return false
				if not _is_count(parts[7]) or int(parts[7]) <= 0:
					return false
				if not parts[8] is bool:
					return false
				if not _valid_entry_id(result.window_id):
					return false
				if not state.windows.has(result.window_id):
					return false
				if int(result.loss_total) < int(parts[7]):
					return false
				if int(result.cap) < int(parts[7]):
					return false
				if not state.engagements.has(command_id):
					return false
			_:
				return false
	return true


static func _valid_result(value: Dictionary) -> bool:
	if value.size() != RESULT_KEYS.size():
		return false
	for key: String in RESULT_KEYS:
		if not value.has(key):
			return false
	if not value.ok is bool or not bool(value.ok):
		return false
	if not value.reason is String or not str(value.reason).is_empty() \
			or str(value.reason).length() > 64:
		return false
	if not value.duplicate is bool or bool(value.duplicate):
		return false
	if not value.subject is String or str(value.subject).is_empty() \
			or str(value.subject).length() > MAX_COMMAND_ID_LENGTH:
		return false
	if not value.window_id is String or str(value.window_id).length() > MAX_ENTRY_ID_LENGTH:
		return false
	if not _is_count(value.loss_total) or not _is_count(value.cap):
		return false
	if str(value.window_id).is_empty() and (int(value.loss_total) != 0 or int(value.cap) != 0):
		return false
	return true


static func _valid_id_list(ids: Array, registry: Dictionary) -> bool:
	var seen: Dictionary = {}
	for id: Variant in ids:
		if not _valid_entry_id(id):
			return false
		var key: String = str(id)
		if seen.has(key) or not registry.has(key):
			return false
		seen[key] = true
	return true


static func _parse_declaration(state: Dictionary, value: Variant,
		declared_utc: float) -> Dictionary:
	if not value is Dictionary or value.size() != DECLARATION_KEYS.size():
		return {"ok": false, "reason": "invalid_declaration"}
	for key: String in DECLARATION_KEYS:
		if not value.has(key):
			return {"ok": false, "reason": "invalid_declaration"}
	var tier_value: Variant = value.tier
	if not tier_value is String or not TIERS.has(str(tier_value)):
		return {"ok": false, "reason": "invalid_regime"}
	var declaration_id: Variant = value.declaration_id
	if not _valid_entry_id(declaration_id):
		return {"ok": false, "reason": "invalid_declaration"}
	var effective_value: Variant = value.effective_utc
	if not _valid_time(effective_value) or float(effective_value) < declared_utc:
		return {"ok": false, "reason": "invalid_declaration"}
	var higher_value: Variant = value.higher_risk
	if not higher_value is bool:
		return {"ok": false, "reason": "invalid_regime"}
	var loss_value: Variant = value.loss_cap
	var offline_value: Variant = value.offline_loss_cap
	if not _is_count(loss_value) or not _is_count(offline_value):
		return {"ok": false, "reason": "invalid_regime"}
	var raw_areas: Variant = value.areas
	var raw_windows: Variant = value.windows
	if not raw_areas is Array or not raw_windows is Array:
		return {"ok": false, "reason": "invalid_regime"}
	var tier: String = str(tier_value)
	var higher: bool = bool(higher_value)
	var loss_cap: int = int(loss_value)
	var offline_cap: int = int(offline_value)
	if tier == TIER_PEACE:
		# Peace is the default and refuses all attacks, so it carries no scope
		# and no budget. A non-empty peace declaration is a forged document.
		if higher or not raw_areas.is_empty() or not raw_windows.is_empty():
			return {"ok": false, "reason": "invalid_regime"}
		if loss_cap != 0 or offline_cap != 0:
			return {"ok": false, "reason": "invalid_regime"}
	else:
		# `limited` never opens risk by implication: the host must publish a
		# higher-risk declaration with explicit zones, windows and caps.
		if not higher:
			return {"ok": false, "reason": "risk_not_declared"}
		if raw_areas.is_empty() or raw_windows.is_empty():
			return {"ok": false, "reason": "invalid_regime"}
		if loss_cap <= 0 or offline_cap <= 0 or offline_cap > loss_cap:
			return {"ok": false, "reason": "invalid_regime"}
	var parsed_areas: Dictionary = _parse_areas(state, raw_areas)
	if not parsed_areas.ok:
		return parsed_areas
	var parsed_windows: Dictionary = _parse_windows(state, raw_windows)
	if not parsed_windows.ok:
		return parsed_windows
	var regime: Dictionary = {
		"tier": tier,
		"revision": 0,
		"declaration_id": str(declaration_id),
		"declared_by": str(state.host),
		"declared_utc": float(declared_utc),
		"effective_utc": float(effective_value),
		"higher_risk": higher,
		"area_ids": parsed_areas.ids,
		"window_ids": parsed_windows.ids,
		"loss_cap": loss_cap,
		"offline_loss_cap": offline_cap,
		"command_id": "",
	}
	return {
		"ok": true,
		"reason": "",
		"regime": regime,
		"areas": parsed_areas.rows,
		"windows": parsed_windows.rows,
	}


static func _parse_areas(state: Dictionary, raw: Array) -> Dictionary:
	var rows: Array = []
	var ids: Array = []
	var seen: Dictionary = {}
	for entry: Variant in raw:
		if not entry is Dictionary or entry.size() != AREA_KEYS.size():
			return {"ok": false, "reason": "invalid_area"}
		for key: String in AREA_KEYS:
			if not entry.has(key):
				return {"ok": false, "reason": "invalid_area"}
		var area_id: Variant = entry.id
		if not _valid_entry_id(area_id) or seen.has(str(area_id)):
			return {"ok": false, "reason": "duplicate_area"}
		if not _valid_rect(entry):
			return {"ok": false, "reason": "invalid_area"}
		var row: Dictionary = {
			"id": str(area_id),
			"min_x": int(entry.min_x),
			"min_z": int(entry.min_z),
			"max_x": int(entry.max_x),
			"max_z": int(entry.max_z),
		}
		var existing: Variant = state.areas.get(str(area_id))
		if existing is Dictionary:
			if _area_row(existing) != row:
				return {"ok": false, "reason": "area_conflict"}
		elif state.areas.size() + _new_count(state.areas, rows) >= MAX_AREAS:
			return {"ok": false, "reason": "capacity"}
		seen[str(area_id)] = true
		ids.append(str(area_id))
		rows.append(row)
	# Only the new declaration's own set must be disjoint: it replaces the live
	# scope. Historical rows stay in the registry for audit but grant nothing
	# unless a later declaration lists them again.
	for left: int in range(ids.size()):
		for right: int in range(left + 1, ids.size()):
			if _rects_overlap(_resolved_area(state, rows, ids[left]),
					_resolved_area(state, rows, ids[right])):
				return {"ok": false, "reason": "overlapping_areas"}
	return {"ok": true, "reason": "", "rows": _new_area_rows(state, rows), "ids": ids}


static func _parse_windows(state: Dictionary, raw: Array) -> Dictionary:
	var rows: Array = []
	var ids: Array = []
	var seen: Dictionary = {}
	for entry: Variant in raw:
		if not entry is Dictionary or entry.size() != WINDOW_KEYS.size():
			return {"ok": false, "reason": "invalid_window"}
		for key: String in WINDOW_KEYS:
			if not entry.has(key):
				return {"ok": false, "reason": "invalid_window"}
		var window_id: Variant = entry.id
		if not _valid_entry_id(window_id) or seen.has(str(window_id)):
			return {"ok": false, "reason": "duplicate_window"}
		if not _valid_time(entry.start_utc) or not _valid_time(entry.end_utc) \
				or float(entry.end_utc) <= float(entry.start_utc):
			return {"ok": false, "reason": "invalid_window"}
		var row: Dictionary = {
			"id": str(window_id),
			"start_utc": float(entry.start_utc),
			"end_utc": float(entry.end_utc),
		}
		var existing: Variant = state.windows.get(str(window_id))
		if existing is Dictionary:
			if _window_row(existing) != row:
				return {"ok": false, "reason": "window_conflict"}
		elif state.windows.size() + _new_count(state.windows, rows) >= MAX_WINDOWS:
			return {"ok": false, "reason": "capacity"}
		seen[str(window_id)] = true
		ids.append(str(window_id))
		rows.append(row)
	# Windows are half-open, so touching endpoints (`end == start`) do not
	# overlap and an instant maps to at most one live window.
	for left: int in range(ids.size()):
		for right: int in range(left + 1, ids.size()):
			if _windows_overlap(_resolved_window(state, rows, ids[left]),
					_resolved_window(state, rows, ids[right])):
				return {"ok": false, "reason": "overlapping_windows"}
	return {"ok": true, "reason": "", "rows": _new_window_rows(state, rows), "ids": ids}


## Looks up an area row from the rows staged by this declaration, falling back
## to the durable registry for reused ids.
static func _resolved_area(state: Dictionary, rows: Array, area_id: String) -> Dictionary:
	for row: Dictionary in rows:
		if str(row.id) == area_id:
			return row
	return state.areas[area_id]


static func _resolved_window(state: Dictionary, rows: Array, window_id: String) -> Dictionary:
	for row: Dictionary in rows:
		if str(row.id) == window_id:
			return row
	return state.windows[window_id]


static func _new_count(registry: Dictionary, rows: Array) -> int:
	var count: int = 0
	for row: Dictionary in rows:
		if not registry.has(str(row.id)):
			count += 1
	return count


static func _new_area_rows(state: Dictionary, rows: Array) -> Array:
	var output: Array = []
	for row: Dictionary in rows:
		if not state.areas.has(str(row.id)):
			output.append(row)
	return output


static func _new_window_rows(state: Dictionary, rows: Array) -> Array:
	var output: Array = []
	for row: Dictionary in rows:
		if not state.windows.has(str(row.id)):
			output.append(row)
	return output


static func _area_row(area: Dictionary) -> Dictionary:
	return {
		"id": str(area.get("id", "")),
		"min_x": int(area.get("min_x", 0)),
		"min_z": int(area.get("min_z", 0)),
		"max_x": int(area.get("max_x", 0)),
		"max_z": int(area.get("max_z", 0)),
	}


static func _window_row(window: Dictionary) -> Dictionary:
	return {
		"id": str(window.get("id", "")),
		"start_utc": float(window.get("start_utc", 0.0)),
		"end_utc": float(window.get("end_utc", 0.0)),
	}


## Keeps only the cap, area and window rows that still mean something: the live
## revision's scope plus every row named by a durable engagement. Without this,
## a room that re-declares often would exhaust the registry bounds on rows no
## one can act on any more. Rows that still explain a settled engagement are
## never dropped, so auditability is preserved.
static func _prune_history(state: Dictionary) -> void:
	var needed_areas: Dictionary = {}
	var needed_windows: Dictionary = {}
	for area_id: Variant in state.regime.get("area_ids", []):
		needed_areas[str(area_id)] = true
	for window_id: Variant in state.regime.get("window_ids", []):
		needed_windows[str(window_id)] = true
	for command_id: Variant in state.engagements:
		var engagement: Dictionary = state.engagements[command_id]
		needed_areas[str(engagement.area_id)] = true
		needed_windows[str(engagement.window_id)] = true
	for area_id: Variant in state.areas.keys():
		if not needed_areas.has(str(area_id)):
			state.areas.erase(area_id)
	for window_id: Variant in state.windows.keys():
		if not needed_windows.has(str(window_id)):
			state.windows.erase(window_id)
	var needed_caps: Dictionary = {}
	if bool(state.regime.get("higher_risk", false)):
		needed_caps[str(int(state.regime.revision))] = true
	for command_id: Variant in state.engagements:
		var engagement: Dictionary = state.engagements[command_id]
		needed_caps[str(int(engagement.revision))] = true
	for revision_key: Variant in state.caps.keys():
		if not needed_caps.has(str(revision_key)):
			state.caps.erase(revision_key)


## True when `command_id` already names a durable row owned by someone else.
## The bounded command window may have evicted the result row, so ownership has
## to be checked against the durable rows too; otherwise a later command could
## reuse an evicted id and produce a document `valid()` refuses.
static func _command_id_taken(state: Dictionary, command_id: String, actor: String,
		role_owner: String) -> bool:
	if state.engagements.has(command_id):
		return true
	if role_owner != "regime" and str(state.regime.get("command_id", "")) == command_id:
		return true
	var participants: Variant = state.participants
	if not participants is Dictionary:
		return false
	for player_id: Variant in participants:
		var participant: Variant = participants[player_id]
		if not participant is Dictionary:
			continue
		if str(participant.get("consent_command_id", "")) == command_id \
				and not (str(player_id) == actor and role_owner == "consent"):
			return true
		if str(participant.get("withdraw_command_id", "")) == command_id \
				and not (str(player_id) == actor and role_owner == "withdraw"):
			return true
	return false


static func _inactive_reason(state: Dictionary, player: Variant, role: String,
		at_utc: float) -> String:
	var participants: Variant = state.get("participants")
	if not participants is Dictionary or not _valid_player(player):
		return "not_consented"
	var participant: Variant = participants.get(str(player))
	if not participant is Dictionary:
		return "not_consented"
	if not bool(participant.get(role, false)):
		return "not_consented"
	if int(participant.get("consent_revision", 0)) != int(state.regime.get("revision", 0)):
		return "not_consented"
	if at_utc < float(participant.get("consent_utc", 0.0)):
		return "not_consented"
	var effective: float = float(participant.get("withdraw_effective_utc", 0.0))
	if effective > 0.0 and at_utc >= effective:
		return "withdrawn"
	return ""


static func _replay_engagement(state: Dictionary, command_id: String, attacker: Variant,
		target: Variant, x: int, z: int, at_utc: float, amount: int,
		online: bool) -> Dictionary:
	var engagements: Variant = state.get("engagements")
	if not engagements is Dictionary:
		return {}
	var row: Variant = engagements.get(command_id)
	if not row is Dictionary:
		return {}
	if str(row.get("attacker", "")) != str(attacker) \
			or str(row.get("target", "")) != str(target) \
			or int(row.get("x", -1)) != x or int(row.get("z", -1)) != z \
			or float(row.get("at_utc", -1.0)) != at_utc \
			or int(row.get("amount", 0)) != amount \
			or bool(row.get("defender_online", false)) != online:
		return _error("command_conflict", str(target))
	return _result(true, "", true, str(target), str(row.get("window_id", "")),
		int(row.get("loss_total_after", 0)), int(row.get("cap", 0)))


static func _replay(state: Dictionary, command_id: String, payload: String) -> Dictionary:
	var results: Variant = state.get("command_results")
	if not results is Dictionary or not results.has(command_id):
		return {}
	var entry: Variant = results[command_id]
	if not entry is Dictionary or not entry.get("result") is Dictionary:
		return _error("invalid_state", "")
	if str(entry.get("payload", "")) != payload:
		return _error("command_conflict", str(entry.result.get("subject", "")))
	return _copy_result(entry.result, true)


static func _record_command(state: Dictionary, command_id: String, payload: String,
		result: Dictionary) -> void:
	var results: Variant = state.get("command_results")
	if not results is Dictionary:
		return
	state.sequence = int(state.get("sequence", 0)) + 1
	results[command_id] = {"payload": payload, "result": _copy_result(result, false)}
	while results.size() > MAX_COMMAND_RESULTS:
		results.erase(results.keys()[0])


static func _new_participant(player_id: String) -> Dictionary:
	return {
		"participant": player_id,
		"attacker": false,
		"defender": false,
		"consent_revision": 0,
		"consent_utc": 0.0,
		"consent_command_id": "",
		"withdraw_utc": 0.0,
		"withdraw_effective_utc": 0.0,
		"withdraw_command_id": "",
	}


static func _canonical_declaration(value: Variant) -> Variant:
	if not value is Dictionary:
		return null
	if value.size() != DECLARATION_KEYS.size():
		return null
	for key: String in DECLARATION_KEYS:
		if not value.has(key):
			return null
	if not value.tier is String or not value.declaration_id is String:
		return null
	if not _valid_time(value.effective_utc):
		return null
	if not value.higher_risk is bool:
		return null
	if not _is_count(value.loss_cap) or not _is_count(value.offline_loss_cap):
		return null
	if not value.areas is Array or not value.windows is Array:
		return null
	var areas: Array = []
	for entry: Variant in value.areas:
		if not entry is Dictionary or entry.size() != AREA_KEYS.size():
			return null
		for key: String in AREA_KEYS:
			if not entry.has(key):
				return null
		if not entry.id is String:
			return null
		for field: String in ["min_x", "min_z", "max_x", "max_z"]:
			if not _is_count(entry[field]):
				return null
		areas.append({
			"id": str(entry.id),
			"min_x": int(entry.min_x),
			"min_z": int(entry.min_z),
			"max_x": int(entry.max_x),
			"max_z": int(entry.max_z),
		})
	var windows: Array = []
	for entry: Variant in value.windows:
		if not entry is Dictionary or entry.size() != WINDOW_KEYS.size():
			return null
		for key: String in WINDOW_KEYS:
			if not entry.has(key):
				return null
		if not entry.id is String:
			return null
		if not _valid_time(entry.start_utc) or not _valid_time(entry.end_utc):
			return null
		windows.append({
			"id": str(entry.id),
			"start_utc": float(entry.start_utc),
			"end_utc": float(entry.end_utc),
		})
	return {
		"tier": str(value.tier),
		"declaration_id": str(value.declaration_id),
		"effective_utc": float(value.effective_utc),
		"higher_risk": bool(value.higher_risk),
		"areas": areas,
		"windows": windows,
		"loss_cap": int(value.loss_cap),
		"offline_loss_cap": int(value.offline_loss_cap),
	}


static func _canonical_regime_declaration(state: Dictionary, regime: Dictionary) -> Dictionary:
	var areas: Array = []
	for area_id: Variant in regime.get("area_ids", []):
		var area: Variant = state.areas.get(str(area_id))
		if not area is Dictionary:
			continue
		areas.append({
			"id": str(area.id),
			"min_x": int(area.min_x),
			"min_z": int(area.min_z),
			"max_x": int(area.max_x),
			"max_z": int(area.max_z),
		})
	var windows: Array = []
	for window_id: Variant in regime.get("window_ids", []):
		var window: Variant = state.windows.get(str(window_id))
		if not window is Dictionary:
			continue
		windows.append({
			"id": str(window.id),
			"start_utc": float(window.start_utc),
			"end_utc": float(window.end_utc),
		})
	return {
		"tier": str(regime.get("tier", "")),
		"declaration_id": str(regime.get("declaration_id", "")),
		"effective_utc": float(regime.get("effective_utc", 0.0)),
		"higher_risk": bool(regime.get("higher_risk", false)),
		"areas": areas,
		"windows": windows,
		"loss_cap": int(regime.get("loss_cap", 0)),
		"offline_loss_cap": int(regime.get("offline_loss_cap", 0)),
	}


static func _valid_rect(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	for key: String in AREA_KEYS:
		if not value.has(key):
			return false
	if not _valid_entry_id(value.get("id")):
		return false
	if not _valid_coord(value.get("min_x")) or not _valid_coord(value.get("min_z")) \
			or not _valid_coord(value.get("max_x")) or not _valid_coord(value.get("max_z")):
		return false
	return int(value.min_x) <= int(value.max_x) and int(value.min_z) <= int(value.max_z)


static func _rects_overlap(a: Dictionary, b: Dictionary) -> bool:
	return int(a.min_x) <= int(b.max_x) and int(b.min_x) <= int(a.max_x) \
		and int(a.min_z) <= int(b.max_z) and int(b.min_z) <= int(a.max_z)


static func _windows_overlap(a: Dictionary, b: Dictionary) -> bool:
	return float(a.start_utc) < float(b.end_utc) and float(b.start_utc) < float(a.end_utc)


static func _state_ready(state: Dictionary) -> bool:
	return state.get("regime") is Dictionary \
		and state.get("areas") is Dictionary \
		and state.get("windows") is Dictionary \
		and state.get("caps") is Dictionary \
		and state.get("participants") is Dictionary \
		and state.get("losses") is Dictionary \
		and state.get("engagements") is Dictionary \
		and state.get("command_results") is Dictionary \
		and _is_count(state.get("sequence", -1))


static func _ok_regime(declaration_id: String, duplicate: bool) -> Dictionary:
	return _result(true, "", duplicate, declaration_id, "", 0, 0)


static func _ok_subject(subject: String, duplicate: bool) -> Dictionary:
	return _result(true, "", duplicate, subject, "", 0, 0)


static func _ok_engage(target: String, window_id: String, total: int, cap: int,
		duplicate: bool) -> Dictionary:
	return _result(true, "", duplicate, target, window_id, total, cap)


static func _error(reason: String, subject: String) -> Dictionary:
	return _result(false, reason, false, subject, "", 0, 0)


static func _result(ok: bool, reason: String, duplicate: bool, subject: String,
		window_id: String, loss_total: int, cap: int) -> Dictionary:
	return {
		"ok": ok,
		"reason": reason,
		"duplicate": duplicate,
		"subject": subject,
		"window_id": window_id,
		"loss_total": loss_total,
		"cap": cap,
	}


static func _copy_result(value: Dictionary, duplicate: bool) -> Dictionary:
	return _result(bool(value.get("ok", false)), str(value.get("reason", "")),
		duplicate, str(value.get("subject", "")), str(value.get("window_id", "")),
		int(value.get("loss_total", 0)), int(value.get("cap", 0)))


static func _parse_payload(text: String) -> Variant:
	# JSON.parse_string logs an engine error for malformed input; the document
	# validator treats that as a normal rejection, so parse quietly instead.
	var json: JSON = JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


static func _string_array(value: Variant) -> Array:
	var output: Array = []
	if value is Array:
		for entry: Variant in value:
			output.append(str(entry))
	return output


static func _valid_player(value: Variant) -> bool:
	return value is String and str(value) != "public" and OwnerIds.valid(value)


static func _valid_coord(value: Variant) -> bool:
	return _is_count(value) and int(value) >= 0 and int(value) <= MAX_COORD


static func _valid_entry_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= MAX_ENTRY_ID_LENGTH and OwnerIds.valid(value)


static func _valid_world_id(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > MAX_WORLD_ID_LENGTH:
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		var letter: bool = (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		var digit: bool = code >= 48 and code <= 57
		if not letter and not digit and code != 95 and code != 45 and code != 46 and code != 58:
			return false
	return true


static func _valid_command_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= MAX_COMMAND_ID_LENGTH


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and float(value) >= 0.0 and float(value) <= float(MAX_SAFE_INTEGER)


static func _is_count(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)
