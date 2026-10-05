shader_type spatial;
render_mode cull_back;

// Pax CorpInc3D — the Earth from orbit (src/earth/earth.gd puts it on the Earth's material).
// The game's own planet shader (res://shaders/planet.gdshader) with real maps on top: the surface itself is still the
// game's (planet_surface.gdshaderinc — its colour map, climate, floods, snow, the cities it grows), so nothing the game
// shows of the world's state is lost. Added, each only when its map is there (use_* = 1):
//   night_map  — city lights at night (NASA Black Marble); the game's own procedural lights stay, dimmer (proc_lights);
//   relief_map — elevation (NASA/GEBCO): mountains and valleys lit by the sun through the normal;
//   water_map  — a sharp water mask: the sea is smooth and glints, the land is rough;
//   clouds_map — the cloud shell's map: the clouds' shadows on the ground (cloud_basis turns with the shell);
// and a softer atmosphere: a blue limb by day, orange at the terminator, the far ground hazed.
// Names are Latin only (the shader language has no Cyrillic).

#include "res://shaders/planet_surface.gdshaderinc"

// The real colour of the map (map_albedo — the game's own colour map, or the NASA one that replaces it): the game
// takes only the brightness from it and colours the land by the planet's state (biomass greens ALL the land), so
// deserts, forests, tundra and snow vanish. real_color brings the map's colour back over the land and the sea;
// what the game changed stays the game's: scorched land, cities, a sea where the map has land (a flood).
uniform float real_color : hint_range(0.0, 1.0) = 0.85;
uniform float real_gain : hint_range(0.3, 2.5) = 1.15;

// Countries and provinces (the game gives the globe region_map, region_pal — the owner's colour by province id —
// and region_flags: R ours, G someone's, B selected, A known). The borders come from borders_ids (A: this province,
// B: the one across the nearest border) and borders_dist (the distance to that border, smoothed and upsampled from
// the game's province map — no staircase), so a line of any width is a smooth curve. A country's border is where
// A and B have different owners; it follows the owners at once when a province changes hands.
uniform sampler2D borders_ids : filter_nearest, repeat_disable;
uniform sampler2D borders_dist : filter_linear, repeat_enable;
uniform float use_borders : hint_range(0.0, 1.0) = 0.0;
uniform float country_width : hint_range(0.0, 8.0) = 1.2;      // screen pixels
uniform float country_alpha : hint_range(0.0, 1.0) = 0.22;
uniform float province_width : hint_range(0.0, 4.0) = 0.6;
uniform float province_alpha : hint_range(0.0, 1.0) = 0.06;
uniform float province_far : hint_range(0.5, 20.0) = 1.6;      // map texels per pixel past which province lines fade
uniform float fill_alpha : hint_range(0.0, 1.0) = 0.0;          // the owner's colour over the land (0 — the real Earth)
uniform float edge_glow : hint_range(0.0, 1.0) = 0.06;         // a faint tint of the owner's colour along its border
uniform float edge_glow_px : hint_range(1.0, 60.0) = 10.0;
uniform vec3 our_border : source_color = vec3(0.95, 0.85, 0.62);
// Realism (as in Terra Invicta): the borders are thin light lines over the real Earth, no bright colours, no glow;
// the owner's colour only hints in them (border_tint). The player's own border is a little warmer and stronger.
uniform vec3 border_color : source_color = vec3(0.90, 0.90, 0.86);
uniform float border_tint : hint_range(0.0, 1.0) = 0.12;
uniform float our_alpha : hint_range(0.0, 1.0) = 0.3;
uniform float border_glow : hint_range(0.0, 1.0) = 0.0;
uniform float country_far_alpha : hint_range(0.0, 1.0) = 0.4;
uniform float country_far_width : hint_range(1.0, 4.0) = 1.8;   // the borders widen as the planet gets smaller on screen  // the borders' strength when the whole planet is on screen
// The country the player is looking at (its statistics, its card): its border is outlined clearly, the rest stay
// faint. focus_color — that country's owner colour (region_pal), focus_on 0..1 (src/earth/earth.gd focus_country).
uniform vec3 focus_color = vec3(0.0);
uniform float focus_on : hint_range(0.0, 1.0) = 0.0;
uniform vec3 focus_line : source_color = vec3(1.0, 0.93, 0.72);
uniform float focus_alpha : hint_range(0.0, 1.0) = 0.85;
uniform float focus_width : hint_range(0.0, 8.0) = 2.2;
// The country clicked on the globe (src/layers/globe_layers.gd → earth.gd select_country): its land a little lighter, a
// slow pulse of light along its inner edge, a bright outline — unlike the outline of focus_country.
// The economic zones (Pax Corporations' layer «Экономические зоны», earth.gd _update_zones): by a province's id its
// zone's colour (A — 0 outside any zone); the members' land tinted, a line where one zone meets another or none.
uniform sampler2D zone_pal : filter_nearest, repeat_disable;
uniform float use_zones = 0.0;
uniform float zone_alpha : hint_range(0.0, 1.0) = 0.38;
uniform float zone_line_px : hint_range(0.0, 8.0) = 2.4;
uniform vec3 sel_color = vec3(0.0);
uniform float sel_on : hint_range(0.0, 1.0) = 0.0;
uniform vec3 sel_line : source_color = vec3(0.55, 0.95, 1.0);
uniform float sel_fill : hint_range(0.0, 1.0) = 0.18;
uniform float sel_width : hint_range(0.0, 8.0) = 2.6;
uniform float sel_glow_px : hint_range(0.0, 60.0) = 12.0;

// The ground in 3D: height_map (R high, G low byte of 0..6400 m, the sea 0) raises the vertices, height_exag times
// the real height (the Earth's 8.8 km are 0.14 % of its radius — invisible without it). The mesh is fine enough near
// the camera (src/earth/terrain.gd: chunks with levels of detail); the game's own procedural relief is off then.
uniform sampler2D height_map : filter_nearest, repeat_enable;
uniform float use_height_map : hint_range(0.0, 1.0) = 0.0;
uniform float height_exag : hint_range(0.0, 40.0) = 3.5;

uniform sampler2D night_map : source_color, hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float use_night : hint_range(0.0, 1.0) = 0.0;
uniform float night_gain : hint_range(0.0, 8.0) = 2.2;
// The game's own procedural cities (blocks, windows, fields round them): 0 — off, the real cities stand instead
// (urban.png, Black Marble, towns.gd).
uniform float aurora_k : hint_range(0.0, 1.0) = 0.25;   // the aurora's strength (the game's × 1)
uniform float game_city : hint_range(0.0, 1.0) = 0.0;
uniform float proc_lights : hint_range(0.0, 1.0) = 0.3;

uniform sampler2D relief_map : hint_default_black, filter_linear_mipmap, repeat_enable;   // RG — slope east, north
uniform float use_relief : hint_range(0.0, 1.0) = 0.0;
uniform float relief_strength : hint_range(0.0, 40.0) = 10.0;   // the slope's exaggeration for the light

uniform sampler2D water_map : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float use_water : hint_range(0.0, 1.0) = 0.0;
uniform float sea_roughness : hint_range(0.0, 1.0) = 0.45;

// The ground seen close (textures/earth/detail.png, earth_maps.py detail): tiling patterns — R forest and fields,
// G sand, B rock, A snow, grey 0.5 = flat. The colour stays the map's; where the map blurs (one of its texels wider
// than a few pixels) the pattern of the ground there (by the map's colour and the slope) adds texture and small
// relief lit by the sun. Two sizes, detail_km and ×7 finer, laid on the sphere from three sides (no poles' pinch).
uniform sampler2D detail_map : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float use_detail : hint_range(0.0, 1.0) = 0.0;
uniform float detail_km : hint_range(0.5, 100.0) = 8.0;
uniform float detail_strength : hint_range(0.0, 2.0) = 0.6;
uniform float detail_bump : hint_range(0.0, 4.0) = 1.0;
uniform float sharpen : hint_range(0.0, 2.0) = 0.8;        // the map's own small contrast, raised where it is magnified
uniform float fields : hint_range(0.0, 1.0) = 0.5;         // the patchwork of fields on flat farmland
uniform float field_km : hint_range(0.5, 30.0) = 4.0;
// Cities: the built-up area (textures/earth/urban.png from GeoNames cities, earth_maps.py cities) — concrete and
// roofs instead of green fields under the cities' buildings, and their lights at night.
uniform sampler2D urban_map : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float use_urban = 0.0;
uniform vec3 urban_color : source_color = vec3(0.5, 0.48, 0.44);
uniform float urban_strength : hint_range(0.0, 1.0) = 0.75;
uniform vec3 urban_light : source_color = vec3(1.0, 0.78, 0.45);
uniform float urban_glow : hint_range(0.0, 4.0) = 1.2;
uniform float lakes : hint_range(0.0, 1.0) = 1.0;
uniform vec3 lake_color : source_color = vec3(0.03, 0.11, 0.24);
// The clouds' shadows fade as the clouds themselves do up close (shaders/earth_clouds.gdshader near_alpha…).
uniform float cloud_near_alpha : hint_range(0.0, 1.0) = 0.25;
uniform float cloud_near_km = 400.0;
uniform float cloud_far_km = 3000.0;
uniform sampler2D clouds_map : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float use_cloud_shadow : hint_range(0.0, 1.0) = 0.0;
uniform float cloud_shadow : hint_range(0.0, 1.0) = 0.35;
uniform mat3 cloud_basis = mat3(1.0);   // the Earth's local direction → the cloud shell's local direction

uniform vec3 sky_day : source_color = vec3(0.32, 0.58, 1.0);
uniform vec3 sky_dusk : source_color = vec3(1.0, 0.46, 0.18);
uniform float air_glow : hint_range(0.0, 3.0) = 1.0;
uniform float haze : hint_range(0.0, 1.0) = 0.25;
uniform float air_height : hint_range(0.0001, 0.02) = 0.0016;    // the air's scale height, Earth radii (~10 km)
uniform vec3 horizon_haze : source_color = vec3(0.66, 0.76, 0.88);  // the far ground seen from inside the air
uniform float haze_inside : hint_range(0.0, 1.0) = 0.7;
uniform float air_thickness : hint_range(1.0, 60.0) = 20.0;      // paths this many heights long are fully hazed

varying vec3 local_pos;

// A map in the equirectangular layout the game uses (sph_uv), without the seam where the longitude wraps: the
// derivatives are taken across the seam the short way round, so the mip level stays right. (One helper per sampler
// is not allowed for samplers with different hints, so the uv and its derivatives are shared and each map reads itself.)
struct EqUv {
	vec2 uv;
	vec2 dx;
	vec2 dy;
};

EqUv eq_uv(vec3 n) {
	EqUv o;
	o.uv = sph_uv(n);
	o.dx = dFdx(o.uv);
	o.dy = dFdy(o.uv);
	o.dx.x -= round(o.dx.x);
	o.dy.x -= round(o.dy.x);
	return o;
}

// A macro, not a function: a function may not take samplers with different hints.
#define EQ(t, n) textureGrad(t, eq_uv(n).uv, eq_uv(n).dx, eq_uv(n).dy)
// A cell of a grid on the cube's faces around a direction (the fields): its id (3D) and the place inside it.
vec3 field_cell(vec3 n, float k, out vec2 inside) {
	vec3 a = abs(n);
	vec3 f;
	if (a.x >= a.y && a.x >= a.z) {
		f = vec3(n.z / a.x, n.y / a.x, n.x > 0.0 ? 0.0 : 1.0);
	} else if (a.y >= a.z) {
		f = vec3(n.x / a.y, n.z / a.y, n.y > 0.0 ? 2.0 : 3.0);
	} else {
		f = vec3(n.x / a.z, n.y / a.z, n.z > 0.0 ? 4.0 : 5.0);
	}
	vec2 p = f.xy * k;
	// Rows of fields, a little skewed per region, as the land was cut.
	p += 0.35 * sin(p.yx * 0.11 + f.z);
	inside = fract(p);
	return vec3(floor(p), f.z);
}

float field_hash(vec3 c) {
	return fract(sin(dot(c, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

// The detail patterns at a direction: triplanar on the unit sphere, k tiles per Earth radius.
vec4 detail_at(vec3 n, float k) {
	vec3 w = pow(abs(n), vec3(4.0));
	w /= (w.x + w.y + w.z);
	vec3 p = n * k;
	return texture(detail_map, p.zy) * w.x + texture(detail_map, p.xz + vec2(0.37, 0.61)) * w.y + texture(detail_map, p.xy + vec2(0.71, 0.13)) * w.z;
}

// The height at a direction, 0..1 (× 6400 m): bilinear by hand over the 16-bit byte pairs.
float h_texel(ivec2 p, ivec2 sz) {
	p.x = (p.x % sz.x + sz.x) % sz.x;
	p.y = clamp(p.y, 0, sz.y - 1);
	vec4 t = texelFetch(height_map, p, 0);
	return (t.r * 255.0 * 256.0 + t.g * 255.0) / 65535.0;
}

float ground_h(vec3 n) {
	ivec2 sz = textureSize(height_map, 0);
	vec2 f = sph_uv(n) * vec2(sz) - vec2(0.5);
	ivec2 p = ivec2(floor(f));
	vec2 w = fract(f);
	float a = mix(h_texel(p, sz), h_texel(p + ivec2(1, 0), sz), w.x);
	float b = mix(h_texel(p + ivec2(0, 1), sz), h_texel(p + ivec2(1, 1), sz), w.x);
	return mix(a, b, w.y);
}

// The ground's radius at a direction (1 — the sea): 6400 m = 0.001 of the Earth's radius, × height_exag.
float ground_r(vec3 n) {
	return 1.0 + ground_h(n) * 0.0010046 * height_exag;
}

void vertex() {
	vec3 n = normalize(VERTEX);
	if (use_height_map > 0.5) {
		// Skirts of the terrain chunks (COLOR.r = 0; a mesh without colours reads white) hang a little below the
		// ground: no cracks between neighbouring chunks of different detail.
		float skirt = (1.0 - COLOR.r) * 0.0015;
		vec3 ref0 = mix(vec3(0.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), step(0.99, abs(n.y)));
		vec3 t0 = normalize(cross(ref0, n));
		vec3 b0 = cross(n, t0);
		ivec2 hs = textureSize(height_map, 0);
		float e0 = 3.14159265 / float(max(hs.y, 1)) * 1.5;
		vec3 na0 = normalize(n + t0 * e0);
		vec3 nb0 = normalize(n + b0 * e0);
		vec3 q0 = n * (ground_r(n) - skirt);
		vec3 q1 = na0 * ground_r(na0);
		vec3 q2 = nb0 * ground_r(nb0);
		VERTEX = q0;
		NORMAL = normalize(cross(q1 - n * ground_r(n), q2 - n * ground_r(n)));
		local_pos = n;
	} else {

	vec3 ref = mix(vec3(0.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), step(0.99, abs(n.y)));
	vec3 t = normalize(cross(ref, n));
	vec3 b = cross(n, t);

	float eps = 0.012;
	vec3 na = normalize(n + t * eps);
	vec3 nb = normalize(n + b * eps);

	vec3 p0 = n * (1.0 + displace(n));
	vec3 p1 = na * (1.0 + displace(na));
	vec3 p2 = nb * (1.0 + displace(nb));

	VERTEX = p0;
	NORMAL = normalize(cross(p1 - p0, p2 - p0));
	local_pos = n;
	}
}

// One texel of the province map: its owner's fill (colour, strength), whether it is the selected country, its zone.
void prov_tap(ivec2 at, ivec2 bs, out vec3 own_c, out float own_k, out float sel, out vec4 zone) {
	vec4 t = texelFetch(borders_ids, ivec2(((at.x % bs.x) + bs.x) % bs.x, clamp(at.y, 0, bs.y - 1)), 0);
	int id = int(t.r * 255.0 + 0.5) + int(t.g * 255.0 + 0.5) * 256;
	ivec2 ps = textureSize(region_pal, 0);
	own_c = vec3(0.0);
	own_k = 0.0;
	sel = 0.0;
	zone = vec4(0.0);
	if (id <= 0 || id >= ps.x) {
		return;
	}
	vec4 pal = texelFetch(region_pal, ivec2(id, 0), 0);
	vec4 fl = texelFetch(region_flags, ivec2(id, 0), 0);
	if (fl.g > 0.5) {
		own_c = pal.rgb * 0.9 + vec3(0.05);
		own_k = fill_alpha * (fl.r > 0.5 ? 1.25 : 1.0);
		sel = (sel_on > 0.0 && distance(pal.rgb, sel_color) < 0.002) ? 1.0 : 0.0;
	}
	ivec2 zs = textureSize(zone_pal, 0);
	if (use_zones > 0.5 && id < zs.x) {
		zone = texelFetch(zone_pal, ivec2(id, 0), 0);
	}
}

void fragment() {
	vec3 n = normalize(local_pos);
	Surface s = surface(n);
	vec3 col = s.col;
	vec3 sp = s.sp;
	float land = s.land;
	float depth = s.depth;
	float lat = s.lat;
	float T = s.T;
	float RAD = s.RAD;
	float greening = s.greening;
	float heat = s.heat;
	float cold = s.cold;
	float city = s.city * game_city;
	float city_land = s.city_land * game_city;
	float city_sea = s.city_sea * game_city;
	float submerged = s.submerged * game_city;
	float sea_life = s.sea_life;
	float lava_frac = s.lava_frac;
	float cracks = s.cracks;
	float kind = s.kind;
	float lit = s.lit;
	float street = s.street * game_city;
	float legible_b = s.legible_b;
	float shine = s.shine;

	// ---- the real colour of the map ----
	float map_sea_here = use_water > 0.5 ? EQ(water_map, (n)).r : 1.0 - land;
	if (use_map > 0.5 && real_color > 0.0) {
		vec3 mc = EQ(map_albedo, (n)).rgb * real_gain;
		float own = real_color * (1.0 - s.burn) * (1.0 - city * 0.85) * (1.0 - lava_frac);
		// The map's colour everywhere, but where the game has water over the map's land (a flood), the game's water
		// stays. (Gating land on land and sea on sea left a dark seam where two masks differ by a pixel at the coast.)
		float here = 1.0 - (1.0 - land) * (1.0 - map_sea_here) * smoothstep(0.3, 0.9, 1.0 - land);
		col = mix(col, mc, own * here);
	}

	// ---- countries and provinces ----
	vec3 pol_light = vec3(0.0);
	if (use_borders > 0.5 && use_regions > 0.5) {
		vec2 buv = sph_uv(n);
		ivec2 bs = textureSize(borders_ids, 0);
		ivec2 bp = ivec2(int(fract(buv.x) * float(bs.x)), int(clamp(buv.y, 0.0, 0.99999) * float(bs.y)));
		vec4 ab = texelFetch(borders_ids, bp, 0);
		int ia = int(ab.r * 255.0 + 0.5) + int(ab.g * 255.0 + 0.5) * 256;
		int ib = int(ab.b * 255.0 + 0.5) + int(ab.a * 255.0 + 0.5) * 256;
		EqUv e = eq_uv(n);
		float tpp = max(max(length(e.dx * vec2(bs)), length(e.dy * vec2(bs))), 1e-4);   // texels per screen pixel
		float dpx = textureLod(borders_dist, buv, 0.0).r * 255.0 / 32.0 / tpp;          // distance in screen pixels
		ivec2 ps = textureSize(region_pal, 0);
		vec4 pa = (ia > 0 && ia < ps.x) ? texelFetch(region_pal, ivec2(ia, 0), 0) : vec4(0.0);
		vec4 pb = (ib > 0 && ib < ps.x) ? texelFetch(region_pal, ivec2(ib, 0), 0) : vec4(0.0);
		vec4 fa = (ia > 0 && ia < ps.x) ? texelFetch(region_flags, ivec2(ia, 0), 0) : vec4(0.0);
		vec4 fb = (ib > 0 && ib < ps.x) ? texelFetch(region_flags, ivec2(ib, 0), 0) : vec4(0.0);
		// Owned by someone (G), known to the player or not (A): with «known» required, the borders of the countries the
		// player had not met were not drawn. Owners differ by their colour's bytes: one byte apart is another country.
		bool own_a = fa.g > 0.5;
		bool own_b = fb.g > 0.5;
		bool same = (own_a == own_b) && (!own_a || distance(pa.rgb, pb.rgb) < 0.002);
		// The game's province map is coarser than the coast: the owner's colour stays on the land only.
		float on_land = clamp(land * (1.0 - map_sea_here * use_water), 0.0, 1.0);
		float land_day = on_land;
		// The fills (the owner's colour, the selection, the zones) from the province map's texels. Close in one texel
		// is many screen pixels: the nearest texel alone drew every border as a staircase; there the four texels
		// around are blended by their distance (a soft edge one texel wide that follows the smooth line).
		vec3 f_c = vec3(0.0);
		float f_k = 0.0;
		float f_sel = 0.0;
		vec4 f_zone = vec4(0.0);
		if (tpp < 1.5) {
			vec2 tx = vec2(fract(buv.x) * float(bs.x), clamp(buv.y, 0.0, 0.99999) * float(bs.y)) - 0.5;
			ivec2 b0 = ivec2(floor(tx));
			vec2 w = fract(tx);
			for (int j = 0; j < 4; j++) {
				ivec2 o = ivec2(j % 2, j / 2);
				float wt = (o.x == 1 ? w.x : 1.0 - w.x) * (o.y == 1 ? w.y : 1.0 - w.y);
				vec3 c;
				float k;
				float sl;
				vec4 z;
				prov_tap(b0 + o, bs, c, k, sl, z);
				f_c += c * k * wt;
				f_k += k * wt;
				f_sel += sl * wt;
				f_zone += vec4(z.rgb * z.a, z.a) * wt;
			}
			f_c /= max(f_k, 1e-5);
			f_zone.rgb /= max(f_zone.a, 1e-5);
		} else {
			prov_tap(bp, bs, f_c, f_k, f_sel, f_zone);
		}
		// The owner's colour over its land, a little stronger along its border (like a district in a city builder).
		if (f_k > 0.0) {
			float near_edge = (ia > 0 && own_a && !same && ib > 0) ? 1.0 - smoothstep(0.0, edge_glow_px, dpx) : 0.0;
			float k = f_k + edge_glow * near_edge * min(f_k / max(fill_alpha, 1e-4), 1.0);
			col = mix(col, f_c, clamp(k, 0.0, 0.85) * land_day);
		}
		if (use_zones > 0.5) {
			ivec2 zs = textureSize(zone_pal, 0);
			vec4 za = (ia > 0 && ia < zs.x) ? texelFetch(zone_pal, ivec2(ia, 0), 0) : vec4(0.0);
			vec4 zb = (ib > 0 && ib < zs.x) ? texelFetch(zone_pal, ivec2(ib, 0), 0) : vec4(0.0);
			col = mix(col, f_zone.rgb, f_zone.a * zone_alpha * land_day);
			if (ia > 0 && ib > 0 && ia != ib && za.a > 0.0 && distance(za, zb) > 0.01) {
				float zl = 1.0 - smoothstep(zone_line_px * 0.5, zone_line_px * 0.5 + 1.0, dpx);
				col = mix(col, za.rgb * 1.15 + vec3(0.05), zl * 0.9);
				pol_light += za.rgb * zl * 0.3;
			}
		}
		bool sel_a = sel_on > 0.0 && ia > 0 && own_a && distance(pa.rgb, sel_color) < 0.002;
		if (f_sel > 0.0) {
			col = mix(col, mix(col, vec3(1.0), 0.6), sel_fill * sel_on * land_day * f_sel);
		}
		if (ia > 0 && ib > 0 && ia != ib) {
			if (!same) {
				bool ours = fa.r > 0.5 || fb.r > 0.5;
				float w = country_width * (ours ? 1.25 : 1.0) * mix(1.0, country_far_width, smoothstep(2.0, 8.0, tpp));
				// From far away (the whole planet on screen) the lines are fainter still — the Earth comes first.
				float far_k = mix(1.0, country_far_alpha, smoothstep(2.0, 8.0, tpp));
				float line = (1.0 - smoothstep(w * 0.5, w * 0.5 + 1.0, dpx)) * (ours ? our_alpha : country_alpha) * far_k;
				vec3 lc = ours ? our_border : mix(border_color, mix(pa.rgb, pb.rgb, 0.5), border_tint);
				col = mix(col, lc, line);
				pol_light += lc * line * border_glow;
				// The chosen country: a clear outline on its side of the border, a soft light inside it along the edge.
				if (focus_on > 0.0) {
					bool fa_in = own_a && distance(pa.rgb, focus_color) < 0.002;
					bool fb_in = own_b && distance(pb.rgb, focus_color) < 0.002;
					if (fa_in != fb_in) {
						float fl = (1.0 - smoothstep(focus_width * 0.5, focus_width * 0.5 + 1.0, dpx)) * focus_alpha * focus_on;
						col = mix(col, focus_line, fl);
						pol_light += focus_line * fl * 0.25;
						if (fa_in) {
							col = mix(col, focus_line, (1.0 - smoothstep(0.0, 18.0, dpx)) * 0.12 * focus_on);
						}
					}
				}
				if (sel_on > 0.0) {
					bool sel_b = own_b && distance(pb.rgb, sel_color) < 0.002;
					if (sel_a != sel_b) {
						float sl = (1.0 - smoothstep(sel_width * 0.5, sel_width * 0.5 + 1.0, dpx)) * sel_on;
						col = mix(col, sel_line, sl);
						pol_light += sel_line * sl * 0.4;
						if (sel_a) {
							float pulse = 0.75 + 0.25 * sin(TIME * 2.4);
							float inner = (1.0 - smoothstep(0.0, sel_glow_px, dpx)) * 0.35 * pulse * sel_on;
							col = mix(col, sel_line, inner);
							pol_light += sel_line * inner * 0.3;
						}
					}
				}
			} else {
				float fade = 1.0 - smoothstep(province_far * 0.6, province_far, tpp);
				float line = (1.0 - smoothstep(province_width * 0.5, province_width * 0.5 + 1.0, dpx)) * province_alpha * fade;
				col = mix(col, border_color, line * max(on_land, 0.3));
			}
		}
		// The province the player chose: a white outline inside it.
		if (ia > 0 && fa.b > 0.9) {
			float sel = 1.0 - smoothstep(1.2, 2.4, dpx);
			col = mix(col, vec3(1.0), sel * (ib != ia ? 1.0 : 0.0));
			col = mix(col, vec3(1.0), 0.08);
		}
	}

	vec3 sun = normalize(sun_dir);
	float ndl = dot(n, sun);
	float night = smoothstep(0.10, -0.20, ndl);
	float day = 1.0 - night;

	// ---- the sea: a sharp mask when there is one; the sea glints, the land does not ----
	float sea = 1.0 - max(land, city);
	if (use_water > 0.5) {
		// The game's own sea (floods, a risen ocean) wins where it is wider than the map's.
		sea = max(EQ(water_map, (n)).r * (1.0 - city), 1.0 - max(land, city));
	}
	// Inland water the game's ocean mask does not know (the Great Lakes, Baikal, Ladoga…): in the map's real colours
	// it is dark and bluer than green or red — drawn as water (blue, with the sea's sheen), not as black land.
	if (lakes > 0.0) {
		// The map's own colour (sRGB-ish): lakes in it are near black (Superior 0,3,6 of 255; Erie greenish 0,6,4) —
		// darker than any forest or taiga — and their blue is not far below their green.
		vec3 lc0 = sqrt(max(EQ(map_albedo, (n)).rgb, vec3(0.0)));
		float llum = dot(lc0, vec3(0.3, 0.59, 0.11));
		float lake = (1.0 - smoothstep(0.035, 0.07, llum)) * smoothstep(0.35, 0.6, lc0.b / max(lc0.g, 0.004)) * (1.0 - sea) * lakes;
		col = mix(col, lake_color, lake);
		sea = max(sea, lake);
	}

	// The air is measured against the round planet, not the relief: a steep slope must not glow like the limb.
	// The air between the eye and the ground: how long the look travels through it. From orbit the column is short
	// in the middle of the disc and long at the limb (the blue rim); inside the atmosphere the near ground is clear and
	// the horizon hazes (aerial perspective). L = min(distance, H / cos(zenith)), in the Earth's radii.
	float earth_r = max(length(MODEL_MATRIX[0].xyz), 1e-6);
	vec3 up_v = normalize((VIEW_MATRIX * (MODEL_MATRIX * vec4(n, 0.0))).xyz);
	float cosz = max(dot(up_v, normalize(-VERTEX)), 0.015);
	float path = min(length(VERTEX) / earth_r, air_height / cosz);
	float fres = 1.0 - exp(-path / (air_height * air_thickness));
	// The eye inside the air (descent.gd): the far ground fades into the pale horizon, not the deep blue of the limb.
	vec3 eye_local = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	float inside = 1.0 - smoothstep(air_height * 3.0, air_height * 25.0, length(eye_local) - 1.0);

	// ---- relief: the normal from the elevation map ----
	vec3 nn = n;
	float steep = 0.0;
	if (use_relief > 0.5) {
		// relief.png (pax_corporations_dev/earth_maps.py): the slope of the smoothed ground, m per m, stored ×12
		// around 0.5 (SLOPE_SCALE there). Filtered like any map, so plains stay smooth (an 8-bit height lit directly made them bumpy).
		vec3 east = normalize(cross(vec3(0.0, 1.0, 0.0), n) + vec3(1e-5, 0.0, 0.0));
		vec3 north = cross(n, east);
		vec2 slope = (EQ(relief_map, (n)).rg - vec2(0.5)) * (2.0 / 12.0);
		nn = normalize(n - (east * slope.x + north * slope.y) * relief_strength * (1.0 - sea));
		NORMAL = normalize((VIEW_MATRIX * (MODEL_MATRIX * vec4(nn, 0.0))).xyz);
		steep = length(slope) * height_exag;
	}

	// ---- cities: the built-up area ----
	float urban_area = 0.0;
	if (use_urban > 0.5) {
		urban_area = EQ(urban_map, (n)).r * (1.0 - sea);
		// A grain of blocks and roofs; in the middle the city is denser and greyer.
		float grain = 0.82 + 0.36 * detail_at(n, 6371.0 / 3.0).b;
		vec3 town = urban_color * grain * mix(1.05, 0.9, smoothstep(0.5, 1.0, urban_area));
		col = mix(col, town, smoothstep(0.08, 0.6, urban_area) * urban_strength);
	}

	// ---- the ground seen close: detail patterns where the map blurs ----
	if (use_detail > 0.5) {
		EqUv eu = eq_uv(n);
		vec2 msz = vec2(textureSize(map_albedo, 0));
		float tpp = max(length(eu.dx * msz), length(eu.dy * msz));     // map texels per screen pixel
		float near_k = (1.0 - smoothstep(0.25, 1.2, tpp)) * (1.0 - sea);
		if (near_k > 0.001) {
			vec3 b = s.col;
			float lum = dot(b, vec3(0.3, 0.59, 0.11));
			float sat = max(b.r, max(b.g, b.b)) - min(b.r, min(b.g, b.b));
			float snow_w = smoothstep(0.5, 0.72, lum) * (1.0 - smoothstep(0.06, 0.18, sat));
			float veg_w = smoothstep(-0.01, 0.05, b.g - b.r) * (1.0 - snow_w);
			float rock_w = max(smoothstep(0.05, 0.25, steep), 0.25) * (1.0 - snow_w) * (1.0 - veg_w * 0.6);
			float sand_w = smoothstep(0.02, 0.12, b.r - b.b) * (1.0 - veg_w) * (1.0 - snow_w) * (1.0 - rock_w * 0.7);
			vec4 wts = vec4(veg_w, sand_w, rock_w, snow_w);
			wts /= max(wts.x + wts.y + wts.z + wts.w, 1e-4);
			float k1 = 6371.0 / detail_km;
			vec4 big = detail_at(n, k1 * 0.23) - vec4(0.5);
			vec4 mid = detail_at(n, k1) - vec4(0.5);
			vec4 fine = detail_at(n, k1 * 7.1) - vec4(0.5);
			vec4 bias = vec4(1.0, 0.8, 1.2, 0.5);
			float h_big = dot(wts, big * bias);
			float h_mid = dot(wts, mid * bias);
			float h = (h_big * 0.45 + h_mid * 0.4 + dot(wts, fine * bias) * 0.15) * near_k;
			col *= 1.0 + h * 2.0 * detail_strength;
			// The map's own small contrast, raised: a finer and a coarser look at it, the difference added back.
			float lod0 = max(log2(max(tpp, 1e-4)), 0.0);
			vec2 muv = eu.uv;
			vec3 fine_c = textureLod(map_albedo, muv, lod0).rgb;
			vec3 coarse_c = textureLod(map_albedo, muv, lod0 + 1.5).rgb;
			float l0 = dot(fine_c, vec3(0.3, 0.59, 0.11));
			float l1 = max(dot(coarse_c, vec3(0.3, 0.59, 0.11)), 0.02);
			col *= clamp(1.0 + (l0 - l1) / l1 * sharpen * near_k, 0.6, 1.6);
			// Fields: on flat land of grass or steppe, plots of their own colour — wheat, young green, ploughed, fallow.
			float farm = (veg_w * 0.8 + sand_w * 0.5) * (1.0 - smoothstep(0.03, 0.12, steep)) * (1.0 - snow_w) * fields * near_k;
			if (farm > 0.01) {
				vec2 inside;
				vec3 cell = field_cell(n, 6371.0 / field_km, inside);
				float fh = field_hash(cell);
				vec3 tint = fh < 0.25 ? vec3(1.18, 1.08, 0.72) : (fh < 0.5 ? vec3(0.9, 1.12, 0.82) : (fh < 0.72 ? vec3(0.95, 0.82, 0.68) : vec3(1.0)));
				// The furrows and the boundaries between plots.
				float furrow = 0.94 + 0.06 * sin((fh > 0.5 ? inside.x : inside.y) * 70.0);
				float edge = smoothstep(0.0, 0.04, min(min(inside.x, 1.0 - inside.x), min(inside.y, 1.0 - inside.y)));
				vec3 farmed = col * tint * furrow * mix(0.82, 1.0, edge);
				col = mix(col, farmed, farm * smoothstep(0.35, 0.8, field_hash(cell + vec3(3.1, 7.7, 1.3)) + 0.4));
			}
			// Small relief: the larger patterns as a height, lit (bump by the screen derivatives; the finest one
			// only shades — as a bump it would shimmer).
			float earth_r0 = max(length(MODEL_MATRIX[0].xyz), 1e-6);
			float hv = (h_big * 4.0 + h_mid) * near_k * detail_bump * (detail_km / 6371.0) * earth_r0 * 0.05;
			vec3 dpx = dFdx(VERTEX);
			vec3 dpy = dFdy(VERTEX);
			vec3 N0 = NORMAL;
			vec3 r1 = cross(dpy, N0);
			vec3 r2 = cross(N0, dpx);
			float det = dot(dpx, r1);
			vec3 grad = sign(det) * (dFdx(hv) * r1 + dFdy(hv) * r2);
			NORMAL = normalize(abs(det) * N0 - grad);
		}
	}

	// ---- the clouds' shadows ----
	float cover_here = 0.0;
	if (use_cloud_shadow > 0.5) {
		cover_here = EQ(clouds_map, (normalize(cloud_basis * n))).r;
		float shade = EQ(clouds_map, (normalize(cloud_basis * normalize(n + sun * 0.006)))).r;
		float cloud_alt = (length((inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz) - 1.0) * 6371.0;
		shade *= mix(cloud_near_alpha, 1.0, smoothstep(cloud_near_km, cloud_far_km, cloud_alt));
		col *= 1.0 - shade * cloud_shadow * day;
	}

	// ---- the air between the eye and the ground: far ground hazes blue ----
	float sky_t = smoothstep(-0.05, 0.40, ndl);
	vec3 sky = mix(sky_dusk, sky_day, sky_t);
	vec3 haze_col = mix(sky * 0.55, horizon_haze, inside);
	col = mix(col, haze_col, fres * mix(haze, haze_inside, inside) * day * atmo_visible);

	ALBEDO = col;
	float rough_sea = mix(sea_roughness, 0.90, lava_frac);
	ROUGHNESS = mix(0.92, rough_sea, sea);
	SPECULAR = mix(0.08, mix(0.25, 0.05, lava_frac), sea);   // a soft sheen: a white spot on a narrow sea reads as a salt flat
	METALLIC = 0.0;

	// ================= NIGHT AND LIGHTS (the game's, then the real ones) =================
	vec3 light_urban = vec3(0.52, 0.74, 1.00);
	vec3 light_bio   = vec3(0.28, 1.00, 0.58);
	vec3 light_hot   = vec3(1.00, 0.40, 0.13);
	vec3 light_cold  = vec3(0.66, 0.85, 1.00);
	vec3 light_col = mix(light_urban, light_bio, greening);
	light_col = mix(light_col, light_hot, heat);
	light_col = mix(light_col, light_cold, cold * 0.75);

	float far_glow = smoothstep(0.52, 0.86, fbm(sp * 18.0 + vec3(7.3)));
	float wmask = mix(far_glow, lit * (1.0 - street * 0.75) + street * 0.22, legible_b);
	vec3 w_res = vec3(1.00, 0.80, 0.46);
	vec3 w_farm = vec3(0.85, 0.75, 0.45);
	vec3 w_ind = vec3(0.90, 0.60, 0.30);
	vec3 w_hi = vec3(0.55, 0.85, 1.00);
	vec3 w_col = w_res;
	w_col = mix(w_col, w_farm, step(0.30, kind) * step(kind, 0.54));
	w_col = mix(w_col, w_ind, step(0.54, kind) * step(kind, 0.80));
	w_col = mix(w_col, w_hi, step(0.80, kind));
	w_col = mix(w_col, light_col, greening * 0.5);
	float w_pow = 0.70;
	w_pow = mix(w_pow, 0.22, step(0.30, kind) * step(kind, 0.54));
	w_pow = mix(w_pow, 0.40, step(0.54, kind) * step(kind, 0.80));
	w_pow = mix(w_pow, 1.15, step(0.80, kind));
	vec3 win_glow = w_col * (city_land + city_sea) * night * wmask * w_pow * lights_on;
	float artery = street * legible_b * step(0.80, shine) * (city_land + city_sea);
	win_glow += mix(w_col, vec3(1.0), 0.35) * artery * (0.10 + night * 0.85) * 0.55 * lights_on;

	vec3 real_lights = vec3(0.0);
	if (use_night > 0.5) {
		win_glow *= proc_lights;
		vec3 nl = EQ(night_map, (n)).rgb;
		// Black Marble's dark ground is not black (the 2016 map's moonlit land and sea are blue-grey): only the bright
		// part is light, read by its red (the bluish ground has next to none). Warm sodium colour.
		vec3 glow = vec3(max(min(nl.r, nl.g) - 0.06, 0.0)) * vec3(1.15, 0.92, 0.62);
		real_lights = glow * night_gain * night * lights_on * (1.0 - cover_here * 0.65) * (1.0 - sea * 0.85);
	}

	float deep_pulse = fbm(sp * 5.0 + vec3(61.0));
	float pl_n = smoothstep(0.45, 0.85, fbm(sp * 6.5 + vec3(29.0)));
	vec3 planktone = vec3(0.20, 0.95, 0.68) * sea_life * (1.0 - land) * night * (0.30 + pl_n * 0.85) * 0.55;
	vec3 under = light_col * submerged * night * (0.35 + deep_pulse * 0.5) * 0.55;
	vec3 lava_glow = mix(vec3(0.95, 0.24, 0.03), vec3(1.0, 0.60, 0.13), depth) * cracks * lava_frac * (1.0 - land) * (1.5 + night * 1.1);
	float land_lava = smoothstep(0.80, 1.0, T) * smoothstep(0.52, 0.86, fbm(sp * 6.0 + vec3(91.0)));
	vec3 molten = vec3(1.0, 0.28, 0.06) * land_lava * 1.6 * land * (1.0 - city_land * 0.7);

	// ================= ATMOSPHERE: blue by day, orange where the sun sets =================
	// The Earth's air is the sky's blue only (sunlight scattered): the game's mix with a brown «radiation» colour
	// turned the rim lilac.
	vec3 air = sky;
	float day_side = smoothstep(-0.25, 0.25, ndl);
	float dusk = smoothstep(-0.15, 0.0, ndl) * (1.0 - smoothstep(0.0, 0.15, ndl));   // narrow: no violet blue + orange
	vec3 halo = (air * day_side * (1.0 - dusk * 0.6) + sky_dusk * dusk * 0.2) * fres * atmosphere * 1.1 * air_glow * atmo_visible;
	halo *= 1.0 - inside * 0.8;

	float fheat = feature_heat(n);
	vec3 feat_glow = mix(vec3(1.0, 0.30, 0.05), vec3(1.0, 0.72, 0.25), fheat * 0.6) * fheat * 1.6;

	float aur_band = smoothstep(0.885, 0.925, lat) * (1.0 - smoothstep(0.962, 0.992, lat));
	float aur_wave = fbm(vec3(n.x * 7.0, n.y * 22.0, n.z * 7.0) + seed_shift());
	// A real aurora: a faint green oval on the night side only (the game's was violet patches, by day too, as
	// bright as clouds).
	float aurora = aur_band * smoothstep(0.55, 0.8, aur_wave) * magnetic * smoothstep(0.06, 0.30, atmosphere) * night * aurora_k;
	vec3 aur_col = mix(vec3(0.20, 1.0, 0.45), vec3(0.75, 0.30, 0.35), smoothstep(0.93, 0.97, lat) * 0.4);

	float city_glow = use_urban > 0.5 ? smoothstep(0.15, 0.9, urban_area) * night * lights_on * (1.0 - cover_here * 0.6) * urban_glow : 0.0;
	EMISSION = halo + pol_light * mix(0.4, 1.0, night) + win_glow + real_lights + urban_light * city_glow + under + planktone + molten + lava_glow + feat_glow + aur_col * aurora * 0.9;
}
