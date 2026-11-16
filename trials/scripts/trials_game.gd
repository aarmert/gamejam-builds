extends Node2D
# Trials modu çalışma zamanı: bölümü yükler, odaları kurar, kamera/oda geçişi, anında yeniden deneme,
# toplanabilirler, kovalamaca (Manager_Darkness), karanlık odalar, HUD ve kayıt.
# Trials runtime. One scene per chapter slot (trials/scenes/trials_chapterN.tscn) sets chapter_path.

signal room_changed(index: int)
signal player_died(at: Vector2)
signal chapter_completed(stats: Dictionary)

const Parser := preload("res://trials/scripts/chapter_parser.gd")
const Builder := preload("res://trials/scripts/chapter_builder.gd")
const Themes := preload("res://trials/scripts/trials_themes.gd")
const Save := preload("res://trials/scripts/trials_save.gd")
const Hud := preload("res://trials/scripts/trials_hud.gd")
const Rules := preload("res://scripts/player/player_movement_rules.gd")
const PLAYER := preload("res://scenes/asil_karakter.tscn")
const MANAGER := preload("res://scripts/darkness/Manager_Darkness.gd")
const DARK_BLOCK := preload("res://scenes/levels/level1_Scene/darkness_block_1_1.tscn")
const CHASE_MUSIC := preload("res://audio/jam/music/canavar_escape.wav")
const MENU_SCENE := "res://scenes/main_menu.tscn"

const ZOOM := 2.0
const DEATH_TIME := 0.32          # ölüm efekti -> yeniden doğuş (s)
const TRANSITION_TIME := 0.32     # oda geçişi kamera kayması (s)
const UP_ENTRY_BOOST := -330.0    # alttan yukarı odaya girerken en az bu dikey hız
const PIT_MARGIN := 24.0          # oda altından bu kadar düşünce ölüm

@export_file("*.gd", "*.txt") var chapter_path := "res://trials/chapters/chapter1.gd"
@export var chapter_id := "chapter1"

## Araçlar (validate/render/replay) farklı bir dosya yükletmek için kullanır.
static var override_path := ""
## Araçlar: HUD, arka plan ve ses çağrılarını kapat.
static var tool_mode := false
## Araçlar: en iyi sonuçları user://'a kaydetme.
static var no_save := false

var chapter: Dictionary = {}
var rooms: Array = []           # build_room info'ları
var player: CharacterBody2D
var camera: Camera2D
var hud: CanvasLayer
var current := -1
var respawn_pos := Vector2.ZERO
var deaths := 0
var time := 0.0
var banked := {}                # collectible id -> true
var pending: Array = []         # izleyen (henüz bankaya yatmamış) toplanabilirler
var complete := false
var transitioning := false
var load_errors: PackedStringArray = PackedStringArray()

var _dead := false
var _death_left := 0.0
var _cam_pos := Vector2.ZERO
var _world_mod: CanvasModulate
var _bg_layer: CanvasLayer
var _bg_mod: CanvasModulate
var _bg_rects: Array = []
var _chase_holder: Node2D = null
var _chase_origin_override = null
var _theme: Dictionary = {}
var _frames := 0
var _music_key := ""
var _chase_music_on := false
var _orb_timers := {}           # orb -> kalan süre


func _ready() -> void:
	process_physics_priority = 10
	CheckpointData.clear()
	var path := override_path if not override_path.is_empty() else chapter_path
	chapter = Parser.parse_file(path)
	for e in chapter.errors:
		push_error("[Trials] " + e)
		load_errors.append(e)
	for w in chapter.warnings:
		print("[Trials] warning: " + w)
	_theme = Themes.theme(chapter.theme)
	_music_key = chapter.music if not chapter.music.is_empty() else _theme.music
	if _music_key == "none":
		_music_key = ""

	_world_mod = CanvasModulate.new()
	_world_mod.name = "WorldModulate"
	_world_mod.color = _theme.world
	add_child(_world_mod)
	if not tool_mode:
		_build_background()

	var world := Node2D.new()
	world.name = "Rooms"
	add_child(world)
	if load_errors.is_empty() or not chapter.rooms.is_empty():
		for r in chapter.rooms:
			var info := Builder.build_room(chapter, r)
			rooms.append(info)
			world.add_child(info.node)
			if info.exit != null:
				info.exit.body_entered.connect(_on_exit_entered)
			info.dynamic.process_mode = Node.PROCESS_MODE_DISABLED

	_spawn_player()
	camera = Camera2D.new()
	camera.name = "Camera"
	camera.zoom = Vector2(ZOOM, ZOOM)
	camera.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(camera)
	camera.make_current()

	if not tool_mode:
		hud = Hud.new()
		hud.game = self
		add_child(hud)
		if not load_errors.is_empty():
			hud.show_errors(load_errors)

	if rooms.is_empty() or rooms[0].spawns.is_empty():
		return
	_enter_room(0, rooms[0].spawns[0], false)
	_snap_camera()


func _spawn_player() -> void:
	var has_dark := false
	for r in chapter.rooms:
		if r.dark:
			has_dark = true
	player = PLAYER.instantiate()
	player.name = "Player"
	player.set("movement_rules", Rules.new())
	player.set("starts_with_dash_skill", true)
	player.set("starts_with_flashlight_skill", has_dark)
	player.set("use_darkness_mechanics", has_dark)
	player.set("darkness_damage_enabled", false)
	player.z_index = 1
	add_child(player)
	if has_dark:
		var fc = player.get("flashlight_component")
		if fc != null:
			fc.drain_rate = 0.0
			# Pil bitmediği için fener pil göstergesi gereksiz: gizle
			if fc.battery_changed.is_connected(player._on_flashlight_battery_changed):
				fc.battery_changed.disconnect(player._on_flashlight_battery_changed)
		var fb = player.get("flashlight_bar_ui")
		if fb != null:
			fb.hide()
		_set_ambient(false)
	player.trials_died.connect(_on_player_died)
	player.trials_orb_used.connect(_on_orb_used)
	if not rooms.is_empty() and not rooms[0].spawns.is_empty():
		player.global_position = rooms[0].spawns[0]


# ------------------------------------------------------------------------------- loop

func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 3 and not tool_mode:
		_apply_room_audio()
	if not tool_mode:
		_update_background()


func _physics_process(delta: float) -> void:
	if rooms.is_empty() or current < 0:
		return
	if not complete:
		time += delta
	_tick_orbs(delta)
	_poll_checkpoint()
	if _dead:
		_death_left -= delta
		if _death_left <= 0.0:
			_respawn()
		_follow_camera(delta)
		return
	if complete:
		return
	var r: Dictionary = rooms[current]
	var center := player.global_position + Vector2(0, -32) # gövde merkezi (kök ayakların 17.5 px altında)
	if not r.rect.has_point(center):
		var ni := room_at(center)
		if ni != -1 and ni != current:
			_begin_transition(ni)
			return
		if player.global_position.y > r.rect.end.y + PIT_MARGIN:
			player.die()
			return
	_follow_camera(delta)


func room_at(p: Vector2) -> int:
	for i in rooms.size():
		if rooms[i].rect.has_point(p):
			return i
	return -1


# ------------------------------------------------------------------------------- rooms

func _enter_room(i: int, spawn: Vector2, reset_player: bool) -> void:
	var old := current
	if old != -1 and old != i:
		rooms[old].dynamic.process_mode = Node.PROCESS_MODE_DISABLED
	current = i
	respawn_pos = spawn
	_chase_origin_override = null
	_reset_room(i)
	rooms[i].dynamic.process_mode = Node.PROCESS_MODE_INHERIT
	if reset_player:
		player.trials_respawn(respawn_pos)
	_apply_room_flags()
	room_changed.emit(i)


func _reset_room(i: int) -> void:
	var info: Dictionary = rooms[i]
	pending.clear()
	var made: Array = Builder.build_dynamic(info, banked)
	for c in made:
		c.picked.connect(_on_collectible_picked)
	for orb in info.orbs:
		_set_orb_active(orb, true)
	_stop_chase()
	if not info.chase.is_empty() and info.chase.has("origin"):
		_start_chase(info)


func _apply_room_flags() -> void:
	var r: Dictionary = rooms[current].room
	var dark: bool = r.dark
	var target: Color = _theme.dark if dark else _theme.world
	if _world_mod.color != target:
		var tw := create_tween()
		tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
		tw.tween_property(_world_mod, "color", target, 0.25)
	if _bg_mod != null:
		_bg_mod.color = _theme.bg_mod * (Color(0.35, 0.35, 0.4) if dark else Color.WHITE)
	_set_ambient(dark)
	var fc = player.get("flashlight_component")
	if fc != null and player.get("has_flashlight_skill"):
		if dark and not fc.is_on:
			fc.battery = fc.max_battery
			fc._turn_on()
		elif not dark and fc.is_on:
			fc._turn_off()
	player.set("trials_drain_enabled", r.drain)
	var hb = player.get("health_bar")
	if hb != null:
		hb.visible = r.drain
	if not tool_mode and _frames >= 3:
		_apply_room_audio()


func _set_ambient(on: bool) -> void:
	var amb = player.get("_ambient_light")
	if amb != null and is_instance_valid(amb):
		amb.enabled = on


func _apply_room_audio() -> void:
	var am := get_node_or_null("/root/AudioManager")
	if am == null:
		return
	var chase: bool = not rooms.is_empty() and current >= 0 and not rooms[current].chase.is_empty()
	am.play_music("" if chase else _music_key)
	am.play_ambient(_theme.ambient, _theme.ambient_db)


func _begin_transition(ni: int) -> void:
	transitioning = true
	_bank_pending()
	_stop_chase()
	var from_cam := _cam_pos
	var entry := player.global_position
	var old_rect: Rect2 = rooms[current].rect
	# alttan yukarı girerken küçük bir itme: üst odadaki çıkıntıya ulaşılabilsin
	if rooms[ni].rect.end.y <= old_rect.position.y + 1.0 and player.velocity.y < 0.0:
		player.velocity.y = minf(player.velocity.y, UP_ENTRY_BOOST)
	player.trials_refill_dash()
	var spawn := _nearest_spawn(ni, entry)
	_enter_room(ni, spawn, false)
	var to_cam := _clamped_target(ni)
	_sfx("whoosh")
	if tool_mode and DisplayServer.get_name() == "headless":
		pass
	get_tree().paused = true
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_method(func(v: Vector2) -> void:
		_cam_pos = v
		camera.global_position = v, from_cam, to_cam, TRANSITION_TIME)
	tw.tween_callback(func() -> void:
		get_tree().paused = false
		transitioning = false)


func _nearest_spawn(i: int, p: Vector2) -> Vector2:
	var best: Vector2 = rooms[i].spawns[0]
	for s in rooms[i].spawns:
		if s.distance_to(p) < best.distance_to(p):
			best = s
	return best


# ------------------------------------------------------------------------------- death / retry

func _on_player_died(at: Vector2) -> void:
	if _dead or complete:
		return
	_dead = true
	_death_left = DEATH_TIME
	deaths += 1
	_death_fx(at)
	player_died.emit(at)


func _respawn() -> void:
	_dead = false
	_reset_room(current)
	player.trials_respawn(respawn_pos)
	_apply_room_flags()
	var spr := player.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if spr != null and not tool_mode:
		spr.scale = Vector2(0.4, 1.6)
		var tw := spr.create_tween()
		tw.tween_property(spr, "scale", Vector2.ONE, 0.12)


## Odayı baştan dene (duraklat menüsü). Ölüm sayılır.
func retry_room(count_death := true) -> void:
	if rooms.is_empty() or complete:
		return
	if count_death:
		deaths += 1
	_dead = false
	_reset_room(current)
	player.trials_respawn(respawn_pos)
	_apply_room_flags()
	_snap_camera()


## Araçlar: doğrudan bir odaya git (ölüm sayılmaz). spawn_index -1 = giriş doğuşu.
func debug_goto_room(i: int, spawn: Vector2 = Vector2.INF) -> void:
	if spawn == Vector2.INF:
		spawn = default_entry_spawn(i)
	_dead = false
	transitioning = false
	get_tree().paused = false
	_bank_pending()
	_enter_room(i, spawn, true)
	_snap_camera()


## Oda i'nin varsayılan giriş doğuşu: önceki odaya (dosya sırası) açılan kenara en yakın P.
func default_entry_spawn(i: int) -> Vector2:
	if i == 0 or rooms[i].spawns.size() == 1:
		return rooms[i].spawns[0]
	var r: Dictionary = rooms[i].room
	for l in r.links:
		if l.to == i - 1 and not l.cells.is_empty():
			var c: Vector2i = l.cells[l.cells.size() / 2]
			return _nearest_spawn(i, Builder.cell_center(r, c.x, c.y))
	return rooms[i].spawns[0]


func _death_fx(at: Vector2) -> void:
	var spr := player.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if spr != null:
		var tw := spr.create_tween()
		tw.tween_property(spr, "modulate", Color(3, 3, 3, 1), 0.06)
		tw.tween_property(spr, "modulate", Color(1, 1, 1, 0), 0.14)
	if tool_mode:
		return
	var p := CPUParticles2D.new()
	p.position = at + Vector2(0, -32)
	p.one_shot = true
	p.amount = 18
	p.lifetime = 0.35
	p.explosiveness = 1.0
	p.spread = 180.0
	p.gravity = Vector2.ZERO
	p.initial_velocity_min = 60.0
	p.initial_velocity_max = 140.0
	p.scale_amount_min = 2.0
	p.scale_amount_max = 4.0
	p.color = Color(0.85, 0.8, 1.0)
	p.z_index = 5
	add_child(p)
	p.emitting = true
	get_tree().create_timer(0.6).timeout.connect(p.queue_free)


# ------------------------------------------------------------------------------- orbs / collectibles / checkpoints

func _on_orb_used(orb: Area2D) -> void:
	if not is_instance_valid(orb):
		return
	_set_orb_active(orb, false)
	var t: float = rooms[current].room.orb_respawn if current >= 0 else 2.5
	if t > 0.0:
		_orb_timers[orb] = t


func _set_orb_active(orb: Area2D, on: bool) -> void:
	orb.set_meta("trials_active", on)
	var cs := orb.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs != null:
		cs.set_deferred("disabled", not on)
	for n in ["Sprite2D", "Ring"]:
		var spr := orb.get_node_or_null(n) as CanvasItem
		if spr != null:
			spr.self_modulate = Color(1, 1, 1, 1) if on else Color(1, 1, 1, 0.15)
	if on:
		_orb_timers.erase(orb)


func _tick_orbs(delta: float) -> void:
	for orb in _orb_timers.keys():
		_orb_timers[orb] -= delta
		if _orb_timers[orb] <= 0.0:
			_set_orb_active(orb, true)


func _on_collectible_picked(c: Area2D) -> void:
	pending.append(c)
	_sfx("pickup")


func _bank_pending() -> void:
	for c in pending:
		if is_instance_valid(c) and c.state == "following":
			banked[c.cid] = true
			c.bank()
	if not pending.is_empty():
		_sfx("lantern_pickup")
	pending.clear()


func _poll_checkpoint() -> void:
	# heal_zone (lamba) CheckpointData'ya yazar; Trials'ta bu, oda içi doğuş noktasını günceller.
	if CheckpointData.has_spawn:
		if not _dead:
			respawn_pos = CheckpointData.spawn_position
			if CheckpointData.has_darkness_origin and current >= 0:
				var rr: Rect2 = rooms[current].rect.grow(-16.0)
				var o := CheckpointData.darkness_origin_pos
				_chase_origin_override = Vector2(clampf(o.x, rr.position.x, rr.end.x), clampf(o.y, rr.position.y, rr.end.y))
		CheckpointData.clear()


# ------------------------------------------------------------------------------- chase

func _start_chase(info: Dictionary) -> void:
	CheckpointData.clear()
	var ch: Dictionary = info.chase
	_chase_holder = Node2D.new()
	_chase_holder.name = "Chase"
	var goal := Marker2D.new()
	goal.name = "ChaseGoal"
	goal.position = ch.get("goal", ch.origin)
	_chase_holder.add_child(goal)
	var m := Node2D.new()
	m.name = "Manager_Darkness"
	m.set_script(MANAGER)
	var mus := AudioStreamPlayer2D.new()
	mus.name = "Muzik"
	mus.stream = CHASE_MUSIC
	mus.max_distance = 100000.0
	mus.attenuation = 0.0
	mus.bus = &"Music"
	mus.volume_db = 3.0
	if tool_mode:
		mus.volume_db = -80.0
	m.add_child(mus)
	m.set("block_scene", DARK_BLOCK)
	m.set("player", player)
	m.set("tile_map", info.tilemap)
	m.set("progress_target", goal)
	m.set("speed", ch.speed)
	m.set("start_delay", ch.delay)
	m.position = _chase_origin_override if _chase_origin_override != null else ch.origin
	_chase_holder.add_child(m)
	info.node.add_child(_chase_holder)
	if not tool_mode and _frames >= 3:
		_apply_room_audio()


func _stop_chase() -> void:
	if _chase_holder != null and is_instance_valid(_chase_holder):
		_chase_holder.get_parent().remove_child(_chase_holder)
		_chase_holder.queue_free()
	_chase_holder = null


func chase_manager() -> Node:
	if _chase_holder == null or not is_instance_valid(_chase_holder):
		return null
	return _chase_holder.get_node_or_null("Manager_Darkness")


# ------------------------------------------------------------------------------- exit / save

func _on_exit_entered(body: Node) -> void:
	if complete or _dead or body != player:
		return
	complete = true
	_bank_pending()
	_stop_chase()
	player.velocity = Vector2.ZERO
	player.set_physics_process(false)
	var tw := player.create_tween()
	tw.tween_property(player, "modulate:a", 0.0, 0.5)
	_sfx("checkpoint")
	var stats := {
		"chapter_id": chapter_id,
		"title": chapter.title,
		"time": time,
		"deaths": deaths,
		"collectibles": banked.size(),
		"collectibles_total": chapter.collectible_total,
	}
	var best := {}
	if not tool_mode and not no_save:
		best = Save.record(chapter_id, stats)
	stats["best"] = best
	chapter_completed.emit(stats)
	if hud != null:
		hud.show_complete(stats)


func back_to_menu() -> void:
	get_tree().paused = false
	var st := get_node_or_null("/root/SceneTransition")
	if st != null and st.has_method("transition_to"):
		st.transition_to(MENU_SCENE)
	else:
		get_tree().change_scene_to_file(MENU_SCENE)


# ------------------------------------------------------------------------------- camera / background

func view_size() -> Vector2:
	return get_viewport().get_visible_rect().size / ZOOM


func _clamped_target(i: int) -> Vector2:
	return clamp_to_room(i, player.global_position + Vector2(0, -40))


func clamp_to_room(i: int, p: Vector2) -> Vector2:
	var r: Rect2 = rooms[i].rect
	var half := view_size() * 0.5
	var out := p
	if r.size.x <= half.x * 2.0:
		out.x = r.get_center().x
	else:
		out.x = clampf(p.x, r.position.x + half.x, r.end.x - half.x)
	if r.size.y <= half.y * 2.0:
		out.y = r.get_center().y
	else:
		out.y = clampf(p.y, r.position.y + half.y, r.end.y - half.y)
	return out


func _snap_camera() -> void:
	if current < 0:
		return
	_cam_pos = _clamped_target(current)
	camera.global_position = _cam_pos
	camera.reset_smoothing()


func _follow_camera(delta: float) -> void:
	if transitioning or current < 0:
		return
	var target := _clamped_target(current)
	_cam_pos = _cam_pos.lerp(target, 1.0 - exp(-14.0 * delta))
	_cam_pos = clamp_to_room(current, _cam_pos)
	camera.global_position = _cam_pos


func _build_background() -> void:
	_bg_layer = CanvasLayer.new()
	_bg_layer.name = "Background"
	_bg_layer.layer = -10
	add_child(_bg_layer)
	_bg_mod = CanvasModulate.new()
	_bg_mod.color = _theme.bg_mod
	_bg_layer.add_child(_bg_mod)
	var vp := get_viewport().get_visible_rect().size
	var clear := ColorRect.new()
	clear.color = _theme.clear
	clear.size = vp
	clear.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg_layer.add_child(clear)
	var i := 0
	for path in _theme.bg:
		var tex: Texture2D = load(path)
		var s := vp.y / float(tex.get_height())
		var tr := TextureRect.new()
		tr.texture = tex
		tr.stretch_mode = TextureRect.STRETCH_TILE
		tr.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		tr.size = Vector2(ceil(vp.x / s) + tex.get_width() * 2, tex.get_height())
		tr.scale = Vector2(s, s)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_bg_layer.add_child(tr)
		_bg_rects.append([tr, float(_theme.parallax[i]), float(tex.get_width()) * s])
		i += 1


func _update_background() -> void:
	for e in _bg_rects:
		var tr: TextureRect = e[0]
		tr.position.x = -fposmod(_cam_pos.x * e[1], e[2])


func _sfx(n: String) -> void:
	if tool_mode:
		return
	var am := get_node_or_null("/root/AudioManager")
	if am != null:
		am.play_sfx(n, 0.03)


# ------------------------------------------------------------------------------- info for HUD / tools

func room_count() -> int:
	return rooms.size()


func room_label() -> String:
	if current < 0:
		return ""
	var r: Dictionary = rooms[current].room
	return "%d/%d" % [current + 1, rooms.size()]


func is_dead() -> bool:
	return _dead
