extends Node

# Sahneler arasi fade-to-black geçislerini ve hikaye yazilarini yöneten singleton.
# Project Settings → AutoLoad'a "SceneTransition" adiyla eklenmis olmali.
#
# Kullanim:
#   SceneTransition.transition_to("res://scenes/levels/level2.tscn")
#   SceneTransition.transition_to("res://scenes/levels/level2.tscn", ["Maya karanliga adim atti...", "Geri dönüs yoktu."])

@export var fade_duration: float = 0.6
@export var story_line_duration: float = 7.0  # Her hikaye satiri en az kaç saniye ekranda kalsin
@export var story_fade_in: float = 0.7
@export var story_fade_out: float = 0.5
# Uzun metinler daha uzun kalsin: saniyede okunan karakter sayisi (süre = max(story_line_duration, 2 + uzunluk / bu))
@export var story_reading_speed: float = 18.0
# Bir satir göründükten sonra atlama tusunun dikkate alinmadigi süre (yanlislikla çift atlamayi önler)
@export var skip_grace_time: float = 0.35

const STORY_FONT: FontFile = preload("res://assets/blockholders/fonts/PixelOperator8.ttf")
const STORY_FONT_SIZE := 24
const HINT_FONT_SIZE := 16

# Bu cutscene PNG'leri sadece el yazisi tarzi fontla çizilmis yazi içeriyor ve oyuncular okuyamiyor.
# Bu görseller istendiginde resim yerine ayni metni okunakli fontla gösteriyoruz.
# (Görsele yeni yazi eklenirse buraya da eklenmeli; ya da metni dogrudan story_lines olarak verin.)
const TEXT_ONLY_IMAGES := {
	"res://assets/cutscene1.png": [
		"A part of me is... gone?",
		"I need to find it. Light cannot exist without darkness. And darkness cannot exist without light.",
		"I don't have much time. I must push through the pain and carry on.",
	],
	"res://assets/cutscene2.png": [
		"Where are you? Do you not want to be complete?",
		"...",
		"What's that noise..? Is that..? No! Wait!",
	],
	"res://assets/Ending.png": [
		"Why? Why does it not want to be whole?",
		"Will I just... disappear? Is this the end?",
		"Darkness cannot exist without light. Light cannot exist without darkness.",
		"Goodbye...",
	],
}

signal transition_started
signal transition_finished

var _is_transitioning: bool = false
var _canvas_layer: CanvasLayer
var _fade_rect: ColorRect
var _story_image: TextureRect
var _story_label: Label
var _skip_hint: Label
var _accept_skip: bool = false
var _skip_requested: bool = false


func _ready() -> void:
	# Pause olsa bile çalissin, oyun durdurulmus olsa da fade devam eder
	process_mode = Node.PROCESS_MODE_ALWAYS

	_canvas_layer = CanvasLayer.new()
	_canvas_layer.layer = 100  # Her seyin üstünde
	add_child(_canvas_layer)

	_fade_rect = ColorRect.new()
	_fade_rect.color = Color(0, 0, 0, 0)
	_fade_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas_layer.add_child(_fade_rect)

	_story_image = TextureRect.new()
	_story_image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_story_image.offset_left = 80
	_story_image.offset_right = -80
	_story_image.offset_top = 105
	_story_image.offset_bottom = -105
	_story_image.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_story_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_story_image.modulate = Color(1, 1, 1, 0)
	_story_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas_layer.add_child(_story_image)

	# Taban çözünürlük 1152x648 (project.godot); kenarlarda rahat bosluk birak
	_story_label = Label.new()
	_story_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_story_label.offset_left = 160
	_story_label.offset_right = -160
	_story_label.offset_top = 72
	_story_label.offset_bottom = -96
	_story_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_story_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_story_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_story_label.clip_text = false
	_story_label.add_theme_font_override("font", STORY_FONT)
	_story_label.add_theme_font_size_override("font_size", STORY_FONT_SIZE)
	_story_label.add_theme_constant_override("line_spacing", 12)
	_story_label.add_theme_color_override("font_color", Color(0.96, 0.94, 1.0, 1))
	_story_label.add_theme_color_override("font_shadow_color", Color(0.25, 0.18, 0.45, 0.8))
	_story_label.add_theme_constant_override("shadow_offset_x", 2)
	_story_label.add_theme_constant_override("shadow_offset_y", 2)
	_story_label.modulate = Color(1, 1, 1, 0)
	_story_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas_layer.add_child(_story_label)

	_skip_hint = Label.new()
	_skip_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_skip_hint.offset_left = -480
	_skip_hint.offset_top = -56
	_skip_hint.offset_right = -32
	_skip_hint.offset_bottom = -28
	_skip_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_skip_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_skip_hint.text = "Press any key to continue"
	_skip_hint.add_theme_font_override("font", STORY_FONT)
	_skip_hint.add_theme_font_size_override("font_size", HINT_FONT_SIZE)
	_skip_hint.add_theme_color_override("font_color", Color(0.7, 0.64, 0.86, 1))
	_skip_hint.modulate = Color(1, 1, 1, 0)
	_skip_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas_layer.add_child(_skip_hint)


# Hikaye ekraninda herhangi bir tus / fare tiklamasi / gamepad tusu bir sonraki satira geçer.
func _input(event: InputEvent) -> void:
	if not _accept_skip:
		return
	var is_skip := false
	if event is InputEventKey:
		var key := event as InputEventKey
		# F11 / Alt+Enter tam ekran içindir, atlama sayilmaz
		var is_fullscreen_key := key.keycode == KEY_F11 or key.alt_pressed or key.keycode == KEY_ALT
		is_skip = key.pressed and not key.echo and not is_fullscreen_key
	elif event is InputEventMouseButton:
		is_skip = (event as InputEventMouseButton).pressed
	elif event is InputEventJoypadButton:
		is_skip = (event as InputEventJoypadButton).pressed
	elif event.is_action_pressed("jump"):
		is_skip = true
	if is_skip:
		_skip_requested = true
		get_viewport().set_input_as_handled()


# Ana giris noktasi. story_lines bos olabilir.
func transition_to(
	scene_path: String,
	story_lines: PackedStringArray = PackedStringArray(),
	story_image_paths: PackedStringArray = PackedStringArray()
) -> void:
	if _is_transitioning:
		return
	if scene_path.is_empty():
		push_warning("[SceneTransition] Bos scene_path verildi")
		return
	_is_transitioning = true
	transition_started.emit()
	_run_transition(scene_path, story_lines, story_image_paths)


func is_transitioning() -> bool:
	return _is_transitioning


func _run_transition(
	scene_path: String,
	story_lines: PackedStringArray,
	story_image_paths: PackedStringArray
) -> void:
	# 1) Siyaha fade
	await _fade_to(1.0, fade_duration)

	# 2) Hikaye yazilari (varsa)
	if story_lines.size() > 0 or story_image_paths.size() > 0:
		await _show_story_lines(story_lines, story_image_paths)

	# 3) Sahneyi degistir
	# Slow-motion'i sifirla (ölüm sirasinda kalmis olabilir)
	Engine.time_scale = 1.0
	# Checkpoint'ler bölüme özel: yeni bölüme geçerken sıfırla, yoksa oyuncu
	# yeni bölümde bir önceki bölümün checkpoint koordinatında doğar
	CheckpointData.clear()
	var err := get_tree().change_scene_to_file(scene_path)
	if err != OK:
		push_error("[SceneTransition] Sahne yüklenemedi: %s (hata: %d)" % [scene_path, err])

	# Yeni sahnenin _ready'si bitsin diye bir frame bekle
	await get_tree().process_frame

	# 4) Geri fade
	await _fade_to(0.0, fade_duration)
	_is_transitioning = false
	transition_finished.emit()


func _fade_to(target_alpha: float, duration: float) -> void:
	var tween := create_tween()
	tween.set_ignore_time_scale(true)
	tween.tween_property(_fade_rect, "color:a", target_alpha, duration)
	await tween.finished


# Hikaye ekranlari: her adimda bir yazi ve/veya görsel. Tusa basinca sonraki adima geçer.
func _show_story_lines(lines: PackedStringArray, image_paths: PackedStringArray) -> void:
	var step_count: int = max(lines.size(), image_paths.size())
	for i in range(step_count):
		var line := lines[i] if i < lines.size() else ""
		var image_path := image_paths[i] if i < image_paths.size() else ""
		var texture: Texture2D = null
		var image_text := _text_for_image(image_path)
		if not image_text.is_empty():
			# Yazi-görseli: resim yerine okunakli metni göster
			line = image_text if line.is_empty() else line + "\n\n" + image_text
		else:
			texture = _load_story_texture(image_path)
		_story_label.text = line
		_story_image.texture = texture
		var has_line := not line.is_empty()

		# Yaziyi belirginlestir
		var tw_in := create_tween()
		tw_in.set_ignore_time_scale(true)
		tw_in.tween_property(_story_image, "modulate:a", 1.0, story_fade_in)
		tw_in.parallel().tween_property(_skip_hint, "modulate:a", 1.0, story_fade_in)
		if has_line:
			tw_in.parallel().tween_property(_story_label, "modulate:a", 1.0, story_fade_in)

		# Ekranda dur (gerçek zamanla; tusa basilinca erken biter)
		var hold := story_line_duration
		if has_line:
			hold = max(story_line_duration, 2.0 + line.length() / max(story_reading_speed, 1.0))
		await _wait_or_skip(story_fade_in + hold)
		if tw_in.is_running():
			tw_in.custom_step(story_fade_in)

		# Solduruyor
		var tw_out := create_tween()
		tw_out.set_ignore_time_scale(true)
		tw_out.tween_property(_story_image, "modulate:a", 0.0, story_fade_out)
		if has_line:
			tw_out.parallel().tween_property(_story_label, "modulate:a", 0.0, story_fade_out)
		if i == step_count - 1:
			tw_out.parallel().tween_property(_skip_hint, "modulate:a", 0.0, story_fade_out)
		await tw_out.finished

	_story_label.text = ""
	_story_image.texture = null
	_skip_hint.modulate.a = 0.0


func _wait_or_skip(seconds: float) -> void:
	_skip_requested = false
	_accept_skip = false
	var elapsed := 0.0
	while true:
		if elapsed >= seconds:
			break
		if not _accept_skip and elapsed >= skip_grace_time:
			_accept_skip = true
		if _skip_requested:
			break
		await get_tree().process_frame
		# Engine.time_scale'den bagimsiz (ölümde slow-motion kalmis olabilir)
		elapsed += get_process_delta_time() / max(Engine.time_scale, 0.001)
	_accept_skip = false
	_skip_requested = false


func _text_for_image(path: String) -> String:
	if path.is_empty():
		return ""
	var key := path
	if path.begins_with("uid://"):
		var id := ResourceUID.text_to_id(path)
		if ResourceUID.has_id(id):
			key = ResourceUID.get_id_path(id)
	if TEXT_ONLY_IMAGES.has(key):
		return "\n\n".join(PackedStringArray(TEXT_ONLY_IMAGES[key]))
	return ""


func _load_story_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	var texture := load(path) as Texture2D
	if texture == null:
		push_warning("[SceneTransition] Cutscene görseli yüklenemedi: %s" % path)
	return texture
