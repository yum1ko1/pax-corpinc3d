extends Logger
## One journal for all the Pax CorpInc mods in the game (Pax Corporations, Pax Corpface, Pax Corptimizer, Pax CorpInc3D).
## The first of them to load makes it (ensure) and hands it to the engine (OS.add_logger), so it hears:
##   • the engine's errors and warnings whose script is one of our mods (a broken key, a null, a bad call) —
##     the GDScript errors a player never sees;
##   • the lines the mods print themselves (PaxMod.log_info / log_warning / log_error, tagged with the mod id);
##   • what the mods write through log.gd (Log.info("zones", "…")) with a level and a category.
## A line repeated in a row is kept once with a counter. The last errors and warnings are saved (the owner mod's
## save_data «journal», every 15 s when changed) and shown as «the previous start» next time — a crash does not lose
## them. The window (log_window.gd) reads it; the feedback window and the window send it to the developer.
## The engine may call a Logger from any thread: every change goes under the lock, nothing touches the scene here.
## Shared by the mods through Engine meta «pax_corpinc_log» — reached untyped (call/get), as each mod has its copy.

const META := &"pax_corpinc_log"
const MAX := 800                  # lines kept in memory
const KEEP := 200                 # errors and warnings saved for the next start
const OURS := ["pax_corporations", "pax_corpface", "pax_corptimizer", "pax_corpinc3d"]
const SAVE_NAME := "journal"

var owner_mod: Object             # the mod that made the journal: saves it, owns the console command
var debug := false                # debug lines are kept only when on (console: paxlog debug on)
var muted := false                # set by log.gd while it prints its own line (the engine would echo it back)
var serial := 0                   # grows with every change — the window redraws when it moved
var errors := 0                   # errors of this start
var warnings := 0
var _items: Array = []            # {t: msec, w: "HH:MM:SS", m: mod, l: level, c: category, s: text, n: repeats, p: previous start}
var _lock := Mutex.new()
var _dirty := false


## The journal of this game (made by the first mod that asks). null if the engine refuses a logger.
static func ensure(mod: Object) -> Object:
	if Engine.has_meta(META):
		var have: Variant = Engine.get_meta(META)
		if have is Object and is_instance_valid(have):
			return have
	var hub = new()
	hub.owner_mod = mod
	hub._load_previous()
	OS.add_logger(hub)
	Engine.set_meta(META, hub)
	if mod is Node:
		var t := Timer.new()
		t.name = "PaxCorpIncJournalSave"
		t.wait_time = 15.0
		t.autostart = true
		t.timeout.connect(hub.flush)
		(mod as Node).add_child(t)
	Pax.register_command("paxlog", hub.command, "paxlog [errors|all|clear|debug on|off] — the Pax CorpInc mods' journal")
	return hub


## The owner mod leaves: the journal is saved and handed back (the next mod to load makes a new one).
static func release(mod: Object) -> void:
	if not Engine.has_meta(META):
		return
	var hub: Variant = Engine.get_meta(META)
	if hub is Object and is_instance_valid(hub) and (hub as Object).get("owner_mod") == mod:
		(hub as Object).call("flush")
		OS.remove_logger(hub as Logger)
		Engine.remove_meta(META)


# ---------- writing ----------

func add(mod_id: String, level: String, category: String, text: String) -> void:
	if level == "debug" and not debug:
		return
	_lock.lock()
	var last: Dictionary = _items.back() if not _items.is_empty() else {}
	if not last.is_empty() and str(last["m"]) == mod_id and str(last["l"]) == level and str(last["s"]) == text \
			and str(last["c"]) == category and not bool(last["p"]):
		last["n"] = int(last["n"]) + 1
		last["w"] = Time.get_time_string_from_system()
	else:
		_items.append({"t": Time.get_ticks_msec(), "w": Time.get_time_string_from_system(), "m": mod_id, "l": level,
			"c": category, "s": text, "n": 1, "p": false})
		if _items.size() > MAX:
			_items = _items.slice(_items.size() - MAX)
	if level == "error":
		errors += 1
	elif level == "warn":
		warnings += 1
	if level in ["error", "warn"]:
		_dirty = true
	serial += 1
	_lock.unlock()


func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
		error_type: int, script_backtrace: Array[ScriptBacktrace]) -> void:
	if muted:
		return
	var where := file
	var mod_id := _ours(file)
	if mod_id.is_empty():
		for bt in script_backtrace:
			for i in bt.get_frame_count():
				mod_id = _ours(bt.get_frame_file(i))
				if not mod_id.is_empty():
					where = "%s:%d %s()" % [bt.get_frame_file(i), bt.get_frame_line(i), bt.get_frame_function(i)]
					break
			if not mod_id.is_empty():
				break
	elif line > 0:
		where = "%s:%d %s()" % [file, line, function]
	if mod_id.is_empty():
		return
	var what := rationale if not rationale.is_empty() else code
	add(mod_id, "warn" if error_type == ERROR_TYPE_WARNING else "error", "engine",
		"%s — %s" % [what, where.replace("res://mods/%s/" % mod_id, "")])


func _log_message(message: String, error: bool) -> void:
	if muted:
		return
	for id in OURS:
		var tag := "[%s]" % id
		if message.begins_with(tag):
			add(id, "error" if error else "info", "log", message.substr(tag.length()).strip_edges())
			return


func _ours(path: String) -> String:
	for id in OURS:
		if path.contains("res://mods/%s/" % id):
			return id
	return ""


# ---------- reading ----------

## A copy of the lines (oldest first).
func entries() -> Array:
	_lock.lock()
	var out := _items.duplicate(true)
	_lock.unlock()
	return out


func clear() -> void:
	_lock.lock()
	_items.clear()
	errors = 0
	warnings = 0
	_dirty = true
	serial += 1
	_lock.unlock()


func line_of(e: Dictionary) -> String:
	var n := int(e.get("n", 1))
	return "%s%s %s %s/%s: %s%s" % ["[prev] " if bool(e.get("p", false)) else "", str(e.get("w", "")),
		str(e.get("l", "")).to_upper(), str(e.get("m", "")).trim_prefix("pax_"), str(e.get("c", "")),
		str(e.get("s", "")), " ×%d" % n if n > 1 else ""]


## The journal as text: the newest `count` lines at `min_level` and above (debug < info < warn < error).
func text(min_level: String = "debug", count: int = MAX) -> String:
	var rank := ["debug", "info", "warn", "error"]
	var lo := rank.find(min_level)
	var lines: PackedStringArray = []
	for e in entries():
		if rank.find(str((e as Dictionary)["l"])) >= lo:
			lines.append(line_of(e))
	return "\n".join(lines.slice(maxi(0, lines.size() - count)))


## What goes to the developer: every error and warning that fits, then the latest info lines for context —
## newest first, at most `chars` characters.
func report(chars: int) -> String:
	var all := entries()
	var picked: Array = []
	var used := 0
	for pass_levels in [["error", "warn"], ["info"]]:
		for i in range(all.size() - 1, -1, -1):
			var e: Dictionary = all[i]
			if not (str(e["l"]) in pass_levels):
				continue
			var l := line_of(e)
			if used + l.length() + 1 > chars:
				continue
			picked.append([i, l])
			used += l.length() + 1
	picked.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	return "\n".join(picked.map(func(p: Array) -> String: return str(p[1])))


# ---------- saving ----------

## The errors and warnings to the owner mod's data (only when changed).
func flush() -> void:
	if not _dirty or owner_mod == null or not is_instance_valid(owner_mod):
		return
	_lock.lock()
	_dirty = false
	var keep: Array = _items.filter(func(e: Dictionary) -> bool: return str(e["l"]) in ["error", "warn"])
	keep = keep.slice(maxi(0, keep.size() - KEEP))
	_lock.unlock()
	owner_mod.call("save_data", SAVE_NAME, keep)


func _load_previous() -> void:
	if owner_mod == null:
		return
	var old: Variant = owner_mod.call("load_data", SAVE_NAME, [])
	if not (old is Array):
		return
	for v in old:
		if v is Dictionary:
			var e := (v as Dictionary).duplicate()
			e["p"] = true
			_items.append(e)


# ---------- the console ----------

func command(args: PackedStringArray) -> String:
	var a := args[0] if args.size() > 0 else ""
	match a:
		"clear":
			clear()
			return "journal cleared"
		"debug":
			debug = args.size() > 1 and args[1] == "on"
			return "debug lines: %s" % ("on" if debug else "off")
		"all":
			return text("debug", 60)
		"errors":
			return text("warn", 60)
	return "errors %d, warnings %d this start\n%s" % [errors, warnings, text("info", 25)]
