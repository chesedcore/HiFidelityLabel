extends Control

@export var hfl: HiFidelityLabel

func morph_test() -> void:
	hfl.morph_into("good morning chat")
	await get_tree().create_timer(2).timeout
	hfl.morph_into("my name is monarch")
	await get_tree().create_timer(2).timeout
	hfl.morph_into("no that's not really my name")
	await get_tree().create_timer(2).timeout
	hfl.morph_into("but who cares")
	await get_tree().create_timer(2).timeout
	hfl.morph_into("i fixed the kerning and advancement")
	await get_tree().create_timer(2).timeout
	hfl.morph_into("but the algorithm is now O(n^2)")
	await get_tree().create_timer(2).timeout
	hfl.morph_into("the runtime cost shouldn't be THAT bad")
	await get_tree().create_timer(2).timeout
	hfl.morph_into("but i need to optimise regardless")

func layout_test() -> void:
	hfl.immediately_set_text("hello")
	await get_tree().create_timer(2).timeout
	hfl.immediately_set_text("world")
	await get_tree().create_timer(2).timeout
	hfl.immediately_set_text("car")
	await get_tree().create_timer(2).timeout
	hfl.immediately_set_text("race")
	await get_tree().create_timer(2).timeout
	hfl.immediately_set_text("abacus")
	await get_tree().create_timer(2).timeout
	hfl.immediately_set_text("bachus")

func _ready() -> void:
	await get_tree().create_timer(2).timeout
	morph_test()
