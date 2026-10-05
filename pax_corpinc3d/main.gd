extends PaxMod
## Pax CorpInc3D — the 3D objects of the Pax CorpInc mods. Now: the companies' buildings of Pax Corporations as real
## 3D models on the 3D Earth (src/globe.gd: models/*.glb, config/models.json; the sites from Pax Corporations'
## api.sites_3d). photo.gd keeps which model a site gets. Without Pax Corporations it does nothing.
## Settings (its window «3D», settings/panel_3d.gd): the quality mode off | eco | normal | max | custom, its options,
## the automatic step down when the game lags (settings/quality_ctl.gd). Console: inc3d on|off|eco|normal|max.

const Photo := preload("res://mods/pax_corpinc3d/src/globe/photo.gd")
const Globe := preload("res://mods/pax_corpinc3d/src/globe/globe.gd")
const Earth := preload("res://mods/pax_corpinc3d/src/earth/earth.gd")
const Descent := preload("res://mods/pax_corpinc3d/src/earth/descent.gd")
const GlobeLayers := preload("res://mods/pax_corpinc3d/src/layers/globe_layers.gd")
const Experimental := preload("res://mods/pax_corpinc3d/src/notice/experimental.gd")
const Satellites := preload("res://mods/pax_corpinc3d/src/earth/satellites.gd")
const Forest := preload("res://mods/pax_corpinc3d/src/forest/forest.gd")
const WhatsNew := preload("res://mods/pax_corpinc3d/src/shared/whatsnew.gd")
const Panel3D := preload("res://mods/pax_corpinc3d/src/settings/panel_3d.gd")   # the window «3D»
const Gear := preload("res://mods/pax_corpinc3d/src/settings/gear.gd")         # its gear at the bottom left
const FlatClean := preload("res://mods/pax_corpinc3d/src/core/flat_clean.gd")  # the other mods' 2D buildings and roads off
# The parts of the mod's work, each its own object (src/<feature>/*_ctl.gd, each holds «app» — this object).
# main.gd only registers: modules, shared state and one-line entry points with the old names (the game's
# callbacks, the windows, the other mods' api.call, the console). New logic goes into a part, not here.
const LifeCtl := preload("res://mods/pax_corpinc3d/src/core/life_ctl.gd")
const QualityCtl := preload("res://mods/pax_corpinc3d/src/settings/quality_ctl.gd")
const META := &"pax_corpinc3d"

var photo: Photo
var globe: Globe                     # the buildings on the 3D Earth (globe.gd)
var earth: Earth                     # Earth HD: the globe drawn with real maps (earth.gd)
var descent: Descent                 # down into the atmosphere past the game's nearest zoom (descent.gd)
var layers: GlobeLayers              # the flat map's layers on the 3D Earth (globe_layers.gd)
var experimental: Experimental       # the warning at the start: experimental, heavy, at your own risk
var satellites: Satellites           # the Earth's satellites in the new model (satellites.gd)
var forest: Forest                   # trees where NASA's pictures show forest (forest/forest.gd)
var gear: Gear                       # the «3D» settings behind a gear above the chronicle (settings/gear.gd)
var flat_clean: FlatClean            # the flat map without the mods' buildings and roads (core/flat_clean.gd)
var whatsnew: WhatsNew
var game: PaxGame


var life_ctl: LifeCtl = LifeCtl.new(self)            # the mod's life
var quality_ctl: QualityCtl = QualityCtl.new(self)   # the 3D quality: modes, options, the automatic step down


func _mod_loaded() -> void:
	life_ctl._mod_loaded()


func _mod_unloaded() -> void:
	life_ctl._mod_unloaded()


func _world_ready(g: PaxGame) -> void:
	life_ctl._world_ready(g)


func set_on(on: bool) -> void:
	life_ctl.set_on(on)


func set_quality(quality: String) -> void:
	quality_ctl.choose(quality)


func set_option(key: String, value: Variant) -> void:
	quality_ctl.change(key, value)


func quality_status() -> Dictionary:
	return quality_ctl.status()
