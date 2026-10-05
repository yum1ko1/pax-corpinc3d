shader_type spatial;
render_mode cull_disabled, blend_add, depth_draw_never, shadows_disabled, unshaded;

// Pax CorpInc3D — the air around the Earth (src/earth/earth.gd: a shell a little larger than the planet, a child of the
// Earth's node). Seen from outside: a thin glow past the limb, blue by day, orange where the sun sets. Seen from
// inside (the camera came down into the atmosphere): the sky — deep blue overhead, pale at the horizon, warm toward a
// low sun, black at night and thinning out as the camera climbs. sun_dir — in the Earth's local space.

uniform vec3 sun_dir = vec3(0.0, 0.0, 1.0);
uniform vec3 sky_day : source_color = vec3(0.30, 0.56, 1.0);
uniform vec3 sky_dusk : source_color = vec3(1.0, 0.45, 0.16);
uniform vec3 sky_zenith : source_color = vec3(0.10, 0.28, 0.72);
uniform vec3 sky_horizon : source_color = vec3(0.62, 0.78, 0.98);
uniform float strength : hint_range(0.0, 4.0) = 0.45;
uniform float sky_strength : hint_range(0.0, 4.0) = 1.0;
uniform float thickness : hint_range(0.5, 8.0) = 3.0;   // higher — a thinner bright rim
uniform float shell : hint_range(1.0, 1.2) = 1.025;     // the shell's radius (the air's top), Earth radii
uniform float atmo_visible : hint_range(0.0, 1.0) = 1.0;

varying vec3 local_pos;

void vertex() {
	local_pos = normalize(VERTEX);
}

void fragment() {
	vec3 n = normalize(local_pos);
	vec3 sun = normalize(sun_dir);
	if (FRONT_FACING) {
		// How near the line of sight passes the planet's centre: 1 — it grazes the limb, «shell» — the air's top.
		// (Measured by the angle to the shell, it held only from afar: close in that angle's threshold crossed the
		// middle of the screen as a sharp seam in the air.) Over the planet's disc the glow fades out quickly.
		vec3 cam = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
		vec3 dir = normalize(n * shell - cam);
		float along = max(-dot(cam, dir), 0.0);
		float miss = length(cam + dir * along);
		float x = (miss - 1.0) / (shell - 1.0);                      // < 0 over the disc, 0 at the limb, 1 at the top
		float inner = smoothstep(-0.6, 0.0, x);
		float outer = 1.0 - clamp(x, 0.0, 1.0);
		float glow = inner * pow(outer, thickness * 0.5);
		float ndl = dot(n, sun);
		float day = smoothstep(-0.30, 0.20, ndl);
		// A narrow, weak sunset band: wide, it lay over the blue and the two added up to a violet rim.
		float dusk = smoothstep(-0.15, 0.0, ndl) * (1.0 - smoothstep(0.0, 0.12, ndl));
		ALBEDO = (sky_day * day * (1.0 - dusk * 0.6) + sky_dusk * dusk * 0.15) * glow * strength * atmo_visible;   // additive: the colour is the light
	} else {
		// From inside: the camera in the Earth's local space, its height in the air 0 (ground) .. 1 (the shell).
		mat4 to_local = inverse(MODEL_MATRIX);
		vec3 cam = (to_local * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
		vec3 up = normalize(cam);
		float alt = clamp((length(cam) - 1.0) / (shell - 1.0), 0.0, 1.0);
		if (length(cam) >= shell) {
			discard;   // the far half of the shell seen from space is not a sky
		}
		vec3 dir = normalize(n * shell - cam);
		float elev = dot(dir, up);                                   // −1 down … 1 overhead
		float sun_up = dot(up, sun);                                  // the sun's height over the camera's horizon
		float daylight = smoothstep(-0.12, 0.10, sun_up);
		vec3 sky = mix(sky_horizon, sky_zenith, smoothstep(-0.02, 0.45, elev));
		float toward_sun = pow(max(dot(dir, sun), 0.0), 6.0);
		float low_sun = 1.0 - smoothstep(0.0, 0.35, sun_up);
		sky = mix(sky, sky_dusk, toward_sun * low_sun * 0.7 + low_sun * 0.25 * (1.0 - smoothstep(0.0, 0.2, elev)));
		sky += vec3(1.0, 0.95, 0.85) * pow(max(dot(dir, sun), 0.0), 400.0) * 3.0;   // the sun's disc
		float thin = 1.0 - smoothstep(0.15, 1.0, alt);
		ALBEDO = sky * daylight * thin * sky_strength * atmo_visible;
	}
}
