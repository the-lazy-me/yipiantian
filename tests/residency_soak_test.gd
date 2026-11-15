extends SceneTree
## M13-02 真实驻留切片（规则夹具）：在真实 `HeadlessWorld` + `enable_residents()`
## 上按真实墙钟循环推进世界并结算，周期性采样内存、存档文件与账本，检查长时间
## 驻留下现金守恒、对账、容量有界、重放与重启一致性。
##
## 本夹具与 `long_soak_test.gd`（RECORD-04）和 `long_simulation_test.gd`
## （RECORD-11）的区别：那两个用固定步数推进逻辑时钟，不读墙钟；这里用
## `Time.get_ticks_msec()` 决定循环何时继续，真实等待并采样，因此能观察到
## “跑得越久文件/内存是否越涨”。逻辑时钟仍由夹具自己的固定步长推进，天气与
## 到达/到期由逻辑时刻决定，所以同一时长得到同一逻辑状态。
##
## 循环结构（每个 tick）：
##   1. 用 `advance_to(now + logical_step)` 推进作物/天气/市场/经济扫描；
##   2. 若推进改变了作物字段或结算了经济事件，调用 `save()`（与 `world_server`
##      的真实策略一致：只在有变化时写盘，避免无意义写放大）；
##   3. 调用 `settle_economy_now(now)` 结算经济与居民（启用后居民并入同一次保存）；
##   4. 按自适应采样间隔采样内存、文件与账本；
##   5. 睡眠到 `tick_ms` 的墙钟间隔再开始下一轮。
##
## 断言：现金守恒、对账、账本/社交/记忆/邀约表容量、文件与内存不随运行时长
## 单调无界增长（前 1/3 与后 1/3 的最大值比较，中位数一并报告）、重放同一逻辑
## 时刻无变化、尾段重启后状态一致。
##
## 参数：`--soak-seconds=N`（默认 30；CI 的 180 秒看门狗只跑默认值）、
## `--tick-ms=N`（默认 250，约束在 200–500）、`--logical-step=N`（默认 3600，
## 即每个 tick 推进 1 逻辑小时）。用户参数放在 `--` 之后。
##
## 夹具自身开销固定有界：采样记录写进一块预分配、固定大小的整数缓冲（最多
## `MAX_SAMPLES` 条），不写逐 tick 日志。采样曲线来自世界目录与引擎计数；
## 夹具只在运行目录里写一次 `samples.json`，因此曲线增长不是测试自己造成的。

const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const FarmState = preload("res://farm/farm_state.gd")
const Economy = preload("res://farm/economy_state.gd")
const Market = preload("res://farm/market_state.gd")
const Ledger = preload("res://farm/ledger_state.gd")
const NatureState = preload("res://farm/nature_state.gd")
const TerritoryState = preload("res://world/territory_state.gd")
const Organization = preload("res://world/organization_state.gd")
const PublicFund = preload("res://world/public_fund.gd")
const PublicWorks = preload("res://world/public_works.gd")
const Participation = preload("res://conflict/participation_state.gd")
const Disputes = preload("res://world/dispute_state.gd")
const UnitState = preload("res://conflict/unit_state.gd")
const NpcRoster = preload("res://npc/npc_roster.gd")
const ResidentLedger = preload("res://npc/npc_resident_ledger.gd")
const IntentState = preload("res://npc/npc_intent_state.gd")
const Social = preload("res://npc/npc_social.gd")
const Memory = preload("res://npc/npc_memory.gd")
const ResidentsStore = preload("res://world/residents_store.gd")

const START: float = 1800028800.0
const SEED: int = 42017
const RULES_VERSION: int = 2
const WORLD_ID: String = "residency-soak"
const HOST: String = "soak_host"
const DEFAULT_SOAK_SECONDS: int = 30
## CI's rule-fixture watchdog is 180 seconds, so CI must use the 30-second
## default (or any value that leaves startup, the tail restart and the final
## checks room). A local run may ask for longer, for example 600 seconds; the
## fixture accepts it and only caps runaway values.
const MAX_SOAK_SECONDS: int = 3600
const DEFAULT_TICK_MS: int = 250
const MIN_TICK_MS: int = 200
const MAX_TICK_MS: int = 500
const DEFAULT_LOGICAL_STEP: float = 3600.0
## 采样记录放在一块**预分配**的扁平 `PackedInt64Array` 里（固定
## `MAX_SAMPLES × SAMPLE_FIELDS` 个整数），采样数与运行时长无关地不改变夹具
## 自身占用。早先用 `Array[Dictionary]` 时，每个样本本身就让引擎静态内存
## 每采样增加约 1.2 KB，看上去像产品泄漏——这是测量方法造成的假象。改为一
## 块固定缓冲后，剩余的静态内存变化才来自世界本身。
const MIN_SAMPLE_EVERY_TICKS: int = 4
const MAX_SAMPLES: int = 320
const SAMPLE_FIELDS: int = 12
const F_TICK: int = 0
const F_ELAPSED_MS: int = 1
const F_STATIC_BYTES: int = 2
const F_DYNAMIC_BYTES: int = 3
const F_OBJECTS: int = 4
const F_RESOURCES: int = 5
const F_FILES_TOTAL: int = 6
const F_FARM_BYTES: int = 7
const F_RESIDENTS_BYTES: int = 8
const F_LEDGER_BYTES: int = 9
const F_TOTAL_CASH: int = 10
const F_ISSUED: int = 11
## 尾段重启保留的最终状态是这个目录，测试结束也不删除它（在 `.local` 下）。
const WINDOW_NAME: String = "world"

var checks: int = 0
var failures: Array[String] = []
var base_root: String = ""
var soak_seconds: int = DEFAULT_SOAK_SECONDS
var tick_ms: int = DEFAULT_TICK_MS
var logical_step: float = DEFAULT_LOGICAL_STEP

## 固定大小的采样缓冲与已写入的样本数。
var sample_data: PackedInt64Array = PackedInt64Array()
var sample_count: int = 0


func _initialize() -> void:
	_parse_arguments()
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	base_root = project_root.get_base_dir().path_join(
		".local/verification/residency-soak-%d-%d"
		% [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(base_root)
	# Preallocate the whole sample buffer once, before any measurement, so the
	# sampling itself never grows the engine's static memory during the soak.
	sample_data.resize(MAX_SAMPLES * SAMPLE_FIELDS)
	sample_data.fill(0)
	sample_count = 0
	var started_ms: int = Time.get_ticks_msec()
	_run()
	var elapsed_ms: int = Time.get_ticks_msec() - started_ms
	# A script error while the authority loads aborts `_run()` without raising a
	# GDScript exception, so the process would otherwise exit 0 with no samples
	# and look like a pass. CI also greps the log for SCRIPT ERROR; a local run
	# must fail on its own.
	if sample_count == 0:
		_expect(false, "the soak never reached the sampling loop")
	for failure: String in failures:
		push_error(failure)
	var first: int = 0
	var last: int = maxi(0, sample_count - 1)
	var peak: int = _peak_sample_index()
	print("MEASURE seconds=%.1f samples=%d mem_first=%.1f mem_last=%.1f mem_peak=%.1f "
		% [float(elapsed_ms) / 1000.0, sample_count,
		float(_field(first, F_STATIC_BYTES)) / 1048576.0,
		float(_field(last, F_STATIC_BYTES)) / 1048576.0,
		float(_field(peak, F_STATIC_BYTES)) / 1048576.0]
		+ "files_first=%d files_last=%d cash_issued=%d final_total=%d"
		% [_field(first, F_FILES_TOTAL), _field(last, F_FILES_TOTAL),
		_field(last, F_ISSUED), _field(last, F_TOTAL_CASH)])
	print("ELAPSED_MS=%d soak_seconds=%d tick_ms=%d logical_step=%.0f"
		% [elapsed_ms, soak_seconds, tick_ms, logical_step])
	_write_samples()
	print("RESIDENCY_SOAK_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


## The samples are a test artifact, not a fixture output stream: they live in
## the run directory under `.local/` so a long local soak can be summarized
## without flooding CI logs with one line per sample.
func _write_samples() -> void:
	var rows: Array = []
	for index: int in sample_count:
		rows.append({
			"tick": _field(index, F_TICK),
			"elapsed_ms": _field(index, F_ELAPSED_MS),
			"static_bytes": _field(index, F_STATIC_BYTES),
			"dynamic_bytes": _field(index, F_DYNAMIC_BYTES),
			"objects": _field(index, F_OBJECTS),
			"resources": _field(index, F_RESOURCES),
			"files_total": _field(index, F_FILES_TOTAL),
			"farm_bytes": _field(index, F_FARM_BYTES),
			"residents_bytes": _field(index, F_RESIDENTS_BYTES),
			"ledger_bytes": _field(index, F_LEDGER_BYTES),
			"issued": _field(index, F_ISSUED),
			"total_cash": _field(index, F_TOTAL_CASH),
		})
	var file := FileAccess.open(base_root.path_join("samples.json"), FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(rows, "\t"))
	file.close()


func _parse_arguments() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--soak-seconds="):
			soak_seconds = int(argument.trim_prefix("--soak-seconds="))
		elif argument.begins_with("--tick-ms="):
			tick_ms = int(argument.trim_prefix("--tick-ms="))
		elif argument.begins_with("--logical-step="):
			logical_step = float(argument.trim_prefix("--logical-step="))
	soak_seconds = clampi(soak_seconds, 1, MAX_SOAK_SECONDS)
	tick_ms = clampi(tick_ms, MIN_TICK_MS, MAX_TICK_MS)
	logical_step = clampf(logical_step, 60.0, 86400.0)


func _run() -> void:
	var directory: String = base_root.path_join(WINDOW_NAME)
	DirAccess.make_dir_recursive_absolute(directory)
	var seeded: Dictionary = NatureStore.new(directory).save_state(
		{"seed": SEED, "rules_version": RULES_VERSION})
	_expect(bool(seeded.get("ok", false)),
		"the fixed seed is persisted before the world opens")
	var world = HeadlessWorld.new()
	var opened: Dictionary = world.open(directory, START, WORLD_ID, HOST)
	_expect(bool(opened.get("ok", false)),
		"the authority opens the world (reason=%s)" % str(opened.get("reason", "")))
	_expect(str(opened.get("kind", "")) == "created", "the directory starts fresh")

	_expect(world.farm.economy_issued() == 0,
		"a fresh world issues no cash before any account or merchant opens")
	_expect(world.farm.economy_total_cash() == 0,
		"a fresh world holds no cash before any account or merchant opens")

	# A real merchant gives residents something to buy; otherwise every sweep
	# answers `no_supply` and the economy never moves. Opening it issues its
	# fixed budget, which becomes part of the measured issued/total identity.
	var market: Dictionary = world.execute(
		FarmCommand.make_market_open("soak-market-open", world.now_utc))
	_expect(bool(market.get("ok", false)),
		"the merchant opens with public asks (reason=%s)"
		% str(market.get("reason", "")))
	_expect(world.farm.economy_issued() == Market.MERCHANT_BUDGET,
		"opening the merchant issues exactly its fixed budget")
	_expect(world.farm.economy_total_cash() == world.farm.economy_issued(),
		"total cash equals issued after the merchant opens")
	world.enable_residents()
	_expect(world.residents_enabled, "the authority enables residents")
	_expect(ResidentLedger.valid(world.residents), "the resident ledger starts valid")
	_expect(Social.valid(world.resident_social), "the relation document starts valid")
	_expect(bool(Memory.validate_document(world.resident_memories, START).ok),
		"the memory document starts valid")
	_expect(ResidentsStore.valid_invitations(world.resident_invitations),
		"the invitation table starts valid")
	_expect(ResidentsStore.valid_dialogues(world.resident_dialogues),
		"the dialogue table starts valid")

	# Wall-clock loop. `deadline_ms` is the only thing that decides when the
	# soak ends; the logical clock advances by `logical_step` per tick, so the
	# same duration always reaches the same logical day.
	var expected_ticks: int = maxi(1, soak_seconds * 1000 / tick_ms)
	var sample_every: int = maxi(MIN_SAMPLE_EVERY_TICKS,
		(expected_ticks + MAX_SAMPLES - 1) / MAX_SAMPLES)
	var started_ms: int = Time.get_ticks_msec()
	var deadline_ms: int = started_ms + soak_seconds * 1000
	var tick: int = 0
	while Time.get_ticks_msec() < deadline_ms:
		var tick_started_ms: int = Time.get_ticks_msec()
		world = _tick(world, tick)
		tick += 1
		if tick % sample_every == 0 or Time.get_ticks_msec() >= deadline_ms:
			_sample(world, directory, tick,
				Time.get_ticks_msec() - started_ms)
		# Sleep only the remainder of the tick budget. A slow tick (large
		# save) borrows from the next one instead of piling up.
		var spent_ms: int = Time.get_ticks_msec() - tick_started_ms
		var remaining_ms: int = tick_ms - spent_ms
		if remaining_ms > 0:
			OS.delay_msec(remaining_ms)

	_expect(tick > 0, "the wall-clock loop ran at least one tick")
	_expect(Time.get_ticks_msec() - started_ms >= soak_seconds * 1000,
		"the loop ran for at least the requested wall-clock duration")
	# Guarantee at least one sample even for a very short requested duration.
	if sample_count == 0:
		_sample(world, directory, tick, Time.get_ticks_msec() - started_ms)
	# The loop and the restart below both run inside the CI watchdog; report the
	# sampling cadence so a slow host cannot silently grow the buffer.
	print("SOAK ticks=%d sample_every=%d samples=%d logical_step=%.0f"
		% [tick, sample_every, sample_count, logical_step])

	_measure_curves()
	_check_final_state(world)
	_check_restart(world, directory)


## One tick against the authoritative world. The world instance is not replaced
## anywhere in this fixture; returning it keeps the loop's single source clear.
func _tick(world, tick: int):
	var target: float = world.now_utc + logical_step
	var advanced: Dictionary = world.advance_to(target)
	_expect(bool(advanced.get("ok", false)),
		"tick %d: advance to the next logical step (reason=%s)"
		% [tick, str(advanced.get("reason", ""))])
	var changed_fields: Array = advanced.get("changed_fields", [])
	var economy_events: int = int(advanced.get("market_expired", 0)) \
		+ int(advanced.get("market_matched", 0)) \
		+ int(advanced.get("market_delivered", 0)) \
		+ int(advanced.get("market_lost", 0)) \
		+ int(advanced.get("loans_settled", 0))
	# Same policy as `world_server.gd`: persist growth only when something
	# actually changed, so an idle world does not rewrite the document every
	# tick and inflate the measured file bytes.
	if not changed_fields.is_empty() or economy_events > 0:
		var saved: Dictionary = world.save()
		_expect(bool(saved.get("ok", false)),
			"tick %d: the changed growth state saves (reason=%s)"
			% [tick, str(saved.get("reason", ""))])

	var settled: Dictionary = world.settle_economy_now(world.now_utc)
	_expect(bool(settled.get("ok", false)),
		"tick %d: the economy and resident sweep succeeds (reason=%s)"
		% [tick, str(settled.get("reason", ""))])
	_expect(world.farm.economy_total_cash() == world.farm.economy_issued(),
		"tick %d: total cash equals issued after the sweep" % tick)
	_expect(bool(world.farm.economy_reconcile().get("ok", false)),
		"tick %d: the ledger reconciles after the sweep" % tick)
	_check_resident_bounds(world, "tick %d" % tick)
	# A same-instant replay must be a no-op. This is the same call the live
	# server makes at its own clock, so it also proves the sweep is idempotent
	# between two wall-clock ticks that land in the same logical second.
	var replay: Dictionary = world.settle_economy_now(world.now_utc)
	_expect(bool(replay.get("ok", false)) and not bool(replay.get("changed", true)),
		"tick %d: a same-instant sweep changes nothing" % tick)
	return world


func _sample(world, directory: String, tick: int, elapsed_ms: int) -> void:
	var files: Dictionary = _measure_files(directory)
	var reconcile: Dictionary = world.farm.economy_reconcile()
	var static_bytes: int = OS.get_static_memory_usage()
	# Godot 4.7.2 has no `OS.get_dynamic_memory_usage()`; report -1 rather than
	# invent a number, and keep the object/resource counts as the non-allocator
	# leak signal.
	var dynamic_bytes: int = int(OS.call("get_dynamic_memory_usage")) \
		if OS.has_method("get_dynamic_memory_usage") else -1
	# The cadence above already bounds the count. If a host still produces more
	# samples (for example an unexpectedly fast loop), extra records are dropped:
	# the buffer is preallocated and fixed, and dropping keeps the first-third /
	# last-third curve comparison intact.
	if sample_count < MAX_SAMPLES:
		var base: int = sample_count * SAMPLE_FIELDS
		sample_data[base + F_TICK] = tick
		sample_data[base + F_ELAPSED_MS] = elapsed_ms
		sample_data[base + F_STATIC_BYTES] = static_bytes
		sample_data[base + F_DYNAMIC_BYTES] = dynamic_bytes
		sample_data[base + F_OBJECTS] = int(
			Performance.get_monitor(Performance.OBJECT_COUNT))
		sample_data[base + F_RESOURCES] = int(
			Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
		sample_data[base + F_FILES_TOTAL] = int(files.total)
		sample_data[base + F_FARM_BYTES] = int(files.get("farm.json", 0))
		sample_data[base + F_RESIDENTS_BYTES] = int(files.get("residents.json", 0))
		sample_data[base + F_LEDGER_BYTES] = int(
			files.get("npc_residents.json", 0))
		sample_data[base + F_TOTAL_CASH] = world.farm.economy_total_cash()
		sample_data[base + F_ISSUED] = world.farm.economy_issued()
		sample_count += 1
		_expect(sample_data[base + F_TOTAL_CASH] == sample_data[base + F_ISSUED],
			"sample tick %d: total cash equals issued" % tick)
	_expect(bool(reconcile.get("ok", false)),
		"sample tick %d: the ledger reconciles" % tick)
	_check_documents(world, "sample tick %d" % tick)


func _field(index: int, field: int) -> int:
	if index < 0 or index >= sample_count:
		return 0
	return sample_data[index * SAMPLE_FIELDS + field]


## Document-level validity at every sample, not only at the end. This is the
## periodic version of the final validator pass: a soak should notice a document
## that stopped being valid long before it exits.
func _check_documents(world, label: String) -> void:
	var economy: Dictionary = world.farm.economy_snapshot()
	_expect(Economy.valid(economy), "%s: the economy document is valid" % label)
	_expect(Market.valid(economy), "%s: the market document is valid" % label)
	_expect(Ledger.valid(economy.ledger), "%s: the journal is valid" % label)
	_expect(NatureState.new().restore_snapshot(world.nature.snapshot()),
		"%s: the nature snapshot restores" % label)
	_expect(TerritoryState.valid(world.territory), "%s: the cadastre is valid" % label)
	_expect(Participation.valid(world.participation),
		"%s: the participation document is valid" % label)
	_expect(UnitState.valid(world.units), "%s: the unit document is valid" % label)
	_expect(PublicFund.valid(world.funds), "%s: the fund document is valid" % label)
	_expect(PublicWorks.valid(world.public_works),
		"%s: the public-works document is valid" % label)
	_expect(Organization.valid(world.organizations),
		"%s: the organization document is valid" % label)
	_expect(Disputes.valid(world.disputes), "%s: the dispute document is valid" % label)


## File bytes are measured from the world directory as the product writes them:
## main documents, sidecars and their backups. Pending files do not survive a
## successful save, so they are absent here.
func _measure_files(directory: String) -> Dictionary:
	var result: Dictionary = {"total": 0}
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		return result
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while not name.is_empty():
		if not dir.current_is_dir():
			var file := FileAccess.open(directory.path_join(name), FileAccess.READ)
			if file != null:
				result[name] = file.get_length()
				result.total = int(result.total) + file.get_length()
				file.close()
		name = dir.get_next()
	dir.list_dir_end()
	return result


## The first third and last third of the samples must not grow without bound.
## The tolerance is absolute, not relative, because both the document and the
## engine's static memory have their own fixed working set; a per-run
## multiplier would hide a constant leak in a short run and fail a cold-start
## run. Limits are measured from the observed curves (M13-02 RECORD-12):
##   - world files: the ledger/social documents grow by one bounded row per
##     resident action until each table hits its capacity, so the first third
##     already holds most of the growth. 256 KiB covers formatting and row
##     variance across 10 minutes.
##   - engine static memory: the first minutes load scenes and allocators, so
##     comparing first vs last third is noisy; 8 MiB covers the observed
##     plateau. The object/resource counts are reported to distinguish real
##     object leaks from allocator noise.
const FILE_GROWTH_TOLERANCE_BYTES: int = 262144
const MEMORY_GROWTH_TOLERANCE_BYTES: int = 8 * 1048576


func _measure_curves() -> void:
	_expect(sample_count >= 2, "the soak recorded at least two samples")
	if sample_count < 2:
		return
	# First third vs last third of the recorded samples. Both windows always
	# contain at least one sample (sample_count >= 2 means third >= 1).
	var third: int = sample_count / 3
	var first_from: int = 0
	var first_to: int = third
	var last_from: int = sample_count - third
	var last_to: int = sample_count
	var first_files: int = _max_field(first_from, first_to, F_FILES_TOTAL)
	var last_files: int = _max_field(last_from, last_to, F_FILES_TOTAL)
	var first_mem: int = _max_field(first_from, first_to, F_STATIC_BYTES)
	var last_mem: int = _max_field(last_from, last_to, F_STATIC_BYTES)
	var first_objects: int = _max_field(first_from, first_to, F_OBJECTS)
	var last_objects: int = _max_field(last_from, last_to, F_OBJECTS)
	_expect(last_files - first_files <= FILE_GROWTH_TOLERANCE_BYTES,
		"world files do not grow without bound (%d -> %d, tolerance %d)"
		% [first_files, last_files, FILE_GROWTH_TOLERANCE_BYTES])
	_expect(last_mem - first_mem <= MEMORY_GROWTH_TOLERANCE_BYTES,
		"engine static memory does not grow without bound (%d -> %d, tolerance %d)"
		% [first_mem, last_mem, MEMORY_GROWTH_TOLERANCE_BYTES])
	# Object count is the leak signal that is not allocator noise. The world
	# creates no Nodes after opening, so a bounded count across the run is the
	# expected result.
	_expect(last_objects - first_objects <= 64,
		"the engine object count stays bounded (%d -> %d)" % [first_objects, last_objects])
	var first_median: int = _median_field(first_from, first_to, F_FILES_TOTAL)
	var last_median: int = _median_field(last_from, last_to, F_FILES_TOTAL)
	# The medians are reported next to the maxima, but the bound is asserted on
	# the maximum: an unbounded growth raises the late-window maximum first,
	# while the median of the 30-second default run still sits inside the
	# initial fill (the relation document grows through its first rows and then
	# plateaus). A median gate there would be almost no headroom and would fail
	# on a host that covers more logical hours, which is noise, not a leak.
	print("CURVE files_max_first=%d files_max_last=%d files_median_first=%d "
		% [first_files, last_files, first_median]
		+ "files_median_last=%d mem_max_first=%d mem_max_last=%d "
		% [last_median, first_mem, last_mem]
		+ "objects_first=%d objects_last=%d samples=%d"
		% [first_objects, last_objects, sample_count])


## Max of one field over the sample index range `[from, to)`. The buffer is
## fixed and preallocated, so this allocates nothing per call.
func _max_field(from: int, to: int, field: int) -> int:
	var result: int = 0
	for index: int in range(from, to):
		result = maxi(result, _field(index, field))
	return result


func _median_field(from: int, to: int, field: int) -> int:
	if to - from <= 0:
		return 0
	var values: PackedInt64Array = PackedInt64Array()
	values.resize(to - from)
	for offset: int in range(to - from):
		values[offset] = _field(from + offset, field)
	values.sort()
	return values[values.size() / 2]


## The sample holding the peak static memory, or 0 before any sample exists.
func _peak_sample_index() -> int:
	var peak: int = 0
	for index: int in range(1, sample_count):
		if _field(index, F_STATIC_BYTES) > _field(peak, F_STATIC_BYTES):
			peak = index
	return peak


func _check_resident_bounds(world, label: String) -> void:
	_expect(ResidentLedger.valid(world.residents),
		"%s: the resident intent ledger stays valid" % label)
	for npc_id: String in NpcRoster.IDS:
		var state: Dictionary = ResidentLedger.state_for(world.residents, npc_id)
		_expect(IntentState.valid(state),
			"%s: %s's intent state stays valid" % [label, npc_id])
		_expect((state.intents as Dictionary).size() <= IntentState.MAX_RECORDS,
			"%s: %s's intent ledger stays within MAX_RECORDS" % [label, npc_id])
		var memory_row: Dictionary = world.resident_memories.npcs.get(npc_id, {})
		_expect((memory_row.get("entries", {}) as Dictionary).size() <= Memory.MAX_ENTRIES,
			"%s: %s's memory stays within MAX_ENTRIES" % [label, npc_id])
	_expect(Social.valid(world.resident_social),
		"%s: the relation document stays valid" % label)
	for from_id: String in world.resident_social.relations:
		for peer: Variant in world.resident_social.relations[from_id]:
			var row: Dictionary = world.resident_social.relations[from_id][peer]
			_expect((row.acts as Dictionary).size() <= Social.MAX_ACTS_PER_PEER,
				"%s: %s -> %s acts stay within MAX_ACTS_PER_PEER"
				% [label, from_id, str(peer)])
			_expect((row.gifts_utc as Array).size() <= Social.MAX_GIFTS_PER_PEER,
				"%s: %s -> %s gifts stay within MAX_GIFTS_PER_PEER"
				% [label, from_id, str(peer)])
	_expect(world.resident_invitations.size() <= ResidentsStore.MAX_INVITATIONS,
		"%s: the invitation table stays within MAX_INVITATIONS" % label)
	_expect(ResidentsStore.valid_invitations(world.resident_invitations),
		"%s: the invitation table stays valid" % label)
	_expect(world.resident_dialogues.size() <= ResidentsStore.MAX_DIALOGUE_PLAYERS,
		"%s: the dialogue table stays within MAX_DIALOGUE_PLAYERS" % label)
	_expect(ResidentsStore.valid_dialogues(world.resident_dialogues),
		"%s: the dialogue table stays valid" % label)


func _check_final_state(world) -> void:
	var now: float = world.now_utc
	_expect(world.farm.economy_total_cash() == world.farm.economy_issued(),
		"final: total cash equals issued after %.1f logical hours"
		% ((now - START) / 3600.0))
	_expect(bool(world.farm.economy_reconcile().get("ok", false)),
		"final: the double-entry ledger reconciles")
	_expect(Economy.valid(world.farm.economy_snapshot()),
		"final: the economy document is valid")
	_expect(Market.valid(world.farm.economy_snapshot()),
		"final: the market document is valid")
	_expect(world.farm.economy_ledger_entries().size() <= Ledger.MAX_ENTRIES,
		"final: journal entries stay within MAX_ENTRIES")
	_expect(world.farm.market_orders().size() <= Market.MAX_ORDERS,
		"final: market orders stay within MAX_ORDERS")
	_expect(world.farm.market_trades().size() <= Market.MAX_TRADES,
		"final: market trades stay within MAX_TRADES")
	_expect(FarmState.new().restore_snapshot(world.farm.snapshot()),
		"final: the farm snapshot restores from its own saved shape")
	_expect(NatureState.new().restore_snapshot(world.nature.snapshot()),
		"final: the nature snapshot restores")
	_expect(TerritoryState.valid(world.territory), "final: the cadastre is valid")
	_expect(Organization.valid(world.organizations), "final: organizations are valid")
	_expect(PublicFund.valid(world.funds), "final: funds are valid")
	_expect(PublicWorks.valid(world.public_works), "final: public works are valid")
	_expect(Participation.valid(world.participation), "final: participation is valid")
	_expect(Disputes.valid(world.disputes), "final: disputes are valid")
	_expect(UnitState.valid(world.units), "final: units are valid")
	_expect(ResidentLedger.valid(world.residents), "final: the resident ledger is valid")
	_expect(Social.valid(world.resident_social), "final: the relation document is valid")
	_expect(bool(Memory.validate_document(world.resident_memories, now).ok),
		"final: the memory document is valid")
	_expect(ResidentsStore.valid_state({
		"social": world.resident_social, "memories": world.resident_memories,
		"invitations": world.resident_invitations,
		"dialogues": world.resident_dialogues,
	}, WORLD_ID, now), "final: the residents sidecar envelope is valid")
	# An empty conflict context is the documented "not engaged yet" shape; it
	# cannot pass `valid_context()` because participation is intentionally
	# empty until the first engagement. Assert it is still the initial shape
	# instead of asserting a validator that is known to reject it.
	_expect(str(world.conflicts.get("world_id", "")) == WORLD_ID
		and (world.conflicts.get("consumed", {}) as Dictionary).is_empty(),
		"final: the untouched conflict context is still the initial shape")
	_check_resident_bounds(world, "final")
	# The tail restart happens once, after all samples. It proves the persisted
	# world reloads into the same fingerprint and that a replay at the same
	# logical instant still changes nothing.
	print("FINAL now_utc=%.0f cash_issued=%d final_total=%d logical_hours=%.1f"
		% [now, world.farm.economy_issued(), world.farm.economy_total_cash(),
		(now - START) / 3600.0])


func _check_restart(world, directory: String) -> void:
	var fingerprint: String = _world_fingerprint(world)
	var save_result: Dictionary = world.save()
	_expect(bool(save_result.get("ok", false)),
		"restart: the final state saves before reopening")
	var reopened = HeadlessWorld.new()
	var opened: Dictionary = reopened.open(directory, world.now_utc, WORLD_ID, HOST)
	_expect(bool(opened.get("ok", false)),
		"restart: the authority reopens the world (reason=%s)"
		% str(opened.get("reason", "")))
	_expect(str(opened.get("kind", "")) == "loaded", "restart: the directory loads")
	reopened.enable_residents()
	var reopened_fingerprint: String = _world_fingerprint(reopened)
	_expect(reopened_fingerprint == fingerprint,
		"restart: the reloaded documents match the live fingerprint")
	# The same logical instant must not settle a second resident action.
	var sweep: Dictionary = reopened.settle_economy_now(reopened.now_utc)
	_expect(bool(sweep.get("ok", false)),
		"restart: a sweep after reopening succeeds (reason=%s)"
		% str(sweep.get("reason", "")))
	_expect(not bool(sweep.get("changed", true)),
		"restart: a sweep at the same logical instant changes nothing")
	_expect(_world_fingerprint(reopened) == fingerprint,
		"restart: the replayed sweep leaves every document unchanged")
	_expect(reopened.farm.economy_total_cash() == reopened.farm.economy_issued(),
		"restart: total cash equals issued after reopening")
	print("RESTART fingerprint=%s reopened=%s equal=%s changed=%s"
		% [fingerprint, reopened_fingerprint, str(reopened_fingerprint == fingerprint),
		str(sweep.get("changed", true))])


## Fingerprint over every durable document and the logical instant. Directory
## names, wall time and the session-only result windows are excluded, so the
## same persisted world must reproduce the same string after a restart.
func _world_fingerprint(world) -> String:
	var document: Dictionary = {
		"now_utc": world.now_utc,
		"farm": world.farm.snapshot(),
		"economy": world.farm.economy_snapshot(),
		"nature": world.nature.snapshot(),
		"territory": world.territory,
		"organizations": world.organizations,
		"funds": world.funds,
		"public_works": world.public_works,
		"participation": world.participation,
		"disputes": world.disputes,
		"units": world.units,
		"conflicts": world.conflicts,
		"residents": world.residents,
		"social": world.resident_social,
		"memories": world.resident_memories,
		"invitations": world.resident_invitations,
		"dialogues": world.resident_dialogues,
	}
	return JSON.stringify(document).sha256_text().substr(0, 16)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
