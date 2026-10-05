extends RefCounted
## «What's new» shared by the author's mods (Pax Corporations, Pax Corpface, Pax Corptimizer — each carries a
## copy of this file). When a world starts, a window lists what changed since the version the player last saw
## (config/whatsnew.json — the versions, newest first; texts in data/lang «<prefix>whatsnew_<version>» and
## «…_title»). Every copy registers itself in Engine meta REG; the first mod whose timer fires opens ONE window
## with a tab for each registered mod that has news; a mod coming later adds its tab to the open window.
## At the bottom a «don't show again» box: ticked — every shown mod stays quiet until its next version.
## The version seen is kept in each mod's own settings («whatsnew_seen»). The copies talk only through call().
## On the right — «Recommended mods» of the active tab's mod (config/whatsnew.json «рекомендуем»: id, name and a
## lang key of a short description): what each adds, installed or to be found in the game's store by its name.

const GOLD := Color(0.95, 0.78, 0.32)
const LATEST_SEEN := 3
const WheelGuard := preload("res://mods/pax_corpinc3d/src/shared/wheel_guard.gd")   # the wheel scrolls the window, not the map under it
const REG := &"pax_whatsnew_registry"   # Dictionary: mod id -> this object of that mod
const WIN := &"pax_whatsnew_window"     # the object that owns the open window

var mod: PaxMod
var game: PaxGame
var prefix := ""
var _id := ""
var _current := ""
var _name := ""
# The window (only on the copy that opened it).
var _panel: PanelContainer
var _never: CheckBox
var _tabs: HBoxContainer
var _title: Label
var _sub: Label
var _text: RichTextLabel
var _recs: VBoxContainer
var _recs_panel: PanelContainer
var _sources: Array = []          # the mods in the window (objects like this one)
var _active: Object
var _players := false             # the «From players» tab is open (config/feedback_log.json)
var _stories := false             # the «Memes and stories» tab is open (config/stories.json)
var _share_row: HBoxContainer     # under the text: «Share a meme or a story» (only on that tab)
var _feed_btn: Button             # on «From players»: the live list on the server's page (the game cannot go online)
const PLAYER := &"pax_corpinc_player"   # the player's number (feedback.gd), shared by the author's mods
const NICK := &"pax_corpinc_nick"       # the player's nickname (feedback.gd ⚙), shared by the author's mods
const ST_COL := {"new": "#8da2b8", "accept": "#6fc3ff", "work": "#f0c25a", "fixed": "#5fd39a", "reject": "#ef7b72"}


func setup(m: PaxMod, g: PaxGame, lang_prefix: String) -> void:
	mod = m
	game = g
	prefix = lang_prefix
	var manifest: Variant = m.load_json("mod.json", {})
	if manifest is Dictionary:
		_current = str((manifest as Dictionary).get("version", ""))
		_id = str((manifest as Dictionary).get("id", lang_prefix))
		var nm: Variant = (manifest as Dictionary).get("name", _id)
		if nm is Dictionary:
			var ru := TranslationServer.get_locale().begins_with("ru")
			_name = str((nm as Dictionary).get("ru" if ru else "en", (nm as Dictionary).get("en", _id)))
		else:
			_name = str(nm)
	var reg: Dictionary = Engine.get_meta(REG, {}) if Engine.has_meta(REG) else {}
	reg[_id] = self
	Engine.set_meta(REG, reg)
	# The player's number and nickname are one for all the author's mods: whatever this mod keeps goes to the shared
	# meta at once (before, the window of another mod did not know the nickname typed in Corpface's ⚙ until it was
	# opened again — memes went without it; or even made a second number).
	for pair in [["fb_player", PLAYER], ["fb_nick", NICK]]:
		var v := str(m.get_setting(str(pair[0]), ""))
		if not v.is_empty() and (not Engine.has_meta(pair[1]) or str(Engine.get_meta(pair[1])).is_empty()):
			Engine.set_meta(pair[1], v)


func _t(key: String) -> String:
	return mod.tr_key(prefix + key)


# ---------- what this mod offers (called by whichever copy owns the window) ----------

func display_name() -> String:
	return _name


func version() -> String:
	return _current


func seen() -> String:
	return str(mod.get_setting("whatsnew_seen", ""))


func mark_seen() -> void:
	mod.set_setting("whatsnew_seen", _current)


func has_news() -> bool:
	return is_instance_valid(mod) and not _current.is_empty() and seen() != _current and not _unseen().is_empty()


## The versions newer than the one seen (all of them if none was seen yet), newest first.
func _unseen() -> Array:
	var cfg: Variant = mod.load_json("config/whatsnew.json", {})
	var all: Array = (cfg as Dictionary).get("versions", []) if cfg is Dictionary else []
	var s := seen()
	var out: Array = all.filter(func(v): return s.is_empty() or newer(str(v), s))
	if out.is_empty() and _always:
		out = all.slice(0, LATEST_SEEN)   # opened by hand with nothing new: the latest versions
	return out


## The mods this one recommends: [{имя, текст, есть}] (есть — installed: registered here or known by its metas).
func recommendations() -> Array:
	var cfg: Variant = mod.load_json("config/whatsnew.json", {})
	var list: Array = (cfg as Dictionary).get("recommended", []) if cfg is Dictionary else []
	var reg: Dictionary = Engine.get_meta(REG, {}) if Engine.has_meta(REG) else {}
	var out: Array = []
	for r in list:
		if not (r is Dictionary):
			continue
		var id := str((r as Dictionary).get("id", ""))
		var have := reg.has(id) or (id == "pax_corporations" and Engine.has_meta("pax_corporations_api")) 			or (id == "pax_corpface" and Engine.has_meta("pax_corpface_panel"))
		out.append({"имя": str((r as Dictionary).get("имя", id)), "текст": _t(str((r as Dictionary).get("ключ", ""))), "has_flag": have})
	return out


func rec_text(key: String) -> String:
	return _t(key)


## The window's text for this mod (BBCode) and the line under the title. A change made after a player's message
## carries «{игрок:NUMBER}» in its text — it becomes a 🐞 mark (yours — «по вашему сообщению»).
func body() -> String:
	var out := ""
	for ver in _unseen():
		var key := "whatsnew_" + str(ver).replace(".", "_")
		out += "[b][color=#f2c752]%s — %s[/color][/b]\n%s\n\n" % [str(ver), _t(key + "_title"), _marks(_t(key))]
	return out.strip_edges()


func _me() -> String:
	if Engine.has_meta(PLAYER) and not str(Engine.get_meta(PLAYER)).is_empty():
		return str(Engine.get_meta(PLAYER))
	return str(mod.get_setting("fb_player", ""))


func _nick() -> String:
	if Engine.has_meta(NICK) and not str(Engine.get_meta(NICK)).is_empty():
		return str(Engine.get_meta(NICK))
	return str(mod.get_setting("fb_nick", ""))


func _marks(text: String) -> String:
	var re := RegEx.new()
	re.compile("\\{игрок:([A-Z0-9]+)\\}")
	var out := text
	for m in re.search_all(text):
		var id := m.get_string(1)
		var mark := _t("whatsnew_from_you") if id == _me() else _t("whatsnew_from_player") % id
		out = out.replace(m.get_string(0), " [color=#7fd6ff]🐞 %s[/color]" % mark)
	return out


## «From players»: everything the players sent through «Contact the developer» and what became of it, newest first
## (config/feedback_log.json, renewed with every update of the mods); the player's own messages are marked.
func players_body() -> String:
	var cfg: Variant = mod.load_json("config/feedback_log.json", {})
	var list: Array = (cfg as Dictionary).get("messages", []) if cfg is Dictionary else []
	if list.is_empty():
		return _t("whatsnew_players_none")
	var me := _me()
	var kinds := {"bug": "🐞 #Баг", "wish": "💡 #Пожелание", "praise": "👍 #Оценка/Похвала", "complaint": "👎 #Оценка/Жалоба"}
	var out := ""
	for i in range(list.size() - 1, -1, -1):
		if not (list[i] is Dictionary):
			continue
		var r: Dictionary = list[i]
		var st := str(r.get("s", "new"))
		var mine := str(r.get("p", "")) == me
		out += "[b]%s[/b]  [color=#8d99a8]%s · %s[/color]%s  [color=%s]%s%s[/color]\n" % [str(kinds.get(str(r.get("k", "")), "")),
			str(r.get("d", "")), _t("whatsnew_player_n") % (str(r.get("p", "")) + ((" (%s)" % str(r.get("n", "")).replace("[", "(")) if not str(r.get("n", "")).is_empty() else "")),
			("  [color=#f2c752]%s[/color]" % _t("whatsnew_yours")) if mine else "",
			str(ST_COL.get(st, "#cccccc")), _t("whatsnew_st_" + st), (" " + str(r.get("ver", ""))) if st == "fixed" and not str(r.get("ver", "")).is_empty() else ""]
		out += "%s\n" % str(r.get("t", "")).left(300).replace("[", "(")
		if not str(r.get("c", "")).is_empty():
			out += "[color=#cfe3ff]💬 %s[/color]\n" % str(r.get("c", "")).replace("[", "(")
		out += "\n"
	return out.strip_edges()


## The player's number (shared with «Contact the developer»): made once, kept in this mod's settings too.
func player_id() -> String:
	var own := _me()
	if own.is_empty():
		var abc := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
		for i in 8:
			own += abc[randi() % abc.length()]
	if str(mod.get_setting("fb_player", "")) != own:
		mod.set_setting("fb_player", own)
	Engine.set_meta(PLAYER, own)
	return own


## «Memes and stories»: the players' best (config/stories.json — pictures from the mod's folder, texts), newest first.
func stories_fill(rt: RichTextLabel) -> void:
	rt.clear()
	var cfg: Variant = mod.load_json("config/stories.json", {})
	var list: Array = (cfg as Dictionary).get("histories", []) if cfg is Dictionary else []
	rt.append_text(_t("whatsnew_stories_intro") + "\n\n")
	if list.is_empty():
		rt.append_text("[color=#8d99a8]%s[/color]" % _t("whatsnew_stories_none"))
		return
	var me := _me()
	for i in range(list.size() - 1, -1, -1):
		if not (list[i] is Dictionary):
			continue
		var r: Dictionary = list[i]
		var mine := str(r.get("p", "")) == me
		rt.append_text("[b]%s[/b]  [color=#8d99a8]%s · %s[/color]%s\n" % [str(r.get("заголовок", "📸")), str(r.get("d", "")),
			_t("whatsnew_player_n") % str(r.get("p", "")), ("  [color=#f2c752]%s[/color]" % _t("whatsnew_yours")) if mine else ""])
		var pic := str(r.get("picture", ""))
		if not pic.is_empty():
			var tex: Variant = mod.call("texture", pic)
			if tex is Texture2D:
				rt.add_image(tex as Texture2D, mini(600, (tex as Texture2D).get_width()))
				rt.append_text("\n")
		if not str(r.get("t", "")).is_empty():
			rt.append_text(str(r.get("t", "")).replace("[", "(") + "\n")
		rt.append_text("\n")


func _share() -> void:
	var cfg: Variant = mod.load_json("config/feedback.json", {})
	var server := str((cfg as Dictionary).get("сервер", "")).strip_edges().trim_suffix("/") if cfg is Dictionary else ""
	if server.begins_with("https://"):
		var nick := _nick()
		mod.call("open_link", "%s/share?p=%s&l=%s&n=%s" % [server, player_id(), "ru" if TranslationServer.get_locale().begins_with("ru") else "en", nick.uri_encode()])


## The live list of the players' messages: the server's page (a mod may not go online itself).
func _feed(kind: String = "") -> void:
	var cfg: Variant = mod.load_json("config/feedback.json", {})
	var server := str((cfg as Dictionary).get("сервер", "")).strip_edges().trim_suffix("/") if cfg is Dictionary else ""
	if server.begins_with("https://"):
		mod.call("open_link", "%s/feed?l=%s&p=%s%s" % [server, "ru" if TranslationServer.get_locale().begins_with("ru") else "en", player_id(), "&k=" + kind if not kind.is_empty() else ""])


func players_count() -> int:
	var cfg: Variant = mod.load_json("config/feedback_log.json", {})
	return ((cfg as Dictionary).get("messages", []) as Array).size() if cfg is Dictionary else 0


func since_line() -> String:
	var s := seen()
	if _always and not s.is_empty() and not has_news():
		return _t("whatsnew_latest")
	return _t("whatsnew_since") % s if not s.is_empty() else _t("whatsnew_first")


## a > b for versions like «2.10.1».
static func newer(a: String, b: String) -> bool:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in maxi(pa.size(), pb.size()):
		var x := int(pa[i]) if i < pa.size() else 0
		var y := int(pb[i]) if i < pb.size() else 0
		if x != y:
			return x > y
	return false


# ---------- the shared window ----------

func is_open() -> bool:
	var o := _owner()
	return o != null


## The copy whose window is open now (any mod), or null.
static func _owner() -> Object:
	if not Engine.has_meta(WIN):
		return null
	var o: Variant = Engine.get_meta(WIN)
	if o is Object and is_instance_valid(o) and bool((o as Object).call("owns_window")):
		return o as Object
	return null


func owns_window() -> bool:
	return is_instance_valid(_panel)


func maybe_show() -> void:
	if not has_news():
		return
	var o := _owner()
	if o != null:
		o.call("add_source", self)
		return
	var hud := game.hud_layer() as CanvasLayer
	if hud == null:
		return
	_sources = [self]
	var reg: Dictionary = Engine.get_meta(REG, {}) if Engine.has_meta(REG) else {}
	for k in reg.keys():
		var other: Variant = reg[k]
		if other is Object and is_instance_valid(other) and other != self and bool((other as Object).call("has_news")):
			_sources.append(other)
	_build(hud)
	Engine.set_meta(WIN, self)


var _always := false              # opened by hand: every mod's tab, its latest versions even if seen


## Opened by hand (Pax Corpface's button under the date): every mod of the author, news or not; a second press
## closes it. Without anything unseen a mod shows its latest LATEST_SEEN versions.
func open_always() -> void:
	var o := _owner()
	if o != null:
		o.call("_close")
		return
	var hud := game.hud_layer() as CanvasLayer
	if hud == null:
		return
	_always = true
	_sources = [self]
	var reg: Dictionary = Engine.get_meta(REG, {}) if Engine.has_meta(REG) else {}
	for k in reg.keys():
		var other: Variant = reg[k]
		if other is Object and is_instance_valid(other) and other != self:
			(other as Object).set("_always", true)
			_sources.append(other)
	_build(hud)
	Engine.set_meta(WIN, self)


func add_source(src: Object) -> void:
	if not owns_window() or _sources.has(src):
		return
	_sources.append(src)
	_fill_tabs()


func _build(hud: CanvasLayer) -> void:
	_panel = PanelContainer.new()
	_panel.z_index = 60
	_panel.set_meta(&"pax_corp_skin_skip", true)
	_panel.set_meta(&"pax_interface_skip_skin", true)   # «Pax Interface» does not reskin our window
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.08, 0.11, 0.97)
	sb.border_color = GOLD
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	_panel.add_theme_stylebox_override("panel", sb)
	var outer := HBoxContainer.new()
	outer.add_theme_constant_override("separation", 16)
	_panel.add_child(outer)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	outer.add_child(v)
	_recs_panel = PanelContainer.new()
	var rsb := StyleBoxFlat.new()
	rsb.bg_color = Color(1, 1, 1, 0.04)
	rsb.border_color = Color(GOLD, 0.35)
	rsb.set_border_width_all(1)
	rsb.set_corner_radius_all(8)
	rsb.set_content_margin_all(12)
	_recs_panel.add_theme_stylebox_override("panel", rsb)
	_recs_panel.custom_minimum_size = Vector2(290, 0)
	outer.add_child(_recs_panel)
	_recs = VBoxContainer.new()
	_recs.add_theme_constant_override("separation", 10)
	_recs_panel.add_child(_recs)
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 6)
	v.add_child(_tabs)
	_title = Label.new()
	_title.add_theme_color_override("font_color", GOLD)
	_title.add_theme_font_size_override("font_size", 20)
	v.add_child(_title)
	_sub = Label.new()
	_sub.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	v.add_child(_sub)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(660, 430)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.scroll_active = false
	_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text.custom_minimum_size = Vector2(640, 0)
	_text.add_theme_font_size_override("normal_font_size", 14)
	_text.add_theme_font_size_override("bold_font_size", 15)
	scroll.add_child(_text)
	_share_row = HBoxContainer.new()
	_share_row.add_theme_constant_override("separation", 10)
	_share_row.visible = false
	v.add_child(_share_row)
	var share := Button.new()
	share.text = "📸 " + _t("whatsnew_share")
	share.tooltip_text = _t("whatsnew_share_tip")
	share.focus_mode = Control.FOCUS_NONE
	share.pressed.connect(func() -> void:
		if _active != null and _active.has_method("_share"):
			_active.call("_share"))
	_share_row.add_child(share)
	var memes_live := Button.new()
	memes_live.text = "🔄 " + _t("whatsnew_memes_live")
	memes_live.tooltip_text = _t("whatsnew_feed_tip")
	memes_live.focus_mode = Control.FOCUS_NONE
	memes_live.pressed.connect(func() -> void:
		if _active != null and _active.has_method("_feed"):
			_active.call("_feed", "story"))
	_share_row.add_child(memes_live)
	_feed_btn = Button.new()
	_feed_btn.text = "🔄 " + _t("whatsnew_feed")
	_feed_btn.tooltip_text = _t("whatsnew_feed_tip")
	_feed_btn.focus_mode = Control.FOCUS_NONE
	_feed_btn.visible = false
	_feed_btn.pressed.connect(func() -> void:
		if _active != null and _active.has_method("_feed"):
			_active.call("_feed"))
	v.add_child(_feed_btn)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	v.add_child(row)
	_never = CheckBox.new()
	_never.text = _t("whatsnew_never")
	_never.focus_mode = Control.FOCUS_NONE
	row.add_child(_never)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var close := Button.new()
	close.text = _t("whatsnew_close")
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(_close)
	row.add_child(close)
	_active = self
	_fill_tabs()
	_panel.add_child(WheelGuard.new())
	hud.add_child(_panel)
	_panel.reset_size()
	var view := _panel.get_viewport_rect().size
	_panel.position = ((view - _panel.size) / 2.0).max(Vector2(8, 8))


## The tabs on top (only when there are several mods) and the active mod's text.
func _fill_tabs() -> void:
	for c in _tabs.get_children():
		_tabs.remove_child(c)
		c.queue_free()
	_sources = _sources.filter(func(s): return is_instance_valid(s))
	if not _sources.has(_active):
		_active = self
	_tabs.visible = true
	for s in _sources:
		var src: Object = s
		var b := Button.new()
		b.text = "%s %s" % [str(src.call("display_name")), str(src.call("version"))]
		b.toggle_mode = true
		b.button_pressed = src == _active and not _players and not _stories
		b.focus_mode = Control.FOCUS_NONE
		if src == _active and not _players and not _stories:
			b.add_theme_color_override("font_color", GOLD)
			b.add_theme_color_override("font_pressed_color", GOLD)
		b.pressed.connect(func() -> void:
			_active = src
			_players = false
			_stories = false
			_fill_tabs())
		_tabs.add_child(b)
	# «From players» — what the players sent and what became of it.
	var pb := Button.new()
	pb.text = "🐞 " + _t("whatsnew_players") + " (%d)" % players_count()
	pb.toggle_mode = true
	pb.button_pressed = _players
	pb.focus_mode = Control.FOCUS_NONE
	pb.tooltip_text = _t("whatsnew_players_tip")
	if _players:
		pb.add_theme_color_override("font_color", GOLD)
		pb.add_theme_color_override("font_pressed_color", GOLD)
	pb.pressed.connect(func() -> void:
		_players = true
		_stories = false
		_fill_tabs())
	_tabs.add_child(pb)
	# «Memes and stories» — what players share from their games.
	var sb2 := Button.new()
	sb2.text = "📸 " + _t("whatsnew_stories")
	sb2.toggle_mode = true
	sb2.button_pressed = _stories
	sb2.focus_mode = Control.FOCUS_NONE
	sb2.tooltip_text = _t("whatsnew_stories_tip")
	if _stories:
		sb2.add_theme_color_override("font_color", GOLD)
		sb2.add_theme_color_override("font_pressed_color", GOLD)
	sb2.pressed.connect(func() -> void:
		_stories = true
		_players = false
		_fill_tabs())
	_tabs.add_child(sb2)
	if is_instance_valid(_share_row):
		_share_row.visible = _stories
	if is_instance_valid(_feed_btn):
		_feed_btn.visible = _players
	if _stories:
		_title.text = _t("whatsnew_stories_title")
		_sub.text = _t("whatsnew_stories_sub")
		_active.call("stories_fill", _text)
	elif _players:
		_title.text = _t("whatsnew_players_title")
		_sub.text = _t("whatsnew_players_sub")
		_text.text = players_body()
	else:
		_title.text = _t("whatsnew_title") % ("%s %s" % [str(_active.call("display_name")), str(_active.call("version"))])
		_sub.text = str(_active.call("since_line"))
		_text.text = str(_active.call("body"))
	_fill_recs()


## «Recommended mods» of the active tab's mod (hidden when it recommends none).
func _fill_recs() -> void:
	if not is_instance_valid(_recs):
		return
	for c in _recs.get_children():
		_recs.remove_child(c)
		c.queue_free()
	var list: Array = _active.call("recommendations") if _active.has_method("recommendations") else []
	_recs_panel.visible = not list.is_empty()
	if list.is_empty():
		return
	var title := Label.new()
	title.text = _t("whatsnew_recs")
	title.add_theme_color_override("font_color", GOLD)
	title.add_theme_font_size_override("font_size", 16)
	_recs.add_child(title)
	for r in list:
		var d: Dictionary = r
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", 2)
		_recs.add_child(card)
		var nm := Label.new()
		nm.text = str(d["имя"])
		nm.add_theme_font_size_override("font_size", 14)
		card.add_child(nm)
		var st := Label.new()
		st.text = _t("whatsnew_rec_have") if bool(d["has_flag"]) else _t("whatsnew_rec_find") % str(d["имя"])
		st.add_theme_font_size_override("font_size", 11)
		st.add_theme_color_override("font_color", Color(0.4, 0.85, 0.6) if bool(d["has_flag"]) else Color(GOLD, 0.9))
		st.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		st.custom_minimum_size = Vector2(260, 0)
		card.add_child(st)
		var tx := Label.new()
		tx.text = str(d["текст"])
		tx.add_theme_font_size_override("font_size", 12)
		tx.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
		tx.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tx.custom_minimum_size = Vector2(260, 0)
		card.add_child(tx)
	var note := Label.new()
	note.text = _t("whatsnew_rec_store")
	note.add_theme_font_size_override("font_size", 11)
	note.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(260, 0)
	_recs.add_child(note)


func _close() -> void:
	if is_instance_valid(_never) and _never.button_pressed:
		for s in _sources:
			if is_instance_valid(s):
				(s as Object).call("mark_seen")   # not until each mod's next version
	_drop_window()


func _drop_window() -> void:
	if is_instance_valid(_panel):
		_panel.queue_free()
	_panel = null
	_never = null
	_sources = []
	if Engine.has_meta(WIN) and Engine.get_meta(WIN) == self:
		Engine.remove_meta(WIN)


func teardown() -> void:
	_drop_window()
	if Engine.has_meta(REG):
		var reg: Dictionary = Engine.get_meta(REG)
		if reg.get(_id) == self:
			reg.erase(_id)
