extends SceneTree
## Pax CorpInc3D: a big Earth map baked once for the video card — mipmapped and compressed (S3TC/BC1, sRGB), saved as
## DDS next to it. The mod then only reads it (earth.gd: a .dds beside the .jpg is taken first): no decoding, no
## mipmaps, no compressing at every start (that was the long first load).
##   godot --headless -s tools/bake_dds.gd -- pax_corpinc3d/textures/earth/day.jpg pax_corpinc3d/textures/earth/night.jpg

func _init() -> void:
	for path in OS.get_cmdline_user_args():
		var t0 := Time.get_ticks_msec()
		var img := Image.load_from_file(path)
		if img == null or img.is_empty():
			push_error("cannot read " + path)
			continue
		img.convert(Image.FORMAT_RGB8)
		img.generate_mipmaps()
		img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
		var out := path.get_basename() + ".dds"
		var err := img.save_dds(out)
		print("%s → %s: %dx%d, %d mipmaps, %s, %d ms" % [path, out, img.get_width(), img.get_height(), img.get_mipmap_count(), "ok" if err == OK else "error %d" % err, Time.get_ticks_msec() - t0])
	quit()
