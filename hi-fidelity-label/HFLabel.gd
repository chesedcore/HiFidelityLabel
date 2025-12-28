##A class dedicated to rendering labels up to character degree precision,
##at the cost of heavier performance overhead. Allows animations with character-degree fidelity.
##Basically a pooled, per-char text renderer that supports reordering, insertion and
##morphing between strings. 
class_name HiFidelityLabel extends Control

#region SIGNALS
##emitted when a morph animation completes
signal finished_morphing
#endregion

#region CONFIGURATION

##maximum number of glyphs that this node can render. the node allocates an arena on ready up 
##to that number of label nodes, to avoid the overhead of allocation during runtime. setting this
##during runtime currently will do nothing.
@export_range(4, 500, 1) var max_glyphs: int = 256

##extra spacing added between characters. lets you push characters apart for stylistic reasons.
@export var letter_spacing: float = 0.0

##vertical offset for all characters. the y baseline that all letters sit on.
@export var baseline_y: float = 0.0

##time duration of the animation. named so because of an inside joke i am unwilling to budge on.
@export var zero_point_three: float = 0.3

##font size of each label.
@export var font_size := 10

##text alignment
@export_enum("Left", "Center", "Right") var alignment: int = 1

##tween easing parameters.
@export var t_ease: Tween.EaseType = Tween.EASE_OUT
##tween transition parameters.
@export var t_trans: Tween.TransitionType = Tween.TRANS_EXPO

@export_category("Multiline settings")
##if true, attempts to render the string multilined.
@export var multiline: bool = false
##if zero, uses control.size.x. otherwise uses the one specified.
@export var max_width: float = 0.0 #0 = use Control.size.x lol
##spacing between the lines. duh.
@export var line_spacing: float = 0.0

##cache the font to prevent asking for it on a hot path
var _font: Font
#endregion

#region INTERNAL POOL AND CACHE
##an array of all Label nodes that are allocated once then reused forever. these are the actual visual nodes.
var _label_pool: Array[Label] = []

##An array of unused label indices. if an index is here, then its label is free and can be grabbed.
var _free_label_indices := PackedInt32Array()

##this is the current visible string in order. each element corresponds to one character on the screen.
var _active_glyphs: Array[Glyph] = []

##track active morph tweens to know when morphing is complete
var _active_morph_tweens: Array[Tween] = []
#endregion

#region GLYPH
##a glyph represents ONE CHARACTER on the screen. this does not represent any node.
##this is just data to help with proper arrangement.
class Glyph:
	##the character this glyph represents.
	var repr: String:
		set(string):
			if string.length() > 1: string = string[0]; push_warning("Nonchar string passed.")
			repr = string
	
	##which label in the pool [code]_label_pool[/code] this glyph is currently pointing at (by index)
	var label_idx := -1
	
	##this glyph's visual position.
	var pos := Vector2.ZERO
	
	##the target position this glyph will animate towards.
	var target_pos := Vector2.ZERO
	
	##the active tween controlling this glyph.
	var tween: Tween = null
	
	##whether this glyph is active(alive) or not (scheduled for despawning)
	var is_alive: bool = false
	
	##constructor-like method (thanks godot)
	static func from(c: String, lbl_idx: int, start_pos: Vector2) -> Glyph:
		var g := Glyph.new()
		g.repr = c
		g.label_idx = lbl_idx
		g.pos = start_pos
		g.target_pos = start_pos
		g.is_alive = true
		return g
	
	##stop and clear any running tween
	func stop_tween() -> void:
		if tween: tween.kill()
		tween = null
	
	##mark glyph as dead (finalised)
	func kill() -> void: 
		is_alive = false
#endregion

#region PRIVATE
func _ready() -> void:
	_preallocate_pool()
	if _label_pool.size() > 0: 
		_font = _label_pool[0].get_theme_font("font")

##preallocates all label nodes up-front. this is done to avoid runtime stutter from
##add_child and memory allocation.
func _preallocate_pool() -> void:
	for i in max_glyphs:
		var label := Label.new()
		label.visible = false
		label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.focus_mode = Control.FOCUS_NONE
		label.add_theme_font_size_override("font_size", font_size)
		self.add_child(label)
		_label_pool.push_back(label)
		_free_label_indices.push_back(i)

##imagine not having a fucking pop_back on an ALIAS OF VEC<I32> GODOT. COME THE FUCK ON
func _pop_i32_arr(arr: PackedInt32Array) -> int:
	var last_idx := arr.size() - 1
	var item := arr[last_idx]
	arr.remove_at(last_idx)
	return item

##activates a new glyph from the pool.
func _spawn_glyph(ch: String) -> Glyph:
	assert(_free_label_indices.size() > 0, "Improper handling: no more space left free for this glyph.")
	var idx: int = _pop_i32_arr(_free_label_indices)
	var label := _label_pool[idx]
	
	#init visually
	label.text = ch
	label.visible = true
	label.modulate.a = 1.0
	
	return Glyph.from(ch, idx, label.position)

##animates a glyph out and resets it, freeing its label back into the pool.
func _destroy_glyph(glyph: Glyph) -> void:
	assert(glyph, "This glyph doesn't even exist!")
	
	#mark dead so other logic doesnt attempt to retarget this glyph
	glyph.is_alive = false
	#stop any ongoing tweens if any
	glyph.stop_tween()
	
	var lbl_idx := glyph.label_idx
	if lbl_idx < 0 or lbl_idx >= _label_pool.size():
		push_error("Ran into an invalid state, how did this even happen?")
		print_stack()
	
	var label := _label_pool[lbl_idx]
	var t := create_tween().set_ease(t_ease).set_trans(t_trans)
	label.visible = true
	t.tween_property(label, "modulate:a", 0.0, zero_point_three)
	t.tween_callback(_reset_glyph.bind(lbl_idx))

##add this glyph back into the pool. O(n) time. 
##TODO: make this run in constant time.
##done!! it now runs in constant time!!!! 
func _reset_glyph(label_idx: int) -> void:
	var label := _label_pool[label_idx]
	label.visible = false
	label.text = ""
	_free_label_indices.push_back(label_idx)

##helper for morph_into(). pops the nearest old index (closest to visual index space)
func _pop_nearest(list_idx_arr: Array, target_idx: int) -> int:
	if not list_idx_arr: return -1
	var best_j := 0
	var best_cost := absi(list_idx_arr[0] - target_idx)
	for j in list_idx_arr.size():
		var c := absi(list_idx_arr[j] - target_idx)
		if c < best_cost:
			best_cost = c
			best_j = j
	var chosen: int = list_idx_arr[best_j]
	list_idx_arr.remove_at(best_j)
	return chosen

#region LAYOUT AND ANIMATIONS (tweens)

func _compute_singleline_targets(full_text: String) -> Array[Vector2]:
	var targets: Array[Vector2] = []
	var x_positions := _compute_glyph_positions_from_string(full_text)
	
	var total_width := 0.0
	if x_positions.size() > 0:
		total_width = x_positions[-1] + (x_positions.size() - 1) * letter_spacing
	
	var x_offset := 0.0
	match alignment:
		1: x_offset = (size.x - total_width) * 0.5
		2: x_offset = size.x - total_width
		_: x_offset = 0.0
	
	for i in x_positions.size():
		var x := 0.0
		if i > 0:
			x = x_positions[i - 1]
		x += i * letter_spacing + x_offset
		targets.append(Vector2(x, 0.0))
	
	return targets


##instantly place all glyphs without animation.
func _relayout_immediately() -> void:
	var full_text := ""
	for g in _active_glyphs:
		full_text += g.repr
	
	var targets := \
		_compute_multiline_targets(full_text) if multiline \
		else _compute_singleline_targets(full_text)
	
	for i in _active_glyphs.size():
		var g := _active_glyphs[i]
		var target := targets[i] + Vector2(0.0, baseline_y)
		g.pos = target
		g.target_pos = target
		_set_label_text_and_pos(g.label_idx, g.repr, target)


##compute target positions for the new order and animate each glyph with a tween
func _relayout_animated() -> void:
	var full_text := ""
	for g in _active_glyphs:
		full_text += g.repr
	
	var targets := \
		_compute_multiline_targets(full_text) if multiline \
		else _compute_singleline_targets(full_text)
	
	_active_morph_tweens.clear()

	for i in _active_glyphs.size():
		var g := _active_glyphs[i]
		var target := targets[i] + Vector2(0.0, baseline_y)
		
		_set_label_text_and_pos(g.label_idx, g.repr, g.pos)
		g.stop_tween()
		
		var lbl := _label_pool[g.label_idx]
		var t := create_tween().set_ease(t_ease).set_trans(t_trans)
		t.tween_property(lbl, "position", target, zero_point_three)
		
		g.tween = t
		g.target_pos = target
		g.pos = target
		_active_morph_tweens.append(t)
		
	if _active_morph_tweens.size() > 0:
		_active_morph_tweens[-1].finished.connect(
			_on_morph_complete,
			CONNECT_ONE_SHOT
		)


##called when morphing animation completes
func _on_morph_complete() -> void:
	finished_morphing.emit()

##helper used to set label text and position immediately (used to seed animation start)
func _set_label_text_and_pos(label_idx: int, ch: String, pos: Vector2) -> void:
	var lbl := _label_pool[label_idx]
	lbl.text = ch
	lbl.position = pos
	lbl.visible = true
	lbl.modulate = Color.WHITE
#endregion

#region MEASUREMENT AND UTILS
##returns X positions for each glyph based on real kerning & shaping.
##index i gives the X at which character i should be placed.
func _compute_glyph_positions_from_string(full_text: String) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	
	if not _font:
		push_error("Font cache missing. I haven't added a fallback yet lol")
		return result
	
	var run := ""
	##HACK: runs in O(n^2) time. fucking horrendous for 1000 glyphs -> 1,000,000 time units :sob:
	##TODO: reduce to O(n) time
	for i in full_text.length():
		run += full_text.substr(i, 1)
		var _size := _font.get_string_size(
			run,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_size
		)
		result.push_back(_size.x)
	
	return result

func _compute_multiline_targets(text: String) -> Array[Vector2]:
	var targets: Array[Vector2] = []
	var limit := max_width if max_width > 0.0 else size.x
	
	#build lines first to calculate their widths for alignment
	var lines: Array[Array] = []
	var current_line: Array[Dictionary] = []
	var line_x := 0.0
	
	for i in text.length():
		var ch := text.substr(i, 1)
		
		if ch == "\n":
			lines.append(current_line)
			current_line = []
			line_x = 0.0
			continue
		
		var ch_width := _font.get_string_size(
			ch,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_size
		).x
		
		#check if I need to wrap (only if multiline is true)
		if multiline and line_x + ch_width > limit and current_line.size() > 0:
			lines.append(current_line)
			current_line = []
			line_x = 0.0
		
		#add character to current line with its position relative to line start
		current_line.append({"char": ch, "width": ch_width, "x": line_x})
		line_x += ch_width + letter_spacing
	
	#don't forget the last line
	if current_line.size() > 0:
		lines.append(current_line)
	
	#now layout each line with alignment
	var cursor_y := 0.0
	for line in lines:
		if line.size() == 0:
			cursor_y += _get_line_height() + line_spacing
			continue
		
		#calculate actual line width (last char x + last char width)
		var last_char: Dictionary = line[-1]
		var line_width := last_char["x"] + last_char["width"] as float
		
		#apply alignment offset based on line width
		var x_offset := 0.0
		var align_width := limit if multiline else size.x
		match alignment:
			1: x_offset = (align_width - line_width) * 0.5
			2: x_offset = align_width - line_width
			_: x_offset = 0.0
		
		for char_data in line:
			targets.append(Vector2(char_data["x"] + x_offset, cursor_y))
		
		cursor_y += _get_line_height() + line_spacing
	
	return targets


##obtain current label position (used when reusing a label index as fallback)
func _get_label_pos(label_idx: int) -> Vector2:
	return _label_pool[label_idx].position

##destroy every active glyph immediately and return all labels to the pool.
func _immediately_destroy_all_glyphs() -> void:
	for g in _active_glyphs:
		g.stop_tween()
		var lbl := _label_pool[g.label_idx]
		lbl.visible = false
		lbl.text = ""
		lbl.modulate = Color.WHITE
		_free_label_indices.push_back(g.label_idx)
	_active_glyphs.clear()

##fetches the line height (size.y)
func _get_line_height() -> float:
	if not _font: return font_size
	return _font.get_height(font_size)
#endregion

#endregion

##immediately layouts the string given.
func immediately_set_text(string: String) -> void:
	_immediately_destroy_all_glyphs()
	for i in string.length():
		var ch := string.substr(i, 1)
		if ch == "\n": continue
		var g := _spawn_glyph(ch)
		_active_glyphs.append(g)
	
	#snap to layout
	_relayout_immediately()
	
	finished_morphing.emit.call_deferred()

##morph (animate) the current string into the given text.
func morph_into(new_text: String) -> void:
	if not _active_glyphs: 
		immediately_set_text(new_text)
		return
	
	var bucket: Dictionary[String, Array]= {}
	
	for i in _active_glyphs.size():
		var g := _active_glyphs[i]
		if not bucket.has(g.repr):
			bucket[g.repr] = []
		bucket[g.repr].append(i)
	
	var new_active: Array[Glyph] = []
	for new_idx in new_text.length():
		var ch := new_text.substr(new_idx, 1)
		var reused: Glyph
		if bucket.has(ch):
			var list := bucket[ch]
			var old_idx := _pop_nearest(list, new_idx)
			if old_idx >= 0: reused = _active_glyphs[old_idx]
		
		if reused:
			reused.stop_tween()
			reused.is_alive = true
			new_active.append(reused)
		else:
			var ng := _spawn_glyph(ch)
			new_active.append(ng)
	
	#kill unused indices
	for key in bucket.keys():
		var list_rem: Array = bucket[key]
		for rem_idx in list_rem:
			var old_glyph := _active_glyphs[rem_idx]
			_destroy_glyph(old_glyph)
	
	_active_glyphs.assign(new_active)
	
	#if no glyphs to animate, emit immediately
	if _active_glyphs.size() == 0:
		finished_morphing.emit.call_deferred()
	else:
		_relayout_animated()
