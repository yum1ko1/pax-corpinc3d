shader_type spatial;
render_mode unshaded;
// The warning light on a communication mast (src/layers/roads3d.gd): red, blinking.
void fragment() {
	ALBEDO = vec3(1.0, 0.1, 0.05) * (0.3 + 0.7 * step(0.5, fract(TIME * 0.7)));
}
