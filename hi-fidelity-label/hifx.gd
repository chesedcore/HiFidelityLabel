# glyph_fx.gd
# A RichTextEffect that can animate glyphs out (exit) and in (enter).
# It does not change the label text itself — it only modifies the CharFXTransform
# that Godot passes for each glyph during rendering.
# The orchestrator (HiFidelityRichTextLabel) will call `start_exit` and `start_enter`
# and provide callbacks to be executed when each phase finishes.

extends RichTextEffect
class_name GlyphFX

# Modes:
const MODE_IDLE := 0
const MODE_EXIT := 1
const MODE_ENTER := 2

# Public tuning
var duration: float = 0.32               # default phase duration
var stagger: float = 0.02                 # per-glyph delay (seconds) between chars
var vertical_offset: float = -18.0        # how far glyphs fly vertically on exit/enter
var rotation_deg: float = 8.0             # small rotation during motion
var ease_func := func(t):
	# smoothstep
	return t * t * (3.0 - 2.0 * t)

# Internal state
var _mode: int = MODE_IDLE
var _start_time: float = 0.0
var _on_complete: Callable
var _glyph_count_hint: int = 0  # optional hint to help timing

# Start exit phase: animate current text out.
# on_complete will be called once when last glyph finished its exit animation.
func start_exit(p_duration: float, p_on_complete: Callable, p_stagger: float = 0.02, p_vertical_offset: float = -18.0) -> void:
	_mode = MODE_EXIT
	duration = p_duration
	stagger = p_stagger
	vertical_offset = p_vertical_offset
	_start_time = Engine.get_idle_time()  # uses engine time, consistent while running
	_on_complete = p_on_complete
	_glyph_count_hint = 0
	# request redraw (effect will run in next draw)
	update()

# Start enter phase: animate current text in. Label.text should be the TARGET text
# before calling this (the orchestrator will swap the text).
func start_enter(p_duration: float, p_on_complete: Callable, p_stagger: float = 0.02, p_vertical_offset: float = -18.0) -> void:
	_mode = MODE_ENTER
	duration = p_duration
	stagger = p_stagger
	vertical_offset = p_vertical_offset
	_start_time = Engine.get_idle_time()
	_on_complete = p_on_complete
	_glyph_count_hint = 0
	update()

# Force immediate reset (stop animations)
func reset() -> void:
	_mode = MODE_IDLE
	_start_time = 0.0
	_on_complete = null
	_glyph_count_hint = 0
	update()

# _process_custom_fx is called by Godot for every glyph being drawn.
# It receives a CharFXTransform we can mutate (offset / transform / color / visible).
# We use transform.relative_index to compute per-glyph delays and do per-glyph motion.
func _process_custom_fx(fx: CharFXTransform) -> bool:
	# If idle, do nothing (leave glyph untouched).
	if _mode == MODE_IDLE:
		return

	# Some cheap caching/hinting: track max glyph index seen so we can know when to call completion callback.
	if fx.relative_index + 1 > _glyph_count_hint:
		_glyph_count_hint = fx.relative_index + 1

	# Compute per-glyph start time (staggered)
	var glyph_delay := fx.relative_index * stagger
	var t_global := Engine.get_idle_time() - _start_time - glyph_delay
	var raw_t := t_global / max(duration, 0.0001)
	var clamped := clamp(raw_t, 0.0, 1.0)
	var e := ease_func(clamped)

	if _mode == MODE_EXIT:
		# Exit: glyphs fly up (vertical_offset negative) and fade out
		# initial: offset=(0,0), alpha=1; final: offset=(0,vertical_offset), alpha=0
		var off_y := lerp(0.0, vertical_offset, e)
		fx.offset = Vector2(0, off_y)
		# rotate a little for flair
		var rot := deg2rad(lerp(0.0, rotation_deg, e))
		var s := 1.0 - 0.15 * e
		fx.transform = Transform2D( cos(rot)*s, -sin(rot)*s, sin(rot)*s, cos(rot)*s, 0, 0 )
		# fade alpha
		fx.color = Color(1,1,1, 1.0 - e)

		# if this glyph is the last one and its t >= 1, we may be done
		if fx.relative_index == _glyph_count_hint - 1 and raw_t >= 1.0:
			# call on_complete once (clear mode to idle so we stop calling)
			var cb := _on_complete
			_on_complete = null
			_mode = MODE_IDLE
			if cb:
				cb.call()

	elif _mode == MODE_ENTER:
		# Enter: glyphs start offset = vertical_offset (off-screen) and alpha=0, they land at (0,0) with alpha=1
		var off_y := lerp(vertical_offset, 0.0, ease_func(clamped))
		fx.offset = Vector2(0, off_y)
		# small pop: scale up a bit in early phase
		var pop := 1.0 + 0.08 * sin(e * PI)
		var rot_e := deg2rad(lerp(-rotation_deg*0.5, 0.0, e))
		fx.transform = Transform2D( cos(rot_e)*pop, -sin(rot_e)*pop, sin(rot_e)*pop, cos(rot_e)*pop, 0, 0 )
		fx.color = Color(1,1,1, e)

		if fx.relative_index == _glyph_count_hint - 1 and raw_t >= 1.0:
			var cb2 := _on_complete
			_on_complete = null
			_mode = MODE_IDLE
			if cb2:
				cb2.call()
