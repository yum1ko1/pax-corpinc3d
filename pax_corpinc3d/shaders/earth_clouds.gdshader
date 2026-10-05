shader_type spatial;
render_mode cull_back, blend_mix, depth_draw_never, shadows_disabled, unshaded;

// Pax CorpInc3D — the Earth's real clouds (src/earth/earth.gd puts it on the game's cloud shell). The shell is the
// game's: it turns by itself and the game sets sun_dir in its local space every frame, as for its own clouds.
// clouds_map — NASA Blue Marble clouds (white = cloud), equirectangular like every map of the game.
// Lit by hand (unshaded): white by day, warm at the terminator, a faint grey on the night side; thin clouds let
// the ground show through.

uniform sampler2D clouds_map : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec3 sun_dir = vec3(0.0, 0.0, 1.0);
uniform float atmosphere : hint_range(0.0, 1.0) = 0.30;   // the game's: no air — no clouds
uniform float atmo_visible : hint_range(0.0, 1.0) = 1.0;
uniform float density : hint_range(0.0, 2.0) = 1.0;
uniform float near_fade : hint_range(0.0, 1.0) = 1.0;   // earth.gd: 0 close to the ground — the clouds give way
uniform float brightness : hint_range(0.0, 2.0) = 1.0;
uniform vec3 dusk : source_color = vec3(1.0, 0.55, 0.30);
// Coming close the clouds thin out (a strategy needs the land): × near_alpha below near_km over the shell, full
// above far_km.
uniform float near_alpha : hint_range(0.0, 1.0) = 0.25;
uniform float near_km = 400.0;
uniform float far_km = 3000.0;
// The game's other uniforms of its cloud shader (it sets them on this material too).
uniform float water : hint_range(0.0, 1.0) = 0.66;
uniform float temperature : hint_range(0.0, 1.0) = 0.30;
uniform float radiation : hint_range(0.0, 1.0) = 0.0;
uniform float world_seed = 0.0;

varying vec3 local_pos;

vec2 sph_uv(vec3 n) {
	return vec2(atan(n.x, n.z) / 6.28318531 + 0.5, acos(clamp(n.y, -1.0, 1.0)) / 3.14159265);
}

void vertex() {
	local_pos = normalize(VERTEX);
}

void fragment() {
	vec3 n = normalize(local_pos);
	vec2 uv = sph_uv(n);
	vec2 dx = dFdx(uv);
	vec2 dy = dFdy(uv);
	dx.x -= round(dx.x);
	dy.x -= round(dy.x);
	float c = textureGrad(clouds_map, uv, dx, dy).r;
	vec3 eye = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	float alt_km = (length(eye) - 1.0) * 6371.0;
	// Coming down from far_km to near_km the clouds break up: the thin haze goes first, the thick thins out.
	float high = smoothstep(near_km, far_km, alt_km);
	float alpha = smoothstep(mix(0.5, 0.06, high), 0.85, c) * density * smoothstep(0.05, 0.35, atmosphere) * atmo_visible * near_fade;
	alpha *= mix(near_alpha, 1.0, high);
	if (alpha < 0.004) {
		discard;
	}
	float ndl = dot(n, normalize(sun_dir));
	float lit = smoothstep(-0.18, 0.35, ndl);
	float edge = smoothstep(-0.2, 0.0, ndl) * (1.0 - smoothstep(0.0, 0.3, ndl));
	vec3 col = mix(vec3(0.03, 0.035, 0.05), vec3(1.0, 0.99, 0.97), lit);
	col = mix(col, dusk, edge * 0.35);   // a thin warm band at sunset only
	// Thick cloud is brighter on top than thin haze.
	col *= (0.78 + 0.22 * c) * brightness;
	ALBEDO = col;
	ALPHA = clamp(alpha, 0.0, 1.0);
}
