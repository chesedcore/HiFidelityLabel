##A class dedicated to rendering labels up to character degree precision,
##at the cost of heavier performance overhead. Allows animations with character-degree fidelity.
##Basically a pooled, per-char text renderer that supports reordering, insertion and
##morphing between strings. 
class_name HiFidelityLabel extends Control

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

##tween easing parameters.
@export var t_ease: Tween.EaseType = Tween.EASE_OUT
##tween transition parameters.
@export var t_trans: Tween.TransitionType = Tween.TRANS_EXPO

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
##instantly place all glyphs without animation.
func _relayout_immediately() -> void:
	var x := 0.0
	for g in _active_glyphs:
		var width := _measure_char_width(g)
		var target := Vector2(x, baseline_y)
		g.pos = target
		g.target_pos = target
		#ensure label shows correct char and is moved properly
		_set_label_text_and_pos(g.label_idx, g.repr, target)
		x += width + letter_spacing

##compute target positions for the new order and animate each glyph with a tween
func _relayout_animated() -> void:
	var x := 0.0
	for g in _active_glyphs:
		var width := _measure_char_width(g)
		var target := Vector2(x, baseline_y)
		_set_label_text_and_pos(g.label_idx, g.repr, g.pos) #keep this visual position as a start
		g.stop_tween()
		#create tween here for position movement from current to target
		var lbl := _label_pool[g.label_idx]
		var t := create_tween().set_ease(t_ease).set_trans(t_trans)
		#animate
		t.tween_property(lbl, "position", target, zero_point_three)
		g.tween = t
		g.target_pos = target
		g.pos = target
		x += width + letter_spacing

##helper used to set label text and position immediately (used to seed animation start)
func _set_label_text_and_pos(label_idx: int, ch: String, pos: Vector2) -> void:
	var lbl := _label_pool[label_idx]
	lbl.text = ch
	lbl.position = pos
	lbl.visible = true
	lbl.modulate = Color.WHITE
#endregion

#region MEASUREMENT AND UTILS
@export var extra_fit: int = 1
##measure glyph width accurately using the cached font if available.
##fallback to minimum size if font is not cached.
func _measure_char_width(g: Glyph) -> float:
	if _font:
		print_rich("[color=green]Font cache found!")
		return _font.get_string_size(g.repr+" ".repeat(extra_fit)).x
	#fallback code
	if _label_pool.size() > 0:
		var tmp := _label_pool[0]
		tmp.text = g.repr
		#await get_tree().process_frame
		return tmp.get_minimum_size().x
	#absolute fallback
	push_warning("No proper fallback found. Returning a const fallback 8.0.")
	return 8.0

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
#endregion

#endregion

##immediately layouts the string given.
func immediately_set_text(string: String) -> void:
	_immediately_destroy_all_glyphs()
	for i in string.length():
		var ch := string.substr(i, 1)
		var g := _spawn_glyph(ch)
		_active_glyphs.append(g)
	
	#snap to layout
	_relayout_immediately()

##look man this shit does too much, i dont blame you if you don get it
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
			ng.pos.y += baseline_y
			new_active.append(ng)
	
	#kill unused indices
	for key in bucket.keys():
		var list_rem: Array = bucket[key]
		for rem_idx in list_rem:
			var old_glyph := _active_glyphs[rem_idx]
			_destroy_glyph(old_glyph)
	
	_active_glyphs.assign(new_active)
	_relayout_animated()
