shader_type canvas_item;

// PALETTE SWAP for a character built from the player's art: replaces the colours of his HAT and of his PANTS by other colours, exactly and
// nothing else (outline, skin, shirt, held things and the alpha stay as drawn). Compatibility-safe (plain uniform arrays, no texture lookups
// of its own); no filtering: use it with the node's Nearest filter. PaletteSwap (scripts/palette_swap.gd) fills the uniforms.
//
// The art uses ONE colour for the hat and for the pants, so a colour that is in both lists is told apart by the pixel's row in the sheet:
// rows above `split_row` are the hat, from it down the pants (PaletteSwap finds the row from the art of each animation and sets it when the
// animation changes). A colour that is in only one list is swapped wherever it is.

const int SLOTS = 8;

uniform vec4 hat_src[8];
uniform vec4 hat_dst[8];
uniform int hat_count = 0;
uniform vec4 pants_src[8];
uniform vec4 pants_dst[8];
uniform int pants_count = 0;
uniform float split_row = 8.0;
uniform float epsilon = 0.004;

bool same(vec3 a, vec3 b) {
	vec3 d = abs(a - b);
	return d.r < epsilon && d.g < epsilon && d.b < epsilon;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	if (c.a > 0.0) {
		float row = floor(UV.y / TEXTURE_PIXEL_SIZE.y);
		bool lower = row >= split_row;
		int hat_i = -1;
		int pants_i = -1;
		for (int i = 0; i < SLOTS; i++) {
			if (i < hat_count && hat_i < 0 && same(c.rgb, hat_src[i].rgb)) {
				hat_i = i;
			}
			if (i < pants_count && pants_i < 0 && same(c.rgb, pants_src[i].rgb)) {
				pants_i = i;
			}
		}
		if (hat_i >= 0 && pants_i >= 0) {
			c.rgb = lower ? pants_dst[pants_i].rgb : hat_dst[hat_i].rgb;
		} else if (hat_i >= 0) {
			c.rgb = hat_dst[hat_i].rgb;
		} else if (pants_i >= 0) {
			c.rgb = pants_dst[pants_i].rgb;
		}
	}
	COLOR = c;
}
