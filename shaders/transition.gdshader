shader_type canvas_item;

// Blends two viewport textures. progress 0 = all A, 1 = all B.
// mode: 0 cut, 1 crossfade, 2 wipe (left->right), 3 iris, 4 mask dissolve.
uniform sampler2D tex_a : filter_linear, repeat_disable;
uniform sampler2D tex_b : filter_linear, repeat_disable;
uniform sampler2D mask_tex : filter_linear, repeat_enable;
uniform int mode = 1;
uniform float progress = 1.0;
uniform float softness = 0.15;

void fragment() {
	vec4 a = texture(tex_a, UV);
	vec4 b = texture(tex_b, UV);
	float m;
	if (mode == 1) {
		m = progress;
	} else {
		// v = per-pixel "time" at which B takes over; softness widens the edge.
		float v = 0.0;
		if (mode == 2) {
			v = UV.x;
		} else if (mode == 3) {
			v = distance(UV, vec2(0.5)) / 0.7072;
		} else if (mode == 4) {
			v = texture(mask_tex, UV).r;
		}
		m = smoothstep(v, v + softness, progress * (1.0 + softness));
	}
	COLOR = vec4(mix(a, b, m).rgb, 1.0);
}
