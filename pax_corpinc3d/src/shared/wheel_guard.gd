extends Node
## Keeps the mouse wheel inside a window: the game's map zooms on the wheel even over a mod's window, so while the
## pointer is over the window (its parent Control) the wheel scrolls the window's list under the pointer and the
## event goes no further. A full-screen modal (whole = true) swallows the wheel everywhere while it is shown.
## Shared by the author's mods (each carries a copy).

const STEP := 60
var whole := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _input(event: InputEvent) -> void:
	var host := get_parent() as Control
	if host == null or not host.is_visible_in_tree():
		return
	var wheel := event is InputEventMouseButton and (event as InputEventMouseButton).button_index in \
		[MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]
	var gesture := event is InputEventPanGesture or event is InputEventMagnifyGesture
	if not wheel and not gesture:
		return
	var at := host.get_global_mouse_position()
	if not whole and not host.get_global_rect().has_point(at):
		return
	get_viewport().set_input_as_handled()
	if not wheel or not (event as InputEventMouseButton).pressed:
		return
	var mb := event as InputEventMouseButton
	var down := mb.button_index == MOUSE_BUTTON_WHEEL_DOWN
	if mb.button_index == MOUSE_BUTTON_WHEEL_LEFT or mb.button_index == MOUSE_BUTTON_WHEEL_RIGHT:
		return
	# The innermost scrolling list under the pointer scrolls by hand (the event no longer reaches it).
	var best: ScrollContainer = null
	for n in host.find_children("*", "ScrollContainer", true, false):
		var sc := n as ScrollContainer
		if sc.is_visible_in_tree() and sc.get_global_rect().has_point(at):
			best = sc
	if best != null:
		best.scroll_vertical += STEP if down else -STEP
		return
	for n in host.find_children("*", "RichTextLabel", true, false):
		var rt := n as RichTextLabel
		if rt.is_visible_in_tree() and rt.scroll_active and rt.get_global_rect().has_point(at):
			var bar := rt.get_v_scroll_bar()
			bar.value += STEP if down else -STEP
			return
