extends RefCounted

# Where to put a sprite's origin so the bottom-centre of its drawing sits on the node's ground point,
# whatever the size of the canvas (so art can be swapped without code changes; nothing is ever scaled).

static var _cache: Dictionary = {}
static var _heights: Dictionary = {}

# Height in pixels of the drawn part of the picture.
static func used_height(texture: Texture2D) -> int:
	if not _heights.has(texture):
		_heights[texture] = texture.get_image().get_used_rect().size.y
	return _heights[texture]

static func offset_for(texture: Texture2D) -> Vector2:
	if _cache.has(texture):
		return _cache[texture]
	var image: Image = texture.get_image()
	var used: Rect2i = image.get_used_rect()
	var offset := Vector2(floorf(image.get_width() * 0.5 - (used.position.x + used.size.x * 0.5) + 0.5), floorf(image.get_height() * 0.5 - used.end.y + 0.5))
	_cache[texture] = offset
	return offset
