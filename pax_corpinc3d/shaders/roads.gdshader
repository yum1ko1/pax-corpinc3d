shader_type spatial;
render_mode cull_disabled;
// The game's networks as 3D geometry on the Earth (src/layers/roads3d.gd): ribbons with their own vertices along
// each road, rail and power line — a raised bed with slopes, the surface drawn here: asphalt with its markings and
// the traffic (lights at night), ballast with sleepers, two rails and trains, wires.
// A vertex: VERTEX — the centre line's direction (unit sphere, the Earth's own space), NORMAL — the side direction,
// UV — x: across −1..1 (the bed's edges ±1), y: along, km; UV2 — x: half width, km, y: height over the ground, m
// (exaggerated already); COLOR.r — the kind (0 highway, 0.25 road, 0.5 rail, 0.75 wire).
// The height is the ground's own (the same height map and formula as the terrain, shaders/earth.gdshader), so the
// ribbons lie on the 3D ground; far away they keep at least min_px pixels wide and are drawn plain.

uniform sampler2D height_map : filter_nearest, repeat_enable;
uniform float use_height_map = 0.0;
uniform float height_exag = 3.5;
uniform float min_px = 1.6;
uniform float wire_px = 3.0;                   // power lines: never thinner than this from afar (amber threads)
uniform float pull = 0.012;                  // towards the eye, × the distance: never under the ground's triangles (the
                                             // ground is a coarser mesh than the height map — with heights × 3.5 it rose
                                             // over the ribbons in patches and they looked see-through; along the line of
                                             // sight the ribbon stays where it is on the screen)
uniform vec3 sun_dir = vec3(0.0, 0.0, 1.0);   // the Earth's own space
uniform vec3 haze_color : source_color = vec3(0.66, 0.76, 0.88);
uniform float haze_km = 1400.0;
uniform float traffic = 1.0;
uniform float night_glow = 1.6;                // the roads' light at night seen from far
uniform float far_light = 0.5;   // far away (drawn wider than life) roads and rails read light, as on photos from orbit
uniform vec3 eye_local = vec3(0.0);   // the camera in the Earth's own space (roads3d.gd, every frame)
uniform float px_angle = 0.0;         // one screen pixel's angle, radians (roads3d.gd): the widening's measure — the
                                      // built-ins (VIEWPORT_SIZE, PROJECTION_MATRIX) gave no widening in some renderers,
                                      // and 4-metre power wires were drawn as specks

varying float v_kind;
varying vec2 v_uv;
varying float v_half;
varying float v_wide;     // how many times wider than life it is drawn (far away)
varying float v_dist;     // km to the eye
varying vec3 v_up;

float h_texel(ivec2 p, ivec2 sz) {
	p.x = (p.x % sz.x + sz.x) % sz.x;
	p.y = clamp(p.y, 0, sz.y - 1);
	vec4 t = texelFetch(height_map, p, 0);
	return (t.r * 255.0 * 256.0 + t.g * 255.0) / 65535.0;
}

float ground_r(vec3 n) {
	if (use_height_map < 0.5) {
		return 1.0;
	}
	ivec2 sz = textureSize(height_map, 0);
	vec2 uv = vec2(atan(n.x, n.z) / 6.28318530718 + 0.5, acos(clamp(n.y, -1.0, 1.0)) / 3.14159265359);
	vec2 f = uv * vec2(sz) - vec2(0.5);
	ivec2 p = ivec2(floor(f));
	vec2 w = fract(f);
	float a = mix(h_texel(p, sz), h_texel(p + ivec2(1, 0), sz), w.x);
	float b = mix(h_texel(p + ivec2(0, 1), sz), h_texel(p + ivec2(1, 1), sz), w.x);
	return 1.0 + mix(a, b, w.y) * 0.0010046 * height_exag;
}

float hash1(float x) {
	return fract(sin(x * 127.1) * 43758.5453);
}

float noise1(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash1(dot(i, vec2(1.0, 57.0)));
	float b = hash1(dot(i + vec2(1.0, 0.0), vec2(1.0, 57.0)));
	float c = hash1(dot(i + vec2(0.0, 1.0), vec2(1.0, 57.0)));
	float d = hash1(dot(i + vec2(1.0, 1.0), vec2(1.0, 57.0)));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	vec3 n = normalize(VERTEX);
	vec3 side = normalize(NORMAL);
	vec3 eye = px_angle > 0.0 ? eye_local : (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	float r0 = ground_r(n);
	float d_model = length(eye - n * r0);
	// One screen pixel there, in the Earth's radii.
	float pix = px_angle > 0.0 ? d_model * px_angle : 2.0 * d_model / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float half_m = UV2.x / 6371.0;
	float half_eff = max(half_m, pix * (COLOR.r > 0.6 ? max(min_px, wire_px) : min_px) * 0.5);
	vec3 p = normalize(n + side * UV.x * half_eff);
	float r = ground_r(p) + UV2.y / 6371000.0;
	vec3 pos = p * r;
	pos += normalize(eye - pos) * d_model * pull;
	VERTEX = pos;
	NORMAL = p;
	v_kind = COLOR.r;
	v_uv = UV;
	v_half = UV2.x;
	v_wide = half_eff / max(half_m, 1e-9);
	v_dist = d_model * 6371.0;
	v_up = p;
}

vec3 car_color(float id) {
	float h = hash1(id);
	if (h < 0.3) {
		return vec3(0.85, 0.85, 0.86);
	}
	if (h < 0.5) {
		return vec3(0.08, 0.08, 0.09);
	}
	if (h < 0.65) {
		return vec3(0.55, 0.08, 0.07);
	}
	if (h < 0.8) {
		return vec3(0.12, 0.2, 0.45);
	}
	return vec3(0.5, 0.5, 0.52);
}

void fragment() {
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;   // both sides drawn: the one seen is lit as the top
	}
	float x = v_uv.x;
	float ax = abs(x);
	float along = v_uv.y;
	float w = max(v_half * 2.0, 1e-4);         // the bed's width, km
	float a_w = along / w;                     // along, in the bed's widths
	float detail = 1.0 - smoothstep(1.5, 3.0, v_wide);   // markings, sleepers and traffic only when near life size
	float night = smoothstep(0.08, -0.15, dot(normalize(v_up), normalize(sun_dir)));
	vec3 col;
	vec3 glow = vec3(0.0);
	float rough = 0.85;
	float metal = 0.0;
	if (v_kind < 0.4) {
		// ---- a road: asphalt on a bed, gravel shoulders, grass slopes ----
		bool highway = v_kind < 0.12;
		vec3 asphalt = vec3(0.075, 0.077, 0.082) * (0.85 + 0.3 * noise1(vec2(a_w * 3.0, x * 4.0)));
		vec3 shoulder = vec3(0.36, 0.34, 0.3);
		vec3 slope = vec3(0.2, 0.26, 0.14);
		float top = highway ? 0.82 : 0.8;
		col = mix(asphalt, shoulder, smoothstep(top - 0.06, top, ax));
		col = mix(col, slope, smoothstep(top + 0.02, top + 0.08, ax));
		// Markings: the edge lines, the lanes' dashes; a highway — two carriageways and a barrier between them.
		float edge = (1.0 - smoothstep(0.012, 0.022, abs(ax - (top - 0.09)))) * detail;
		col = mix(col, vec3(0.92), edge * 0.9);
		float dash = step(fract(a_w * 0.6), 0.4);
		if (highway) {
			float barrier = 1.0 - smoothstep(0.02, 0.035, ax);
			col = mix(col, vec3(0.62, 0.62, 0.6), barrier);
			float lanes = (1.0 - smoothstep(0.008, 0.016, abs(ax - 0.37))) * dash * detail;
			col = mix(col, vec3(0.9), lanes * 0.85);
		} else {
			float centre = (1.0 - smoothstep(0.012, 0.022, ax)) * dash * detail;
			col = mix(col, vec3(0.95, 0.85, 0.35), centre * 0.85);
		}
		// Traffic: cars in every lane, both ways; at night headlights ahead, red lights behind.
		if (traffic > 0.0 && detail > 0.01) {
			float lanes_n = highway ? 4.0 : 2.0;
			float lane_w = (top - 0.09) * 2.0 / lanes_n;
			float li = floor((x + (top - 0.09)) / lane_w);
			if (li >= 0.0 && li < lanes_n) {
				float lc = -(top - 0.09) + (li + 0.5) * lane_w;
				float dir = x < 0.0 ? -1.0 : 1.0;
				float speed = (highway ? 2.6 : 1.4) * (0.8 + 0.4 * hash1(li + 3.0));
				float s = a_w * 1.2 - dir * TIME * speed / max(w, 0.05) * 0.05 + li * 0.37;
				float cell = floor(s);
				float f = fract(s);
				float present = step(hash1(cell * 1.7 + li), 0.55 * traffic);
				float body = step(f, 0.12) * (1.0 - smoothstep(lane_w * 0.2, lane_w * 0.27, abs(x - lc))) * present * detail;
				col = mix(col, car_color(cell + li * 31.0), body);
				float front = dir > 0.0 ? step(f, 0.025) : step(0.095, f) * step(f, 0.12);
				float back = dir > 0.0 ? step(0.095, f) * step(f, 0.12) : step(f, 0.025);
				glow += body * night * (front * vec3(1.0, 0.95, 0.8) * 3.0 + back * vec3(1.0, 0.1, 0.05) * 2.0);
			}
		}
		rough = 0.8;
		// Far away: plain grey, a little lighter than the ground.
		col = mix(vec3(0.26, 0.25, 0.24), col, detail);
		// At night the roads are threads of light between the cities: the highways bright, the others faint; from far
		// (the ribbon drawn wider than life) the whole width glows.
		float lit_road = 1.0 - smoothstep(top - 0.1, top, ax);
		glow += vec3(1.0, 0.72, 0.38) * night * lit_road * (highway ? 1.0 : 0.4) * mix(0.35, night_glow, 1.0 - detail);
	} else if (v_kind < 0.6) {
		// ---- a railway: ballast, sleepers, two rails, the trains ----
		vec3 ballast = vec3(0.34, 0.31, 0.28) * (0.75 + 0.5 * noise1(vec2(a_w * 40.0, x * 20.0)));
		vec3 slope = vec3(0.24, 0.24, 0.2);
		col = mix(ballast, slope, smoothstep(0.62, 0.72, ax));
		float sleepers = step(fract(a_w * 8.0), 0.45) * (1.0 - smoothstep(0.42, 0.46, ax)) * detail;
		col = mix(col, vec3(0.22, 0.15, 0.1), sleepers);
		float rails = (1.0 - smoothstep(0.015, 0.03, abs(ax - 0.27))) * detail;
		col = mix(col, vec3(0.7, 0.7, 0.72), rails);
		metal = rails * 0.8;
		// A train now and then: a long string of cars.
		float s = a_w * 0.08 - TIME * 0.05 / max(w, 0.05) * 0.03;
		float cell = floor(s);
		float f = fract(s);
		float train = step(hash1(cell * 3.1), 0.35 * traffic) * step(f, 0.35) * (1.0 - smoothstep(0.34, 0.38, ax)) * detail;
		float gap = step(0.08, fract(f * 60.0));
		col = mix(col, mix(vec3(0.15, 0.3, 0.2), vec3(0.45, 0.12, 0.08), step(0.5, hash1(cell))), train * gap);
		glow += train * gap * night * vec3(1.0, 0.85, 0.55) * 0.8 * step(0.6, fract(f * 180.0));
		col = mix(vec3(0.3, 0.22, 0.17), col, detail);
		rough = mix(0.9, 0.35, rails);
	} else {
		// ---- a wire ----
		// Amber like the power lines of maps, and glowing a little: dark grey wires read as one more road.
		col = vec3(1.0, 0.62, 0.16);
		glow += vec3(1.0, 0.55, 0.12) * (0.35 + 0.65 * night);
		metal = 0.3;
		rough = 0.5;
	}
	// From afar a dark ribbon on dark land was barely seen: drawn many times wider than life, a road turns the light
	// grey of a road seen from orbit, a railway a warm grey (wires stay as they are).
	if (v_kind < 0.6) {
		vec3 far_col = v_kind < 0.4 ? vec3(0.78, 0.75, 0.68) : vec3(0.62, 0.55, 0.48);
		col = mix(col, far_col, smoothstep(2.0, 8.0, v_wide) * far_light);
	}
	float haze = 1.0 - exp(-v_dist / haze_km);
	ALBEDO = mix(col, haze_color * 0.8, haze * 0.6);
	ROUGHNESS = rough;
	METALLIC = metal;
	EMISSION = glow;
}
