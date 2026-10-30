shader_type canvas_item;

// A 1 px outline round the opaque part of a sprite (the current pickup target). Works in the Compatibility renderer.
uniform vec4 outline_color : source_color = vec4(1.0, 0.93, 0.55, 1.0);

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	vec2 ps = TEXTURE_PIXEL_SIZE;
	float around = 0.0;
	around = max(around, texture(TEXTURE, UV + vec2(ps.x, 0.0)).a);
	around = max(around, texture(TEXTURE, UV - vec2(ps.x, 0.0)).a);
	around = max(around, texture(TEXTURE, UV + vec2(0.0, ps.y)).a);
	around = max(around, texture(TEXTURE, UV - vec2(0.0, ps.y)).a);
	if (c.a < 0.1 && around > 0.1) {
		COLOR = outline_color;
	} else {
		COLOR = c;
	}
}
