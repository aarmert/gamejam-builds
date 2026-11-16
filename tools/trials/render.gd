extends SceneTree
# Trials oda görüntüleyici: her odanın gerçek oyun grafikleriyle PNG'sini (+ ızgara, koordinat,
# doğuş/kovalamaca/platform işaretleri) ve bölüm haritasını çizer. Xvfb altında çalıştırın:
#   ~/tools/gjtools/xrun.sh <display> ~/tools/godot/godot --path . --rendering-driver opengl3 \
#       --audio-driver Dummy --resolution 1280x720 -s tools/trials/render.gd -- <chapter> <out_dir> [--room id] [--no-grid]
# Çıktı: <out_dir>/<chapter>_<NN>_<room>.png (1 karo = 32 px) ve <out_dir>/<chapter>_overview.png

const GameScript := preload("res://trials/scripts/trials_game.gd")
const Builder := preload("res://trials/scripts/chapter_builder.gd")
const GAME_SCENE := "res://trials/scenes/trials_chapter1.tscn"
const FONT := preload("res://assets/blockholders/fonts/PixelOperator8.ttf")
const T := 32
const MARGIN := 1

var chapter_path := ""
var out_dir := ""
var only_room := ""
var grid := true
var game: Node
var f := 0
var jobs: Array = []   # [SubViewport, path]


class Overlay extends Node2D:
	var ch: Dictionary
	var grid := true
	var font: Font

	func _draw() -> void:
		for r in ch.rooms:
			var rect := Rect2(r.x * T, r.y * T, r.w * T, r.h * T)
			if grid:
				for x in range(r.w + 1):
					var X: float = (r.x + x) * T
					var c := Color(1, 1, 1, 0.35 if x % 5 == 0 else 0.12)
					draw_line(Vector2(X, rect.position.y), Vector2(X, rect.end.y), c, 1.0)
				for y in range(r.h + 1):
					var Y: float = (r.y + y) * T
					var c2 := Color(1, 1, 1, 0.35 if y % 5 == 0 else 0.12)
					draw_line(Vector2(rect.position.x, Y), Vector2(rect.end.x, Y), c2, 1.0)
				for x in range(0, r.w, 5):
					_txt(Vector2((r.x + x) * T + 2, rect.position.y - 4), str(x), Color(1, 1, 0.6))
				for y in range(0, r.h, 5):
					_txt(Vector2(rect.position.x - 28, (r.y + y) * T + 20), str(y), Color(1, 1, 0.6))
			draw_rect(rect, Color(1.0, 0.85, 0.3, 0.9), false, 2.0)
			var flags := PackedStringArray()
			if r.dark:
				flags.append("DARK")
			if r.drain:
				flags.append("DRAIN")
			if r.chase > 0.0:
				flags.append("CHASE %s" % str(r.chase))
			_txt(rect.position + Vector2(36, 22), "#%d %s  %dx%d %s" % [r.index + 1, r.id, r.w, r.h, " ".join(flags)], Color(1, 0.9, 0.4), 16)
			for y in r.h:
				for x in r.w:
					var c: String = r.rows[y][x]
					var p := Vector2((r.x + x) * T, (r.y + y) * T)
					match c:
						"P":
							draw_rect(Rect2(p + Vector2(4, 4), Vector2(24, 24)), Color(0.3, 1, 0.4, 0.9), false, 2.0)
							_txt(p + Vector2(11, 22), "P", Color(0.3, 1, 0.4))
						"D":
							draw_rect(Rect2(p, Vector2(32, 32)), Color(0.6, 0.1, 0.8, 0.6))
							_txt(p + Vector2(11, 22), "D", Color(1, 1, 1))
						"x":
							draw_rect(Rect2(p + Vector2(2, 2), Vector2(28, 28)), Color(1, 0.1, 0.1, 0.9), false, 1.0)
						"m":
							draw_circle(p + Vector2(16, 16), 4, Color(0.4, 0.8, 1))
						"M":
							var q: Vector2i = preload("res://trials/scripts/chapter_parser.gd").platform_partner(r, x, y)
							if q != Vector2i(-1, -1):
								draw_line(p + Vector2(16, 6), Vector2((r.x + q.x) * T + 16, (r.y + q.y) * T + 6), Color(0.4, 0.8, 1, 0.9), 2.0)
			# alt kenarda çukur (komşu oda yok): kırmızı kesik çizgi
			for x in r.w:
				if r.rows[r.h - 1][x] != "#":
					var X2: float = (r.x + x) * T
					draw_line(Vector2(X2 + 4, rect.end.y - 1), Vector2(X2 + 28, rect.end.y - 1), Color(1, 0.2, 0.2, 0.9), 3.0)

	func _txt(p: Vector2, s: String, c: Color, size := 12) -> void:
		draw_string_outline(font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, Color(0, 0, 0, 0.9))
		draw_string(font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, c)


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var i := 0
	var pos := []
	while i < a.size():
		match a[i]:
			"--room":
				i += 1; only_room = a[i]
			"--no-grid":
				grid = false
			_:
				pos.append(a[i])
		i += 1
	if pos.size() < 2:
		print("usage: render.gd -- <chapter> <out_dir> [--room id] [--no-grid]")
		quit(2)
		return
	chapter_path = pos[0] if (pos[0].begins_with("res://") or pos[0].begins_with("/")) else "res://" + pos[0]
	out_dir = pos[1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	GameScript.override_path = chapter_path
	GameScript.no_save = true
	GameScript.tool_mode = true
	game = load(GAME_SCENE).instantiate()
	root.add_child(game)
	current_scene = game


func _process(_d: float) -> bool:
	f += 1
	if f == 3:
		_setup()
	elif f == 12:
		for j in jobs:
			var img: Image = j[0].get_texture().get_image()
			img.save_png(j[1])
			print("saved ", j[1], " ", img.get_size())
		quit(0)
	return false


func _setup() -> void:
	if game.rooms.is_empty():
		print("ERROR: chapter did not build")
		for e in game.load_errors:
			print("  " + e)
		quit(1)
		return
	game.player.visible = false
	game.player.process_mode = Node.PROCESS_MODE_DISABLED
	game.process_mode = Node.PROCESS_MODE_DISABLED
	game.get_node("WorldModulate").color = Color.WHITE
	var ch: Dictionary = game.chapter
	for info in game.rooms:
		if info.room.index != game.current:
			Builder.build_dynamic(info, {})
	var bg := Polygon2D.new()
	bg.z_index = -100
	var bb := Rect2()
	for r in ch.rooms:
		var rr := Rect2(r.x * T, r.y * T, r.w * T, r.h * T)
		bb = rr if bb.size == Vector2.ZERO else bb.merge(rr)
	bb = bb.grow(T * 3)
	bg.polygon = PackedVector2Array([bb.position, Vector2(bb.end.x, bb.position.y), bb.end, Vector2(bb.position.x, bb.end.y)])
	bg.color = Color(0.11, 0.1, 0.16)
	game.add_child(bg)
	var ov := Overlay.new()
	ov.ch = ch
	ov.grid = grid
	ov.font = FONT
	ov.z_index = 100
	game.add_child(ov)
	var base := chapter_path.get_file().get_basename()
	for r in ch.rooms:
		if not only_room.is_empty() and r.id != only_room:
			continue
		var rect := Rect2((r.x - MARGIN) * T, (r.y - MARGIN) * T, (r.w + 2 * MARGIN) * T, (r.h + 2 * MARGIN) * T)
		_job(rect, 1.0, "%s/%s_%02d_%s.png" % [out_dir, base, r.index + 1, r.id])
	if only_room.is_empty():
		var z := minf(1.0, 2400.0 / maxf(bb.size.x, bb.size.y))
		_job(bb, z, "%s/%s_overview.png" % [out_dir, base])


func _job(rect: Rect2, zoom: float, path: String) -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(ceili(rect.size.x * zoom), ceili(rect.size.y * zoom))
	vp.world_2d = root.world_2d
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	var cam := Camera2D.new()
	cam.position = rect.get_center()
	cam.zoom = Vector2(zoom, zoom)
	vp.add_child(cam)
	root.add_child(vp)
	cam.make_current()
	jobs.append([vp, path])
