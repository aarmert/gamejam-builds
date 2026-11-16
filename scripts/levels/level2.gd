extends Node2D

# Orman bölümü (oyunun ilk gerçek bölümü).
#
# Önizleme kamerasi: bir checkpoint'e (sokak lambasi) ulasinca kamera önümüzdeki bölümü
# gösterir ve oyuncuya geri döner. Her bölümün önizlemesi PreviewPaths/Section<i> altindaki
# Marker2D'leri sirayla gezer (her noktanin "hold" metadata'si o noktada bekleme süresi),
# en sonda bir sonraki checkpoint'te (son bölümde portalda) durur.
# Bölümlerde önizlemede görülen bir karar var (hangi delikten inilecegi vb.); bu yüzden
# önizleme, oyuncu lambanin isiginda dururken W / yukari ok ile tekrar oynatilabilir.
#  - Önizleme boyunca oyun durdurulur (get_tree().paused). Ziplama tusu önizlemeyi atlar.
#  - Önizleme kamerasi oyuncu kamerasinin zoom ve limit degerlerini kullanir.
#  - Ölüp checkpoint'ten dogunca ayni önizleme kendiliginden tekrar gösterilmez.

@onready var canvas_modulate: CanvasModulate = $CanvasModulate
@onready var background_modulate: CanvasModulate = get_node_or_null("ParallaxBackground/BackgroundModulate")
@onready var flashlight: PointLight2D = $MayaChar2/FlashlightPivot/PointLight2D

## checkpoints[i] ulasilinca Section<i> önizlemesi oynar ve checkpoints[i + 1]'de biter.
@export var checkpoints: Array[Area2D] = []
@export var player: CharacterBody2D
@export var preview_camera: Camera2D
@export var player_camera: Camera2D
## Section0, Section1, ... adli çocuklari olan dügüm; her birinin altinda Marker2D yol noktalari.
@export var preview_paths: Node2D
@export var preview_enabled: bool = true
## Kameranin kayma hizi (piksel/sn)
@export var preview_pan_speed: float = 460.0
@export var preview_min_leg_time: float = 0.35
@export var preview_max_leg_time: float = 2.4
## Son hedefin (sonraki checkpoint) üzerinde bekleme süresi (sn)
@export var preview_hold_time: float = 1.0
@export var preview_return_time: float = 0.9
## Atlaninca oyuncuya geri dönüs süresi (sn)
@export var preview_skip_return_time: float = 0.35
## Ilk bölüm: karanlik daha yavas can eritir (5 can / bu kadar saniye)
@export var darkness_tick_seconds: float = 2.0

# Ölüp checkpoint'ten yeniden dogunca ayni önizlemeleri tekrar gösterme
static var _shown_previews: Dictionary = {}

var visited: Array[bool] = []
var is_previewing: bool = false

var _tween: Tween
var _ticker: _PreviewTicker
var _skipping: bool = false
var _pending: Array[int] = []
var _hint_layer: CanvasLayer
var _hint_label: Label


# Oyun durdurulmusken (paused) de çalisan küçük yardimci: atlama tusunu dinler.
class _PreviewTicker extends Node:
	var on_tick: Callable

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_delta: float) -> void:
		if on_tick.is_valid():
			on_tick.call()


func _ready() -> void:
	canvas_modulate.color = Color(0.34, 0.32, 0.42)
	if background_modulate:
		background_modulate.color = Color(0.55, 0.52, 0.64)
	flashlight.enabled = true

	var dark_timer := player.get_node_or_null("DarknessDamageTimer") as Timer
	if dark_timer:
		dark_timer.wait_time = darkness_tick_seconds

	visited.resize(checkpoints.size())
	visited.fill(false)

	if not CheckpointData.has_spawn:
		_shown_previews.clear()

	_ticker = _PreviewTicker.new()
	_ticker.on_tick = _preview_tick
	add_child(_ticker)
	_build_hint()

	if preview_camera:
		# Durdurulmus oyunda da kamera güncellensin
		preview_camera.process_mode = Node.PROCESS_MODE_ALWAYS
		preview_camera.position_smoothing_enabled = false
	_sync_preview_camera()

	if player_camera:
		player_camera.reset_smoothing()
	# Ilk önizleme, oyuncu baslangiçtaki lambaya (checkpoint 0) degince oynar.


func _build_hint() -> void:
	_hint_layer = CanvasLayer.new()
	_hint_layer.layer = 5
	_hint_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_hint_layer)
	_hint_label = Label.new()
	var ls := LabelSettings.new()
	ls.font = load("res://assets/blockholders/fonts/PixelOperator8.ttf")
	ls.font_size = 16
	ls.font_color = Color(0.9, 0.88, 1.0, 0.9)
	ls.outline_size = 4
	ls.outline_color = Color(0.08, 0.06, 0.14, 0.9)
	_hint_label.label_settings = ls
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_hint_label.offset_left = -300
	_hint_label.offset_right = 300
	_hint_label.offset_top = -44
	_hint_label.offset_bottom = -20
	_hint_label.visible = false
	_hint_layer.add_child(_hint_label)


func _sync_preview_camera() -> void:
	if not (preview_camera and player_camera):
		return
	preview_camera.zoom = player_camera.zoom
	preview_camera.limit_left = player_camera.limit_left
	preview_camera.limit_right = player_camera.limit_right
	preview_camera.limit_top = player_camera.limit_top
	preview_camera.limit_bottom = player_camera.limit_bottom


func _view_half_size() -> Vector2:
	return get_viewport().get_visible_rect().size / player_camera.zoom / 2.0


# Kamera merkezini limitlerin izin verdigi alana kirp (yoksa kamera "bos" yere
# kayar gibi yapip bir süre yerinde durur).
func _clamp_center(p: Vector2) -> Vector2:
	var h := _view_half_size()
	var lo := Vector2(player_camera.limit_left, player_camera.limit_top) + h
	var hi := Vector2(player_camera.limit_right, player_camera.limit_bottom) - h
	return Vector2(
		clampf(p.x, lo.x, maxf(lo.x, hi.x)),
		clampf(p.y, lo.y, maxf(lo.y, hi.y)))


func _wait_for_scene_transition() -> void:
	var st := get_node_or_null("/root/SceneTransition")
	while st != null and st.has_method("is_transitioning") and st.is_transitioning():
		await get_tree().process_frame


# Section<index> yol noktalari + son hedef: [konum, bekleme]
func _section_points(index: int) -> Array:
	var pts: Array = []
	var sec: Node = preview_paths.get_node_or_null("Section%d" % index) if preview_paths else null
	if sec:
		for m in sec.get_children():
			if m is Node2D:
				pts.append([(m as Node2D).global_position, float(m.get_meta("hold", 0.0))])
	pts.append([checkpoints[index + 1].global_position, preview_hold_time])
	return pts


func has_preview(index: int) -> bool:
	return index >= 0 and index + 1 < checkpoints.size() and checkpoints[index + 1] != null


## index: ulasilan checkpoint. force: daha önce gösterildiyse de göster (tekrar izleme).
func play_preview(index: int, force: bool = false) -> void:
	if not preview_enabled or not has_preview(index):
		return
	if not force and _shown_previews.has(index):
		return
	if is_previewing:
		if not _pending.has(index):
			_pending.append(index)
		return
	is_previewing = true
	_shown_previews[index] = true
	# Fade/hikaye ekrani bitmeden önizleme baslamasin
	await _wait_for_scene_transition()
	await get_tree().process_frame
	if not is_inside_tree() or not is_instance_valid(player) or player.get("_dying"):
		is_previewing = false
		return

	_sync_preview_camera()
	var start := player_camera.get_screen_center_position()
	get_tree().paused = true
	preview_camera.global_position = start
	preview_camera.make_current()
	_skipping = false
	_show_hint("Space: atla")

	_tween = create_tween()
	_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_interval(0.25)
	var cur := start
	for p in _section_points(index):
		var target := _clamp_center(p[0])
		var t := clampf(cur.distance_to(target) / preview_pan_speed, preview_min_leg_time, preview_max_leg_time)
		_tween.tween_property(preview_camera, "global_position", target, t)
		if p[1] > 0.0:
			_tween.tween_interval(p[1])
		cur = target
	_tween.tween_property(preview_camera, "global_position", start, preview_return_time)
	_tween.tween_callback(_finish_preview)


func _preview_tick() -> void:
	if is_previewing:
		if not _skipping and _tween != null and Input.is_action_just_pressed("jump"):
			_skip_preview()
		return
	# Lambanin isiginda: W / yukari ok ile önizlemeyi tekrar izle
	var at := _lamp_player_is_in()
	if at >= 0 and has_preview(at) and _shown_previews.has(at) and not get_tree().paused:
		_show_hint("W / ↑ : yolu tekrar göster")
		if Input.is_action_just_pressed("move_up"):
			play_preview(at, true)
	else:
		_hide_hint()


func _lamp_player_is_in() -> int:
	if not is_instance_valid(player) or player.get("_dying"):
		return -1
	for i in checkpoints.size():
		var cp := checkpoints[i]
		if cp != null and cp.get("player_in_area") == player:
			return i
	return -1


func _show_hint(text: String) -> void:
	if _hint_label:
		_hint_label.text = text
		_hint_label.visible = true


func _hide_hint() -> void:
	if _hint_label:
		_hint_label.visible = false


func _skip_preview() -> void:
	_skipping = true
	if _tween:
		_tween.kill()
	var back := player_camera.get_screen_center_position()
	_tween = create_tween()
	_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(preview_camera, "global_position", back, preview_skip_return_time)
	_tween.tween_callback(_finish_preview)


func _finish_preview() -> void:
	_tween = null
	_skipping = false
	_hide_hint()
	player_camera.make_current()
	player_camera.reset_smoothing()
	get_tree().paused = false
	is_previewing = false
	if not _pending.is_empty():
		play_preview(_pending.pop_front())


func _exit_tree() -> void:
	# Önizleme sirasinda sahne degisirse oyun durdurulmus kalmasin
	if is_previewing and get_tree():
		get_tree().paused = false


func checkpoint_reached(index: int) -> void:
	if index < 0 or index >= visited.size() or visited[index]:
		return
	visited[index] = true
	play_preview(index)
