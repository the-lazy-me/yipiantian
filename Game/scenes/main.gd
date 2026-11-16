extends Node3D

signal farm_changed(result: Dictionary)
signal startup_finished
var startup_progress: Callable
var startup_preferences: Dictionary = {}
var startup_complete: bool = false

const Crops = preload("res://farm/crop_catalog.gd")
const ToolCursor = preload("res://ui/tool_cursor.gd")
const FieldMenu = preload("res://ui/field_menu.gd")
var field_menu: FieldMenu
var _menu_target: Dictionary = {}
const FarmState = preload("res://farm/farm_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const NatureState = preload("res://farm/nature_state.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const OwnerIds = preload("res://farm/owner_id.gd")
const DecorationState = preload("res://farm/decoration_state.gd")
const DecorationLayout = preload("res://scenes/decoration_layout.gd")
const FarmAudio = preload("res://audio/farm_audio.gd")
const DayNight = preload("res://atmosphere/day_night.gd")
const WeatherAtmosphere = preload("res://presentation/weather_atmosphere.gd")
const DisasterMood = preload("res://presentation/disaster_mood.gd")
const WindowActivity = preload("res://atmosphere/window_activity.gd")
const TrellisCrops=preload("res://presentation/trellis_crops.gd")
const TrellisSlots=preload("res://layout/trellis_slots.gd")
const FocusDetail = preload("res://presentation/focus_detail.gd")
const HUD = preload("res://scenes/farm_hud.gd")
const SettingsStore = preload("res://settings/settings_store.gd")
const GameMenu = preload("res://ui/game_menu.gd")
const PlayerProfile = preload("res://social/player_profile.gd")
const WorldTransfer = preload("res://farm/world_transfer.gd")
const WorldClient = preload("res://world/world_client.gd")
const TerritoryState = preload("res://world/territory_state.gd")
const SocialPanel = preload("res://ui/social_panel.gd")
const BuildPanel = preload("res://ui/build_panel.gd")
const MarketPanel = preload("res://ui/market_panel.gd")
const BankPanel = preload("res://ui/bank_panel.gd")
const GovernancePanel = preload("res://ui/governance_panel.gd")
const UnitPanel = preload("res://ui/unit_panel.gd")
const FundPanel = preload("res://ui/fund_panel.gd")
const ParticipationPanel = preload("res://ui/participation_panel.gd")
const PublicWorksPanel = preload("res://ui/public_works_panel.gd")
const PublicWorksView = preload("res://scenes/environment/public_works_view.gd")
const ConflictPanel = preload("res://ui/conflict_panel.gd")
const DisputePanel = preload("res://ui/dispute_panel.gd")
const ResidentPanel = preload("res://ui/resident_panel.gd")
const DialoguePanel = preload("res://ui/dialogue_panel.gd")
const ResolutionsPanel = preload("res://ui/resolutions_panel.gd")
const Loans = preload("res://farm/loan_state.gd")
const BuildingCatalog = preload("res://farm/building_catalog.gd")
const HousingView = preload("res://scenes/environment/housing_view.gd")
const DesktopWallpaper = preload("res://platform/desktop_wallpaper.gd")
const WallpaperHint = preload("res://ui/wallpaper_hint.gd")
## Economy entries return this named refusal while the last local save failed.
## They resume once a later save succeeds and clears the flag in `_save_farm`.
const SAVE_FAILED_REASON: String = "save_failed"
var wallpaper_hint: WallpaperHint
var desktop_wallpaper: DesktopWallpaper
var _wallpaper_issue: String = ""
var _wallpaper_click: Vector2 = Vector2.INF
var _wallpaper_injecting: bool = false
var _wallpaper_buttons: int = 0
var _wallpaper_entry: String = ""
var _wallpaper_layers: Array[CanvasLayer] = []
var _wallpaper_press: Vector2 = Vector2.INF
var _restore_before_exit: bool = false
const CameraTuning = preload("res://ui/camera_tuning.gd")
const CourtyardPlan = preload("res://layout/courtyard_plan.gd")
const CourtyardEditSession = preload("res://layout/courtyard_edit_session.gd")
const HarvestBook = preload("res://ui/harvest_book.gd")
const KitchenDisplay=preload("res://presentation/kitchen_display.gd")
const AnimalPanel=preload("res://ui/animal_panel.gd")
const GardenAlbum=preload("res://presentation/garden_album.gd")
const SeasonalCourtyard=preload("res://presentation/seasonal_courtyard.gd")
var seasonal_courtyard: SeasonalCourtyard
var garden_album: GardenAlbum
var animal_panel: AnimalPanel
var _pressed_animal: String=""
var _pressed_entry: String=""
var kitchen_display: KitchenDisplay
var harvest_book: HarvestBook
var courtyard_plan := CourtyardPlan.new()
var courtyard_edit: CourtyardEditSession
const IslandBuilder=preload("res://ui/island_builder.gd")
var island_builder: IslandBuilder
var _construction_resume: Dictionary = {}
# One-step undo is session history, carried across a spatial scene rebuild.
# It reverses layout only, never harvests, elapsed growth or subsequent planting.
var previous_layout: Dictionary = {}
var previous_decorations: Dictionary = {}
var _presentation_resume: Dictionary = {}

@onready var farm: FarmLayout = $Farm
@onready var camera: FarmCamera = $Camera3D
# One clock boundary: tests inject a callable before adding the scene to the tree.
var clock: Callable = Time.get_unix_time_from_system
var farm_state: FarmState
var farm_commands := FarmCommand.new()
var decoration_state: DecorationState
var decoration_layout: DecorationLayout
var farm_audio: FarmAudio
var atmosphere: DayNight
var weather_atmosphere: WeatherAtmosphere
## Last kind actually applied to the presentation; repeated ticks compare and
## skip, so a settle tick never rebuilds rain or re-blends the lighting.
var _weather_kind: String = ""
## Last current disaster applied to presentation; warnings never reach the
## visual nodes and empty means no current event.
var _disaster_kind: String = ""
var window_activity: WindowActivity
var trellis_crops: TrellisCrops
var focus_detail: FocusDetail
var store: FarmStore
## The local world reads the same independent nature document as the authority,
## so weather history is one fact in every mode. The seed is written before the
## first farm commit; a present but unreadable document refuses to load.
var nature_store: NatureStore
var nature_state: NatureState
var _nature_persisted: bool = false
## Set when the nature document is damaged but a validated backup exists. The
## storage overlay then offers the same explicit recovery as the farm; loading
## itself never rolls back to the backup.
var _nature_recovery_available: bool = false
var hud: HUD
var settings_store: SettingsStore
var game_menu: GameMenu
var settings_values: Dictionary = {}
var _settings_dirty: bool = false
var _high_quality_pending: bool = false
var _settings_issue: String = ""
var _allow_leave_settings: bool = false
var selected_field: int = -1
var selected_cell: String = ""
var selected_palette: String = ""
var selected_tool: String = ""
var selected_crop: String = "greens"
var hover_field: int = -1
var hover_cell: String = ""
var _pointer_position := Vector2(-100, -100)
var tool_cursor: ToolCursor
var sway_tuning: PanelContainer
var camera_tuning: CameraTuning
var _dragging: bool = false
var _orbit_button: MouseButton = MOUSE_BUTTON_NONE
var _orbit_travel: float = 0.0
var _view_dirty: bool = false
var _press_position := Vector2.INF
var _press_dragged: bool = false
var _pressed_field: int = -1
var _pressed_cell: String = ""
var _press_context: Dictionary = {}
var _tool_press: Dictionary = {}
var _picks: Array[Dictionary] = []
var _loaded: bool = false
var _save_failed: bool = false
var _record_session: String = ""
var _exiting: bool = false
var _startup_state: Dictionary = {}
var _startup_admitted: bool = false
var _dev_wallpaper: bool = false
var _pending_world_import: Dictionary = {}
## Set by the startup scene before this scene enters the tree. In this mode the
## world is authoritative: the farm scene renders what the authority sends and
## never writes a local save, so two clients cannot fork one world.
var remote: WorldClient
var remote_seed: Dictionary = {}
## Set by the startup scene when this session opened its own room. The authority
## process was started by the game, so leaving the farm closes it.
var hosted_room: RefCounted
## Commands waiting for an authoritative reply, by request id. The scene applies
## one only after the authority acknowledges it, never on the click alone.
var _remote_pending: Dictionary = {}
## Fixed-id economy commands (account, merchant, bank opening) kept verbatim so a
## retry replays as the same duplicate instead of a new timestamp that the
## authority would refuse as a payload conflict.
var _remote_fixed_commands: Dictionary = {}
## Set once the authority accepts this member's account opening, so the market
## can send the merchant opening next instead of racing two commands whose
## shared precondition would go stale.
var _remote_account_ack: bool = false
## ADR-027: a projected summary may omit this player's own bag until the
## authority has one. Warn once per absence instead of repeating it every
## reconcile; a delivered bag resets the flag.
var _remote_bag_notice_shown: bool = false
var social_panel: SocialPanel
var build_panel: BuildPanel
var market_panel: MarketPanel
var bank_panel: BankPanel
var governance_panel: GovernancePanel
var unit_panel: UnitPanel
var fund_panel: FundPanel
var participation_panel: ParticipationPanel
var public_works_panel: PublicWorksPanel
var conflict_panel: ConflictPanel
var dispute_panel: DisputePanel
var resident_panel: ResidentPanel
var dialogue_panel: DialoguePanel
var resolutions_panel: ResolutionsPanel
## Set by the startup scene before this scene enters the tree. Singleplayer uses
## it for the player's own bag and economy account; a joined world supplies its
## own authoritative id.
var local_player_id: String = ""
## Only the shared world has yard slots, so this node is created in _adopt_remote.
var housing_view: HousingView
## Built public projects share the same yard slots; created with housing_view.
var public_works_view: PublicWorksView
## 我自己是否开放了偷菜：来自权威的社交回复与命令回执，面板只负责展示。
var _theft_on: bool = false


func _enter_tree() -> void:
	if remote != null:
		# The world's own layout decides which island this client builds. Reading
		# the local save here would build the courtyard of a different world.
		_startup_admitted = true
		courtyard_plan = CourtyardPlan.from_snapshot(remote_seed.farm.snapshot().layout)
	else:
		_startup_admitted = _prepare_stores()
	if remote == null and _startup_admitted:
		_startup_state = store.load_state()
		if _startup_state.ok and _startup_state.kind == "loaded":
			courtyard_plan = CourtyardPlan.from_snapshot(_startup_state.farm.layout)
			$Environment.decoration_data = _startup_state.decorations
	# Children build their geometry in _ready; share one plan before that happens.
	$Environment.startup_progress = startup_progress
	$Environment.plan = courtyard_plan
	$Farm.plan = courtyard_plan
	$Camera3D.configure_layout(courtyard_plan.camera_point, courtyard_plan.camera_distance)

func _prepare_stores() -> bool:
	# Recording is explicitly isolated before any player-state load. A release package
	# does not carry the recording implementation and refuses its launch parameter.
	for argument in OS.get_cmdline_user_args():
		if argument == "--dev-wallpaper":
			_dev_wallpaper = true
		if argument.begins_with("--record-session="):
			if not OS.has_feature("editor"):
				push_error("Development recording arguments are unavailable in this build.")
				get_tree().quit(1)
				return false
			_record_session = argument.trim_prefix("--record-session=").simplify_path()
			var allowed: String = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join(".local/recordings")
			if not _record_session.is_absolute_path() or not _record_session.replace("\\", "/").begins_with(allowed.replace("\\", "/") + "/"):
				push_error("Recording session must be inside the project's isolated recording directory.")
				get_tree().quit(1)
				return false
			store = FarmStore.new(_record_session.path_join("farm"))
			settings_store = SettingsStore.new(_record_session.path_join("preferences"))
	if store == null:
		store = FarmStore.new()
	return true

func _ready() -> void:
	if not _startup_admitted: return
	if startup_progress.is_valid():
		if not $Environment.initialized: await $Environment.initialization_finished
		await startup_progress.call(80.0, "正在恢复农田与作物…")
	get_tree().auto_accept_quit = false
	get_window().min_size = Vector2i(960, 600)
	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)
	field_menu = FieldMenu.new()
	field_menu.name = "FieldMenu"
	add_child(field_menu)
	field_menu.action_requested.connect(_field_menu_action)
	hud.tool_press_started.connect(_start_tool_press)
	hud.tool_requested.connect(_finish_tool_press)
	hud.crop_requested.connect(_select_crop)
	hud.cancel_tool_requested.connect(_cancel_tool)
	hud.palette_requested.connect(_open_palette)
	harvest_book=HarvestBook.new()
	kitchen_display=KitchenDisplay.new()
	kitchen_display.name="KitchenDisplay"
	add_child(kitchen_display)
	kitchen_display.configure($Environment)
	harvest_book.name="HarvestBook"
	add_child(harvest_book)
	hud.basket_requested.connect(_open_basket)
	harvest_book.closed.connect(func() -> void:
		camera.free_input_enabled=true
		_cancel_input()
		_refresh_hud())
	harvest_book.share_requested.connect(func(id: String, visit: int, basket: Dictionary) -> void: _exchange(id,visit,basket,""))
	harvest_book.gift_requested.connect(func(id: String, visit: int, crop: String) -> void: _exchange(id,visit,{},crop))
	harvest_book.view_requested.connect(_view_neighbor)
	harvest_book.kitchen_requested.connect(_kitchen_action)
	harvest_book.construction_requested.connect(func(id: String) -> void:
		harvest_book.dismiss();_begin_construction(id))
	harvest_book.season_requested.connect(_change_season)
	harvest_book.kitchen_view_requested.connect(func(station: String) -> void:
		var framing: Dictionary
		if station=="garden_rack":
			var rack: Node3D=decoration_layout._instances.get("drying_rack")
			if not is_instance_valid(rack): harvest_book.end_view();return
			framing={"subject":rack,"point":rack.global_position+Vector3.UP*.65,"view":Vector3(22,34,5.5)}
		else: framing=kitchen_display.viewpoint(station)
		focus_detail.protect_neighbor(framing.subject)
		camera.view_neighbor(framing.point,framing.view)
		hud.hide())
	harvest_book.view_closed.connect(func() -> void:
		camera.leave_neighbor()
		hud.show())
	tool_cursor = ToolCursor.new()
	animal_panel=AnimalPanel.new()
	animal_panel.name="AnimalPanel"
	add_child(animal_panel)
	animal_panel.action_requested.connect(_animal_action)
	animal_panel.closed.connect(func() -> void:
		camera.leave_neighbor()
		hud.show()
		_cancel_input()
		_refresh_hud())
	add_child(tool_cursor)
	hud.retry_requested.connect(_retry_storage)
	hud.recovery_requested.connect(_recover_storage)
	hud.exit_requested.connect(_finish_exit)
	hud.settings_requested.connect(_open_menu)
	market_panel = MarketPanel.new()
	market_panel.name = "Market"
	add_child(market_panel)
	market_panel.order_requested.connect(_market_order)
	market_panel.cancel_requested.connect(_market_cancel)
	market_panel.ship_requested.connect(_market_ship)
	market_panel.deliver_requested.connect(_market_deliver)
	market_panel.refresh_requested.connect(_market_refresh)
	market_panel.closed.connect(func() -> void:
		camera.free_input_enabled = true
		_cancel_input()
		_refresh_hud())
	hud.market_requested.connect(_open_market)
	bank_panel = BankPanel.new()
	bank_panel.name = "Bank"
	add_child(bank_panel)
	bank_panel.open_requested.connect(_bank_open_requested)
	bank_panel.borrow_requested.connect(_bank_borrow)
	bank_panel.repay_requested.connect(_bank_repay)
	bank_panel.refresh_requested.connect(_bank_refresh)
	bank_panel.closed.connect(func() -> void:
		camera.free_input_enabled = true
		_cancel_input()
		_refresh_hud())
	hud.bank_requested.connect(_open_bank_panel)
	governance_panel = GovernancePanel.new()
	governance_panel.name = "Governance"
	add_child(governance_panel)
	governance_panel.org_action.connect(_governance_action)
	governance_panel.refresh_requested.connect(_governance_refresh)
	governance_panel.closed.connect(func() -> void:
		camera.free_input_enabled = true
		_cancel_input()
		_refresh_hud())
	hud.organization_requested.connect(_open_governance)
	# 单位面板是 Control；挂到 HUD 这一 CanvasLayer 下才能盖住工具栏按钮。
	# 名册与动作全部来自权威，面板只负责显示和转发意图。
	unit_panel = UnitPanel.new()
	unit_panel.name = "Units"
	hud.add_child(unit_panel)
	unit_panel.unit_action.connect(_unit_action)
	unit_panel.refresh_requested.connect(_unit_refresh)
	unit_panel.closed.connect(func() -> void:
		camera.free_input_enabled = true
		_cancel_input()
		_refresh_hud())
	hud.unit_requested.connect(_open_units)
	if remote != null:
		remote.unit_result.connect(unit_panel.apply_result)
	# 公共基金面板与单位面板同型：挂在 HUD 这一 CanvasLayer 下，视图来自权威，
	# 面板只负责显示并转发意图。
	fund_panel = FundPanel.new()
	fund_panel.name = "Funds"
	hud.add_child(fund_panel)
	fund_panel.fund_action.connect(_fund_action)
	fund_panel.refresh_requested.connect(_fund_refresh)
	fund_panel.closed.connect(func() -> void:
		camera.free_input_enabled = true
		_cancel_input()
		_refresh_hud())
	hud.fund_requested.connect(_open_funds)
	if remote != null:
		remote.fund_result.connect(fund_panel.apply_result)
	# 参与制度面板同型：视图来自权威，面板只显示并转发意图；房主区与玩家区
	# 由面板根据视图里的 host 与当前玩家 id 决定是否出现。
	participation_panel = ParticipationPanel.new()
	participation_panel.name = "Participation"
	hud.add_child(participation_panel)
	participation_panel.participation_action.connect(_participation_action)
	participation_panel.refresh_requested.connect(_participation_refresh)
	participation_panel.closed.connect(func() -> void:
		camera.free_input_enabled = true
		_cancel_input()
		_refresh_hud())
	hud.participation_requested.connect(_open_participation)
	if remote != null:
		remote.participation_result.connect(participation_panel.apply_result)
	# 公共项目面板同型：项目视图来自权威，面板只显示并转发意图；能否登记、
	# 承诺、退回或建成由权威裁决。
	public_works_panel = PublicWorksPanel.new()
	public_works_panel.name = "PublicWorks"
	hud.add_child(public_works_panel)
	public_works_panel.public_works_action.connect(_public_works_action)
	public_works_panel.refresh_requested.connect(_public_works_refresh)
	public_works_panel.closed.connect(func() -> void:
		camera.free_input_enabled = true
		_cancel_input()
		_refresh_hud())
	hud.public_works_requested.connect(_open_public_works)
	if remote != null:
		remote.public_works_result.connect(_on_public_works_result)
	# 交战面板同型：目标与近期结果来自权威，面板只显示并转发意图。交战视图
	# 不含制度与房主，这两项从参与制度视图转给面板做只读表头。
	conflict_panel = ConflictPanel.new()
	conflict_panel.name = "Conflict"
	hud.add_child(conflict_panel)
	conflict_panel.conflict_action.connect(_conflict_action)
	conflict_panel.refresh_requested.connect(_conflict_refresh)
	conflict_panel.closed.connect(func() -> void:
		camera.free_input_enabled = true
		_cancel_input()
		_refresh_hud())
	hud.conflict_requested.connect(_open_conflict)
	if remote != null:
		remote.conflict_result.connect(conflict_panel.apply_result)
		remote.participation_result.connect(func(_request_id: String, payload: Dictionary) -> void:
			var state_value: Variant = payload.get("state")
			if conflict_panel != null and state_value is Dictionary:
				conflict_panel.set_participation(state_value))
	# 纠纷面板同型：案件与公开状态来自权威，面板只显示并转发意图；管理员区是否
	# 出现由视图里的 is_authority 决定，面板不自行判断角色。
	dispute_panel = DisputePanel.new()
	dispute_panel.name = "Dispute"
	hud.add_child(dispute_panel)
	dispute_panel.dispute_action.connect(_dispute_action)
	dispute_panel.refresh_requested.connect(_dispute_refresh)
	dispute_panel.closed.connect(func() -> void:
		camera.free_input_enabled = true
		_cancel_input()
		_refresh_hud())
	hud.dispute_requested.connect(_open_dispute)
	if remote != null:
		remote.dispute_result.connect(dispute_panel.apply_result)
	# 居民面板只读：视图来自权威，面板不派生、不排序、不写回；单机与断开时由
	# 场景清空并标明不可用，不发明本地居民。
	resident_panel = ResidentPanel.new()
	resident_panel.name = "Residents"
	hud.add_child(resident_panel)
	resident_panel.refresh_requested.connect(_resident_refresh)
	resident_panel.close_requested.connect(func() -> void:
		camera.free_input_enabled = true
		_cancel_input()
		_refresh_hud())
	hud.residents_requested.connect(_open_residents)
	if remote != null:
		remote.residents_result.connect(func(_request_id: String,
				payload: Dictionary) -> void:
			resident_panel.apply_result(payload))
	# 对话面板同型：本人行、冷却与最近回复都来自权威，面板只显示并转发一次
	# `say` 意图；冷却、日上限、邀约门限与拒绝原因都由权威裁决，面板的视图
	# 整份替换。单机与断开时它清空并标明世界未打开。
	dialogue_panel = DialoguePanel.new()
	dialogue_panel.name = "Dialogue"
	hud.add_child(dialogue_panel)
	dialogue_panel.dialogue_intent.connect(_dialogue_intent)
	dialogue_panel.refresh_requested.connect(_dialogue_refresh)
	dialogue_panel.closed.connect(func() -> void:
		camera.free_input_enabled = true
		_cancel_input()
		_refresh_hud())
	hud.dialogue_requested.connect(_open_dialogue)
	if remote != null:
		remote.dialogue_result.connect(func(_request_id: String,
				payload: Dictionary) -> void:
			dialogue_panel.apply_result(payload))
	# 规则决议面板同型：版本差异与决议来自权威，面板只显示并转发意图；能否提案、
	# 表决、关闭、生效或撤销，以及投票窗口与预告期都由权威裁决。
	resolutions_panel = ResolutionsPanel.new()
	resolutions_panel.name = "Resolutions"
	hud.add_child(resolutions_panel)
	resolutions_panel.resolution_action.connect(_resolution_action)
	resolutions_panel.refresh_requested.connect(_resolutions_refresh)
	resolutions_panel.closed.connect(func() -> void:
		camera.free_input_enabled = true
		_cancel_input()
		_refresh_hud())
	hud.resolutions_requested.connect(_open_resolutions)
	if remote != null:
		remote.resolutions_result.connect(resolutions_panel.apply_result)
	if OS.is_debug_build() and OS.has_feature("editor"):
		_ensure_developer_controls()
	camera.motion_finished.connect(_refresh_hud)
	camera.motion_finished.connect(func() -> void:
		if not camera.neighbor_view and focus_detail!=null: focus_detail.protect_neighbor(null))
	trellis_crops=TrellisCrops.new();trellis_crops.name="TrellisCrops";add_child(trellis_crops)
	if remote != null:
		_adopt_remote()
	else:
		_load_game(_startup_state)
	_startup_state = {}
	# The courtyard owns all slot transforms and art; no duplicate fallback layout.
	var courtyard: Node3D = $Environment
	decoration_layout = DecorationLayout.new()
	decoration_layout.name = "Decorations"
	add_child(decoration_layout)
	decoration_layout.configure(courtyard, camera, decoration_state if _loaded else DecorationState.new())
	decoration_layout.mode_changed.connect(_on_decoration_mode_changed)
	decoration_layout.change_requested.connect(_change_decoration)
	decoration_layout.illumination_changed.connect(_refresh_lanterns)
	# A failed load keeps farm_state null while the recovery overlay is shown.
	if farm_state != null:
		decoration_layout.update_life(_display_state().kitchen)
	if startup_progress.is_valid(): await startup_progress.call(88.0, "正在准备光照与声音…")
	farm_audio = FarmAudio.new()
	farm_audio.name = "FarmAudio"
	add_child(farm_audio)
	atmosphere = DayNight.new()
	atmosphere.name = "DayNight"
	add_child(atmosphere)
	atmosphere.configure($DirectionalLight3D, $WorldEnvironment, courtyard.get_water_surface())
	hud.preview_hour_requested.connect(func(hour: float) -> void: atmosphere.set_preview_hour(hour))
	hud.time_preview_opened.connect(func() -> void:
		_cancel_input()
		camera.cancel_free_gesture()
		decoration_layout.cancel_pointer_gesture())
	atmosphere.set_backdrop_material(courtyard.get_backdrop_material())
	atmosphere.window_warmth_changed.connect(courtyard.set_window_warmth)
	courtyard.set_window_warmth(atmosphere.get_window_warmth())
	atmosphere.night_weight_changed.connect(courtyard.set_night_weight)
	courtyard.set_night_weight(atmosphere.get_night_weight())
	atmosphere.night_weight_changed.connect(farm_audio.set_night_weight)
	farm_audio.set_night_weight(atmosphere.get_night_weight())
	atmosphere.night_weight_changed.connect(decoration_layout.set_night_weight)
	decoration_layout.set_night_weight(atmosphere.get_night_weight())
	seasonal_courtyard=SeasonalCourtyard.new()
	seasonal_courtyard.name="SeasonalCourtyard"
	courtyard.add_child(seasonal_courtyard)
	seasonal_courtyard.configure(courtyard)
	_apply_season()
	weather_atmosphere = WeatherAtmosphere.new()
	weather_atmosphere.name = "WeatherAtmosphere"
	add_child(weather_atmosphere)
	weather_atmosphere.configure(camera, courtyard_plan.ground_height)
	# Overcast is a presentation input only: day_night.gd blends the same kind
	# into the clock and season values it already owns. Weather never touches
	# farm settlement, saves or the camera.
	weather_atmosphere.weather_changed.connect(atmosphere.set_weather)
	_sync_weather()
	window_activity = WindowActivity.new()
	window_activity.name = "WindowActivity"
	window_activity.foreground_changed.connect(farm_audio.set_foreground)
	window_activity.presentation_changed.connect(_presentation_changed)
	window_activity.deep_idle_changed.connect(func(enabled: bool) -> void:
		if enabled: $Environment.CourtyardAssets.release_cached_scenes())
	add_child(window_activity)
	farm_audio.set_foreground(window_activity.is_foreground())
	decoration_layout.confirmed.connect(_refresh_lanterns)
	_refresh_lanterns()
	focus_detail = FocusDetail.new()
	focus_detail.name = "FocusDetail"
	add_child(focus_detail)
	focus_detail.configure(camera, farm.fields+[trellis_crops.body], courtyard, decoration_layout)
	focus_detail.quality_changed.connect(atmosphere.set_quality)
	focus_detail.shadows_changed.connect(atmosphere.set_shadows)
	if startup_progress.is_valid(): await startup_progress.call(94.0, "正在应用画面设置…")
	_setup_settings()
	desktop_wallpaper = DesktopWallpaper.new()
	desktop_wallpaper.name = "DesktopWallpaper"
	add_child(desktop_wallpaper)
	desktop_wallpaper.changed.connect(_wallpaper_changed)
	desktop_wallpaper.interaction_changed.connect(_wallpaper_interaction_changed)
	desktop_wallpaper.workarea_changed.connect(hud.set_workarea)
	wallpaper_hint = WallpaperHint.new()
	wallpaper_hint.name = "WallpaperHint"
	add_child(wallpaper_hint)
	wallpaper_hint.dismissed.connect(_dismiss_wallpaper_hint)
	desktop_wallpaper.workarea_changed.connect(wallpaper_hint.set_workarea)
	desktop_wallpaper.pointer_moved.connect(_wallpaper_pointer)
	desktop_wallpaper.pointer_left.connect(_wallpaper_leave)
	desktop_wallpaper.pointer_button.connect(_wallpaper_button)
	desktop_wallpaper.visibility_changed.connect(window_activity.set_wallpaper_visible)
	desktop_wallpaper.restoring.connect(window_activity.begin_wallpaper_restore)
	desktop_wallpaper.quit_requested.connect(_request_exit)
	desktop_wallpaper.failed.connect(func(message: String) -> void:
		push_warning(message)
		_wallpaper_issue = message
		if not desktop_wallpaper.active and not desktop_wallpaper.busy:
			game_menu.present(settings_values, message)
			_show_disaster_mode())
	game_menu.set_wallpaper_available(desktop_wallpaper.supported())
	game_menu.set_wallpaper_interaction(desktop_wallpaper.interaction_supported())
	courtyard_edit=CourtyardEditSession.new()
	courtyard_edit.name="CourtyardEditor"
	add_child(courtyard_edit)
	courtyard_edit.apply_requested.connect(_apply_courtyard)
	courtyard_edit.closed.connect(_refresh_hud)
	decoration_layout.hud.courtyard_requested.connect(_begin_courtyard_edit)
	island_builder=IslandBuilder.new();island_builder.name="IslandBuilder";add_child(island_builder)
	island_builder.commit_requested.connect(_apply_construction)
	island_builder.decoration_undo_requested.connect(_undo_decoration)
	island_builder.closed.connect(func() -> void:
		camera.set_construction_framing(false);hud.show();_cancel_input();_refresh_hud())
	hud.construction_requested.connect(_begin_construction)
	if not _construction_resume.is_empty():
		camera.focus_point=_construction_resume.point;camera.view=_construction_resume.view
		_begin_construction.call_deferred(_construction_resume.tool)
	if not _presentation_resume.is_empty():
		focus_detail.set_depth_of_field(_presentation_resume.dof_enabled,_presentation_resume.dof_strength)
		focus_detail.set_fog_strength(_presentation_resume.fog_strength)
		atmosphere.set_preview_hour(_presentation_resume.hour)
	if OS.has_feature("editor") and OS.get_cmdline_user_args().has("--dev-preview") and not startup_progress.is_valid():
		_report_preview_ready.call_deferred()
	# Photos are written into the local save; a shared world has no such file.
	if remote == null:
		garden_album=GardenAlbum.new();garden_album.name="GardenAlbum";add_child(garden_album);garden_album.configure(self)
	var timer := Timer.new()
	timer.name = "SettlementTimer"
	timer.wait_time = 1.0
	timer.timeout.connect(settle_farm)
	add_child(timer)
	timer.start()
	# Every accepted action is saved transactionally. Growth derives from UTC;
	# writing the same farm every 30 seconds adds I/O without protecting actions.
	if not _record_session.is_empty():
		var recording: Node = load("res://development/recording_session.gd").new()
		recording.session_dir = _record_session
		recording.farm_scene = self
		add_child(recording)

	startup_complete = true
	startup_finished.emit()
	if _dev_wallpaper:
		_enter_dev_wallpaper.call_deferred()


func _open_nature_state() -> Dictionary:
	# The same load semantics as HeadlessWorld: a missing document means the
	# fixed default seed (not a new roll), a present but corrupt or newer one is
	# refused. A refused seed must never be replaced by a fresh default.
	if store == null:
		return {"ok": false, "kind": "store_not_open"}
	_nature_recovery_available = false
	nature_store = NatureStore.new(store.directory)
	var loaded: Dictionary = nature_store.load_state()
	if not loaded.ok:
		nature_state = null
		_nature_persisted = false
		if loaded.kind == "recovery_available":
			# A valid previous generation exists; reuse the farm's explicit
			# recovery overlay, but route the click to the nature store first.
			_nature_recovery_available = true
			return {"ok": false, "kind": "recovery_available"}
		return {"ok": false, "kind": "nature_" + str(loaded.kind)}
	if loaded.kind == "loaded":
		var restored := NatureState.new()
		if not restored.restore_snapshot(loaded.state):
			nature_state = null
			_nature_persisted = false
			return {"ok": false, "kind": "nature_corrupt"}
		nature_state = restored
		_nature_persisted = true
	else:
		# A save created before nature.json keeps the fixed default seed until
		# the next farm write persists it.
		nature_state = NatureState.new()
		_nature_persisted = false
	return {"ok": true, "kind": str(loaded.kind)}


func _load_game(initial: Dictionary = {}) -> void:
	if remote == null:
		var nature_result: Dictionary = _open_nature_state()
		if not nature_result.ok:
			# The seed may hold the only record of weather this save already lived
			# through, so a refused document is never replaced by a fresh one. A
			# validated previous generation is offered as explicit recovery; every
			# byte stays untouched until the player chooses it.
			_loaded = false
			farm.visible = false
			trellis_crops.visible=false
			print("NATURE_LOAD stage=failed kind=%s" % (
				"nature_recovery_available" if _nature_recovery_available else str(nature_result.kind)))
			hud.show_storage_issue(str(nature_result.kind), false)
			return
	var result: Dictionary = store.load_state() if initial.is_empty() else initial
	if not result.ok:
		_loaded = false
		farm.visible = false
		trellis_crops.visible=false
		hud.show_storage_issue(result.kind, false)
		return
	if result.kind == "missing":
		farm_state = FarmState.new(clock.call(),courtyard_plan.snapshot(), nature_state)
		decoration_state = DecorationState.new()
	else:
		if result.farm.layout != courtyard_plan.snapshot():
			# Recovery can restore a different island. Recreate all spatial consumers
			# together rather than retaining obsolete colliders, haze or animal routes.
			_reload_saved_scene.call_deferred()
			return
		farm_state = FarmState.new()
		farm_state.restore_snapshot(result.farm)
		farm_state.set_environment(nature_state)
		decoration_state = DecorationState.new()
		decoration_state.restore_snapshot(result.decorations)
	_bind_pantry_owner()
	var display: Dictionary = _display_state()
	decoration_state.unlock(display.harvested,display.kitchen)
	$Environment/CourtyardAnimals.interaction.profiles=display.animals
	if decoration_layout != null:
		decoration_layout.bind_state(decoration_state)
		decoration_layout.update_life(display.kitchen)
		_refresh_lanterns()
	_loaded = true
	_refresh_neighbor_stories()
	kitchen_display.refresh(display.kitchen)
	farm.visible = true
	trellis_crops.visible=true
	if seasonal_courtyard!=null: _apply_season()
	settle_farm()
	refresh_farm()
	_save_farm()
	print("FARM_LOAD stage=%s version=%d migrated=%s saved=%s" % [result.kind, FarmStore.VERSION, result.get("migrated", false), not _save_failed])

## The pantry context is view-only and never serialized: it decides whose bag
## kitchen, animals, baskets and the local market read from. An anonymous or
## invalid id keeps the historical shared inventory.
func _bind_pantry_owner() -> void:
	if farm_state == null:
		return
	farm_state.pantry_owner = local_player_id if OwnerIds.valid(local_player_id) else ""


## A read-only snapshot for the UI: the persisted document with its shared
## inventory replaced by this state's pantry. A bag is stored sparsely, so the
## view starts from the canonical zero table and overlays the pocket; display
## never writes those zeros back, and `pantry_view()` never creates a bag.
## Saves always use `snapshot()`.
func _display_state(state: FarmState = null) -> Dictionary:
	var source: FarmState = farm_state if state == null else state
	if source == null:
		return {}
	var data: Dictionary = source.snapshot()
	var view: Dictionary = {}
	for crop_id: String in Crops.crop_ids():
		view[crop_id] = 0
	view.merge(source.pantry_view(), true)
	data.inventory = view
	return data


## Local edits would change only this client's copy of a shared world, so the
## scene refuses them with a visible reason instead of silently diverging.
func _world_edit_unavailable() -> bool:
	if remote == null:
		return false
	hud.show_notice("联机模式下，院落由世界房主维护。")
	return true


## Takes over the state the startup scene already fetched from the authority.
## From here on the scene only reacts: no local save, no local authority.
func _adopt_remote() -> void:
	if remote.get_parent() != self:
		remote.reparent(self)
	# Growth follows the world's own clock; this machine's wall clock may differ.
	clock = remote.world_time
	farm_state = remote_seed.farm
	decoration_state = remote_seed.decorations
	# The shared document is the same rule owner, so this client's display reads
	# this player's own bag from it; its own saves never happen in this mode.
	_bind_pantry_owner()
	var data: Dictionary = _display_state()
	decoration_state.unlock(data.harvested, data.kitchen)
	$Environment/CourtyardAnimals.interaction.profiles = data.animals
	_loaded = true
	_refresh_neighbor_stories()
	kitchen_display.refresh(data.kitchen)
	farm.visible = true
	trellis_crops.visible = true
	if seasonal_courtyard != null: _apply_season()
	housing_view = HousingView.new()
	housing_view.name = "YardHomes"
	housing_view.ground_y = courtyard_plan.ground_height + courtyard_plan.anchors.east_bank.y
	$Environment.add_child(housing_view)
	public_works_view = PublicWorksView.new()
	public_works_view.name = "PublicWorksScene"
	public_works_view.ground_y = housing_view.ground_y
	$Environment.add_child(public_works_view)
	settle_farm()
	refresh_farm()
	remote.state_ready.connect(_on_remote_state)
	remote.committed.connect(_on_remote_committed)
	remote.changed.connect(_on_remote_changed)
	remote.lost.connect(_on_remote_lost)
	remote.reconnecting.connect(_on_remote_reconnecting)
	remote.reconnected.connect(_on_remote_reconnected)
	remote.summary_refused.connect(_on_remote_summary_refused)
	remote.refused.connect(func(reason: String) -> void: _on_remote_lost("join_" + reason))
	hud.set_world_mode(true)
	social_panel = SocialPanel.new()
	social_panel.name = "Neighbors"
	add_child(social_panel)
	social_panel.action_requested.connect(_social_action)
	hud.social_requested.connect(_open_social)
	build_panel = BuildPanel.new()
	build_panel.name = "Homes"
	add_child(build_panel)
	build_panel.build_requested.connect(_send_build)
	build_panel.demolish_requested.connect(_send_demolish)
	build_panel.land_action.connect(_send_land_action)
	remote.territory_result.connect(_on_territory_result)
	hud.homes_requested.connect(_open_homes)
	remote.organization_result.connect(_on_organization_result)
	remote.member.social_result.connect(_on_social_result)
	remote.member.social_event.connect(_on_social_event)
	remote.member.roster_changed.connect(func(rows: Array[Dictionary]) -> void:
		if social_panel.visible:
			social_panel.present(social_panel.view, rows, _my_bag(), _theft_on))
	print("FARM_REMOTE world=%s role=%s now=%.0f" % [
		str(remote.grant.get("world_id", "")),
		remote.member.role if remote.member != null else "", remote.world_time()])


## Opening the panel asks for a fresh view; the authority is the only place that
## knows the current contacts, messages and grants.
func _open_social() -> void:
	if remote == null or remote.member == null:
		hud.show_notice("还没有连上世界。")
		return
	social_panel.present(social_panel.view, remote.member.roster, _my_bag(), _theft_on)
	# The host may have lost the copied code; the room is still theirs to share.
	var room_code: String = ""
	if hosted_room != null and hosted_room.is_running():
		var room: Dictionary = hosted_room.poll()
		if bool(room.get("ok", false)):
			room_code = str(room.get("join_code", ""))
	social_panel.show_room_code(room_code)
	social_panel.show()
	remote.member.request_social("social-state", "state")


func _social_action(action: String, args: Dictionary) -> void:
	if remote == null or remote.member == null:
		return
	# A gift moves produce, not a social document: it goes through the same farm
	# command channel as a harvest, so the debit and the credit commit together.
	if action == "gift":
		_send_gift(args)
		return
	# The theft switch is a standing on the farm document, so it travels as a
	# farm command: the same path as a harvest, and the same idempotent ledger.
	if action == "set_theft":
		_send_theft(bool(args.get("enabled", false)))
		return
	var request_id: String = "social-" + action + "-" + str(Time.get_ticks_usec())
	remote.member.request_social(request_id, action, args)


func _send_gift(args: Dictionary) -> void:
	var to_id: String = str(args.get("player_id", ""))
	var crop_id: String = str(args.get("crop_id", ""))
	if to_id.is_empty() or crop_id.is_empty():
		social_panel.show_status("先选一份收成和一位邻居。")
		return
	var command: Dictionary = FarmCommand.make_gift(_new_command_id(), to_id, crop_id,
		int(args.get("amount", 1)), remote.world_time())
	if not remote.submit(command):
		social_panel.show_status("还没有连上世界，这份礼没有送出去。")
		return
	_remote_pending[str(command.id)] = {"command": command, "tool": "gift"}


func _send_theft(enabled: bool) -> void:
	var command: Dictionary = FarmCommand.make_set_theft(_new_command_id(), enabled, remote.world_time())
	if not remote.submit(command):
		social_panel.show_status("还没有连上世界，偷菜设置没有保存。")
		return
	_remote_pending[str(command.id)] = {"command": command, "tool": "theft"}


## The buildings table lives in the mirrored farm document, so opening the panel
## needs no extra request: it is the same snapshot the fields come from.
func _open_homes() -> void:
	if remote == null or build_panel == null:
		hud.show_notice("还没有连上世界。")
		return
	_refresh_homes()
	build_panel.show()


func _refresh_homes() -> void:
	if build_panel == null or farm_state == null or remote == null:
		return
	# The authority grants build/demolish to named members only. A visitor or an
	# anonymous connection sees the same yard with its actions disabled.
	var read_only: bool = not _remote_homes_writable()
	build_panel.present(farm_state.buildings_at(remote.world_time()), remote.world_time(),
		remote.player_id, read_only, _remote_homes_reason() if read_only else "",
		_parcel_views())


## Mirrors the cadastre the last summary carried, keyed by yard slot. The panel
## uses it only to say whose land a slot is and to stop offering a build on
## someone else's parcel; the authority still decides the command.
func _parcel_views() -> Dictionary:
	var views: Dictionary = {}
	if remote == null or remote.member == null:
		return views
	var summary: Variant = remote.member.state
	if not summary is Dictionary:
		return views
	var territory: Variant = (summary as Dictionary).get("territory")
	if not territory is Dictionary:
		return views
	var names: Dictionary = {}
	for row: Dictionary in remote.member.roster:
		var player_id: String = str(row.get("player_id", ""))
		if not player_id.is_empty():
			names[player_id] = str(row.get("name", player_id))
	var my_id: String = remote.player_id
	# 只有具名成员才看得到写动作按钮；访客保持原来的只读说明。面板不判断
	# 权限，只渲染这里给出的动作。
	var writable: bool = _remote_homes_writable()
	for value: Variant in (territory as Dictionary).get("parcels", []):
		if not value is Dictionary:
			continue
		var parcel: Dictionary = value
		var slot_id: String = str(parcel.get("slot", ""))
		if slot_id.is_empty():
			continue
		var owner: String = str(parcel.get("owner", ""))
		var status: String = str(parcel.get("status", ""))
		if status == "claimed" and not owner.is_empty():
			if owner == my_id:
				views[slot_id] = {"label": "这是你的宅基", "blocked": "",
					"action": "release" if writable else ""}
			else:
				var who: String = str(names.get(owner, owner))
				views[slot_id] = {
					"label": "宅基属于 %s" % who,
					"blocked": "这块宅基属于 %s，不能在别人的地上建房。" % who,
					"action": "",
				}
		elif status == "public":
			views[slot_id] = {"label": "公共宅基", "blocked": "", "action": ""}
		elif status == "unclaimed":
			views[slot_id] = {"label": "无主宅基，第一次建造就归你", "blocked": "",
				"action": "claim" if writable else ""}
	return views


## The parcel ids the last summary's cadastre carried, for the public works
## parcel picker. No summary (single player, not connected) yields an empty
## list, and the form keeps accepting a manually typed id.
func _parcel_ids() -> Array:
	var ids: Array = []
	if remote == null or remote.member == null:
		return ids
	var summary: Variant = remote.member.state
	if not summary is Dictionary:
		return ids
	var territory: Variant = (summary as Dictionary).get("territory")
	if not territory is Dictionary:
		return ids
	for value: Variant in (territory as Dictionary).get("parcels", []):
		if not value is Dictionary:
			continue
		var parcel: Dictionary = value
		var parcel_id: String = str(parcel.get("id", ""))
		if parcel_id.is_empty():
			parcel_id = TerritoryState.slot_parcel_id(str(parcel.get("slot", "")))
		if not parcel_id.is_empty() and not ids.has(parcel_id):
			ids.append(parcel_id)
	return ids


func _send_build(slot_id: String, blueprint: String) -> void:
	var command: Dictionary = FarmCommand.make_build(_new_command_id(), slot_id, blueprint,
		remote.world_time())
	if not remote.submit(command):
		build_panel.show_status("还没有连上世界，这次建造没有发出去。")
		return
	_remote_pending[str(command.id)] = {"command": command, "tool": "build"}


func _send_demolish(slot_id: String) -> void:
	var command: Dictionary = FarmCommand.make_demolish(_new_command_id(), slot_id, remote.world_time())
	if not remote.submit(command):
		build_panel.show_status("还没有连上世界，这次拆除没有发出去。")
		return
	_remote_pending[str(command.id)] = {"command": command, "tool": "demolish"}


## 把面板上的“主张/释放”变成一次权威请求。地块 id 由槽位按固定约定反查；
## 归属不在本地修改，成功后的摘要广播才是新的权威视图。
func _send_land_action(slot_id: String, action: String) -> void:
	if remote == null or build_panel == null:
		return
	var parcel_id: String = TerritoryState.slot_parcel_id(slot_id)
	if parcel_id.is_empty():
		build_panel.show_status("这个宅基还没有对应地块，暂时不能操作。")
		return
	var request_id: String = _new_command_id()
	if not remote.request_territory(request_id, action,
			{"parcel_id": parcel_id, "command_id": request_id}):
		build_panel.show_status("还没有连上世界，这次土地操作没有发出去。")


## 地籍答复只负责显示结果：失败给出权威文案，成功后等下一份摘要刷新归属。
func _on_territory_result(_request_id: String, payload: Dictionary) -> void:
	if build_panel == null:
		return
	_refresh_homes()
	if bool(payload.get("ok", false)):
		return
	var text: String = str(payload.get("reason_text", ""))
	build_panel.show_status(text if not text.is_empty() \
		else _remote_reason(str(payload.get("reason", ""))))


## 组织只存在于共享世界。单机打开时说明这一点，不虚构本地组织；联机打开先
## 摆出上次已知的视图，再向权威要一份新的。面板不判断权限，只按连接角色决定
## 能否提交。
func _open_governance() -> void:
	if governance_panel == null:
		return
	_cancel_tool()
	hud.hide_time_preview()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	camera.free_input_enabled = false
	if remote == null:
		governance_panel.present([], "", false, "组织需要进入共享世界。")
		governance_panel.show()
		return
	var writable: bool = _remote_organization_writable()
	governance_panel.present(governance_panel.organizations, remote.player_id, writable,
		"" if writable else _remote_organization_reason())
	governance_panel.show()
	if not remote.request_organization("organization-state", "state", {}):
		governance_panel.show_status("还没有连上世界，组织信息没有刷新。")


func _governance_refresh() -> void:
	if governance_panel == null:
		return
	if remote == null:
		governance_panel.present([], "", false, "组织需要进入共享世界。")
		return
	var writable: bool = _remote_organization_writable()
	governance_panel.present(governance_panel.organizations, remote.player_id, writable,
		"" if writable else _remote_organization_reason())
	if not remote.request_organization("organization-state", "state", {}):
		governance_panel.show_status("还没有连上世界，组织信息没有刷新。")


## 面板发出的动作原样转给权威；命令 id 同时作为请求 id 和请求载荷里的
## `command_id`，重试或重放才能被权威识别为同一条命令。创建组织还需要一个
## 组织编号，面板只收名称，编号在这里按合法字符集生成。
func _governance_action(action: String, args: Dictionary) -> void:
	if governance_panel == null or remote == null:
		return
	var request_id: String = _new_command_id()
	var payload: Dictionary = args.duplicate(true)
	payload["command_id"] = request_id
	if action == "create" and not payload.has("org_id"):
		payload["org_id"] = "org-" + request_id
	if not remote.request_organization(request_id, action, payload):
		governance_panel.show_status("还没有连上世界，组织操作没有发出去。")


## 组织答复只负责显示结果：视图整份替换，底部状态行显示权威给出的原因。
func _on_organization_result(_request_id: String, payload: Dictionary) -> void:
	if governance_panel == null or remote == null:
		return
	var organizations: Array = []
	var state_value: Variant = payload.get("state")
	if state_value is Dictionary:
		var rows: Variant = (state_value as Dictionary).get("organizations")
		if rows is Array:
			organizations = rows
	var writable: bool = _remote_organization_writable()
	var status: String = str(payload.get("reason_text", ""))
	if status.is_empty() and bool(payload.get("duplicate", false)):
		status = "这条组织操作已经执行过。"
	if status.is_empty() and not writable:
		status = _remote_organization_reason()
	governance_panel.present(organizations, remote.player_id, writable, status)


## 组织写入要求具名成员；访客与匿名连接只能查看。
func _remote_organization_writable() -> bool:
	if remote == null or remote.member == null or remote.player_id.is_empty():
		return false
	return remote.member.role == "member"


func _remote_organization_reason() -> String:
	if remote == null:
		return "组织需要进入共享世界。"
	if remote.member != null and remote.member.role != "member":
		return "访客只能查看组织，不能创建或管理。"
	return "还没有玩家身份，暂时不能操作组织。"


## 单位名册只存在于共享世界。单机打开时说明这一点，不虚构本地单位；联机打开
## 先摆出上次已知的视图，再向权威要一份新的。面板不判断权限或资源，只转发意图。
func _open_units() -> void:
	if unit_panel == null:
		return
	_cancel_tool()
	hud.hide_time_preview()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	camera.free_input_enabled = false
	unit_panel.open_panel({"units": unit_panel.units.duplicate(true)})
	if remote == null:
		unit_panel.show_status("单位需要进入共享世界。")
		return
	if not remote.request_unit("unit-state", "state"):
		unit_panel.show_status("还没有连上世界，单位名册没有刷新。")


func _unit_refresh() -> void:
	if unit_panel == null:
		return
	if remote == null:
		unit_panel.show_status("单位需要进入共享世界。")
		return
	if not remote.request_unit("unit-state", "state"):
		unit_panel.show_status("还没有连上世界，单位名册没有刷新。")


## 面板发出的动作原样转给权威；命令 id 同时作为请求 id 和请求载荷里的
## `command_id`，重试或重放才能被权威识别为同一条命令。资源与归属由权威裁决。
func _unit_action(action: String, args: Dictionary) -> void:
	if unit_panel == null:
		return
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = _new_command_id()
		payload["command_id"] = request_id
	if remote == null or not remote.request_unit(request_id, action, payload):
		unit_panel.show_status("还没有连上世界，单位操作没有发出去。")


## 公共基金只存在于共享世界。单机打开时说明这一点，不虚构本地基金；联机打开
## 先摆出上次已知的视图，再向权威要一份新的。面板不判断权限或余额，只转发意图。
func _open_funds() -> void:
	if fund_panel == null:
		return
	_cancel_tool()
	hud.hide_time_preview()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	camera.free_input_enabled = false
	fund_panel.open_panel({"funds": fund_panel.funds.duplicate(true)})
	if remote == null:
		fund_panel.show_status("公共基金需要进入共享世界。")
		return
	if not remote.request_fund("fund-state", "state"):
		fund_panel.show_status("还没有连上世界，公共基金没有刷新。")


func _fund_refresh() -> void:
	if fund_panel == null:
		return
	if remote == null:
		fund_panel.show_status("公共基金需要进入共享世界。")
		return
	if not remote.request_fund("fund-state", "state"):
		fund_panel.show_status("还没有连上世界，公共基金没有刷新。")


## 基金动作原样转给权威；命令 id 同时作为请求 id 和请求载荷里的 `command_id`，
## 重试或重放才能被权威识别为同一条命令。组织权限与余额由权威裁决。
func _fund_action(action: String, args: Dictionary) -> void:
	if fund_panel == null:
		return
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = _new_command_id()
		payload["command_id"] = request_id
	if remote == null or not remote.request_fund(request_id, action, payload):
		fund_panel.show_status("还没有连上世界，基金操作没有发出去。")


## 参与制度只存在于共享世界。单机打开时说明这一点，不虚构本地制度；联机打开
## 先摆出上次已知的视图，再向权威要一份新的。面板不判断房主、角色或上限，
## 只负责显示权威视图并转发意图。
func _open_participation() -> void:
	if participation_panel == null:
		return
	_cancel_tool()
	hud.hide_time_preview()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	camera.free_input_enabled = false
	participation_panel.set_self_id(remote.player_id if remote != null else "")
	participation_panel.open_panel(participation_panel.view.duplicate(true))
	if remote == null:
		participation_panel.show_status("参与制度需要进入共享世界。")
		return
	if not remote.request_participation("participation-state", "state"):
		participation_panel.show_status("还没有连上世界，参与制度没有刷新。")


func _participation_refresh() -> void:
	if participation_panel == null:
		return
	if remote == null:
		participation_panel.show_status("参与制度需要进入共享世界。")
		return
	if not remote.request_participation("participation-state", "state"):
		participation_panel.show_status("还没有连上世界，参与制度没有刷新。")


## 参与制度动作原样转给权威；命令 id 同时作为请求 id 和请求载荷里的
## `command_id`，重试或重放才能被权威识别为同一条命令。房主身份、风险声明与
## 角色由权威裁决。
func _participation_action(action: String, args: Dictionary) -> void:
	if participation_panel == null:
		return
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = _new_command_id()
		payload["command_id"] = request_id
	if remote == null or not remote.request_participation(request_id, action, payload):
		participation_panel.show_status("还没有连上世界，参与制度操作没有发出去。")


## 公共项目只存在于共享世界。单机打开时说明这一点，不虚构本地项目；联机打开
## 先摆出上次已知的视图，再向权威要一份新的。面板不判断权限、余额或足额，只
## 转发意图。
func _open_public_works() -> void:
	if public_works_panel == null:
		return
	_cancel_tool()
	hud.hide_time_preview()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	camera.free_input_enabled = false
	public_works_panel.set_parcels(_parcel_ids())
	public_works_panel.open_panel(public_works_panel.view.duplicate(true))
	# The scene and the panel read the same authority view: opening or refreshing
	# re-applies the last confirmed projects before asking for a newer one.
	_refresh_public_works_scene(public_works_panel.view)
	if remote == null:
		if public_works_view != null:
			public_works_view.clear()
		public_works_panel.show_status("公共项目需要进入共享世界。")
		return
	if not remote.request_public_works("public-works-state", "state"):
		public_works_panel.show_status("还没有连上世界，公共项目没有刷新。")


func _public_works_refresh() -> void:
	if public_works_panel == null:
		return
	public_works_panel.set_parcels(_parcel_ids())
	_refresh_public_works_scene(public_works_panel.view)
	if remote == null:
		if public_works_view != null:
			public_works_view.clear()
		public_works_panel.show_status("公共项目需要进入共享世界。")
		return
	if not remote.request_public_works("public-works-state", "state"):
		public_works_panel.show_status("还没有连上世界，公共项目没有刷新。")


## 权威答复同时更新面板与世界视图。没有 `state` 的拒绝答复保留上一份已确认
## 的建成物；视图只使用 `state.projects`，不从本地文档推导项目。
func _on_public_works_result(request_id: String, payload: Dictionary) -> void:
	if public_works_panel != null:
		public_works_panel.apply_result(request_id, payload)
	var state_value: Variant = payload.get("state")
	if state_value is Dictionary:
		_refresh_public_works_scene(state_value)


## Applies the authoritative `{projects: [...]}` view to the built markers. The
## view ignores non-built rows and parcels without a yard slot; it never invents
## a position for an unbound project.
func _refresh_public_works_scene(state: Dictionary) -> void:
	if public_works_view == null:
		return
	public_works_view.refresh(state)


## 公共项目动作原样转给权威；命令 id 同时作为请求 id 和请求载荷里的
## `command_id`，重试或重放才能被权威识别为同一条命令。成员资格与基金余额由
## 权威裁决。
func _public_works_action(action: String, args: Dictionary) -> void:
	if public_works_panel == null:
		return
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = _new_command_id()
		payload["command_id"] = request_id
	if remote == null or not remote.request_public_works(request_id, action, payload):
		public_works_panel.show_status("还没有连上世界，公共项目操作没有发出去。")


## 交战只存在于共享世界。单机打开时说明这一点，不虚构本地战场；联机打开先
## 摆出上次已知的交战视图，再用参与制度视图补上制度与房主，并向权威刷新两份
## 只读视图。面板不判断同意、归属、上限或资产，只转发意图。
func _open_conflict() -> void:
	if conflict_panel == null:
		return
	_cancel_tool()
	hud.hide_time_preview()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	camera.free_input_enabled = false
	if participation_panel != null:
		conflict_panel.set_participation(participation_panel.view)
	conflict_panel.open_panel(conflict_panel.view.duplicate(true))
	if remote == null:
		conflict_panel.show_status("交战需要进入共享世界。")
		return
	if not remote.request_conflict("conflict-state", "state"):
		conflict_panel.show_status("还没有连上世界，交战没有刷新。")
	# The conflict view does not carry the regime; refresh the authoritative
	# participation view so the read-only header is not stale.
	remote.request_participation("participation-state", "state")


func _conflict_refresh() -> void:
	if conflict_panel == null:
		return
	if remote == null:
		conflict_panel.show_status("交战需要进入共享世界。")
		return
	if not remote.request_conflict("conflict-state", "state"):
		conflict_panel.show_status("还没有连上世界，交战没有刷新。")
	remote.request_participation("participation-state", "state")


## 交战动作原样转给权威；命令 id 同时作为请求 id 和请求载荷里的 `command_id`，
## 重试或重放才能被权威识别为同一条命令。参与同意、单位归属、损失上限与资产
## 都由权威裁决。
func _conflict_action(action: String, args: Dictionary) -> void:
	if conflict_panel == null:
		return
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = _new_command_id()
		payload["command_id"] = request_id
	if remote == null or not remote.request_conflict(request_id, action, payload):
		conflict_panel.show_status("还没有连上世界，交战操作没有发出去。")


## 纠纷只存在于共享世界。单机打开时说明这一点，不虚构本地案件或管理员；联机
## 打开先摆出上次已知的权威视图，再向权威要一份新的。面板不判断角色、案件
## 状态或证据窗口，只显示权威视图并转发意图。
func _open_dispute() -> void:
	if dispute_panel == null:
		return
	_cancel_tool()
	hud.hide_time_preview()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	camera.free_input_enabled = false
	dispute_panel.open_panel(dispute_panel.view.duplicate(true))
	if remote == null:
		dispute_panel.show_status("纠纷需要进入共享世界。")
		return
	if not remote.request_dispute("dispute-state", "state"):
		dispute_panel.show_status("还没有连上世界，纠纷没有刷新。")


func _dispute_refresh() -> void:
	if dispute_panel == null:
		return
	if remote == null:
		dispute_panel.show_status("纠纷需要进入共享世界。")
		return
	if not remote.request_dispute("dispute-state", "state"):
		dispute_panel.show_status("还没有连上世界，纠纷没有刷新。")


## 纠纷动作原样转给权威；命令 id 同时作为请求 id 和请求载荷里的
## `command_id`，重试或重放才能被权威识别为同一条命令。管理员身份、案件状态、
## 证据窗口与裁定语义都由权威裁决。
func _dispute_action(action: String, args: Dictionary) -> void:
	if dispute_panel == null:
		return
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = _new_command_id()
		payload["command_id"] = request_id
	if remote == null or not remote.request_dispute(request_id, action, payload):
		dispute_panel.show_status("还没有连上世界，纠纷操作没有发出去。")


## 居民视图只存在于共享世界。单机打开时清空并标明不可用，不虚构本地居民；
## 联机打开先摆出上次确认的权威视图，再向权威要一份新的。面板只负责显示，
## 没有任何写动作。
func _open_residents() -> void:
	if resident_panel == null:
		return
	_cancel_tool()
	hud.hide_time_preview()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	camera.free_input_enabled = false
	resident_panel.open_panel(resident_panel.view.duplicate(true))
	if remote == null:
		resident_panel.show_unavailable("not_open")
		return
	if not remote.request_residents("resident-state", "state"):
		resident_panel.show_unavailable("not_open")


func _resident_refresh() -> void:
	if resident_panel == null:
		return
	if remote == null:
		resident_panel.show_unavailable("not_open")
		return
	if not remote.request_residents("resident-state", "state"):
		resident_panel.show_unavailable("not_open")


## 规则决议只存在于共享世界。单机打开时清空并标明不可用，不虚构本地规则版本；
## 联机打开先摆出上次确认的权威视图，再向权威要一份新的。面板不判断成员资格、
## 投票窗口、计票阈值或生命周期，只显示权威视图并转发意图。
func _open_resolutions() -> void:
	if resolutions_panel == null:
		return
	_cancel_tool()
	hud.hide_time_preview()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	camera.free_input_enabled = false
	resolutions_panel.open_panel(resolutions_panel.view.duplicate(true))
	if remote == null:
		resolutions_panel.show_unavailable("not_open")
		return
	if not remote.request_resolutions("resolution-state", "state"):
		resolutions_panel.show_status("还没有连上世界，决议没有刷新。")


## 对话只存在于共享世界。单机打开时清空并标明不可用，不虚构本地居民；联机
## 打开先摆出上次确认的权威视图，再向权威要一份新的。面板没有写动作，点击
## 只转发一次 `say`。
func _open_dialogue() -> void:
	if dialogue_panel == null:
		return
	_cancel_tool()
	hud.hide_time_preview()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	camera.free_input_enabled = false
	dialogue_panel.open_panel(dialogue_panel.view.duplicate(true))
	if remote == null:
		dialogue_panel.show_unavailable("not_open")
		return
	if not remote.request_dialogue("dialogue-state", "state"):
		dialogue_panel.show_unavailable("not_open")


func _dialogue_refresh() -> void:
	if dialogue_panel == null:
		return
	if remote == null:
		dialogue_panel.show_unavailable("not_open")
		return
	if not remote.request_dialogue("dialogue-state", "state"):
		dialogue_panel.show_unavailable("not_open")


## 一次对话意图原样转给权威；面板给的 `command_id` 同时作为请求 id 和请求
## 载荷里的命令编号，重试或重放才能被权威识别为同一条命令。冷却、日上限、
## 邀约门限与拒绝原因都由权威裁决并写回答复。
func _dialogue_intent(action: String, args: Dictionary) -> void:
	if dialogue_panel == null:
		return
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = _new_command_id()
		payload["command_id"] = request_id
	if remote == null or not remote.request_dialogue(request_id, action, payload):
		dialogue_panel.show_status("还没有连上世界，这句话没有发出去。")


func _resolutions_refresh() -> void:
	if resolutions_panel == null:
		return
	if remote == null:
		resolutions_panel.show_unavailable("not_open")
		return
	if not remote.request_resolutions("resolution-state", "state"):
		resolutions_panel.show_status("还没有连上世界，决议没有刷新。")


## 规则决议动作原样转给权威；命令 id 同时作为请求 id 和请求载荷里的
## `command_id`，重试或重放才能被权威识别为同一条命令。成员资格、投票窗口、
## 预告期与计票阈值都由权威裁决。
func _resolution_action(action: String, args: Dictionary) -> void:
	if resolutions_panel == null:
		return
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = _new_command_id()
		payload["command_id"] = request_id
	if remote == null or not remote.request_resolutions(request_id, action, payload):
		resolutions_panel.show_status("还没有连上世界，决议操作没有发出去。")


## The local view of what this player owns; the authority's summary keeps it in
## sync after every reconnect.
func _my_bag() -> Dictionary:
	if farm_state == null or remote == null:
		return {}
	return farm_state.bag(remote.player_id)


## ADR-027 degradation: a member whose projected snapshot has no own bag sees
## "synchronising" instead of a real zero balance. The notice is shown once;
## the next summary that carries the bag clears it.
func _notice_missing_remote_bag() -> void:
	if farm_state == null or remote == null or remote.player_id.is_empty():
		return
	if farm_state.has_bag(remote.player_id):
		_remote_bag_notice_shown = false
		return
	if _remote_bag_notice_shown:
		return
	_remote_bag_notice_shown = true
	hud.show_notice("个人资料同步中：口袋内容稍后更新。")


func _on_social_result(_request_id: String, payload: Dictionary) -> void:
	if social_panel == null:
		return
	if not bool(payload.get("ok", false)):
		social_panel.show_status(_remote_reason(str(payload.get("reason", ""))))
		return
	var carried: Variant = payload.get("state")
	if payload.has("theft"):
		_theft_on = bool(payload.get("theft"))
	if carried is Dictionary:
		social_panel.present(carried, remote.member.roster, _my_bag(), _theft_on)


func _on_social_event(payload: Dictionary) -> void:
	if social_panel == null:
		return
	var from_name: String = str(payload.get("from_name", ""))
	if from_name.is_empty(): from_name = "一位旅人"
	social_panel.show_status("%s 留了话。" % from_name)
	if social_panel.visible:
		remote.member.request_social("social-state", "state")


func _on_remote_state(farm: FarmState, decorations: DecorationState, _now: float) -> void:
	if not _loaded:
		return
	# A different layout means a different island; rebuilding it is its own flow,
	# so say so rather than rendering fields that do not exist here.
	if farm.snapshot().layout != farm_state.snapshot().layout:
		hud.show_notice("世界的院落已变化，请重新加入。")
		return
	farm_state.accept(farm)
	decoration_state.restore_snapshot(decorations.snapshot())
	_notice_missing_remote_bag()
	refresh_farm()
	# The kitchen is a world-shared document, so a summary (including the one
	# broadcast after another member's kitchen command) is what makes it visible
	# here; the book shows it without waiting for this client to act again.
	var kitchen: Dictionary = farm_state.snapshot().kitchen
	kitchen_display.refresh(kitchen)
	if decoration_layout != null:
		decoration_layout.update_life(kitchen)
	if harvest_book != null:
		harvest_book.decorations = decoration_state.snapshot()
		if harvest_book.active:
			harvest_book.update_time(float(clock.call()))
			harvest_book.refresh(_display_state())
	if market_panel != null and market_panel.visible:
		_refresh_market()
	if bank_panel != null and bank_panel.visible:
		_refresh_bank()
	# 摘要携带新的地籍视图；打开中的宅基面板跟着刷新，成员无需本地回放主张。
	if build_panel != null and build_panel.visible:
		_refresh_homes()
	# A reconnect or periodic summary also refreshes the authoritative nature
	# view; compare against the last applied kind and skip the common case.
	_sync_weather()


func _on_remote_committed(request_id: String, reply: Dictionary) -> void:
	var pending: Dictionary = _remote_pending.get(request_id, {}) as Dictionary
	_remote_pending.erase(request_id)
	if pending.is_empty() or not _loaded:
		return
	var command: Dictionary = pending.get("command", {}) as Dictionary
	if FarmCommand.is_economy_kind(str(command.get("kind", ""))):
		# Economy writes are not replayed locally: the authority also broadcasts
		# the full summary, and a local replay would double-apply the change or
		# diverge on fees and scan results.
		_on_economy_committed(pending, command, reply)
		return
	if not bool(reply.get("ok", false)):
		hud.show_notice(_remote_reason(str(reply.get("reason", ""))))
		if str(command.get("kind", "")) == "kitchen":
			# The panel showed a revision the authority no longer holds; redraw
			# it from the last confirmed document instead of leaving a stale row.
			harvest_book.refresh(_display_state())
		_cancel_tool()
		_refresh_hud()
		return
	# A granted harvest is decided by the owner's record on the authority; the
	# reply states whether it was in force so this replay reaches the same verdict.
	if reply.has("authorized"):
		command["authorized"] = bool(reply.authorized)
	var applied: bool = _apply_remote_command(command, str(pending.tool))
	var kind: String = str(command.get("kind", ""))
	if applied and kind == "set_theft":
		_theft_on = bool(command.get("enabled", false))
		if social_panel != null:
			social_panel.show_status("已允许邻居偷一份收成。" if _theft_on else "已关闭偷菜。")
			social_panel.present(social_panel.view, remote.member.roster, _my_bag(), _theft_on)
	if applied and kind in ["build", "demolish"] and build_panel != null and build_panel.visible:
		_refresh_homes()
	if applied and kind == "gift" and social_panel != null:
		var crop_id: String = str(command.get("crop_id", ""))
		var crop: String = str(Crops.definition(crop_id).get("name", ""))
		social_panel.show_status("已经送出一份%s。" % crop)
		social_panel.present(social_panel.view, remote.member.roster, _my_bag(), _theft_on)
	if kind == "kitchen" and not applied:
		# A summary may have already delivered this commit (the authority
		# broadcasts one for shared documents); redraw from what it applied.
		_refresh_kitchen_views(str(command.get("action", "")))


## ADR-027: mirror a gift addressed to this player after the projection dropped
## the sender's pocket. The sender half is already reflected by the authority's
## summary; crediting twice is impossible because a duplicate event returns
## before this helper.
func _credit_received_gift(command: Dictionary, actor: String) -> bool:
	if remote == null or remote.player_id.is_empty() or actor == remote.player_id:
		return false
	if str(command.get("to_id", "")) != remote.player_id:
		return false
	return farm_state.credit_view_bag(remote.player_id,
		str(command.get("crop_id", "")), int(command.get("amount", 0)))


func _on_remote_changed(entry: Dictionary) -> void:
	if not _loaded:
		return
	var command: Variant = entry.get("command")
	if command is Dictionary:
		var kind: String = str((command as Dictionary).get("kind", ""))
		if FarmCommand.is_economy_kind(kind) or kind == "kitchen":
			# The change entry carries no settled fees or scan counts, and a
			# kitchen replay would spend the *sender's* pocket, which this
			# projection does not carry. The full summary that follows every
			# shared-document commit is the only safe way to apply it locally.
			return
		# The broadcast names who did it; replaying under this player's id would
		# put a neighbour's harvest into this player's own bag.
		var applied: bool = _apply_remote_command(command, kind,
			str(entry.get("from_id", "")))
		if applied:
			_announce_neighbour(entry, command)
			# Houses and gifts change what the panel shows; an open one must not
			# keep offering a slot that a neighbour just took.
			if build_panel != null and build_panel.visible \
					and str((command as Dictionary).get("kind", "")) in ["build", "demolish"]:
				_refresh_homes()
			# A gift changes what this player owns, so an open panel must show the
			# new picker instead of a stale one.
			if social_panel != null and social_panel.visible 					and str((command as Dictionary).get("kind", "")) == "gift":
				social_panel.present(social_panel.view, remote.member.roster, _my_bag(), _theft_on)


## A neighbour's action is worth one quiet line: it is the difference between a
## shared farm and a farm that merely syncs. Anonymous members have no name and
## are not announced, so nobody is labelled with an invented one.
func _announce_neighbour(entry: Dictionary, command: Dictionary) -> void:
	var who: String = str(entry.get("from_name", ""))
	if who.is_empty():
		return
	var kind: String = str(command.get("kind", ""))
	var crop_id: String = str(command.get("crop_id", ""))
	if kind == "build":
		var blueprint: String = str(command.get("blueprint", ""))
		var title: String = str(BuildingCatalog.definition(blueprint).get("name", "房子"))
		hud.show_notice("%s 盖起了%s" % [who, title])
		return
	if kind == "demolish":
		hud.show_notice("%s 拆掉了一座房子" % who)
		return
	if kind == "harvest":
		crop_id = str(entry.get("reward_crop_id", ""))
	var crop: String = str(Crops.definition(crop_id).get("name", "")) if not crop_id.is_empty() else ""
	# A gift is addressed to a person: say so when it is this player's.
	if kind == "gift":
		var to_id: String = str(command.get("to_id", ""))
		var name: String = crop if not crop.is_empty() else "收成"
		if remote != null and not remote.player_id.is_empty() and to_id == remote.player_id:
			hud.show_notice("%s 送了你一份%s" % [who, name])
		else:
			hud.show_notice("%s 送给邻居一份%s" % [who, name])
		return
	var action: String = ""
	match kind:
		"harvest": action = ("收了" + crop) if not crop.is_empty() else "收了菜"
		"sow": action = ("种下了" + crop) if not crop.is_empty() else "种下了菜"
		"water": action = "浇了水"
		"weed": action = "除了草"
		"till": action = "翻了土"
	if action.is_empty():
		return
	hud.show_notice("%s %s" % [who, action])


## Replays a command the authority accepted. The rules are deterministic, so the
## local view converges without shipping a snapshot per action; the periodic
## summary corrects any drift this client never saw.
func _apply_remote_command(command: Dictionary, tool: String, actor: Variant = null) -> bool:
	# Harvest credits the actor's bag on the authority, so the replay must use the
	# same actor or the two views drift until the next summary. A neighbour's
	# broadcast carries its own id; this player's own command uses this player's.
	var who: String = str(actor) if actor != null else (remote.player_id if remote != null else "")
	var kind: String = str(command.get("kind", ""))
	var execution: Dictionary = farm_commands.execute(farm_state, command, who,
		decoration_state.snapshot())
	if execution.duplicate:
		return false
	var result: Dictionary = execution.get("result", {}) as Dictionary
	if not bool(execution.get("ok", false)) or not bool(result.get("ok", false)):
		# ADR-027: a projected view omits the giver's bag, so the deterministic
		# gift rule refuses for lack of produce even though the authority already
		# accepted the transfer. Mirror only the recipient half; the next summary
		# stays authoritative.
		if kind == "gift" and _credit_received_gift(command, who):
			_refresh_hud()
			return true
		return false
	# The kitchen changes a world-shared document and may unlock the drying rack
	# from a shared meal; applying it through the same helper as the local path
	# keeps the visible result identical.
	if kind == "kitchen":
		var decorations := DecorationState.new()
		decorations.restore_snapshot(decoration_state.snapshot())
		var unlock_state: Dictionary = _display_state(execution.candidate as FarmState)
		decorations.unlock(unlock_state.harvested, unlock_state.kitchen)
		_adopt_kitchen(execution.candidate as FarmState, decorations,
			str(command.get("action", "")))
		return true
	# A gift only moves produce between bags, a theft setting records a standing,
	# and a building is not soil work; none of them may run the soil visual path.
	if kind in ["gift", "set_theft", "build", "demolish"]:
		farm_state.accept(execution.candidate as FarmState)
		if kind == "build" or kind == "demolish":
			_refresh_homes_scene()
		_refresh_hud()
		return true
	_commit_tool(tool, execution.candidate as FarmState, result)
	return true


## A lost or replaced session can no longer answer the requests that were still
## waiting. Retire them before an old id can match a new request after reconnect,
## and tell the panel that owns each waiting tool instead of leaving it pending.
func _clear_remote_pending(reason: String) -> void:
	if _remote_pending.is_empty():
		return
	var tools: Dictionary = {}
	for entry: Dictionary in _remote_pending.values():
		tools[str(entry.get("tool", ""))] = true
	_remote_pending.clear()
	var text: String = _remote_reason(reason)
	if tools.has("market") or tools.has("bank"):
		_show_economy_status(text)
	if (tools.has("gift") or tools.has("theft")) and social_panel != null:
		social_panel.show_status(text)
	if (tools.has("build") or tools.has("demolish")) and build_panel != null:
		build_panel.show_status(text)
	if tools.has("kitchen") and harvest_book != null and _loaded:
		# A kitchen request has no panel of its own: redraw the book from the last
		# confirmed document so no action stays visually pending.
		harvest_book.refresh(_display_state())


func _on_remote_lost(reason: String) -> void:
	# Pending replies are gone with the connection; a later reconnect must not
	# mistake an old request id for a new one.
	_clear_remote_pending("connection_lost")
	# Built markers describe the authority's current document, so they do not
	# outlive the connection; the housing view keeps its last confirmed frame.
	if public_works_view != null:
		public_works_view.clear()
	# 居民视图属于权威，连接断开后不再成立；清空列表并标明世界未打开，保留
	# 面板本身让玩家看到原因。
	if resident_panel != null:
		resident_panel.show_unavailable("not_open")
	# 规则决议视图属于权威，连接断开后不再成立；清空列表并标明世界未打开，保留
	# 面板本身让玩家看到原因。
	if resolutions_panel != null:
		resolutions_panel.show_unavailable("not_open")
	# 对话视图属于权威，连接断开后不再成立；清空列表并标明世界未打开，保留
	# 面板本身让玩家看到原因。
	if dialogue_panel != null:
		dialogue_panel.show_unavailable("not_open")
	hud.show_notice("与世界断开：%s。画面停在最后一次确认的状态，未完成的请求已取消。" % _remote_reason(reason))
	_cancel_tool()
	_refresh_hud()


## 客户端会自己按 1/2/4/8/16/30 秒退避重试；这里只把进展告诉玩家，画面
## 保持最后确认的一帧，仍然可交互但不会产生本地写入。
func _on_remote_reconnecting(attempt: int, _delay: float) -> void:
	# 居民视图属于权威，重连期间不再成立；其余画面停在最后确认的一帧，居民
	# 面板清空并标明世界未打开，避免把旧名册当成当前事实。
	if resident_panel != null:
		resident_panel.show_unavailable("not_open")
	if resolutions_panel != null:
		resolutions_panel.show_unavailable("not_open")
	if dialogue_panel != null:
		dialogue_panel.show_unavailable("not_open")
	hud.show_notice("正在重新连接世界（第 %d 次）…" % attempt)


func _on_remote_reconnected(_sequence: int) -> void:
	# A request submitted during the tail of a broken link has no reply to wait
	# for either; clear it again so the new session starts with a clean table.
	_clear_remote_pending("connection_lost")
	hud.show_notice("已重新连上世界")


## The connection is still there; only one whole-world refresh could not travel.
## Nothing was applied, so the screen keeps the last confirmed state and the next
## reconcile asks again.
func _on_remote_summary_refused(reason: String) -> void:
	hud.show_notice("世界资料过大，暂时无法刷新（%s）。画面停在最后一次确认的状态。"
		% _remote_reason(reason))

## Authority refusals are codes; a player needs to know what to do about them.
func _remote_reason(reason: String) -> String:
	match reason:
		"forbidden": return "没有这项操作的权限"
		"not_a_member": return "已不在这个世界中"
		"read_only": return "世界正在搬迁，暂时不能操作"
		"command_conflict": return "地里已经变了，请再试一次"
		"time_backwards": return "与世界时间不一致，请稍后再试"
		"server_disconnected": return "连接已关闭"
		"connection_failed": return "连不上服务器"
		"theft_disabled": return "这是别人种的，对方没有开放偷菜"
		"not_owner": return "只有房主能拆"
		"theft_limit": return "今天已经从这家拿走够多了"
		"theft_cooldown": return "刚取过一次，稍后再来"
		"invalid_player": return "还没有可用的玩家身份"
		"connection_lost": return "连接已断开，未完成的请求已取消，请重新提交。"
		"invalid_slot": return "这里不能盖房"
		"invalid_blueprint": return "没有这种房子"
		"occupied": return "这块宅基已经有房子了"
		"payload_too_large": return "世界资料超过一条消息的大小上限"
		"rate_limited": return "操作太频繁，请稍后再试"
		"not_parcel_owner": return "这块地不属于你，不能在这里建造"
		"slot_unmapped": return "这个宅基还没有对应地块，暂时不能建造"
		"land_unavailable": return "地籍尚未载入，暂时不能建造"
		"stale_land": return "土地状态已变化，请重试"
		"empty": return "这里还没有建筑"
		"stale_kitchen": return "厨房已经变化，请刷新后再试"
		"invalid_action": return "没有这种厨房操作"
		"wrong_crop": return "这份食材做不了这道菜"
		"invalid_station": return "这个工位做不了这道菜"
		"station_busy": return "这个工位还在用"
		"station_unavailable": return "这个工位还没有摆放好"
		"insufficient_food": return "食材不够"
		"no_dish": return "还没有这道成品"
		"already_displayed": return "这道菜已经摆上了"
		"invalid_neighbor": return "邻里身份无效"
		"not_ready": return "这道菜还没有做好"
		"join_player_proof": return "这个世界登记的是另一个玩家档案；换回原来的档案，或请房主重置这个身份的绑定"
		"join_player_invalid_secret": return "本机玩家凭据缺失或损坏，暂时无法以具名身份进入"
		"join_invalid_player": return "玩家身份或名称无效，无法进入世界"
		"join_player_bindings_unavailable": return "服务器还没有准备好身份记录，请稍后再试"
		"": return "未知原因"
	if reason.begins_with("save_player_bindings_") \
			or reason.begins_with("join_save_player_bindings_"):
		return "玩家身份未能保存这次操作"
	if reason.begins_with("save_land_"): return "土地状态未能保存这次操作"
	if reason.begins_with("save_"): return "世界未能保存这次操作"
	return reason


func _reload_saved_scene() -> void:
	_loaded = false
	process_mode = Node.PROCESS_MODE_DISABLED
	if is_instance_valid(farm_audio): farm_audio.shutdown()
	await get_tree().create_timer(.1,true,false,true).timeout
	var replacement: Node3D = load("res://scenes/main.tscn").instantiate()
	replacement.name=name
	replacement.store = store
	replacement.settings_store = settings_store
	replacement.clock = clock
	# The cart identity is session context, not saved state: without it the
	# rebuilt scene would read the shared inventory and grant a second account
	# to `local_player`.
	replacement.local_player_id = local_player_id
	replacement.previous_layout=previous_layout.duplicate(true)
	if island_builder!=null and island_builder.active and not island_builder.close_after_commit:
		replacement._construction_resume={"tool":island_builder.tool,"point":camera.focus_point,"view":camera.view}
	if focus_detail!=null:
		replacement._presentation_resume=focus_detail.get_settings()
		replacement._presentation_resume.hour=atmosphere.get_preview_hour()
	var tree: SceneTree = get_tree()
	var parent: Node = get_parent()
	var was_current: bool = tree.current_scene == self
	parent.remove_child(self)
	parent.add_child(replacement)
	if was_current: tree.current_scene = replacement
	queue_free()


## Every local farm write goes through here. The nature seed is written first
## because it is the input that makes moisture settlement reproducible; a failed
## seed write keeps the action retryable and returns a save-failure kind, so the
## callers' existing input lock and storage overlay handle it without a second
## error path.
func _save_state(candidate: FarmState, decorations: DecorationState) -> Dictionary:
	var nature_saved: Dictionary = _prepare_local_write()
	if not nature_saved.ok:
		return nature_saved
	return store.save_state(candidate, decorations)


func _save_state_snapshot(farm_document: Dictionary, decoration_document: Dictionary) -> Dictionary:
	var nature_saved: Dictionary = _prepare_local_write()
	if not nature_saved.ok:
		return nature_saved
	return store.save(farm_document, decoration_document)


## A shared world has no local writes: every menu that would reach one refuses
## before opening, so this only fires if a future path forgets that gate. It
## fails loudly instead of reporting a success that the authority never saw.
func _prepare_local_write() -> Dictionary:
	if remote != null:
		push_error("local save attempted in a shared world")
		return {"ok": false, "kind": "shared_world"}
	var nature_saved: Dictionary = _ensure_nature_persisted()
	if not nature_saved.ok:
		return {"ok": false, "kind": "save_nature_" + str(nature_saved.kind)}
	return nature_saved


## Mirrors HeadlessWorld's first-commit rule: re-read before writing so a seed
## another authority already committed is adopted instead of overwritten, and a
## corrupt document is never replaced by a fresh one.
func _ensure_nature_persisted() -> Dictionary:
	if nature_state == null or nature_store == null:
		return {"ok": false, "kind": "not_open"}
	if _nature_persisted:
		return {"ok": true, "kind": "already_saved"}
	var current: Dictionary = nature_store.load_state()
	if not current.ok:
		return {"ok": false, "kind": "reread_" + str(current.kind)}
	if current.kind == "loaded":
		if not nature_state.restore_snapshot(current.state):
			return {"ok": false, "kind": "corrupt"}
		_nature_persisted = true
		return {"ok": true, "kind": "adopted"}
	var saved: Dictionary = nature_store.save_state(nature_state.snapshot())
	if saved.ok:
		_nature_persisted = true
	return saved


func _save_farm() -> bool:
	if not _loaded:
		return false
	# A shared world is saved by its authority; writing a local copy here would
	# fork the world into two states that only look like one.
	if remote != null:
		return true
	var result: Dictionary = _save_state(farm_state, decoration_state)
	_save_failed = not result.ok
	if _save_failed:
		if garden_album!=null: garden_album.end_photo()
		if harvest_book!=null: harvest_book.dismiss()
		if animal_panel!=null: animal_panel.dismiss()
		if game_menu != null:
			game_menu.dismiss()
		if decoration_layout != null:
			decoration_layout.finish_mode()
		_cancel_input()
		selected_tool = ""
		selected_palette = ""
		hud.show_storage_issue(result.kind, true)
	else:
		hud.show_saved()
	_refresh_hud()
	return result.ok


func _retry_storage() -> void:
	if _loaded:
		settle_farm()
		_save_farm()
	else:
		_load_game()


func _recover_storage() -> void:
	if _nature_recovery_available:
		var nature_result: Dictionary = nature_store.recover()
		if not nature_result.ok:
			hud.show_storage_issue("nature_" + str(nature_result.kind), false)
			return
		_nature_recovery_available = false
		_load_game()
		return
	var result: Dictionary = store.recover()
	if not result.ok:
		hud.show_storage_issue(result.kind, false)
		return
	_load_game()


func _export_world_package(directory: String) -> void:
	if not _loaded or _save_failed or _exiting:
		return
	if remote != null:
		game_menu.set_world_status("联机世界中，世界包由服务器保存。")
		return
	settle_farm()
	if not _save_farm():
		return
	var result: Dictionary = WorldTransfer.export_world(store.directory, directory)
	if result.ok:
		game_menu.set_world_status("世界包已导出到：%s" % str(result.summary.get("output_directory", directory)))
	else:
		game_menu.set_world_status(_world_transfer_message(result.kind, true))


func _prepare_world_import(directory: String) -> void:
	if not _loaded or _save_failed or _exiting:
		return
	if remote != null:
		game_menu.set_world_status("联机世界中，不能导入本地存档。")
		return
	# Validation is read-only; the live save is untouched until confirmation.
	var result: Dictionary = WorldTransfer.prepare_import(directory, store.directory)
	if not result.ok:
		game_menu.set_world_status(_world_transfer_message(result.kind, false))
		return
	_pending_world_import = result
	game_menu.present_world_import(result.summary)


func _confirm_world_import() -> void:
	if _pending_world_import.is_empty() or not _loaded or _save_failed:
		return
	settle_farm()
	if not _save_farm():
		_pending_world_import = {}
		return
	var result: Dictionary = WorldTransfer.apply_import(_pending_world_import, store.directory)
	if not result.ok:
		game_menu.world_import_failed(_world_transfer_message(result.kind, false))
		return
	_pending_world_import = {}
	# The old store admitted the previous main; rebuild it before the scene reload
	# so later saves trust the imported bytes rather than the pre-import text.
	store = FarmStore.new(store.directory)
	previous_layout = {}
	previous_decorations = {}
	_construction_resume = {}
	_presentation_resume = {}
	_reload_saved_scene()


func _cancel_world_import() -> void:
	_pending_world_import = {}


func _world_transfer_message(kind: String, exporting: bool) -> String:
	if kind.begins_with("write_") or kind.begins_with("flush_") or kind.begins_with("verify_") or kind.begins_with("replace_"):
		return "导出未能完成，请换一个空文件夹重试。" if exporting else "写入存档失败，原存档已保留。"
	match kind:
		"missing":
			return "没有找到当前农场存档。" if exporting else "没有找到可导入的世界包，请选择包含 world.json 的文件夹。"
		"ambiguous":
			return "这个文件夹里有多个世界包，请选择其中一个世界目录。"
		"corrupt":
			return "世界包无法读取，文件可能已损坏；当前存档未改变。" if not exporting else "当前农场存档无法读取。"
		"too_large":
			return "世界包过大，无法导入；当前存档未改变。"
		"newer_rules", "newer_version", "newer_format":
			return "世界包来自更新的游戏版本，请先更新游戏。"
		"unsupported_rules", "unsupported_version", "unsupported_format":
			return "世界包来自较旧版本，当前无法导入。"
		"unknown_format":
			return "世界包格式不受支持。"
		"invalid_snapshot", "invalid_decorations", "invalid_farm", "invalid_time":
			return "世界包内容不完整，无法导入；当前存档未改变。"
		"invalid_identifier", "invalid_identity", "identity_mismatch":
			return "世界包的身份记录无效，无法导入。"
		"identity_conflict":
			return "这个文件夹已有另一个玩家身份，请选择一个空文件夹。"
		"existing_output":
			return "这个文件夹已有内容，请选择一个空文件夹。"
		"unsafe_path", "unsafe_output":
			return "不能在这个位置读写世界包，请选择其他文件夹。"
		"package_changed":
			return "世界包在确认前发生了变化，请重新选择。"
		"changed_path":
			return "存档位置发生了变化，请重新打开设置。"
		"changed_on_disk":
			return "存档在确认前发生了变化，本次导入未执行。"
		"create_backup", "backup_copy", "backup_replace":
			return "备份原存档失败，本次导入未执行。"
		"verify_import":
			return "导入后校验失败，已尽量恢复原存档。"
		"recovery_available":
			return "当前存档需要先恢复，暂时不能导入。"
		"nature_recovery_available":
			return "天气记录需要先恢复，本次操作未执行。"
		"unsupported":
			return "当前存档来自更新的版本，不能覆盖。"
		"io":
			return "无法读取存档或世界包，请稍后重试。"
		"conflict", "identity_write":
			return "导出未能完成，请换一个空文件夹重试。" if exporting else "身份记录未能写入，但农场已导入。"
		_:
			return "导出未能完成，请稍后重试。" if exporting else "本次导入未完成，当前存档已保留。"


func _request_exit() -> void:
	if _exiting:
		return
	# A wallpaper window hides the HUD; restore it first so a failed save can
	# still show its recovery choices.
	if desktop_wallpaper != null and desktop_wallpaper.active and not _restore_before_exit:
		_restore_before_exit = true
		desktop_wallpaper.restore()
		await desktop_wallpaper.changed
		_restore_before_exit = false
		if not is_inside_tree(): return
		_request_exit()
		return
	if garden_album!=null and garden_album.busy: return
	_cancel_input()
	if not _loaded:
		_finish_exit()
		return
	if game_menu != null:
		if (_settings_dirty or not _settings_issue.is_empty()) and not _allow_leave_settings:
			_open_menu()
			if not _save_settings():
				return
		game_menu.dismiss()
	if decoration_layout != null:
		decoration_layout.finish_mode()
	settle_farm()
	if _save_farm():
		_finish_exit()


func _finish_exit() -> void:
	if _exiting:
		return
	_exiting = true
	_cancel_input()
	selected_tool = ""
	selected_palette = ""
	# Admission is final: saving succeeded, or the player explicitly chose to
	# leave without saving. No UI, timers, focus events or repeated close may write
	# state or restart audio during the short mixer drain.
	get_viewport().gui_disable_input = true
	process_mode = Node.PROCESS_MODE_DISABLED
	if is_instance_valid(farm_audio):
		farm_audio.shutdown()
	await get_tree().create_timer(0.1, true, false, true).timeout
	await get_tree().process_frame
	get_tree().quit()


func settle_farm() -> void:
	if not _loaded:
		return
	var result: Dictionary = farm_state.settle(clock.call())
	harvest_book.update_time(clock.call())
	if result.ok:
		for field_id: String in result.visual_changed:
			if field_id == TrellisSlots.FIELD_ID: refresh_trellis()
			else: farm.show_field(farm_state.get_field(field_id))
		_refresh_hud()
	_refresh_homes_scene()
	# The idle tick also crosses weather blocks; the comparison inside makes a
	# same-kind tick free.
	_sync_weather()


func _presentation_changed(visible: bool) -> void:
	_cancel_input()
	if visible:
		settle_farm()
		atmosphere._apply_clock()


func refresh_farm() -> void:
	for field_id: String in farm_state.field_ids():
		farm.show_field(farm_state.get_field(field_id))
	refresh_trellis()
	_refresh_hud()
	_refresh_homes_scene()


## Houses are derived from the mirrored document, never from a local build call.
## `buildings_at` turns done_utc into the visible state, so a construction that
## finishes while the client is idle changes on the next settlement tick.
func _refresh_homes_scene() -> void:
	if remote == null or housing_view == null or farm_state == null:
		return
	housing_view.refresh(farm_state.buildings_at(remote.world_time()),
		str(remote.grant.get("world_id", "")))


func refresh_trellis() -> void:
	if trellis_crops.show_state(courtyard_plan,farm_state.get_field(TrellisSlots.FIELD_ID)) and focus_detail!=null:
		focus_detail._bounds_dirty=true


func _planting_id(index: int) -> String:
	return TrellisSlots.FIELD_ID if index==TrellisCrops.INDEX else farm.field_id(index)


func _select_field_visual(index: int) -> void:
	farm.select_field(-1 if index==TrellisCrops.INDEX else index)
	trellis_crops.select(trellis_crops._selected,index==TrellisCrops.INDEX)


func _select_cell_visual(index: int,id: String) -> void:
	farm.select_cell(-1 if index==TrellisCrops.INDEX else index,id)
	trellis_crops.select(id if index==TrellisCrops.INDEX else "",selected_field==TrellisCrops.INDEX)


func _refresh_hud() -> void:
	if hud == null or not _loaded:
		return
	# The selected cell is what the player is working on; hovering still gives a
	# preview before the first click. The HUD shows the soil's own moisture and
	# the growth rate it applies, both read-only views of the authoritative cell.
	var cell: Dictionary = {}
	if selected_field >= 0 and not selected_cell.is_empty():
		cell = farm_state.get_cell(_planting_id(selected_field), selected_cell)
	elif hover_field >= 0 and not hover_cell.is_empty():
		cell = farm_state.get_cell(_planting_id(hover_field), hover_cell)
	var state: Dictionary=_display_state()
	hud.show_state(cell, state.harvested, selected_tool, selected_crop, camera.is_transitioning() or _save_failed or camera.free_view or _basket_active() or (camera_tuning != null and camera_tuning.visible) or (sway_tuning != null and sway_tuning.visible), selected_field, selected_palette, state.inventory)
	hud.show_decoration_mode(decoration_layout != null and decoration_layout.active)
	if _layout_active(): hud.show_decoration_mode(true)

func _basket_active() -> bool:
	return harvest_book!=null and harvest_book.active

func _animal_active() -> bool:
	return animal_panel!=null and animal_panel.active

func _animal_at(point: Vector2) -> String:
	var animals: Node=$Environment/CourtyardAnimals
	var chosen: String=""
	var depth: float=INF
	for bird: Dictionary in animals.birds:
		var center: Vector3=bird.node.global_position+Vector3.UP*(.24 if bird.kind=="hen" else (.48 if bird.kind=="duck" else .67))*bird.node.scale.x
		if camera.is_position_behind(center): continue
		var projected: Vector2=camera.unproject_position(center)
		var edge: Vector2=camera.unproject_position(center+camera.global_basis.x*bird.radius)
		var radius: float=clampf(projected.distance_to(edge),12,42)
		if point.distance_to(projected)>radius: continue
		var distance: float=camera.global_position.distance_to(center)
		if distance<depth and decoration_layout.world_point_visible(center,animals):
			chosen=bird.node.name;depth=distance
	return chosen

func _open_animal(id: String) -> void:
	if remote != null:
		hud.show_notice("联机模式下，动物由世界房主照料。")
		return
	if not _tools_available(): return
	var bird: Dictionary=$Environment/CourtyardAnimals.interaction.find(id)
	if bird.is_empty(): return
	_cancel_tool();hud.hide_time_preview();camera.cancel_zoom()
	var data: Dictionary=_display_state()
	animal_panel.present(id,data.animals[id],data.inventory)
	focus_detail.protect_neighbor(bird.node)
	camera.view_neighbor(bird.node.global_position+Vector3.UP*.25,Vector3(27.5,24,5.8))
	hud.hide()
	_refresh_hud()

func _animal_action(id: String,action: String,value: Variant,revision: int) -> void:
	if _world_edit_unavailable():
		return
	if not _animal_active() or animal_panel.animal_id!=id or not _loaded or _save_failed: return
	var interaction: RefCounted=$Environment/CourtyardAnimals.interaction
	var approach: Dictionary={}
	if action in ["feed","call"]:
		approach=interaction.prepare(id,camera,decoration_layout.world_point_visible)
		if approach.is_empty(): animal_panel.show_issue("这会儿没有能靠近的空位");return
	var candidate: FarmState = farm_state.copy()
	var result: Dictionary=candidate.animal_action(id,action,value,revision)
	if not result.ok:
		animal_panel.show_issue("名字请用一到十二个字" if result.reason=="invalid_name" else "这次操作未完成")
		return
	var saved: Dictionary=_save_state(candidate,decoration_state)
	if not saved.ok:
		_save_failed=true;animal_panel.dismiss();hud.show_storage_issue(saved.kind,true);_refresh_hud();return
	farm_state.accept(candidate)
	var data: Dictionary=_display_state()
	interaction.profiles=data.animals
	if not approach.is_empty(): interaction.begin(id,approach,action=="feed")
	animal_panel.refresh(data.animals[id],data.inventory)
	animal_panel.set_activity(interaction.status(id))
	farm_audio.play_ui()
	_refresh_hud()

func _open_basket() -> void:
	if not _tools_available(): return
	_cancel_tool()
	hud.hide_time_preview()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	camera.free_input_enabled=false
	harvest_book.update_time(clock.call())
	harvest_book.decorations=decoration_state.snapshot()
	harvest_book.present(_display_state())
	_refresh_hud()


## The market is a view over the same farm document. Opening it first settles
## the deterministic sweeps (expiry, matching, delivery), then shows exactly
## what the rules would decide at that instant.
func _open_market() -> void:
	if not _loaded or _save_failed or farm_state == null or market_panel == null:
		return
	if not _tools_available():
		return
	_cancel_tool()
	hud.hide_time_preview()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	var message: String = ""
	if remote == null:
		message = _prepare_singleplayer_market()
		if not message.is_empty():
			hud.show_notice(message)
			return
		var settlement: Dictionary = _settle_market(float(clock.call()))
		if bool(settlement.get("changed", false)) and not _save_farm():
			return
		message = _market_settlement_text("", settlement)
	else:
		message = _prepare_remote_market()
	camera.free_input_enabled = false
	_refresh_market(message)
	market_panel.show()


## A singleplayer market needs one player account and the rule merchant once.
## Both commands are durable and idempotent; the fixed ids are only called when
## the durable marker is still absent.
func _prepare_singleplayer_market() -> String:
	var owner: String = _market_owner()
	if owner.is_empty():
		return "没有找到本机玩家。"
	var now: float = float(clock.call())
	var changed: bool = false
	var snapshot: Dictionary = farm_state.economy_snapshot()
	var accounts: Variant = snapshot.get("accounts")
	var account: Variant = accounts.get(owner) if accounts is Dictionary else null
	if not account is Dictionary or not bool(account.get("granted", false)):
		var opened: Dictionary = farm_state.economy_open_account(
			"market-open-" + owner, owner, now)
		if opened.ok:
			changed = true
		elif str(opened.get("reason", "")) != "already_granted":
			return _market_reason(str(opened.get("reason", "")))
	var merchant: Dictionary = farm_state.market_merchant()
	if not bool(merchant.get("opened", false)):
		var opened_merchant: Dictionary = farm_state.market_open_merchant("market-merchant", now)
		if opened_merchant.ok:
			changed = true
		elif str(opened_merchant.get("reason", "")) != "already_opened":
			return _market_reason(str(opened_merchant.get("reason", "")))
	if changed and not _save_farm():
		return "市场开张未能保存。"
	return ""


## The shared market needs the member's account and the world's merchant once.
## Both are durable, so opening the panel only submits the missing fixed-id
## command and lets the authority decide; no local economy write happens here.
func _prepare_remote_market() -> String:
	if not _remote_economy_writable():
		return ""
	var message: String = _ensure_remote_account()
	if not message.is_empty():
		return message
	if not bool(farm_state.market_merchant().get("opened", false)):
		return _submit_fixed_command("market-merchant", "market_open", "market_open")
	return ""


## Expiry, matching and delivery are authority sweeps, not panel actions. They
## run on the farm candidate and only report what actually changed.
func _settle_market(now: float) -> Dictionary:
	if remote != null or farm_state == null:
		return {"ok": true, "changed": false, "trades": 0, "expired": 0, "delivered": 0}
	var expired: Dictionary = farm_state.market_expire(now)
	if not expired.ok:
		return {"ok": false, "changed": false, "trades": 0, "expired": 0, "delivered": 0,
			"message": _market_reason(str(expired.get("reason", "")))}
	var matched: Dictionary = farm_state.market_match(now)
	if not matched.ok:
		return {"ok": false, "changed": int(expired.get("expired", 0)) > 0, "trades": 0,
			"expired": int(expired.get("expired", 0)), "delivered": 0,
			"message": _market_reason(str(matched.get("reason", "")))}
	var delivered: Dictionary = farm_state.market_deliver(now)
	if not delivered.ok:
		return {"ok": false, "changed": int(expired.get("expired", 0)) > 0
			or int(matched.get("count", 0)) > 0, "trades": int(matched.get("count", 0)),
			"expired": int(expired.get("expired", 0)), "delivered": 0,
			"message": _market_reason(str(delivered.get("reason", "")))}
	var changes: int = int(expired.get("expired", 0)) + int(matched.get("count", 0)) \
		+ int(delivered.get("count", 0)) + int(delivered.get("lost", 0))
	return {"ok": true, "changed": changes > 0, "trades": int(matched.get("count", 0)),
		"expired": int(expired.get("expired", 0)), "delivered": int(delivered.get("count", 0)),
		"lost": int(delivered.get("lost", 0))}


## A failed save leaves memory ahead of the durable copy; another economy write
## would widen that gap invisibly. The refusal is named so the panel can show it,
## and a later successful `_save_farm` clears the flag without extra state.
func _save_failed_refusal(panel: CanvasLayer) -> String:
	if not _save_failed:
		return ""
	panel.show_status("保存失败，暂时不能进行经济操作。请先重试保存。")
	return SAVE_FAILED_REASON


func _market_order(side: String, good_id: String, price: int, quantity: int,
		expires_utc: float) -> String:
	var refusal: String = _save_failed_refusal(market_panel)
	if not refusal.is_empty():
		return refusal
	if remote != null:
		if not _remote_economy_writable():
			market_panel.show_status(_remote_economy_reason())
			return ""
		_send_economy_command(FarmCommand.make_market_place(_new_command_id(), side, good_id,
			price, quantity, expires_utc, remote.world_time()), "market")
		return ""
	if farm_state == null:
		return ""
	var now: float = float(clock.call())
	var result: Dictionary = farm_state.market_place_order(_new_command_id(), _market_owner(),
		side, good_id, price, quantity, expires_utc, now)
	if not result.ok:
		market_panel.show_status(_market_reason(str(result.get("reason", ""))))
		return ""
	var settlement: Dictionary = _settle_market(now)
	if not _save_farm():
		return ""
	_refresh_market(_market_settlement_text("已下单", settlement))
	return ""


func _market_cancel(order_id: String) -> String:
	var refusal: String = _save_failed_refusal(market_panel)
	if not refusal.is_empty():
		return refusal
	if remote != null:
		if not _remote_economy_writable():
			market_panel.show_status(_remote_economy_reason())
			return ""
		_send_economy_command(FarmCommand.make_market_cancel(_new_command_id(), order_id,
			remote.world_time()), "market")
		return ""
	if farm_state == null:
		return ""
	var now: float = float(clock.call())
	var result: Dictionary = farm_state.market_cancel_order(_new_command_id(), _market_owner(),
		order_id, now)
	if not result.ok:
		market_panel.show_status(_market_reason(str(result.get("reason", ""))))
		return ""
	var settlement: Dictionary = _settle_market(now)
	if not _save_farm():
		return ""
	_refresh_market(_market_settlement_text("已撤单", settlement))
	return ""


func _market_ship(good_id: String, quantity: int, origin: String, destination: String) -> String:
	var refusal: String = _save_failed_refusal(market_panel)
	if not refusal.is_empty():
		return refusal
	if remote != null:
		if not _remote_economy_writable():
			market_panel.show_status(_remote_economy_reason())
			return ""
		_send_economy_command(FarmCommand.make_market_ship(_new_command_id(), origin,
			destination, good_id, quantity, remote.world_time()), "market")
		return ""
	if farm_state == null:
		return ""
	var now: float = float(clock.call())
	var result: Dictionary = farm_state.market_ship(_new_command_id(), _market_owner(),
		origin, destination, good_id, quantity, now)
	if not result.ok:
		market_panel.show_status(_market_reason(str(result.get("reason", ""))))
		return ""
	var settlement: Dictionary = _settle_market(now)
	if not _save_farm():
		return ""
	_refresh_market(_market_settlement_text("已发货", settlement))
	return ""


func _market_deliver() -> String:
	var refusal: String = _save_failed_refusal(market_panel)
	if not refusal.is_empty():
		return refusal
	if remote != null:
		market_panel.show_status("货物到达后由世界自动入袋，无需手动交付。")
		return ""
	if farm_state == null:
		return ""
	var result: Dictionary = farm_state.market_deliver(float(clock.call()))
	if not result.ok:
		market_panel.show_status(_market_reason(str(result.get("reason", ""))))
		return ""
	var count: int = int(result.get("count", 0))
	if count == 0:
		_refresh_market("还没有到达的货物。")
		return ""
	if not _save_farm():
		return ""
	_refresh_market("已交付 %d 笔。" % count)
	return ""


func _market_refresh() -> void:
	if not _loaded or farm_state == null or market_panel == null:
		return
	var message: String = ""
	if remote == null:
		var settlement: Dictionary = _settle_market(float(clock.call()))
		if bool(settlement.get("changed", false)) and not _save_farm():
			return
		message = _market_settlement_text("", settlement)
	else:
		# A manual refresh asks the authority for a fresh view instead of
		# settling anything locally.
		remote.request_summary()
	_refresh_market(message)


func _refresh_market(message: String = "") -> void:
	if market_panel == null or farm_state == null:
		return
	market_panel.present(_market_view())
	if not message.is_empty():
		market_panel.show_status(message)


func _market_view() -> Dictionary:
	var owner: String = _market_owner()
	var orders: Array = farm_state.market_orders()
	var escrow_cash: int = 0
	var escrow_goods: int = 0
	for order: Dictionary in orders:
		if not _row_is_mine(order, owner) or str(order.get("status", "")) != "open":
			continue
		if str(order.get("side", "")) == "buy":
			escrow_cash += int(order.get("reserved", 0))
		else:
			escrow_goods += int(order.get("reserved", 0))
	var shipments: Array = farm_state.market_shipments()
	var in_transit: int = 0
	for shipment: Dictionary in shipments:
		if _row_is_mine(shipment, owner) \
				and str(shipment.get("status", "")) == "in_transit":
			in_transit += int(shipment.get("quantity", 0))
	var goods: Dictionary = farm_state.economy_goods(owner)
	var goods_total: int = 0
	for amount: Variant in goods.values():
		goods_total += int(amount)
	return {
		"now_utc": float(clock.call()),
		"owner": owner,
		"cash": farm_state.economy_cash(owner),
		"goods": goods_total,
		"escrow_cash": escrow_cash,
		"escrow_goods": escrow_goods,
		"in_transit": in_transit,
		"quotes": farm_state.market_quotes(),
		"orders": orders,
		"shipments": shipments,
		"deliveries": farm_state.market_deliveries(),
		"routes": farm_state.market_routes(),
		"read_only": remote != null and not _remote_economy_writable(),
		"read_only_reason": _remote_economy_reason() \
			if remote != null and not _remote_economy_writable() else "",
		"auto_delivery": remote != null,
	}


## ADR-027: a projected row names its owner only as `owner_scope`. The local
## authority document has no scope and keeps using the full id. A row with
## neither is never treated as this player's.
func _row_is_mine(row: Dictionary, owner: String) -> bool:
	if row.has("owner_scope"):
		return str(row.get("owner_scope", "")) == "me"
	return not owner.is_empty() and str(row.get("owner", "")) == owner


## The market button changes what it can do with the mode.
func _market_owner() -> String:
	if remote != null and not remote.player_id.is_empty():
		return remote.player_id
	if local_player_id.is_empty():
		return "local_player"
	return local_player_id


## The shared world decides who may write. Visitors keep read access; an
## anonymous member has no economic identity, so it is read-only as well.
func _remote_economy_writable() -> bool:
	if remote == null:
		return true
	if remote.member == null or remote.player_id.is_empty() or farm_state == null:
		return false
	# ADR-027 degradation: without the own-account block the view is incomplete,
	# so the market and bank stay read-only instead of showing a false zero.
	if not farm_state.economy_view_complete():
		return false
	return remote.member.role == "member"


func _remote_economy_reason() -> String:
	if remote == null:
		return ""
	if remote.member != null and remote.member.role != "member":
		return "访客只能查看市场和银行，不能下单、发货、开市或借贷。"
	return "还没有玩家身份，暂时不能进行经济操作。"


## The authority allows build/demolish to named members only, so the yard view
## is read-only for visitors and for anonymous connections.
func _remote_homes_writable() -> bool:
	if remote == null:
		return true
	if remote.member == null or remote.player_id.is_empty():
		return false
	return remote.member.role == "member"


func _remote_homes_reason() -> String:
	if remote == null:
		return ""
	if remote.member != null and remote.member.role != "member":
		return "访客只能查看宅基，不能建造或拆除。"
	return "还没有玩家身份，暂时不能建造或拆除。"


func _has_granted_account(player_id: String) -> bool:
	if farm_state == null or player_id.is_empty():
		return false
	var accounts: Variant = farm_state.economy_snapshot().get("accounts")
	if not accounts is Dictionary:
		return false
	var account: Variant = (accounts as Dictionary).get(player_id)
	return account is Dictionary and bool((account as Dictionary).get("granted", false))


## Opens the member's account once before trading or borrowing. The id is
## derived from the player so a retry is the same durable command.
func _ensure_remote_account() -> String:
	if _remote_account_ack or _has_granted_account(remote.player_id):
		return ""
	return _submit_fixed_command("account-open-" + remote.player_id, "account_open", "account_open")


## Sends one economy command and shows a Chinese refusal when the connection is
## already gone. The authority remains the only place that validates it.
func _send_economy_command(command: Dictionary, tool: String) -> void:
	if not remote.submit(command):
		_show_economy_status("还没有连上世界，这次操作没有发出去。")
		return
	_remote_pending[str(command.id)] = {"command": command, "tool": tool}


func _submit_fixed_command(id: String, kind: String, tool: String) -> String:
	if _remote_pending.has(id):
		return ""
	var command: Dictionary = _remote_fixed_commands.get(id, {}) as Dictionary
	if command.is_empty():
		match kind:
			"account_open":
				command = FarmCommand.make_account_open(id, remote.world_time())
			"market_open":
				command = FarmCommand.make_market_open(id, remote.world_time())
			"bank_open":
				command = FarmCommand.make_bank_open(id, remote.world_time())
			_:
				return "无法准备这个操作。"
	if not remote.submit(command):
		return "还没有连上世界，这次操作没有发出去。"
	_remote_fixed_commands[id] = command
	_remote_pending[id] = {"command": command, "tool": tool, "fixed": id}
	return ""


func _on_economy_committed(pending: Dictionary, command: Dictionary, reply: Dictionary) -> void:
	if not bool(reply.get("ok", false)):
		if pending.has("fixed"):
			# A refused fixed-id command did not commit, so a later attempt may
			# carry a fresh timestamp without a payload conflict.
			_remote_fixed_commands.erase(str(pending.get("fixed", "")))
		_show_economy_status(_economy_reply_text(reply))
		return
	var kind: String = str(command.get("kind", ""))
	var message: String = ""
	match kind:
		"account_open":
			_remote_account_ack = true
			message = "账户已开通。"
		"market_open":
			message = "商人已开市。"
		"bank_open":
			message = "银行已开市。"
	if bool(reply.get("duplicate", false)):
		# A duplicate is the authority confirming it already applied this id,
		# not a failure.
		message = "世界已确认过这笔操作。" if message.is_empty() else message + "世界已确认过这笔操作。"
	elif message.is_empty():
		message = "世界已接受这次操作，正在同步。"
	_show_economy_status(message)
	# The account reply already advanced the authority sequence, so the merchant
	# opening can follow now without a stale precondition.
	if kind == "account_open" and market_panel != null and market_panel.visible:
		var follow: String = _prepare_remote_market()
		if not follow.is_empty():
			_show_economy_status(follow)


func _show_economy_status(text: String) -> void:
	if bank_panel != null and bank_panel.visible:
		bank_panel.show_status(text)
		return
	if market_panel != null and market_panel.visible:
		market_panel.show_status(text)
		return
	hud.show_notice(text)


## The authority ships a Chinese `reason_text` with every refusal. The local
## maps are only a fallback for a reply that predates it.
func _economy_reply_text(reply: Dictionary) -> String:
	var text: String = str(reply.get("reason_text", ""))
	if not text.is_empty():
		return text
	var reason: String = str(reply.get("reason", ""))
	var market_text: String = _market_reason(reason)
	if market_text != "操作没有完成。":
		return market_text
	var loan_text: String = _loan_reason(reason)
	if loan_text != "操作没有完成。":
		return loan_text
	return _remote_reason(reason)


func _market_settlement_text(prefix: String, settlement: Dictionary) -> String:
	var parts: Array[String] = []
	if not prefix.is_empty():
		parts.append(prefix)
	if int(settlement.get("trades", 0)) > 0:
		parts.append("成交 %d 笔" % int(settlement.get("trades", 0)))
	if int(settlement.get("expired", 0)) > 0:
		parts.append("%d 张订单到期" % int(settlement.get("expired", 0)))
	if int(settlement.get("delivered", 0)) > 0:
		parts.append("交付 %d 笔" % int(settlement.get("delivered", 0)))
	if int(settlement.get("lost", 0)) > 0:
		# A declared-risk arrival that was destroyed is not a silent event: the
		# player must see that the goods are gone, not merely "delivered".
		parts.append("路上损失 %d 笔" % int(settlement.get("lost", 0)))
	if not bool(settlement.get("ok", true)):
		parts.append(str(settlement.get("message", "")))
	if parts.is_empty():
		return ""
	return "；".join(parts) + "。"


func _market_reason(reason: String) -> String:
	match reason:
		"invalid_command": return "操作编号无效。"
		"invalid_time": return "时间无效，请稍后再试。"
		"invalid_owner", "invalid_player": return "玩家身份无效。"
		"invalid_side": return "买卖方向无效。"
		"invalid_good": return "这种商品不能上市。"
		"invalid_price": return "价格无效。"
		"invalid_quantity": return "数量无效。"
		"invalid_expiry": return "有效期必须晚于现在。"
		"invalid_market": return "市场状态无效。"
		"order_exists": return "这张订单已经提交过。"
		"order_limit": return "订单太多了，先撤掉一些。"
		"merchant_closed": return "商人还没有开市。"
		"insufficient_cash": return "现金不够。"
		"insufficient_goods": return "货物不够。"
		"unknown_account": return "还没有开户。"
		"order_closed": return "这张订单已经关闭。"
		"order_expired": return "这张订单已经到期。"
		"not_owner": return "只能撤自己的订单。"
		"unknown_order": return "找不到这张订单。"
		"command_conflict": return "操作编号重复。"
		"shipment_exists": return "这次发货已经提交过。"
		"shipment_limit": return "在途发货太多了。"
		"invalid_route": return "这两处市场之间不能发货。"
		"delivery_limit": return "交付记录已满。"
		"already_granted", "already_opened": return "已经开通过。"
	return "操作没有完成。"


## The bank is a view over the same farm document. Opening it first settles the
## deterministic overdue sweep and makes sure the rule bank exists, then shows
## exactly what the rules would decide at that instant.
func _open_bank_panel() -> void:
	if not _loaded or _save_failed or farm_state == null or bank_panel == null:
		return
	if not _tools_available():
		return
	_cancel_tool()
	hud.hide_time_preview()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	var message: String = ""
	if remote == null:
		var settlement: Dictionary = _settle_bank(float(clock.call()))
		if not bool(settlement.get("ok", true)):
			message = str(settlement.get("message", ""))
		elif int(settlement.get("overdue", 0)) > 0:
			message = "%d 笔贷款已逾期。" % int(settlement.get("overdue", 0))
		if bool(settlement.get("changed", false)) and not _save_farm():
			return
		var prepared: String = _prepare_singleplayer_bank()
		if prepared == "!":
			return
		if not prepared.is_empty():
			message = prepared
	else:
		message = _prepare_remote_bank()
	camera.free_input_enabled = false
	_refresh_bank(message)
	bank_panel.show()


## A singleplayer bank needs its one-time capital once, and a borrower needs an
## opened account. Both commands are durable and idempotent; the fixed ids are
## only called while the durable marker is still absent. The account uses the
## same one-time grant the market already issues, not a second issuance path.
func _prepare_singleplayer_bank() -> String:
	var now: float = float(clock.call())
	var owner: String = _market_owner()
	var changed: bool = false
	var failure: String = ""
	var snapshot: Dictionary = farm_state.economy_snapshot()
	var accounts: Variant = snapshot.get("accounts")
	var account: Variant = accounts.get(owner) if accounts is Dictionary else null
	if not account is Dictionary or not bool(account.get("granted", false)):
		var opened_account: Dictionary = farm_state.economy_open_account(
			"bank-account-" + owner, owner, now)
		if opened_account.ok:
			changed = true
		elif str(opened_account.get("reason", "")) != "already_granted":
			failure = _loan_reason(str(opened_account.get("reason", "")))
	var bank: Dictionary = farm_state.economy_bank()
	if not bool(bank.get("opened", false)):
		var opened: Dictionary = farm_state.economy_open_bank("bank-open", now)
		if opened.ok:
			changed = true
		elif failure.is_empty():
			failure = _loan_reason(str(opened.get("reason", "")))
	if changed and not _save_farm():
		return "!"
	return failure


## A member needs an account before the first loan; the panel opens it once via
## the same durable command the singleplayer path uses. The bank itself stays a
## deliberate click on the open button.
func _prepare_remote_bank() -> String:
	if not _remote_economy_writable():
		return ""
	return _ensure_remote_account()


## Overdue is an authority sweep, not a panel action. It returns whether the
## contract rows actually changed so the caller can decide to save.
func _settle_bank(now: float) -> Dictionary:
	if remote != null or farm_state == null:
		return {"ok": true, "changed": false, "overdue": 0}
	var result: Dictionary = farm_state.economy_settle_loans(now)
	if not result.ok:
		return {"ok": false, "changed": false, "overdue": 0,
			"message": _loan_reason(str(result.get("reason", "")))}
	var count: int = int(result.get("count", 0))
	return {"ok": true, "changed": count > 0, "overdue": count}


func _bank_open_requested() -> String:
	var refusal: String = _save_failed_refusal(bank_panel)
	if not refusal.is_empty():
		return refusal
	if remote != null:
		if not _remote_economy_writable():
			bank_panel.show_status(_remote_economy_reason())
			return ""
		if bool(farm_state.economy_bank().get("opened", false)):
			_refresh_bank("银行已经开市。")
			return ""
		var failure: String = _submit_fixed_command("bank-open", "bank_open", "bank_open")
		if not failure.is_empty():
			bank_panel.show_status(failure)
		return ""
	if farm_state == null:
		return ""
	var now: float = float(clock.call())
	if bool(farm_state.economy_bank().get("opened", false)):
		_refresh_bank("银行已经开市。")
		return ""
	var opened: Dictionary = farm_state.economy_open_bank("bank-open", now)
	if not opened.ok:
		bank_panel.show_status(_loan_reason(str(opened.get("reason", ""))))
		return ""
	if not _save_farm():
		return ""
	_refresh_bank("银行已开市。")
	return ""


func _bank_borrow(principal: int, term: int) -> String:
	var refusal: String = _save_failed_refusal(bank_panel)
	if not refusal.is_empty():
		return refusal
	if remote != null:
		if not _remote_economy_writable():
			bank_panel.show_status(_remote_economy_reason())
			return ""
		_send_economy_command(FarmCommand.make_loan_borrow(_new_command_id(), principal,
			term, remote.world_time()), "bank")
		return ""
	if farm_state == null:
		return ""
	var result: Dictionary = farm_state.economy_borrow_loan(_new_command_id(),
		_market_owner(), principal, term, float(clock.call()))
	if not result.ok:
		bank_panel.show_status(_loan_reason(str(result.get("reason", ""))))
		return ""
	if not _save_farm():
		return ""
	_refresh_bank(_bank_success_text("已借款", result))
	return ""


func _bank_repay(loan_id: String) -> String:
	var refusal: String = _save_failed_refusal(bank_panel)
	if not refusal.is_empty():
		return refusal
	if remote != null:
		if not _remote_economy_writable():
			bank_panel.show_status(_remote_economy_reason())
			return ""
		_send_economy_command(FarmCommand.make_loan_repay(_new_command_id(), loan_id,
			remote.world_time()), "bank")
		return ""
	if farm_state == null:
		return ""
	var result: Dictionary = farm_state.economy_repay_loan(_new_command_id(),
		_market_owner(), loan_id, float(clock.call()))
	if not result.ok:
		bank_panel.show_status(_loan_reason(str(result.get("reason", ""))))
		return ""
	if not _save_farm():
		return ""
	_refresh_bank("已还款 %d COIN。" % int(result.get("amount", 0)))
	return ""


func _bank_refresh() -> void:
	if not _loaded or farm_state == null or bank_panel == null:
		return
	var message: String = ""
	if remote == null:
		var settlement: Dictionary = _settle_bank(float(clock.call()))
		if not bool(settlement.get("ok", true)):
			message = str(settlement.get("message", ""))
		elif int(settlement.get("overdue", 0)) > 0:
			message = "%d 笔贷款已逾期。" % int(settlement.get("overdue", 0))
		if bool(settlement.get("changed", false)) and not _save_farm():
			return
	else:
		# A manual refresh asks the authority for a fresh view instead of
		# settling overdue loans locally.
		remote.request_summary()
	_refresh_bank(message)


func _refresh_bank(message: String = "") -> void:
	if bank_panel == null or farm_state == null:
		return
	bank_panel.present(_bank_view())
	if not message.is_empty():
		bank_panel.show_status(message)


func _bank_view() -> Dictionary:
	var owner: String = _market_owner()
	var snapshot: Dictionary = farm_state.economy_snapshot()
	var bank: Dictionary = farm_state.economy_bank()
	# ADR-027 §10: other borrowers' contracts are not sent, so a projected view
	# carries the bank-wide outstanding/fees aggregate beside the bank row. The
	# local authority document has no such keys and keeps deriving them.
	return {
		"now_utc": float(clock.call()),
		"owner": owner,
		"cash": farm_state.economy_cash(owner),
		"bank": bank,
		"loans": farm_state.economy_loans(),
		"outstanding": int(bank.get("outstanding", Loans.outstanding_principal(snapshot))),
		"fees": int(bank.get("fees", Loans.collected_fees(snapshot))),
		"read_only": remote != null and not _remote_economy_writable(),
		"read_only_reason": _remote_economy_reason() \
			if remote != null and not _remote_economy_writable() else "",
	}


func _bank_success_text(prefix: String, result: Dictionary) -> String:
	return "%s %d COIN，费用 %d COIN，合计 %d COIN。" % [
		prefix, int(result.get("amount", 0)), int(result.get("fee", 0)),
		int(result.get("total", 0)),
	]


func _loan_reason(reason: String) -> String:
	match reason:
		"invalid_command": return "操作编号无效。"
		"invalid_time": return "时间无效，请稍后再试。"
		"invalid_principal": return "本金需在 10 到 1000 COIN 之间。"
		"invalid_term": return "期限只能是 7、14 或 30 天。"
		"invalid_due": return "到期时间超出范围。"
		"invalid_borrower", "invalid_owner": return "玩家身份无效。"
		"unknown_account", "account_not_open": return "还没有开户，先打开市场完成开户。"
		"bank_closed": return "银行还没有开市。"
		"bank_insufficient": return "银行现金不够这笔贷款。"
		"loan_active": return "还有一笔未结清的贷款，先还清再借。"
		"loan_limit": return "贷款合同太多了。"
		"loan_not_found": return "找不到这笔贷款。"
		"not_borrower": return "只能还自己的贷款。"
		"already_repaid": return "这笔贷款已经还清。"
		"insufficient": return "现金不够还清本金和费用。"
		"command_conflict": return "操作编号重复。"
		"duplicate_event": return "这笔操作已经提交过。"
		"invalid_ledger", "invalid_bank", "invalid_amount": return "银行账本状态无效。"
	return "操作没有完成。"

func _scene_entry_at(point: Vector2) -> String:
	var hit: MeshInstance3D=decoration_layout.environment_surface_at(point)
	if hit==null: return ""
	var tool: String = $Environment/DoorTools.tool_for_mesh(hit)
	if tool == "rest": return "rest"
	if not tool.is_empty(): return "tool_" + tool
	for item: String in ["drying_rack","tea_table","pot"]:
		var placed: Node=decoration_layout._instances.get(item)
		if placed!=null and (placed==hit or placed.is_ancestor_of(hit)):
			return {"drying_rack":"garden_rack","tea_table":"table","pot":"jar"}[item]
	var courtyard: Node3D=$Environment
	for pair: Array in [["Kitchen","stove"],["LivingDetails/SidePorchDryingRack","rack"],
		["LivingDetails/YardJarCluster","jar"],["LivingDetails/PorchHarvestTable","table"],
		["NeighborIslets/WillowNeighbor","willow"],["NeighborIslets/BambooNeighbor","bamboo"],
		["NeighborIslets/EasternCottage","ferry"]]:
		var source: Node=courtyard.get_node(pair[0])
		if source==hit or source.is_ancestor_of(hit): return pair[1]
	return ""

func _open_scene_entry(id: String) -> void:
	if id == "rest":
		if desktop_wallpaper.active and desktop_wallpaper.interacting: _end_wallpaper_interaction()
		return
	if not _tools_available(): return
	if id.begins_with("tool_"):
		_cancel_input()
		var tool: String = id.trim_prefix("tool_")
		if tool=="sow":
			_open_palette("sow")
		else: _select_tool(tool)
		return
	if id in ["willow","bamboo","ferry"]:
		harvest_book.tab="neighbors"
		harvest_book.neighbor=id
		harvest_book._history_open=false
	elif id in ["stove","rack","garden_rack","jar","table"]:
		harvest_book.tab="kitchen"
		var choices: Dictionary={"stove":"leaf_stir","rack":"root_dry","garden_rack":"root_dry","jar":"leaf_pickle"}
		if choices.has(id): harvest_book.kitchen_page.recipe=choices[id]
		harvest_book.kitchen_page.selected_station=id
	else: return
	_open_basket()

func _exchange(id: String, visit: int, basket: Dictionary, gift: String) -> void:
	# The book is reachable in a shared world for the kitchen; basket exchanges
	# change the local document only, so they keep refusing there.
	if remote != null:
		hud.show_notice("联机模式下，邻里菜篮由世界房主维护。")
		return
	if not _basket_active() or not _loaded or _save_failed: return
	var candidate: FarmState = farm_state.copy()
	var result: Dictionary=candidate.share_basket(id,visit,basket) if gift.is_empty() else candidate.claim_gift(id,visit,gift)
	if not result.ok:
		harvest_book.refresh(_display_state())
		return
	# Inventory and delivery receipt are one durable transaction. A failed write
	# never publishes the draft or charges the player; reopening can retry it.
	var saved: Dictionary=_save_state(candidate,decoration_state)
	if not saved.ok:
		_save_failed=true
		harvest_book.dismiss()
		hud.show_storage_issue(saved.kind,true)
		_refresh_hud()
		return
	farm_state.accept(candidate)
	_refresh_neighbor_stories()
	harvest_book.refresh(_display_state())
	farm_audio.play_ui()
	_refresh_hud()

func _refresh_neighbor_stories() -> void:
	$Environment/NeighborIslets.show_stories(_display_state().neighbors,$Environment/LivingDetails)

func _kitchen_action(action: String, request: Dictionary, revision: int) -> void:
	if remote != null:
		# The authority owns the shared kitchen document. Submit one command and
		# apply it only when the reply names the same outcome; a refusal leaves
		# this client's document untouched.
		var command: Dictionary = FarmCommand.make_kitchen(
			_new_command_id(), action, request, revision, clock.call())
		if not remote.submit(command):
			hud.show_notice("还没有连上世界，这次厨房操作没有发出。")
			harvest_book.refresh(_display_state())
			return
		_remote_pending[str(command.id)] = {"command": command, "tool": "kitchen"}
		return
	if not _basket_active() or not _loaded or _save_failed: return
	# Singleplayer goes through the same command boundary as a shared world, so
	# a kitchen action has one entry point and a replayed id cannot cook twice.
	var command: Dictionary = FarmCommand.make_kitchen(
		_new_command_id(), action, request, revision, clock.call())
	var actor: String = local_player_id if OwnerIds.valid(local_player_id) else ""
	var execution: Dictionary = farm_commands.execute(
		farm_state, command, actor, decoration_state.snapshot())
	if execution.duplicate:
		return
	var result: Dictionary = execution.get("result", {"ok": false, "reason": "invalid_command"}) as Dictionary
	if not bool(result.get("ok", false)):
		harvest_book.refresh(_display_state())
		return
	var candidate: FarmState = execution.candidate as FarmState
	var decorations:=DecorationState.new();decorations.restore_snapshot(decoration_state.snapshot())
	var display: Dictionary = _display_state(candidate)
	decorations.unlock(display.harvested,display.kitchen)
	var saved: Dictionary=_save_state(candidate,decorations)
	if not saved.ok:
		_save_failed=true
		harvest_book.dismiss()
		hud.show_storage_issue(saved.kind,true)
		_refresh_hud()
		return
	_adopt_kitchen(candidate, decorations, action)
	farm_audio.play_ui()


## Applies an accepted kitchen change to what is on screen. Shared by the local
## save path and the authority replay so one action cannot look different.
func _adopt_kitchen(candidate: FarmState, decorations: DecorationState, action: String) -> void:
	farm_state.accept(candidate)
	if decorations.snapshot()!=decoration_state.snapshot():
		decoration_state=decorations;decoration_layout.bind_state(decorations)
	harvest_book.decorations=decorations.snapshot()
	_refresh_kitchen_views(action)


## Redraws every kitchen surface from the current document. A summary can apply
## another member's kitchen commit before this client's own reply arrives, so
## the reply path uses this too instead of trusting its own replay.
func _refresh_kitchen_views(action: String) -> void:
	kitchen_display.refresh(_display_state().kitchen)
	decoration_layout.update_life(_display_state().kitchen)
	if action=="share": harvest_book.tab="journal"
	harvest_book.update_time(clock.call())
	harvest_book.refresh(_display_state())
	_refresh_hud()

func _change_season(id: String) -> void:
	if remote != null:
		hud.show_notice("联机模式下，时令由世界房主维护。")
		return
	if not _basket_active() or not _loaded or _save_failed: return
	var candidate: FarmState = farm_state.copy()
	if not candidate.set_season(id): return
	if candidate.snapshot().season!=farm_state.snapshot().season:
		var saved: Dictionary=_save_state(candidate,decoration_state)
		if not saved.ok:
			_save_failed=true
			harvest_book.dismiss()
			hud.show_storage_issue(saved.kind,true)
			_refresh_hud()
			return
		farm_state.accept(candidate)
		_apply_season()
	harvest_book.refresh(_display_state())
	farm_audio.play_ui()

func _apply_season() -> void:
	# The storage-failure overlay runs before any authoritative farm exists.
	if farm_state == null: return
	var id: String=_display_state().season
	seasonal_courtyard.set_season(id)
	atmosphere.set_season(id)
	farm_audio.set_season(id)


## Weather is presentation only: read an existing authoritative view, then tell
## the rain emitter and the clock mood. No farm settlement, save or network
## message is involved here.
func _sync_weather() -> void:
	if weather_atmosphere == null:
		return
	var view: Dictionary = _weather_view()
	var kind: String = str(view.get("kind", ""))
	if kind != _weather_kind:
		_weather_kind = kind
		weather_atmosphere.set_weather(kind)
		# Residents keep their existing navigation space; a rain change may
		# replace each bird's goal once with a reachable shelter there.
		$Environment/CourtyardAnimals.set_weather(kind)
	var now: float = float(clock.call())
	if hud != null:
		hud.show_weather(HUD.weather_text(kind, float(view.get("next_utc", -1.0)), now), _loaded)
	# Disasters and warnings are read from the same authoritative view as the
	# weather block. Only a current disaster changes presentation; a warning is
	# HUD-only. Both are read-only and never settle the farm or send a message.
	var hazards: Dictionary = _disaster_view()
	var disaster: Dictionary = _dictionary_or_empty(hazards.get("disaster"))
	var warning: Dictionary = _dictionary_or_empty(hazards.get("warning"))
	var described: Dictionary = DisasterMood.describe(disaster, warning, now)
	# The kind describes either event, but only a current disaster (not a
	# warning) is allowed to reach the scene.
	var disaster_kind: String = ""
	if not bool(described.get("warning", false)):
		disaster_kind = str(described.get("kind", ""))
	if disaster_kind != _disaster_kind:
		_disaster_kind = disaster_kind
		weather_atmosphere.set_disaster(disaster_kind)
		atmosphere.set_disaster(disaster_kind)
	if hud != null:
		hud.show_disaster(str(described.get("text", "")), _loaded)


## The current block from whichever mode owns natural time. Single-player asks
## NatureState directly; a shared world reads the nature view on the last
## authoritative summary, which arrives on every reconnect and reconcile.
func _weather_view() -> Dictionary:
	var now: float = float(clock.call())
	if remote != null:
		var summary: Variant = remote.member.state if remote.member != null else null
		var view: Variant = summary.get("nature") if summary is Dictionary else null
		if view is Dictionary:
			var weather: Variant = view.get("weather")
			if weather is Dictionary and not weather.is_empty():
				var end_utc: float = float(weather.get("end_utc", 0.0))
				if is_finite(end_utc) and end_utc > 0.0 and now < end_utc:
					return {"kind": str(weather.get("kind", "")), "next_utc": end_utc}
		# Past the summary's block, derive from the same seed the summary carried
		# instead of asking for another message. The next reconcile replaces this
		# with the authority's own view.
		return _weather_from_remote_snapshot(now)
	if nature_state != null:
		var weather: Dictionary = nature_state.weather_at(now)
		if not weather.is_empty():
			return {"kind": str(weather.get("kind", "")), "next_utc": float(weather.get("end_utc", -1.0))}
	return {}


func _weather_from_remote_snapshot(now: float) -> Dictionary:
	if remote == null or remote.member == null:
		return {}
	var documents: Variant = remote.member.snapshot
	var data: Variant = documents.get("nature") if documents is Dictionary else null
	if not data is Dictionary:
		return {}
	var source := NatureState.new()
	if not source.restore_snapshot(data):
		return {}
	var weather: Dictionary = source.weather_at(now)
	if weather.is_empty():
		return {}
	return {"kind": str(weather.get("kind", "")), "next_utc": float(weather.get("end_utc", -1.0))}


## The disaster/warning view from the same source that supplies the weather
## kind. A shared summary is authoritative only while its weather block still
## covers now; past that, derive from the seed the summary carried, exactly like
## `_weather_view()`. No extra network message is sent. Single-player asks the
## local NatureState directly.
func _disaster_view() -> Dictionary:
	var now: float = float(clock.call())
	if remote != null:
		var summary: Variant = remote.member.state if remote.member != null else null
		var view: Variant = summary.get("nature") if summary is Dictionary else null
		if view is Dictionary:
			var weather: Variant = view.get("weather")
			if weather is Dictionary and not weather.is_empty():
				var end_utc: float = float(weather.get("end_utc", 0.0))
				if is_finite(end_utc) and end_utc > 0.0 and now < end_utc:
					return _hazards_from_view(view)
		return _disaster_from_remote_snapshot(now)
	if nature_state != null:
		return _hazards_from_source(nature_state, now)
	return {}


func _disaster_from_remote_snapshot(now: float) -> Dictionary:
	if remote == null or remote.member == null:
		return {}
	var documents: Variant = remote.member.snapshot
	var data: Variant = documents.get("nature") if documents is Dictionary else null
	if not data is Dictionary:
		return {}
	var source := NatureState.new()
	if not source.restore_snapshot(data):
		return {}
	return _hazards_from_source(source, now)


func _hazards_from_source(source: NatureState, now: float) -> Dictionary:
	# Mirrors HeadlessWorld.disaster_view(): the current event plus only a
	# warning that starts inside the next block.
	var disaster: Dictionary = {}
	var current: Dictionary = source.disaster_at(now)
	if not current.is_empty():
		disaster = {
			"kind": str(current.get("kind", "")),
			"severity": int(current.get("severity", 0)),
			"starts_utc": float(current.get("start_utc", 0.0)),
			"ends_utc": float(current.get("end_utc", 0.0)),
		}
	var warning: Dictionary = {}
	var next_start: float = source.next_disaster_at(now)
	if next_start >= 0.0:
		var weather: Dictionary = source.weather_at(now)
		var block_end: float = INF
		if not weather.is_empty():
			block_end = float(weather.get("end_utc", INF))
		if next_start <= block_end + 0.001:
			var event: Dictionary = source.disaster_at(next_start)
			if not event.is_empty():
				warning = {
					"kind": str(event.get("kind", "")),
					"severity": int(event.get("severity", 0)),
					"starts_utc": float(event.get("start_utc", next_start)),
					"ends_utc": float(event.get("end_utc", next_start + NatureState.WEATHER_SECONDS)),
					"lead_seconds": maxf(0.0, next_start - now),
				}
	return {"disaster": disaster, "warning": warning}


func _hazards_from_view(view: Dictionary) -> Dictionary:
	return {
		"disaster": _dictionary_or_empty(view.get("disaster")),
		"warning": _dictionary_or_empty(view.get("warning")),
	}


static func _dictionary_or_empty(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


func _change_decoration(candidate: Dictionary, undo: bool = false) -> void:
	if not _loaded or _save_failed: return
	var replacement:=DecorationState.new()
	if not replacement.restore_snapshot(candidate): return
	if not FarmState.Kitchen.placement_valid(farm_state.snapshot().kitchen,candidate):
		decoration_layout._message="晒架上还有食材，请先收起成品。";decoration_layout._refresh()
		if island_builder.active: island_builder.set_busy(false,decoration_layout._message)
		return
	var candidate_farm:=FarmState.new();candidate_farm.restore_snapshot(farm_state.snapshot())
	if replacement.snapshot()!=decoration_state.snapshot(): candidate_farm.remember("arrange",clock.call())
	var saved: Dictionary=_save_state_snapshot(candidate_farm.snapshot(),replacement.snapshot())
	if not saved.ok:
		if island_builder.active:
			decoration_layout.show_save_issue()
			island_builder.set_busy(false,"未能保存，可重试或取消调整。");return
		_save_failed=true
		decoration_layout.finish_mode()
		hud.show_storage_issue(saved.kind,true)
		_refresh_hud()
		return
	previous_decorations={} if undo else decoration_state.snapshot()
	previous_layout={}
	island_builder.previous={}
	decoration_state=replacement
	farm_state.restore_snapshot(candidate_farm.snapshot())
	decoration_layout.accept_state(replacement)
	_refresh_hud()
	if island_builder.active: island_builder._refresh()

func _undo_decoration() -> void:
	if previous_decorations.is_empty(): return
	var candidate: Dictionary=previous_decorations.duplicate(true)
	for id: String in candidate: candidate[id].unlocked=decoration_state.snapshot()[id].unlocked
	var issue: String=decoration_layout.restoration_issue(candidate)
	if not issue.is_empty():
		island_builder.set_busy(false,issue);return
	_change_decoration(candidate,true)

func _view_neighbor(id: String) -> void:
	var scene_view: Dictionary=$Environment/NeighborIslets.story_view(id)
	focus_detail.protect_neighbor(scene_view.island)
	camera.view_neighbor(scene_view.point,scene_view.view)
	hud.hide()

func _layout_active() -> bool:
	return (courtyard_edit!=null and courtyard_edit.editor.active) or (island_builder!=null and island_builder.active)

func _begin_construction(tool: String = "land") -> void:
	if _world_edit_unavailable():
		return
	if not _loaded or _save_failed: return
	if decoration_layout.active: decoration_layout.finish_mode()
	_cancel_tool();_cancel_input();field_menu.dismiss();hud.hide_time_preview()
	selected_field=-1;selected_cell="";hover_field=-1;hover_cell=""
	_select_field_visual(-1);_select_cell_visual(-1,"");focus_detail.set_focus()
	camera.cancel_zoom()
	camera.construction_bounds=courtyard_plan.buildable_bounds()
	camera.set_construction_framing(true,_construction_resume.is_empty())
	_construction_resume={}
	island_builder.begin(self,tool);hud.hide()

func _apply_construction(snapshot: Dictionary, undo: bool) -> void:
	if not island_builder.active or island_builder.busy: return
	var requested_plan: RefCounted=CourtyardPlan.from_snapshot(snapshot)
	if requested_plan==null: return
	var plants_issue: String=CourtyardPlan.Plants.terrain_issue(requested_plan)
	if not plants_issue.is_empty(): island_builder.set_busy(false,plants_issue);return
	var route_issue: String=CourtyardPlan.Routes.terrain_issue(requested_plan)
	if not route_issue.is_empty(): island_builder.set_busy(false,route_issue);return
	var current: Dictionary=farm_state.snapshot().layout
	var unchanged: Dictionary=snapshot.duplicate(true)
	unchanged.routes=current.routes.duplicate(true)
	if unchanged==current and snapshot!=current:
		_apply_routes(snapshot,undo);return
	unchanged=snapshot.duplicate(true)
	unchanged.plants=current.plants.duplicate(true)
	if unchanged==current and snapshot!=current:
		_apply_plants(snapshot,undo)
		return
	unchanged=snapshot.duplicate(true)
	unchanged.construction.bridge=current.construction.bridge.duplicate(true)
	if unchanged==current and snapshot!=current:
		_apply_bridge(snapshot,undo)
		return
	for kind: String in CourtyardPlan.Construction.Flocks.KINDS:
		unchanged=snapshot.duplicate(true)
		unchanged.construction.flocks[kind]=current.construction.flocks[kind].duplicate(true)
		if unchanged==current and snapshot!=current:
			_apply_flock(snapshot,undo,kind)
			return
	unchanged=snapshot.duplicate(true)
	unchanged.fields=current.fields.duplicate(true)
	if unchanged==current:
		_apply_fields(snapshot,undo)
		return
	unchanged=snapshot.duplicate(true)
	unchanged.construction.trellis=current.construction.trellis.duplicate(true)
	if unchanged==current:
		_apply_trellis(snapshot,undo)
		return
	unchanged=snapshot.duplicate(true)
	unchanged.construction.buildings=current.construction.buildings.duplicate(true)
	if unchanged==current:
		var changed_buildings: Array[String]=[]
		for id: String in current.construction.buildings:
			if snapshot.construction.buildings[id]!=current.construction.buildings[id]: changed_buildings.append(id)
		if changed_buildings.size()==1: _apply_building(snapshot,undo,changed_buildings[0])
		return
	unchanged=snapshot.duplicate(true)
	unchanged.construction.land=current.construction.land.duplicate(true)
	unchanged.construction.east_land=current.construction.east_land.duplicate(true)
	if unchanged==current:
		_apply_land(snapshot,undo)
		return
	island_builder.set_busy(true,"正在检查岸边、支承和通路…")
	await get_tree().process_frame
	var plan: RefCounted=CourtyardPlan.from_snapshot(snapshot)
	if plan==null:
		island_builder.set_busy(false,"范围或尺寸不合适，请调整后再试。")
		return
	var message: String=preload("res://layout/island_construction.gd").bridge_issue(plan)
	if message.is_empty(): message=preload("res://layout/island_construction.gd").Flocks.terrain_issue(plan)
	if message.is_empty():
		var probe:=preload("res://scenes/environment/courtyard.gd").new()
		probe.plan=plan;probe.layout_probe=true;probe.process_mode=Node.PROCESS_MODE_DISABLED
		add_child(probe)
		var obstacles: Dictionary=probe.layout_obstacles.duplicate(true)
		obstacles.merge(decoration_layout.ground_footprints())
		var space=preload("res://scenes/environment/animal_space.gd")
		var east: PackedVector2Array=space.footprint(probe.get_node("EastBank"),plan.ground_height-.04,plan.ground_height+.02)
		if not Geometry2D.intersect_polygons(plan.plateau(),east).is_empty(): message="添地碰到了对岸，请留出水道。"
		var issues: Array[String]=preload("res://layout/courtyard_circulation.gd").field_placement_issues(plan,obstacles)
		if not issues.is_empty(): message="这里会碰到田地，请缩小范围或调整位置。"
		if message.is_empty():
			var routes:=preload("res://layout/courtyard_circulation.gd").new()
			routes.build(plan,obstacles)
			if not routes.issues.is_empty(): message="这里会挡住通路，请为屋前、田边和桥头留出空间。"
		remove_child(probe);probe.free()
	if not message.is_empty():
		island_builder.set_busy(false,message);return
	var candidate: RefCounted=farm_state.copy()
	var result: Dictionary=candidate.apply_layout(snapshot,clock.call())
	if not result.ok:
		island_builder.set_busy(false,"已有作物需要保留，请调整范围。");return
	var saved: Dictionary=_save_state(candidate,decoration_state)
	if not saved.ok:
		island_builder.set_busy(false,"未能保存，岛屿保持原样。可再次确认重试，或取消调整。");return
	previous_layout={} if undo else farm_state.snapshot().layout
	previous_decorations={}
	farm_state=candidate
	island_builder.set_busy(true,"已保存，正在更新小岛…")
	_reload_saved_scene()

func _apply_plants(snapshot: Dictionary, undo: bool) -> void:
	var plan: RefCounted=CourtyardPlan.from_snapshot(snapshot)
	if not is_instance_valid(island_builder.plant_preview):
		island_builder._clear_preview();island_builder._ensure_plant_preview()
	var preview: Node3D=island_builder.plant_preview
	preview.update(plan)
	if not preview.message.is_empty(): island_builder.set_busy(false,preview.message);return
	island_builder.set_busy(true)
	var started: int=Time.get_ticks_msec()
	var candidate: RefCounted=farm_state.copy()
	if not candidate.apply_layout(snapshot,clock.call()).ok:
		island_builder.set_busy(false,"已有作物需要保留，请调整范围。");return
	var saved: Dictionary=_save_state(candidate,decoration_state)
	if not saved.ok: island_builder.set_busy(false,"未能保存，可重试或取消调整。");return
	previous_layout={} if undo else farm_state.snapshot().layout
	previous_decorations={};farm_state=candidate
	island_builder.accept_plants(plan)
	_refresh_hud()
	$Environment.refresh_terrain.call_deferred(true)
	print("PLANTS_COMMIT_MS ",Time.get_ticks_msec()-started)

func _apply_routes(snapshot: Dictionary, undo: bool) -> void:
	var plan: RefCounted=CourtyardPlan.from_snapshot(snapshot)
	if plan==null: return
	island_builder.set_busy(true,"正在校对道路和围栏通路…")
	if not is_instance_valid(island_builder.route_preview):
		island_builder._clear_preview()
		island_builder.route_preview=preload("res://presentation/route_layout_preview.gd").new()
		add_child(island_builder.route_preview);island_builder.route_preview.configure(self)
	var preview: Node3D=island_builder.route_preview
	preview.update(plan)
	while preview.pending:
		await get_tree().process_frame
		if _exiting: return
	if preview.validated==null:
		island_builder.set_busy(false,preview.message);return
	var started: int=Time.get_ticks_msec()
	var candidate: RefCounted=farm_state.copy()
	if not candidate.apply_layout(snapshot,clock.call()).ok:
		island_builder.set_busy(false,"已有作物需要保留，请调整范围。");return
	var saved: Dictionary=_save_state(candidate,decoration_state)
	if not saved.ok:
		island_builder.set_busy(false,"未能保存，可重试或取消调整。");return
	previous_layout={} if undo else farm_state.snapshot().layout
	previous_decorations={};farm_state=candidate
	plan=preview.validated
	island_builder.accept_routes(plan)
	decoration_layout.refresh_path_geometry()
	refresh_farm();seasonal_courtyard.refresh_paths($Environment)
	$Environment.refresh_terrain.call_deferred(false)
	print("ROUTES_COMMIT_MS ",Time.get_ticks_msec()-started)

func _apply_bridge(snapshot: Dictionary, undo: bool) -> void:
	var plan: RefCounted=CourtyardPlan.from_snapshot(snapshot)
	if plan==null: return
	island_builder.set_busy(true,"正在校对桥头通路…")
	if not is_instance_valid(island_builder.bridge_preview):
		island_builder._clear_preview()
		island_builder.bridge_preview=preload("res://presentation/bridge_layout_preview.gd").new()
		add_child(island_builder.bridge_preview);island_builder.bridge_preview.configure(self)
	var preview: Node3D=island_builder.bridge_preview
	preview.update(plan)
	while preview.pending:
		await get_tree().process_frame
		if _exiting: return
	if preview.validated==null:
		island_builder.set_busy(false,preview.message);return
	var issue: String=preview.animal_issue()
	if not issue.is_empty(): island_builder.set_busy(false,issue);return
	var started: int=Time.get_ticks_msec()
	var candidate: RefCounted=farm_state.copy()
	if not candidate.apply_layout(snapshot,clock.call()).ok:
		island_builder.set_busy(false,"已有作物需要保留，请调整范围。");return
	var saved: Dictionary=_save_state(candidate,decoration_state)
	if not saved.ok:
		island_builder.set_busy(false,"未能保存，可重试或取消调整。");return
	previous_layout={} if undo else farm_state.snapshot().layout
	previous_decorations={};farm_state=candidate
	plan=preview.validated
	island_builder.accept_bridge(plan)
	decoration_layout.refresh_path_geometry()
	refresh_farm();seasonal_courtyard.refresh_paths($Environment)
	$Environment.refresh_terrain.call_deferred(true)
	print("BRIDGE_COMMIT_MS ",Time.get_ticks_msec()-started)

func _apply_flock(snapshot: Dictionary, undo: bool, kind: String) -> void:
	var plan: RefCounted=CourtyardPlan.from_snapshot(snapshot)
	if plan==null: return
	island_builder.set_busy(true,"正在校对活动区域…")
	if not is_instance_valid(island_builder.flock_preview) or island_builder.flock_preview.kind!=kind:
		island_builder._clear_preview()
		island_builder.flock_preview=preload("res://presentation/flock_layout_preview.gd").new()
		add_child(island_builder.flock_preview);island_builder.flock_preview.configure(self,kind)
	var preview: Node3D=island_builder.flock_preview
	preview.update(plan)
	while preview.pending:
		await get_tree().process_frame
		if _exiting: return
	if preview.validated==null:
		island_builder.set_busy(false,preview.message);return
	var started: int=Time.get_ticks_msec()
	var candidate: RefCounted=farm_state.copy()
	if not candidate.apply_layout(snapshot,clock.call()).ok:
		island_builder.set_busy(false,"范围不合适，请调整后再试。");return
	var saved: Dictionary=_save_state(candidate,decoration_state)
	if not saved.ok:
		island_builder.set_busy(false,"未能保存，可重试或取消调整。");return
	previous_layout={} if undo else farm_state.snapshot().layout
	previous_decorations={};farm_state=candidate
	island_builder.accept_flock(plan)
	refresh_farm()
	print("FLOCK_COMMIT_MS ",Time.get_ticks_msec()-started)

func _apply_land(snapshot: Dictionary, undo: bool) -> void:
	var started: int=Time.get_ticks_msec()
	var plan: RefCounted=CourtyardPlan.from_snapshot(snapshot)
	if plan==null: return
	var construction=preload("res://layout/island_construction.gd")
	var message: String=construction.bridge_issue(plan)
	if message.is_empty(): message=construction.Flocks.terrain_issue(plan)
	if message.is_empty(): message=preload("res://layout/bridge_passage.gd").plan_water_issue(plan,$Environment.layout_obstacles)
	if message.is_empty():
		var support=preload("res://layout/land_support.gd")
		for island: int in 2:
			message=support.issue(plan.plateau(island),support.capture(self,island))
			if not message.is_empty(): break
	if not Geometry2D.intersect_polygons(plan.water_banks()[0],plan.water_banks()[1]).is_empty(): message="请为对岸留出水道。"
	if message.is_empty(): message=preload("res://layout/land_support.gd").neighbor_issue($Environment,plan)
	# Only the brush changed. Existing fields, buildings and routes are retained;
	# do not instantiate a second courtyard to validate unchanged architecture.
	if not preload("res://layout/courtyard_circulation.gd").field_placement_issues(plan,{}).is_empty(): message="请保留田地周围的平地。"
	if not message.is_empty(): island_builder.set_busy(false,message);return
	island_builder.set_busy(true)
	var candidate: RefCounted=farm_state.copy()
	var result: Dictionary=candidate.apply_layout(snapshot,clock.call())
	if not result.ok: island_builder.set_busy(false,"已有作物需要保留，请调整范围。");return
	var saved: Dictionary=_save_state(candidate,decoration_state)
	if not saved.ok: island_builder.set_busy(false,"未能保存，可重试或取消调整。");return
	previous_layout={} if undo else farm_state.snapshot().layout
	previous_decorations={}
	farm_state=candidate
	plan.paths=courtyard_plan.paths.duplicate();plan.garden_fences=courtyard_plan.garden_fences.duplicate(true)
	# Undo can target a different mesh than the current draft.
	if island_builder.draft!=snapshot:
		island_builder._clear_preview();island_builder.draft=snapshot.duplicate(true);island_builder.candidate=plan
	courtyard_plan=plan;farm.plan=plan
	camera.overview_point=plan.camera_point;camera.overview_view.z=plan.camera_distance
	camera.construction_bounds=plan.buildable_bounds()
	RenderingServer.global_shader_parameter_set("courtyard_haze_region",plan.haze_region)
	island_builder.accept_land(plan)
	_refresh_hud()
	print("LAND_COMMIT_MS ",Time.get_ticks_msec()-started)

func _apply_fields(snapshot: Dictionary, undo: bool) -> void:
	var plan: RefCounted=CourtyardPlan.from_snapshot(snapshot)
	if plan==null: return
	island_builder.set_busy(true,"正在校对田边通路…")
	if not is_instance_valid(island_builder.field_preview):
		island_builder._clear_preview()
		island_builder.field_preview=preload("res://presentation/field_layout_preview.gd").new()
		add_child(island_builder.field_preview);island_builder.field_preview.configure(self)
	var preview: Node3D=island_builder.field_preview
	preview.update(plan)
	while preview.pending:
		await get_tree().process_frame
		if _exiting: return
	if preview.validated==null:
		island_builder.set_busy(false,preview.message);return
	var started: int=Time.get_ticks_msec()
	var candidate: RefCounted=farm_state.copy()
	if not candidate.apply_layout(snapshot,clock.call()).ok:
		island_builder.set_busy(false,"这些田格里还有作物，请保留它们，或先收获。");return
	var saved: Dictionary=_save_state(candidate,decoration_state)
	if not saved.ok:
		island_builder.set_busy(false,"未能保存，可重试或取消调整。");return
	previous_layout={} if undo else farm_state.snapshot().layout
	previous_decorations={}
	farm_state=candidate
	plan=preview.validated
	island_builder.accept_fields(plan)
	decoration_layout.refresh_path_geometry()
	refresh_farm()
	seasonal_courtyard.refresh_paths($Environment)
	$Environment.refresh_terrain.call_deferred(false)
	print("FIELD_COMMIT_MS ",Time.get_ticks_msec()-started)

func _apply_trellis(snapshot: Dictionary, undo: bool) -> void:
	var plan: RefCounted=CourtyardPlan.from_snapshot(snapshot)
	if plan==null: return
	island_builder.set_busy(true,"正在校对架旁通路…")
	if not is_instance_valid(island_builder.trellis_preview):
		island_builder._clear_preview()
		island_builder.trellis_preview=preload("res://presentation/trellis_layout_preview.gd").new()
		add_child(island_builder.trellis_preview);island_builder.trellis_preview.configure(self)
	var preview: Node3D=island_builder.trellis_preview
	preview.update(plan)
	while preview.pending:
		await get_tree().process_frame
		if _exiting: return
	if preview.validated==null:
		island_builder.set_busy(false,preview.message);return
	var animal_issue: String=preview.animal_issue(plan)
	if not animal_issue.is_empty(): island_builder.set_busy(false,animal_issue);return
	var started: int=Time.get_ticks_msec()
	var candidate: RefCounted=farm_state.copy()
	if not candidate.apply_layout(snapshot,clock.call()).ok:
		island_builder.set_busy(false,"已有作物需要保留，请调整范围。");return
	var saved: Dictionary=_save_state(candidate,decoration_state)
	if not saved.ok:
		island_builder.set_busy(false,"未能保存，可重试或取消调整。");return
	previous_layout={} if undo else farm_state.snapshot().layout
	previous_decorations={};farm_state=candidate
	plan=preview.validated
	island_builder.accept_trellis(plan)
	decoration_layout.refresh_path_geometry()
	refresh_farm();seasonal_courtyard.refresh_paths($Environment)
	$Environment.refresh_terrain.call_deferred(false)
	print("TRELLIS_COMMIT_MS ",Time.get_ticks_msec()-started)

func _apply_building(snapshot: Dictionary, undo: bool, id: String) -> void:
	var plan: RefCounted=CourtyardPlan.from_snapshot(snapshot)
	if plan==null: return
	island_builder.set_busy(true,"正在校对屋前通路…")
	if is_instance_valid(island_builder.building_preview) and island_builder.building_preview.building_id!=id: island_builder._clear_preview()
	if not is_instance_valid(island_builder.building_preview):
		island_builder._clear_preview()
		island_builder.building_preview=preload("res://presentation/building_layout_preview.gd").new()
		add_child(island_builder.building_preview);island_builder.building_preview.configure(self,id)
	var preview: Node3D=island_builder.building_preview
	preview.update(plan)
	while preview.pending:
		await get_tree().process_frame
		if _exiting: return
	if preview.validated==null:
		island_builder.set_busy(false,preview.message);return
	var animal_issue: String=preview.animal_issue()
	if not animal_issue.is_empty(): island_builder.set_busy(false,animal_issue);return
	var started: int=Time.get_ticks_msec()
	var candidate: RefCounted=farm_state.copy()
	if not candidate.apply_layout(snapshot,clock.call()).ok:
		island_builder.set_busy(false,"已有作物需要保留，请调整范围。");return
	var saved: Dictionary=_save_state(candidate,decoration_state)
	if not saved.ok:
		island_builder.set_busy(false,"未能保存，可重试或取消调整。");return
	previous_layout={} if undo else farm_state.snapshot().layout
	previous_decorations={};farm_state=candidate
	plan=preview.validated
	island_builder.accept_building(plan)
	decoration_layout.refresh_path_geometry()
	refresh_farm();seasonal_courtyard.refresh_paths($Environment)
	$Environment.refresh_terrain.call_deferred(false)
	print("BUILDING_COMMIT_MS ",Time.get_ticks_msec()-started)

func _begin_courtyard_edit() -> void:
	if _world_edit_unavailable():
		return
	if not _loaded or _save_failed or _layout_active(): return
	_return_overview()
	hud.hide_time_preview()
	camera.cancel_zoom()
	courtyard_edit.begin($Environment,farm_state,decoration_layout.ground_footprints(),previous_layout)
	_refresh_hud()

func _apply_courtyard(snapshot: Dictionary, undo: bool) -> void:
	if not _layout_active() or courtyard_edit.editor.busy: return
	var requested_plan: RefCounted=CourtyardPlan.from_snapshot(snapshot)
	if requested_plan==null: return
	var plants_issue: String=CourtyardPlan.Plants.terrain_issue(requested_plan)
	if not plants_issue.is_empty(): courtyard_edit.editor.set_busy(false,plants_issue);return
	var route_issue: String=CourtyardPlan.Routes.terrain_issue(requested_plan)
	if not route_issue.is_empty(): courtyard_edit.editor.set_busy(false,route_issue);return
	var candidate: FarmState = farm_state.copy()
	var result: Dictionary=candidate.apply_layout(snapshot,clock.call())
	if not result.ok:
		courtyard_edit.editor.set_busy(false,"将移除的田格里还有作物，请先收获，或保留这些田格。")
		return
	courtyard_edit.editor.set_busy(true,"正在整理小院…")
	await get_tree().process_frame
	await get_tree().process_frame
	if _exiting: return
	# Commit to disk before replacing either the authoritative state or its scene.
	# A failed write leaves the old island/crops intact and the draft retryable.
	var saved: Dictionary=_save_state(candidate,decoration_state)
	if not saved.ok:
		courtyard_edit.editor.set_busy(false,"未能保存，本次整理还没有生效。可以重试，或取消保留原来的小院。")
		return
	previous_layout={} if undo else farm_state.snapshot().layout
	previous_decorations={}
	farm_state=candidate
	_reload_saved_scene()


func _begin_decoration() -> void:
	if _world_edit_unavailable():
		return
	if not _loaded or _save_failed or decoration_layout == null or _layout_active():
		return
	if decoration_layout.active:
		decoration_layout.finish_mode()
		return
	_return_overview()
	decoration_layout.begin_mode()
	farm_audio.play_ui()


func _on_decoration_mode_changed(active: bool) -> void:
	_cancel_input()
	selected_tool = ""
	selected_palette = ""
	selected_field = -1
	selected_cell = ""
	_select_field_visual(-1)
	_select_cell_visual(-1, "")
	if focus_detail != null:
		focus_detail.set_focus()
	if island_builder==null or not island_builder.active: camera.set_decoration_framing(active)
	_refresh_hud()


func _refresh_lanterns() -> void:
	if atmosphere != null and decoration_layout != null:
		atmosphere.set_lantern_anchors(decoration_layout.lantern_anchors())


func _input(event: InputEvent) -> void:
	if desktop_wallpaper != null and (desktop_wallpaper.busy or (desktop_wallpaper.active and not _wallpaper_injecting)):
		get_viewport().set_input_as_handled()
		return
	# A modal input handler may have consumed the event already; the world must not
	# also act on the same key or click.
	if get_viewport().is_input_handled():
		return
	if bank_panel != null and bank_panel.visible:
		# The panel owns the screen: GUI controls still receive their events, but
		# the world camera and soil gestures do not.
		if (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT):
			bank_panel.close()
			get_viewport().set_input_as_handled()
		return
	if governance_panel != null and governance_panel.visible:
		# The panel owns the screen. Its own Esc handler may have consumed the
		# event first; either path closes exactly once.
		if not governance_panel.is_popup_open() \
				and ((event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)):
			governance_panel.close()
			get_viewport().set_input_as_handled()
		return
	if unit_panel != null and unit_panel.visible:
		# Same rule as the other panels: a dropdown or disband confirmation takes
		# the first Esc; the world camera never receives input behind the panel.
		if not get_viewport().is_input_handled() and not unit_panel.is_popup_open() \
				and ((event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)):
			unit_panel.close_panel()
			get_viewport().set_input_as_handled()
		return
	if fund_panel != null and fund_panel.visible:
		# The rotate confirmation takes the first Esc; the next one closes the
		# fund panel, and the world camera never receives input behind it.
		if not get_viewport().is_input_handled() and not fund_panel.is_popup_open() \
				and ((event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)):
			fund_panel.close_panel()
			get_viewport().set_input_as_handled()
		return
	if participation_panel != null and participation_panel.visible:
		# The withdraw confirmation or a dropdown takes the first Esc; the next
		# one closes the participation panel, and the world camera never receives
		# input behind it.
		if not get_viewport().is_input_handled() and not participation_panel.is_popup_open() \
				and ((event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)):
			participation_panel.close_panel()
			get_viewport().set_input_as_handled()
		return
	if public_works_panel != null and public_works_panel.visible:
		# An open kind dropdown takes the first Esc; the next one closes the
		# public works panel, and the world camera never receives input behind it.
		if not get_viewport().is_input_handled() and not public_works_panel.is_popup_open() \
				and ((event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)):
			public_works_panel.close_panel()
			get_viewport().set_input_as_handled()
		return
	if conflict_panel != null and conflict_panel.visible:
		# The engage confirmation takes the first Esc; the next one closes the
		# conflict panel, and the world camera never receives input behind it.
		if not get_viewport().is_input_handled() and not conflict_panel.is_popup_open() \
				and ((event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)):
			conflict_panel.close_panel()
			get_viewport().set_input_as_handled()
		return
	if dispute_panel != null and dispute_panel.visible:
		# The confirmation or an open dropdown takes the first Esc; the next one
		# closes the dispute panel, and the world camera never receives input behind it.
		if not get_viewport().is_input_handled() and not dispute_panel.is_popup_open() \
				and ((event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)):
			dispute_panel.close_panel()
			get_viewport().set_input_as_handled()
		return
	if resolutions_panel != null and resolutions_panel.visible:
		# The confirmation or an open dropdown takes the first Esc; the next one
		# closes the resolution panel, and the world camera never receives input
		# behind it.
		if not get_viewport().is_input_handled() and not resolutions_panel.is_popup_open() \
				and ((event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)):
			resolutions_panel.close_panel()
			get_viewport().set_input_as_handled()
		return
	if resident_panel != null and resident_panel.visible:
		# Esc or right click closes the read-only resident panel; the world camera
		# never receives input behind it.
		if not get_viewport().is_input_handled() \
				and ((event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)):
			resident_panel.close_panel()
			get_viewport().set_input_as_handled()
		return
	if dialogue_panel != null and dialogue_panel.visible:
		# The target dropdown takes the first Esc; the next one closes the panel,
		# and the world camera never receives input behind it.
		if not get_viewport().is_input_handled() and not dialogue_panel.is_popup_open() \
				and ((event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)):
			dialogue_panel.close_panel()
			get_viewport().set_input_as_handled()
		return
	if market_panel != null and market_panel.visible:
		# The panel owns the screen: GUI controls still receive their events, but
		# the world camera and soil gestures do not.
		if (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT):
			market_panel.close()
			get_viewport().set_input_as_handled()
		return
	if social_panel != null and social_panel.visible:
		# A dropdown or focused compose field consumes the first Esc itself; the
		# main scene must not close the panel and then clear tools behind it.
		if not get_viewport().is_input_handled() and not social_panel.is_popup_open() \
				and ((event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)):
			social_panel.close()
			get_viewport().set_input_as_handled()
		return
	if build_panel != null and build_panel.visible:
		if not get_viewport().is_input_handled() and not build_panel.is_popup_open() \
				and ((event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) \
				or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)):
			build_panel.close()
			get_viewport().set_input_as_handled()
		return
	camera.observe_input(event)
	if island_builder!=null and island_builder.active:
		island_builder.observe(event);return
	if sway_tuning != null and sway_tuning.visible:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			sway_tuning.hide()
			get_viewport().set_input_as_handled()
		return
	if _consume_focus_return_wheel(event): return
	if field_menu != null and field_menu.active:
		if (event is InputEventKey and event.pressed and event.keycode==KEY_ESCAPE) or (event is InputEventMouseButton and event.pressed and event.button_index!=MOUSE_BUTTON_LEFT):
			field_menu.dismiss()
			_cancel_input()
			get_viewport().set_input_as_handled()
		return
	if garden_album!=null and garden_album.active:
		garden_album.cancel_key(event)
		return
	if _animal_active():
		if (event is InputEventKey and event.pressed and not event.echo and event.keycode==KEY_ESCAPE) or (event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_RIGHT):
			animal_panel.dismiss();get_viewport().set_input_as_handled()
		return
	if _basket_active():
		if (event is InputEventKey and event.pressed and not event.echo and event.keycode==KEY_ESCAPE) or (event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_RIGHT):
			if harvest_book.viewing: harvest_book.end_view()
			else: harvest_book.dismiss()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouse:
		_pointer_position = event.position
	if not _loaded or _save_failed:
		return
	if _layout_active():
		if (event is InputEventKey and event.pressed and not event.echo and event.keycode==KEY_ESCAPE) or (event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_RIGHT):
			courtyard_edit.editor.cancel()
			get_viewport().set_input_as_handled()
		return
	if camera_tuning != null and camera_tuning.visible:
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			camera_tuning.hide()
			get_viewport().set_input_as_handled()
		return
	if game_menu != null and game_menu.visible:
		if (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT):
			if decoration_layout.active and not decoration_layout.selected_item.is_empty():
				decoration_layout.cancel_preview()
			else:
				_request_menu_close()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F8 and _developer_enabled():
		_toggle_free_view()
		get_viewport().set_input_as_handled()
		return
	if camera.free_view:
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			_return_overview()
			get_viewport().set_input_as_handled()
		elif event is InputEventMouseButton and (not event.pressed or event.canceled):
			camera.end_free_drag(event.button_index)
		return
	if decoration_layout != null and decoration_layout.active:
		decoration_layout.observe_input(event)
		if (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE) or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT):
			if decoration_layout.selected_item.is_empty():
				decoration_layout.finish_mode()
			else:
				decoration_layout.cancel_preview()
			get_viewport().set_input_as_handled()
		return
	# Cancellation sees even GUI-consumed releases; world gestures start only in unhandled input.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_cancel_or_return()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _press_position != Vector2.INF:
		_press_dragged = _press_dragged or event.position.distance_to(_press_position) > 7.0
	elif event is InputEventMouseButton and not event.pressed:
		if event.button_index == _orbit_button:
			var short_right: bool = _orbit_button==MOUSE_BUTTON_RIGHT and _orbit_travel<7.0 and not event.canceled
			_finish_orbit()
			if short_right: _cancel_or_return()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			var hovered := get_viewport().gui_get_hovered_control()
			if event.canceled:
				_cancel_input()
			elif hovered != null and hovered.mouse_filter != Control.MOUSE_FILTER_IGNORE:
				_cancel_input(false)


func _consume_focus_return_wheel(event: InputEvent) -> bool:
	if not event is InputEventMouseButton or not event.pressed or event.canceled or event.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return false
	if not _loaded or _save_failed or camera.free_view or _layout_active() or _basket_active() or _animal_active(): return false
	if (game_menu != null and game_menu.visible) or (garden_album != null and garden_album.active): return false
	if not camera.consume_focus_return_wheel(): return false
	if field_menu != null: field_menu.dismiss()
	if camera.focused: _return_overview()
	get_viewport().set_input_as_handled()
	return true


func _unhandled_input(event: InputEvent) -> void:
	if sway_tuning != null and sway_tuning.visible: return
	if market_panel != null and market_panel.visible: return
	if bank_panel != null and bank_panel.visible: return
	if social_panel != null and social_panel.visible: return
	if build_panel != null and build_panel.visible: return
	if desktop_wallpaper != null and (desktop_wallpaper.busy or (desktop_wallpaper.active and not _wallpaper_injecting)):
		get_viewport().set_input_as_handled()
		return
	if island_builder!=null and island_builder.active:
		island_builder.handle(event);return
	if field_menu != null and field_menu.active: return
	if garden_album!=null and garden_album.active: return
	if _animal_active(): return
	if _basket_active(): return
	if _layout_active(): return
	if camera_tuning != null and camera_tuning.visible:
		return
	if not _loaded or _save_failed or (game_menu != null and game_menu.visible):
		return
	if camera.free_view:
		camera.free_input(event)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed and not event.canceled and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		_cancel_input()
		if decoration_layout != null:
			decoration_layout.cancel_pointer_gesture()
		camera.zoom((-0.8 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 0.8) * event.factor)
		get_viewport().set_input_as_handled()
		return
	if decoration_layout != null and decoration_layout.active:
		decoration_layout.handle_input(event)
		return
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if event.double_click or event.canceled:
					_cancel_input()
				elif event.pressed:
					_tool_press = {}
					_press_position = event.position
					_press_dragged = _dragging
					_picks.append({"down": true, "position": event.position, "dragged": _dragging,
						"action_allowed": not camera.is_transitioning(), "selection": selected_field})
				elif _press_position != Vector2.INF:
					_picks.append({"down": false, "position": event.position, "dragged": _press_dragged,
						"action_allowed": not camera.is_transitioning()})
					_press_position = Vector2.INF
			MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
				_cancel_input()
				_dragging = event.pressed
				_orbit_button = event.button_index if event.pressed else MOUSE_BUTTON_NONE
				_orbit_travel = 0.0
	elif event is InputEventMouseMotion and _dragging:
		_orbit_travel += event.relative.length()
		if _orbit_button!=MOUSE_BUTTON_RIGHT or _orbit_travel>=7.0:
			camera.drag(event.relative, event.shift_pressed)


func _physics_process(_delta: float) -> void:
	if desktop_wallpaper != null:
		if desktop_wallpaper.busy: return
		if desktop_wallpaper.active and not desktop_wallpaper.interacting:
			var entry: String = ""
			if not wallpaper_hint.contains(_pointer_position) and get_viewport().get_visible_rect().has_point(_pointer_position) and $Environment/DoorTools.may_hit(camera, _pointer_position):
				entry = _scene_entry_at(_pointer_position)
			$Environment/DoorTools.set_hover(entry.trim_prefix("tool_") if entry.begins_with("tool_") or entry == "rest" else "")
			if _wallpaper_click.is_finite():
				entry = _scene_entry_at(_wallpaper_click)
				_wallpaper_click = Vector2.INF
				if entry.begins_with("tool_") or entry == "rest":
					_wallpaper_entry = entry
					desktop_wallpaper.set_interacting(true)
			return
	if field_menu != null and field_menu.active:
		$Environment/DoorTools.set_hover("")
		if not _tools_available(): field_menu.dismiss()
		_cancel_input()
		return
	if garden_album!=null and garden_album.active:
		_cancel_input()
		return
	if _animal_active():
		animal_panel.set_activity($Environment/CourtyardAnimals.interaction.status(animal_panel.animal_id))
		_cancel_input()
		return
	_update_hover()
	if _layout_active() or _basket_active() or camera.free_view or (game_menu != null and game_menu.visible):
		_cancel_input()
		return
	# Space queries belong to the physics boundary. Each gesture carries its admission
	# state so a click made in flight can never become an action after the tween ends.
	var picks: Array[Dictionary] = _picks
	_picks = []
	for pick: Dictionary in picks:
		if selected_tool.is_empty() or $Environment/DoorTools.may_hit(camera,pick.position):
			var animal: String=_animal_at(pick.position) if selected_tool.is_empty() else ""
			var entry: String=_scene_entry_at(pick.position) if animal.is_empty() else ""
			if not selected_tool.is_empty() and not entry.begins_with("tool_") and entry != "rest": entry=""
			if pick.down:
				_pressed_animal=animal
				_pressed_entry=entry
			elif not _pressed_animal.is_empty() or not _pressed_entry.is_empty():
				var same_animal: bool=not _pressed_animal.is_empty() and animal==_pressed_animal
				var same_entry: bool=not _pressed_entry.is_empty() and entry==_pressed_entry
				_pressed_animal=""
				_pressed_entry=""
				if not pick.dragged and pick.action_allowed and _press_context.get("action_allowed",false):
					if same_animal: _open_animal(animal)
					elif same_entry: _open_scene_entry(entry)
				_pressed_field=-1;_pressed_cell="";_press_context={}
				continue
		var hit: Dictionary = _farm_hit(pick.position)
		var index: int = hit.get("field", -1)
		var cell_id: String = hit.get("cell", "")
		if pick.down:
			_pressed_field = index
			_pressed_cell = cell_id
			_press_context = pick
		else:
			if not pick.dragged and index >= 0 and index == _pressed_field and cell_id == _pressed_cell:
				if pick.action_allowed and _press_context.get("action_allowed", false) and not camera.is_transitioning():
					if not selected_tool.is_empty() and not cell_id.is_empty():
						selected_field = index
						selected_cell = cell_id
						_apply_tool(pick.position)
					elif not cell_id.is_empty():
						_present_field_menu(index,cell_id,pick.position)
					elif index != selected_field or not camera.focused:
						_focus_field(index)
					else:
						_select_cell(cell_id)
			_pressed_field = -1
			_pressed_cell = ""
			_press_context = {}


func _exit_tree() -> void:
	if hosted_room != null:
		hosted_room.stop()
		hosted_room = null


func _notification(what: int) -> void:
	if _exiting:
		return
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_node_ready():
		_request_exit()
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_WM_MOUSE_EXIT:
		if desktop_wallpaper != null and desktop_wallpaper.active: return
		if field_menu != null: field_menu.dismiss()
		if garden_album!=null and garden_album.active: camera.cancel_free_gesture()
		if what==NOTIFICATION_WM_WINDOW_FOCUS_OUT and animal_panel!=null: animal_panel.dismiss()
		_pointer_position = Vector2(-100, -100)
		_cancel_input()
		if _layout_active(): courtyard_edit.editor.chart.cancel_drag()
		if is_instance_valid(camera):
			camera.cancel_free_gesture()
			camera.cancel_zoom()
		selected_tool = ""
		selected_palette = ""
		if island_builder!=null and island_builder.active:
			island_builder._focus_lost()
		elif decoration_layout != null and decoration_layout.active:
			if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
				decoration_layout.finish_mode()
			else:
				decoration_layout.cancel_preview()
		if is_node_ready():
			_refresh_hud()
			if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT and _loaded and not _save_failed:
				settle_farm()
				_save_farm()
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_IN and is_node_ready():
		settle_farm()


func _field_at(screen_point: Vector2) -> int:
	return int(_farm_hit(screen_point).get("field", -1))


func _cell_at(screen_point: Vector2, field_index: int) -> String:
	var hit: Dictionary = _farm_hit(screen_point)
	return str(hit.get("cell", "")) if hit.get("field", -1) == field_index else ""


func _farm_hit(screen_point: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(screen_point)
	var end := origin + camera.project_ray_normal(screen_point) * 120.0
	var query := PhysicsRayQueryParameters3D.create(origin, end, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}
	var index: int = int(hit.collider.get_meta("field_index", -1))
	if index < 0:
		return {}
	# Only the actual top soil plane can select a cell; bed sides still focus its field.
	var cell_id: String=""
	if camera.focused and index==selected_field:
		if index==TrellisCrops.INDEX:
			cell_id=str(hit.collider.get_meta("trellis_cell",""))
			if cell_id.is_empty(): cell_id=trellis_crops.cell_at(hit.position)
		elif hit.normal.y>.9: cell_id=farm.cell_at(index,hit.position)
	return {"field": index, "cell": cell_id}


func _focus_field(index: int) -> void:
	_cancel_input()
	selected_palette = ""
	selected_field = index
	selected_cell = ""
	_select_field_visual(index)
	_select_cell_visual(-1, "")
	var body: Node3D=trellis_crops.body if index==TrellisCrops.INDEX else farm.fields[index]
	focus_detail.set_focus(body)
	var center: Vector3=body.global_position
	var framing: Vector2=body.get_meta("field_size")
	if index==TrellisCrops.INDEX:
		var dimensions: Vector3=TrellisSlots.Construction.trellis_size(courtyard_plan)
		center.y+=dimensions.z*.35
		framing=Vector2(dimensions.y+.8,maxf(dimensions.z,dimensions.x*.65))
	camera.focus_field(center,framing)
	_refresh_hud()


func _select_cell(cell_id: String) -> void:
	if selected_field < 0 or (not cell_id.is_empty() and not farm_state.cell_ids(_planting_id(selected_field)).has(cell_id)):
		return
	_cancel_input()
	selected_cell = cell_id
	_select_cell_visual(selected_field, cell_id)
	_refresh_hud()


func _tools_available() -> bool:
	return _loaded and not _save_failed and not _exiting and not _layout_active() and not _basket_active() and not _animal_active() and not (camera_tuning != null and camera_tuning.visible) and not (sway_tuning != null and sway_tuning.visible) and not camera.free_view and not camera.is_transitioning() and not (game_menu != null and game_menu.visible) and not (decoration_layout != null and decoration_layout.active)


func _start_tool_press(tool: String) -> void:
	var dragging: bool = _dragging
	_cancel_input()
	if not dragging and _tools_available():
		_tool_press = {"tool": tool}


func _finish_tool_press(tool: String) -> void:
	var admitted: bool = _tool_press.get("tool", "") == tool
	_tool_press = {}
	if admitted:
		_select_tool(tool)


func _can_work_cell() -> bool:
	return _tools_available() and camera.focused and selected_field >= 0 and not selected_cell.is_empty()


func _open_palette(palette: String) -> void:
	if not _tools_available() or palette not in ["sow", "tools"]:
		return
	_cancel_input()
	selected_tool = ""
	selected_palette = "" if selected_palette == palette else palette
	_menu_target = {}
	field_menu.dismiss()
	farm_audio.play_ui()
	_refresh_hud()


func _select_tool(tool: String) -> void:
	_cancel_input()
	if not _tools_available() or tool not in ["sow", "water", "harvest", "weed", "till"]:
		return
	selected_tool = "" if selected_tool == tool else tool
	selected_palette = ""
	_refresh_hud()


func _select_crop(crop_id: String) -> void:
	if not _tools_available() or not Crops.crop_ids().has(crop_id):
		return
	_cancel_input()
	camera.cancel_zoom()
	selected_crop = crop_id
	selected_tool = "sow"
	selected_palette = ""
	farm_audio.play_ui()
	_refresh_hud()


func _cancel_tool() -> void:
	_cancel_input()
	selected_tool = ""
	selected_palette = ""
	_refresh_hud()


func _update_hover() -> void:
	if tool_cursor == null:
		return
	var ui: Control = get_viewport().gui_get_hovered_control()
	var blocked: bool = not _tools_available() or _dragging or (ui != null and ui.mouse_filter != Control.MOUSE_FILTER_IGNORE) or not get_viewport().get_visible_rect().has_point(_pointer_position)
	var door_tools: Node3D = $Environment/DoorTools
	var tool_hit: String = ""
	# Test the three tiny bounds first; only perform scene occlusion when nearby.
	if not blocked and door_tools.may_hit(camera,_pointer_position):
		tool_hit = _scene_entry_at(_pointer_position).trim_prefix("tool_")
	door_tools.set_hover(tool_hit)
	var hit: Dictionary = {} if blocked else _farm_hit(_pointer_position)
	var index: int = hit.get("field", -1)
	var cell_id: String = hit.get("cell", "")
	if index != hover_field or cell_id != hover_cell:
		hover_field = index
		hover_cell = cell_id
		_select_cell_visual(index, cell_id)
		_select_field_visual(index if index >= 0 and cell_id.is_empty() else selected_field)
		_refresh_hud()
	tool_cursor.show_tool("" if blocked else selected_tool, selected_crop)


func _present_field_menu(index: int, cell_id: String, point: Vector2) -> void:
	if not _tools_available() or not camera.focused or index != selected_field or cell_id.is_empty(): return
	_cancel_input()
	selected_field = index
	selected_cell = cell_id
	_menu_target = {"field":index,"cell":cell_id}
	_select_cell_visual(index,cell_id)
	tool_cursor.show_tool("", selected_crop)
	field_menu.present(point,farm_state.get_cell(_planting_id(index),cell_id))
	_refresh_hud()


func _field_menu_action(tool: String, crop: String) -> void:
	var target: Dictionary = _menu_target
	_menu_target = {}
	if not _tools_available(): return
	# Every crop picker equips the same carried seed; only a later soil click sows.
	if tool == "sow":
		_select_crop(crop)
		return
	if target.is_empty():
		_select_tool(tool)
		return
	if not camera.focused or target.field != selected_field: return
	selected_field = target.field
	selected_cell = target.cell
	selected_tool = tool
	_apply_tool()
	# Non-planting soil actions remain one-shot.
	_cancel_tool()


func _apply_tool(menu_point: Vector2 = Vector2.INF) -> void:
	if not _can_work_cell() or selected_tool.is_empty():
		return
	var field_id: String = _planting_id(selected_field)
	var now: float = clock.call()
	var command: Dictionary = _tool_command(field_id, now)
	if command.is_empty():
		return
	if remote != null:
		# The authority decides. The same command is applied here only after it
		# answers, so a refused click never moves a crop and two clients cannot
		# invent different outcomes for one id.
		if remote.submit(command):
			_remote_pending[str(command.id)] = {"command": command, "tool": selected_tool}
		else:
			hud.show_notice("还没有连上世界，这次操作没有发出。")
		return
	# Every soil action goes through the M0 command boundary so a replayed id can
	# never apply a second change; the candidate carries the idempotent result.
	# Singleplayer names this machine's player, so a harvest lands in their bag;
	# an invalid id stays anonymous and keeps the shared inventory.
	var actor: String = local_player_id if OwnerIds.valid(local_player_id) else ""
	var execution: Dictionary = farm_commands.execute(farm_state, command, actor)
	if execution.duplicate:
		return
	var result: Dictionary = execution.get("result", {"ok": false, "reason": "invalid_command"}) as Dictionary
	if not result.ok:
		# A selected tool must not turn incompatible soil clicks into silent no-ops.
		if menu_point.is_finite() and result.reason in ["empty", "not_mature", "mature", "already_watered", "occupied", "wrong_ground", "unprepared", "wrong_support"]:
			_present_field_menu(selected_field, selected_cell, menu_point)
		return
	_commit_tool(selected_tool, execution.candidate as FarmState, result)
	var saved: Dictionary=_save_state(farm_state,decoration_state)
	if not saved.ok:
		_save_failed=true
		_cancel_tool()
		hud.show_storage_issue(saved.kind,true)


## Applies an accepted soil command to what is on screen. Shared by the local
## path and the networked path so one action cannot look different in the two.
func _commit_tool(tool: String, candidate: FarmState, result: Dictionary) -> void:
	var decorations:=DecorationState.new()
	decorations.restore_snapshot(decoration_state.snapshot())
	var unlock_state: Dictionary = _display_state(candidate)
	decorations.unlock(unlock_state.harvested,unlock_state.kitchen)
	# The action is visible in memory even if a later write fails: retry saves this
	# snapshot instead of asking the player to harvest again.
	farm_state.accept(candidate)
	decoration_state.restore_snapshot(decorations.snapshot())
	farm_audio.play_action(tool, result)
	for changed_field: String in result.visual_changed:
		if changed_field == TrellisSlots.FIELD_ID: refresh_trellis()
		else: farm.show_field(farm_state.get_field(changed_field))
	_refresh_hud()
	farm_changed.emit(result)


func _new_command_id() -> String:
	return "%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]


func _tool_command(field_id: String, now: float) -> Dictionary:
	var id: String = _new_command_id()
	match selected_tool:
		"harvest": return FarmCommand.make(id, field_id, selected_cell, now)
		"sow": return FarmCommand.make_sow(id, field_id, selected_cell, selected_crop, now)
		"water": return FarmCommand.make_water(id, field_id, selected_cell, now)
		"weed", "till": return FarmCommand.make_tidy(id, selected_tool, field_id, selected_cell, now)
	return {}


func _cancel_or_return() -> void:
	_cancel_input()
	if not selected_tool.is_empty() or not selected_palette.is_empty():
		_cancel_tool()
	elif not selected_cell.is_empty():
		_select_cell("")
	elif desktop_wallpaper != null and desktop_wallpaper.interacting and not camera.focused:
		_end_wallpaper_interaction()
	else:
		_return_overview()


func _return_overview() -> void:
	if sway_tuning != null: sway_tuning.hide()
	if camera_tuning != null:
		camera_tuning.hide()
	if camera.free_view:
		camera.set_free_view(false)
		game_menu.show_free_view(false)
	if decoration_layout != null and decoration_layout.active:
		decoration_layout.finish_mode()
	_cancel_input()
	selected_tool = ""
	selected_palette = ""
	selected_field = -1
	selected_cell = ""
	_select_field_visual(-1)
	_select_cell_visual(-1, "")
	focus_detail.set_focus()
	camera.return_overview()
	_refresh_hud()


func _reset_view() -> void:
	_return_overview()
	camera.reset_view()
	_refresh_hud()


func _toggle_free_view() -> void:
	if not _developer_enabled() or not _loaded or _save_failed or (game_menu != null and game_menu.visible):
		return
	var enabled: bool = not camera.free_view
	_return_overview()
	if enabled:
		camera.set_free_view(true)
		game_menu.show_free_view(true)


func _toggle_camera_tuning() -> void:
	if camera_tuning == null or not _loaded or _save_failed or (game_menu != null and game_menu.visible):
		return
	if camera_tuning.visible:
		camera_tuning.hide()
		return
	# The tuning overlay consumes pointer input; leave no field tool armed behind it.
	_cancel_tool()
	_return_overview()
	hud.hide_time_preview()
	camera_tuning.present(focus_detail.get_settings())


func _cancel_input(cancel_tool_press: bool = true) -> void:
	_finish_orbit()
	_pressed_animal=""
	_pressed_entry=""
	if cancel_tool_press:
		_tool_press = {}
	_dragging = false
	_press_position = Vector2.INF
	_press_dragged = true
	_pressed_field = -1
	_pressed_cell = ""
	_press_context = {}
	_picks.clear()

func _finish_orbit() -> void:
	_dragging = false
	_orbit_button = MOUSE_BUTTON_NONE
	if _view_dirty and game_menu!=null:
		_view_dirty = false
		_save_settings()

func _remember_overview() -> void:
	# Integer millidegrees round-trip exactly through JSON verification.
	settings_values.overview_mdeg = [float(roundi(camera.overview_view.x*1000)),float(roundi(camera.overview_view.y*1000))]
	_settings_dirty = true
	_view_dirty = true


func _setup_settings() -> void:
	if settings_store == null:
		settings_store = SettingsStore.new()
	var loaded: Dictionary = settings_store.load_settings() if startup_preferences.is_empty() else startup_preferences
	startup_preferences = {}
	settings_values = loaded.settings
	if OS.has_feature("editor") and OS.get_cmdline_user_args().has("--dev-preview"):
		# Development startup overrides the old window preference for this session.
		settings_values.fullscreen = true
	if not loaded.ok:
		_settings_issue = {
			"corrupt": "设置文件无法读取，已使用默认设置；原件保留。保存设置时会先留存原件。",
			"unsupported": "设置来自较新版本，本次使用默认设置；原件保留，暂时不能覆盖。",
		}.get(loaded.kind, "设置暂时无法读取，本次使用默认设置；农场进度不受影响。")
	game_menu = GameMenu.new()
	game_menu.name = "GameMenu"
	add_child(game_menu)
	game_menu.settings_changed.connect(_change_settings)
	game_menu.disaster_mode_changed.connect(_change_disaster_mode)
	game_menu.save_requested.connect(_save_settings)
	game_menu.developer_requested.connect(_developer_action)
	game_menu.close_requested.connect(_request_menu_close)
	game_menu.quit_requested.connect(_request_exit)
	game_menu.wallpaper_requested.connect(_enter_wallpaper)
	game_menu.world_export_requested.connect(_export_world_package)
	game_menu.world_import_requested.connect(_prepare_world_import)
	game_menu.world_import_confirmed.connect(_confirm_world_import)
	game_menu.world_import_cancelled.connect(_cancel_world_import)
	game_menu.identity_reset_requested.connect(_reset_identity)
	get_window().size_changed.connect(_apply_render_resolution)
	_apply_settings()
	if settings_values.has("overview_mdeg"):
		camera.restore_overview_angles(Vector2(settings_values.overview_mdeg[0],settings_values.overview_mdeg[1])/1000.0)
	camera.overview_changed.connect(_remember_overview)
	hud.show_settings_issue(not _settings_issue.is_empty())


func _apply_settings(previous: Dictionary = {}) -> void:
	if previous.get("sway_enabled") != settings_values.sway_enabled or previous.get("sway_idle_seconds") != settings_values.sway_idle_seconds:
		camera.configure_sway(settings_values.sway_enabled, settings_values.sway_idle_seconds)
	if previous.get("master") != settings_values.master or previous.get("music") != settings_values.music or previous.get("effects") != settings_values.effects:
		farm_audio.set_volumes(settings_values.master, settings_values.music, settings_values.effects)
	var graphics_changed: bool = previous.is_empty()
	for key: String in ["quality", "shadows", "lighting", "antialiasing"]:
		graphics_changed = graphics_changed or previous.get(key) != settings_values[key]
	if graphics_changed:
		if not previous.is_empty() and previous.get("lighting") != "high" and settings_values.lighting == "high":
			if not _high_quality_pending:
				_high_quality_pending = true
				_apply_high_quality.call_deferred()
		else:
			focus_detail.apply_graphics(settings_values)
	if previous.get("dof_enabled") != settings_values.dof_enabled:
		focus_detail.set_depth_of_field(settings_values.dof_enabled, focus_detail.get_settings().dof_strength)
	if previous.get("resolution") != settings_values.resolution or previous.get("fsr") != settings_values.fsr:
		_apply_render_resolution()
	# Headless validation has no OS window; preference validation remains identical.
	if DisplayServer.get_name() != "headless" and not (desktop_wallpaper != null and (desktop_wallpaper.active or desktop_wallpaper.busy)):
		var window: Window = get_window()
		var desired: Window.Mode = Window.MODE_FULLSCREEN if settings_values.fullscreen else Window.MODE_WINDOWED
		if settings_values.fullscreen and OS.has_feature("editor") and OS.get_cmdline_user_args().has("--dev-preview"):
			desired = Window.MODE_EXCLUSIVE_FULLSCREEN
		if window.mode != desired:
			_cancel_input()
			window.mode = desired
			if not settings_values.fullscreen:
				window.borderless = false


func _apply_render_resolution() -> void:
	if settings_values.is_empty(): return
	var output: Vector2i = get_window().size
	var choice: String = settings_values.resolution
	# Never lower UI resolution or change the display's video mode for 3D quality.
	var scale_3d: float = 1.0 if choice == "native" else clampf(float(choice) / maxf(output.y, 1), .25, 1.0)
	var fsr_enabled: bool = settings_values.fsr != "off" and RenderingServer.get_current_rendering_method() == "forward_plus"
	if fsr_enabled:
		# Presets are relative to the output, never multiplied by the old 3D cap.
		match settings_values.fsr:
			"quality": scale_3d = 1.0 / 1.5
			"balanced": scale_3d = 1.0 / 1.7
			"performance": scale_3d = 0.5
	var mode: Viewport.Scaling3DMode = Viewport.SCALING_3D_MODE_FSR2 if fsr_enabled else Viewport.SCALING_3D_MODE_BILINEAR
	if get_viewport().scaling_3d_mode != mode:
		get_viewport().scaling_3d_mode = mode
	if not is_equal_approx(get_viewport().scaling_3d_scale, scale_3d):
		get_viewport().scaling_3d_scale = scale_3d
	focus_detail.refresh_antialiasing()


func _open_menu() -> void:
	if sway_tuning != null: sway_tuning.hide()
	if game_menu == null or not _loaded or _save_failed:
		return
	_cancel_input()
	if camera_tuning != null:
		camera_tuning.hide()
	hud.hide_time_preview()
	camera.free_input_enabled = false
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	decoration_layout.cancel_pointer_gesture()
	selected_tool = ""
	selected_palette = ""
	_allow_leave_settings = false
	_refresh_hud()
	game_menu.present(settings_values, _settings_issue)
	_show_disaster_mode()
	farm_audio.play_ui()


## The world-level disaster mode. A shared world reports only what its authority
## carried in the summary/snapshot; the client never changes it.
func _current_disaster_mode() -> String:
	if remote != null:
		var summary: Variant = remote.member.state if remote.member != null else null
		var view: Variant = summary.get("nature") if summary is Dictionary else null
		if view is Dictionary and NatureState.valid_disaster_mode(view.get("disaster_mode")):
			return str(view.disaster_mode)
		var documents: Variant = remote.member.snapshot if remote.member != null else null
		var data: Variant = documents.get("nature") if documents is Dictionary else null
		if data is Dictionary:
			var source := NatureState.new()
			if source.restore_snapshot(data):
				return source.get_disaster_mode()
		return NatureState.DEFAULT_DISASTER_MODE
	if nature_state != null:
		return nature_state.get_disaster_mode()
	return NatureState.DEFAULT_DISASTER_MODE


func _show_disaster_mode() -> void:
	if game_menu != null:
		game_menu.set_disaster_mode(_current_disaster_mode(), remote == null)


## Persists the world switch before changing the in-memory object, so a failed
## write leaves both the derivation and the menu on the last accepted mode.
func _change_disaster_mode(mode: String) -> void:
	if game_menu == null:
		return
	if remote != null:
		game_menu.set_disaster_mode(_current_disaster_mode(), false)
		game_menu.set_status("联机模式下，灾害由世界房主决定。")
		return
	if not _loaded or _save_failed or nature_state == null or nature_store == null:
		game_menu.set_disaster_mode(_current_disaster_mode(), true)
		game_menu.set_status("灾害设置暂时无法更改。")
		return
	if not NatureState.valid_disaster_mode(mode) or nature_state.get_disaster_mode() == mode:
		game_menu.set_disaster_mode(_current_disaster_mode(), true)
		return
	var candidate := NatureState.new()
	if not candidate.restore_snapshot(nature_state.snapshot()):
		game_menu.set_disaster_mode(_current_disaster_mode(), true)
		game_menu.set_status("灾害设置未能保存，请重试。")
		return
	candidate.set_disaster_mode(mode)
	var saved: Dictionary = nature_store.save_state(candidate.snapshot())
	if not saved.ok:
		game_menu.set_disaster_mode(_current_disaster_mode(), true)
		game_menu.set_status("灾害设置未能保存，已有湿度与生长未改变。")
		return
	nature_state.set_disaster_mode(mode)
	_nature_persisted = true
	game_menu.set_disaster_mode(mode, true)
	game_menu.set_status(_disaster_mode_status(mode))
	# Apply the new view at once: this clears the HUD line and the visual mood.
	_sync_weather()


## The switch's own confirmation text. A mode change never rewrites settled
## moisture or growth, so every branch says so instead of implying a reset.
static func _disaster_mode_status(mode: String) -> String:
	match mode:
		"off":
			return "已关闭灾害，已有湿度与生长保持不变。"
		"risk":
			return "灾害已切换为风险模式，单次与单日损失有上限。"
		_:
			return "灾害已恢复为温和模式。"


func _enter_dev_wallpaper() -> void:
	# Internal measurement entry. Wait until the startup scene hands the farm
	# over, so an unattended first-run quality dialog is never mistaken for
	# readiness; the harness reports a timeout instead of measuring that screen.
	while is_inside_tree() and get_tree().current_scene != self:
		await get_tree().process_frame
	while is_inside_tree() and (_high_quality_pending or desktop_wallpaper.busy):
		await get_tree().process_frame
	if not is_inside_tree() or not _loaded or _save_failed or not desktop_wallpaper.available():
		return
	_enter_wallpaper()


func _enter_wallpaper() -> void:
	if desktop_wallpaper == null or desktop_wallpaper.busy: return
	if desktop_wallpaper.active:
		_end_wallpaper_interaction()
		return
	if not _loaded or _save_failed or _layout_active() or (garden_album != null and garden_album.active): return
	if (_settings_dirty or not _settings_issue.is_empty()) and not _save_settings(): return
	settle_farm()
	if not _save_farm(): return
	_wallpaper_issue = ""
	_wallpaper_click = Vector2.INF
	_cancel_input()
	_cancel_tool()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	game_menu.set_status("正在进入桌面壁纸…")
	desktop_wallpaper.enter()


func _wallpaper_changed(enabled: bool) -> void:
	_wallpaper_buttons = 0
	tool_cursor.set_system_pointer(enabled)
	_wallpaper_click = Vector2.INF
	_wallpaper_press = Vector2.INF
	_cancel_input()
	window_activity.set_wallpaper(enabled)
	focus_detail.set_wallpaper_observing(enabled)
	camera.free_input_enabled = not enabled
	get_viewport().gui_disable_input = enabled
	game_menu.set_wallpaper_mode(enabled)
	if enabled:
		print("WALLPAPER_ACTIVE screen=%d size=%s" % [DisplayServer.window_get_current_screen(), DisplayServer.window_get_size()])
		game_menu.dismiss()
		hud.hide()
		if desktop_wallpaper.interaction_supported() and not settings_values.wallpaper_hint_dismissed:
			wallpaper_hint.present(camera, $Environment/DoorTools.chair)
			$Environment/DoorTools.set_chair_hint(true)
	else:
		_hide_wallpaper_hint()
		_restore_wallpaper_layers()
		hud.set_workarea(Vector4(0, 0, 1, 1))
		hud.show()
		_refresh_hud()
		settle_farm()
		if not _wallpaper_issue.is_empty():
			game_menu.present(settings_values, _wallpaper_issue)


func _wallpaper_interaction_changed(enabled: bool) -> void:
	window_activity.set_wallpaper_interacting(enabled)
	focus_detail.set_wallpaper_observing(not enabled)
	get_viewport().gui_disable_input = not enabled
	camera.free_input_enabled = enabled
	if enabled:
		_hide_wallpaper_hint()
		_restore_wallpaper_layers()
		hud.show()
		var entry: String = _wallpaper_entry
		_wallpaper_entry = ""
		if entry.begins_with("tool_"): _open_scene_entry(entry)
		_refresh_hud()
	else:
		_wallpaper_entry = ""


func _restore_wallpaper_layers() -> void:
	for canvas: CanvasLayer in _wallpaper_layers:
		if is_instance_valid(canvas): canvas.show()
	_wallpaper_layers.clear()


func _hide_wallpaper_hint() -> void:
	wallpaper_hint.dismiss()
	$Environment/DoorTools.set_chair_hint(false)


func _dismiss_wallpaper_hint(permanently: bool) -> void:
	if permanently:
		settings_values.wallpaper_hint_dismissed = true
		_settings_dirty = true
		if not _save_settings():
			# Keep the bubble actionable; a failed write is not an opt-out.
			settings_values.wallpaper_hint_dismissed = false
			wallpaper_hint.show_save_failure()
			return
	_hide_wallpaper_hint()


func _inject_wallpaper(event: InputEventMouse, flags: int = 0) -> void:
	event.shift_pressed = bool(flags & 1)
	event.ctrl_pressed = bool(flags & 2)
	event.alt_pressed = bool(flags & 4)
	_wallpaper_injecting = true
	get_viewport().push_input(event, true)
	_wallpaper_injecting = false


func _wallpaper_pointer(point: Vector2, flags: int = 0) -> void:
	var position: Vector2 = point * get_viewport().get_visible_rect().size
	var previous: Vector2 = _pointer_position
	_pointer_position = position
	if not desktop_wallpaper.interacting:
		wallpaper_hint.move_pointer(position)
		return
	tool_cursor.update_pointer(position)
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.relative = position-previous if get_viewport().get_visible_rect().has_point(previous) else Vector2.ZERO
	event.button_mask = _wallpaper_buttons
	_inject_wallpaper(event, flags)


func _wallpaper_button(point: Vector2, button: int, pressed: bool, factor: float, flags: int) -> void:
	_wallpaper_pointer(point, flags)
	if not desktop_wallpaper.interacting:
		if button == MOUSE_BUTTON_LEFT:
			if wallpaper_hint.pointer_button(_pointer_position, pressed):
				_wallpaper_press = Vector2.INF
				_wallpaper_click = Vector2.INF
				return
			if pressed:
				_wallpaper_press = _pointer_position
			else:
				if _wallpaper_press.is_finite() and _wallpaper_press.distance_to(_pointer_position) < 7.0:
					_wallpaper_click = _pointer_position
				_wallpaper_press = Vector2.INF
		return
	var held: bool = button <= 3 or button >= 8
	var mask: int = 1 << (button-1)
	if held:
		_wallpaper_buttons = (_wallpaper_buttons | mask) if pressed else (_wallpaper_buttons & ~mask)
	var event := InputEventMouseButton.new()
	event.position = _pointer_position
	event.global_position = _pointer_position
	event.button_index = button as MouseButton
	event.button_mask = _wallpaper_buttons
	event.pressed = pressed
	event.factor = factor
	event.double_click = held and pressed and bool(flags & 8)
	_inject_wallpaper(event, flags)
	if not held:
		event = event.duplicate()
		event.pressed = false
		_inject_wallpaper(event, flags)


func _wallpaper_leave() -> void:
	wallpaper_hint.cancel_pointer()
	tool_cursor.update_pointer(Vector2.INF)
	for button: int in [1, 2, 3, 8, 9]:
		var mask: int = 1 << (button-1)
		if not (_wallpaper_buttons & mask): continue
		_wallpaper_buttons &= ~mask
		var event := InputEventMouseButton.new()
		event.button_index = button as MouseButton
		event.button_mask = _wallpaper_buttons
		event.position = Vector2(-100, -100)
		event.global_position = event.position
		event.canceled = true
		_inject_wallpaper(event)
	if desktop_wallpaper.interacting:
		var motion := InputEventMouseMotion.new()
		motion.position = Vector2(-100, -100)
		motion.global_position = motion.position
		_inject_wallpaper(motion)
	_wallpaper_press = Vector2.INF
	_wallpaper_click = Vector2.INF
	_pointer_position = Vector2(-100, -100)
	_cancel_input()
	if _layout_active(): courtyard_edit.editor.chart.cancel_drag()
	if island_builder != null and island_builder.active: island_builder._focus_lost()
	if decoration_layout != null and decoration_layout.active: decoration_layout.cancel_preview()
	camera.cancel_free_gesture()
	camera.cancel_zoom()
	$Environment/DoorTools.set_hover("")
	tool_cursor.show_tool("", selected_crop)


func _end_wallpaper_interaction() -> void:
	if desktop_wallpaper.busy: return
	_wallpaper_leave()
	# Keep the camera, selected tool, and open pages for the next interaction.
	_wallpaper_layers.clear()
	for node: Node in find_children("*", "CanvasLayer", true, false):
		var canvas := node as CanvasLayer
		if canvas.visible:
			_wallpaper_layers.append(canvas)
			canvas.hide()
	desktop_wallpaper.set_interacting(false)
	get_viewport().gui_disable_input = true
	camera.free_input_enabled = false
	settle_farm()
	_save_farm()


func _change_settings(value: Dictionary) -> void:
	if not SettingsStore.valid_settings(value):
		return
	var previous: Dictionary = settings_values
	settings_values = value.duplicate(true)
	_settings_dirty = true
	_allow_leave_settings = false
	_apply_settings(previous)
	_save_settings()
	if _high_quality_pending and _settings_issue.is_empty():
		game_menu.set_status("正在切换画质…")


func _apply_high_quality() -> void:
	# Let the menu paint feedback before the renderer allocates the GI volume.
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	if not is_inside_tree(): return
	focus_detail.apply_graphics(settings_values)
	_high_quality_pending = false
	if _settings_issue.is_empty(): game_menu.set_status("")


func _save_settings() -> bool:
	var result: Dictionary = settings_store.save(settings_values)
	if result.ok:
		_settings_dirty = false
		_settings_issue = ""
		_allow_leave_settings = false
		game_menu.set_status("")
	else:
		_settings_issue = "设置未能保存，本次调整仍然有效。可重试保存；农场进度不受影响。"
		if result.kind in ["unsupported", "unsupported_pending"]:
			_settings_issue = "设置来自较新版本，未能保存；原件保留，本次调整只在当前窗口有效。"
		_allow_leave_settings = true
		game_menu.set_status(_settings_issue, true)
	hud.show_settings_issue(not result.ok)
	return result.ok


## The running farm keeps the identity it started with; only the stored profile
## changes here. A restart or a fresh world join picks up the new id, which is
## why a successful reset never closes the game by itself.
func _reset_identity() -> void:
	var result: Dictionary = PlayerProfile.new().reset_identity()
	var archived: Array = result.get("archived", [])
	if bool(result.get("ok", false)):
		game_menu.set_world_status("玩家身份已重置。旧身份材料已归档；重启游戏或重新进入世界后使用新身份。")
		return
	var reason: String = _identity_reset_reason(str(result.get("reason", "")))
	if archived.is_empty():
		game_menu.set_world_status("身份没有重置：%s 旧文件保持不变。" % reason)
	else:
		game_menu.set_world_status("身份没有重置：%s 旧身份文件仍保存在归档中。" % reason)


func _identity_reset_reason(reason: String) -> String:
	match reason:
		"unsafe_path": return "玩家档案目录不可用。"
		"preserve_original": return "旧身份文件无法安全归档。"
		"key_write": return "新的本机凭据无法保存。"
		"write", "create_directory": return "新的身份文件无法保存。"
	return "写入玩家档案时出错。"


func _request_menu_close() -> void:
	if game_menu.closing: return
	if game_menu.cancel_quit_confirmation(): return
	if game_menu.cancel_wallpaper_confirmation(): return
	if game_menu.cancel_world_import_confirmation(): return
	if game_menu.cancel_identity_reset_confirmation(): return
	_cancel_input()
	decoration_layout.cancel_pointer_gesture()
	if (_settings_dirty or not _settings_issue.is_empty()) and not _allow_leave_settings:
		if not _save_settings():
			return
	game_menu.dismiss()
	await game_menu.dismissed
	_allow_leave_settings = false
	camera.free_input_enabled = true
	_refresh_hud()
	hud.get_node("Layout/FarmControls/Settings").grab_focus()


func _report_preview_ready() -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	print("DEV_PREVIEW_READY screen=%d mode=%d size=%s" % [DisplayServer.window_get_current_screen(), get_window().mode, DisplayServer.window_get_size()])

func _developer_enabled() -> bool:
	return game_menu != null and game_menu.developer_enabled()


func _developer_action(action: String) -> void:
	if not _developer_enabled(): return
	if not _loaded or _save_failed: return
	_ensure_developer_controls()
	if action == "mature":
		var result: Dictionary = farm_state.mature_all_crops(clock.call())
		if not result.ok:
			game_menu.set_status("作物成熟操作未完成，请重试。")
			return
		refresh_farm()
		if _save_farm(): game_menu.set_status("田地和菜架上的作物已成熟。")
		return
	if action == "models":
		if desktop_wallpaper.active:
			game_menu.set_status("模型检查室请先从托盘返回窗口后打开。")
			return
		var path := "res://development/model_gallery.tscn"
		if not ResourceLoader.exists(path):
			game_menu.set_status("模型检查室未安装在当前工程中。")
			return
		settle_farm()
		if not _save_farm(): return
		if _settings_dirty and not _save_settings(): return
		var error: Error = get_tree().change_scene_to_file(path)
		if error != OK:
			game_menu.set_status("模型检查室未能打开，请重试。")
			return
		farm_audio.shutdown()
		return
	await _request_menu_close()
	if game_menu.visible: return
	match action:
		"sway_tuning":
			_return_overview()
			sway_tuning.present()
		"camera_tuning": _toggle_camera_tuning()
		"free_camera": _toggle_free_view()
		"time": hud._toggle_time_preview()


func _ensure_developer_controls() -> void:
	if camera_tuning != null: return
	sway_tuning = preload("res://ui/sway_tuning.gd").new()
	sway_tuning.camera = camera
	hud.get_node("Layout").add_child(sway_tuning)
	sway_tuning.visibility_changed.connect(_refresh_hud)
	camera_tuning = CameraTuning.new()
	camera_tuning.camera = camera
	hud.get_node("Layout").add_child(camera_tuning)
	camera_tuning.visibility_changed.connect(_refresh_hud)
	camera_tuning.depth_of_field_changed.connect(func(enabled: bool, strength: float) -> void:
		settings_values.dof_enabled = enabled
		focus_detail.set_depth_of_field(enabled, strength))
	camera_tuning.fog_strength_changed.connect(func(strength: float) -> void:
		focus_detail.set_fog_strength(strength))
