extends Node
## «Lower by itself when it lags»: while the 3D buildings or trees are shown, the game's frames per second are checked once a
## second; SLOW_SECONDS in a row below the threshold (setting auto_fps) — the mode goes one step down
## (max → normal → eco → off) through on_slow, and the count starts again. It never raises the mode by itself.
## The first seconds after a world start or a change are not counted (loading stutters).

const SLOW_SECONDS := 8
const GRACE := 12.0

var globe: Object                   # globe.gd (showing())
var forest: Object                  # forest.gd (showing())
var on_slow := Callable()           # func() — the owner lowers the mode
var enabled := true
var threshold := 25
var _slow := 0
var _tick := 0.0
var _grace := GRACE


func _ready() -> void:
	name = "PaxCorpInc3DAutoQuality"
	process_mode = Node.PROCESS_MODE_ALWAYS


## A world started or the quality changed: wait before judging again.
func calm() -> void:
	_slow = 0
	_grace = GRACE


func _process(delta: float) -> void:
	var shown := (globe != null and bool(globe.call("showing"))) or (forest != null and bool(forest.call("showing")))
	if not enabled or not shown:
		_slow = 0
		return
	if _grace > 0.0:
		_grace -= delta
		return
	_tick += delta
	if _tick < 1.0:
		return
	_tick = 0.0
	_slow = _slow + 1 if Engine.get_frames_per_second() < threshold else 0
	if _slow >= SLOW_SECONDS:
		calm()
		if on_slow.is_valid():
			on_slow.call()
