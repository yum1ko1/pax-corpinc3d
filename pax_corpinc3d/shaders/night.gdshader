shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back, depth_test_default;
// The night over our 3D things on the Earth (earth.gd puts it as every one's material_overlay): the game lights the
// planet by its own shader (the sun's side, the night's), while the trees, the houses, the armies were lit by the
// scene's light the same everywhere — green forests in the dark. Here a thing on the night side goes dark too, by
// the same sun the ground has. planet_inv — the Earth's node from world space, sun_dir — the sun in its space.

uniform mat4 planet_inv;
uniform vec3 sun_dir = vec3(0.0, 0.0, 1.0);
uniform float strength : hint_range(0.0, 1.0) = 0.86;

varying vec3 v_dir;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_dir = normalize((planet_inv * vec4(wp, 1.0)).xyz);
}

void fragment() {
	float night = smoothstep(0.06, -0.14, dot(normalize(v_dir), normalize(sun_dir)));
	if (night < 0.01) {
		discard;
	}
	ALBEDO = vec3(0.012, 0.014, 0.03);
	ALPHA = night * strength;
}
