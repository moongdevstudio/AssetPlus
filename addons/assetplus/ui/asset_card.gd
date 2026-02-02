@tool
extends Control

## Card component for displaying an asset in the grid
## Supports two styles: CLASSIC (horizontal) and MODERN (vertical, Fab-style)

const LikeButton = preload("res://addons/assetplus/ui/like_button.gd")

signal clicked(info: Dictionary)
signal favorite_clicked(info: Dictionary)
signal plugin_toggled(info: Dictionary, enabled: bool)

enum CardType { CLASSIC, MODERN, COMPACT }

var _card_type: CardType = CardType.CLASSIC
var _modern_size: Vector2 = Vector2(300, 288)  # Default MODERN size, can be customized

var _icon_rect: TextureRect
var _icon_placeholder: Panel
var _placeholder_style: StyleBoxFlat
var _shimmer_tween: Tween
var _title_label: Label
var _author_label: Label
var _source_badge: Label
var _source_icon: TextureRect  # Source logo overlay on image (top-left)
var _license_label: Label
var _favorite_btn: Button
var _bg_panel: Panel
var _image_container: Panel  # For MODERN cards - stores reference to update border on hover
var _image_container_style: StyleBoxFlat
var _installed_badge: Label
var _update_badge: Label
var _plugin_toggle_btn: Button
var _price_label: Label
var _rating_container: HBoxContainer
var _like_button: Control  # LikeButton component

var _info: Dictionary = {}
var _is_favorite: bool = false
var _is_hovered: bool = false
var _is_selected: bool = false
var _is_installed: bool = false
var _is_plugin: bool = false
var _is_plugin_enabled: bool = false
var _has_update: bool = false

# Shader code shared between styles
const ROUNDED_SHADER_CODE = """
shader_type canvas_item;

uniform float corner_radius : hint_range(0.0, 0.5) = 0.1;
uniform float edge_softness : hint_range(0.0, 0.1) = 0.02;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.25;
uniform float vignette_size : hint_range(0.0, 0.5) = 0.3;

float rounded_box_sdf(vec2 p, vec2 size, float radius) {
	vec2 q = abs(p) - size + radius;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

void fragment() {
	vec4 tex_color = texture(TEXTURE, UV);
	vec2 uv = UV - 0.5;
	vec2 size = vec2(0.5, 0.5);

	// Rounded rectangle mask - cuts corners to transparent
	float dist = rounded_box_sdf(uv, size, corner_radius);
	float mask = 1.0 - smoothstep(0.0, edge_softness, dist);

	// Soft vignette darkening near edges
	float vignette = 1.0 - smoothstep(0.5 - vignette_size, 0.5, length(uv)) * vignette_strength;

	COLOR = vec4(tex_color.rgb * vignette, tex_color.a * mask);
}
"""


func _init() -> void:
	# Default size for classic, will be overridden if modern
	custom_minimum_size = Vector2(390, 140)
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Prevent the card from shrinking below minimum size
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN


func set_card_type(type: CardType, custom_size: Vector2 = Vector2.ZERO) -> void:
	_card_type = type
	if type == CardType.MODERN:
		# Fab-style ratio: ~1.25:1 (width:height), image is 16:9
		# Default: 300px wide, image ~186px, text ~102px = 288px total
		# Can be customized via custom_size parameter for responsive layouts
		if custom_size != Vector2.ZERO:
			_modern_size = custom_size
		custom_minimum_size = _modern_size
		size = _modern_size
		# Prevent expansion
		size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	else:
		custom_minimum_size = Vector2(390, 140)
		size = Vector2(390, 140)


func _ready() -> void:
	if _card_type == CardType.MODERN:
		_build_ui_modern()
		# Force size to stay fixed for modern cards
		resized.connect(_on_card_resized)
	else:
		_build_ui_classic()
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	# If setup was called before _ready, update display now
	if not _info.is_empty():
		_update_display()


func _on_card_resized() -> void:
	# For MODERN cards, force the size back to the configured dimensions
	if _card_type == CardType.MODERN:
		if int(size.x) != int(_modern_size.x) or int(size.y) != int(_modern_size.y):
			# Use set_deferred to avoid infinite loops
			set_deferred("size", _modern_size)
			set_deferred("custom_minimum_size", _modern_size)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			clicked.emit(_info)
			accept_event()


func _build_ui_classic() -> void:
	## Build the classic horizontal card layout (icon left, info right)
	# Background panel
	_bg_panel = Panel.new()
	_bg_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_bg_panel)
	_update_bg_style()

	# Main HBox layout (like native AssetLib)
	var main_hbox = HBoxContainer.new()
	main_hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_hbox.add_theme_constant_override("separation", 0)
	main_hbox.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(main_hbox)

	# Left margin
	var left_margin = MarginContainer.new()
	left_margin.add_theme_constant_override("margin_left", 8)
	left_margin.add_theme_constant_override("margin_top", 8)
	left_margin.add_theme_constant_override("margin_bottom", 8)
	left_margin.mouse_filter = Control.MOUSE_FILTER_PASS
	main_hbox.add_child(left_margin)

	# Icon container to hold placeholder and actual icon
	var icon_container = Control.new()
	icon_container.custom_minimum_size = Vector2(115, 115)
	icon_container.mouse_filter = Control.MOUSE_FILTER_PASS
	left_margin.add_child(icon_container)

	# Skeleton loading placeholder with rounded corners (using Panel + StyleBoxFlat)
	_icon_placeholder = Panel.new()
	_icon_placeholder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon_placeholder.mouse_filter = Control.MOUSE_FILTER_PASS
	_placeholder_style = StyleBoxFlat.new()
	_placeholder_style.bg_color = Color(0.2, 0.2, 0.25, 1.0)
	_placeholder_style.set_corner_radius_all(10)
	_icon_placeholder.add_theme_stylebox_override("panel", _placeholder_style)
	icon_container.add_child(_icon_placeholder)
	_start_shimmer_animation()

	# Shader for rounded corners with soft vignette (for the icon image)
	var rounded_shader = Shader.new()
	rounded_shader.code = ROUNDED_SHADER_CODE

	# Icon (on top of placeholder) with rounded corners shader
	_icon_rect = TextureRect.new()
	_icon_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_rect.mouse_filter = Control.MOUSE_FILTER_PASS
	var icon_material = ShaderMaterial.new()
	icon_material.shader = rounded_shader
	_icon_rect.material = icon_material
	icon_container.add_child(_icon_rect)

	# Center: title + author + badges
	var center_vbox = VBoxContainer.new()
	center_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center_vbox.add_theme_constant_override("separation", 2)
	center_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	center_vbox.clip_contents = true
	main_hbox.add_child(center_vbox)

	# Top spacer - pushes content slightly below center
	var top_spacer = Control.new()
	top_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top_spacer.size_flags_stretch_ratio = 0.62
	center_vbox.add_child(top_spacer)

	# Title (bold)
	_title_label = Label.new()
	_title_label.text = "Asset Name"
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title_label.clip_text = true
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.size_flags_stretch_ratio = 1.0
	_title_label.add_theme_font_size_override("font_size", 16)
	# Use editor's bold font if available
	var editor_theme = EditorInterface.get_editor_theme() if Engine.is_editor_hint() else null
	if editor_theme and editor_theme.has_font("bold", "EditorFonts"):
		_title_label.add_theme_font_override("font", editor_theme.get_font("bold", "EditorFonts"))
	_title_label.mouse_filter = Control.MOUSE_FILTER_PASS
	center_vbox.add_child(_title_label)

	# Author
	_author_label = Label.new()
	_author_label.text = "by Author"
	_author_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	_author_label.add_theme_font_size_override("font_size", 13)
	_author_label.mouse_filter = Control.MOUSE_FILTER_PASS
	center_vbox.add_child(_author_label)

	# Badges row
	var badges_hbox = HBoxContainer.new()
	badges_hbox.add_theme_constant_override("separation", 8)
	badges_hbox.mouse_filter = Control.MOUSE_FILTER_PASS
	center_vbox.add_child(badges_hbox)

	_source_badge = Label.new()
	_source_badge.text = "AssetLib"
	_source_badge.add_theme_font_size_override("font_size", 12)
	_source_badge.add_theme_color_override("font_color", Color(0.4, 0.6, 0.9))
	_source_badge.mouse_filter = Control.MOUSE_FILTER_PASS
	badges_hbox.add_child(_source_badge)

	_license_label = Label.new()
	_license_label.text = "MIT"
	_license_label.add_theme_font_size_override("font_size", 12)
	_license_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_license_label.mouse_filter = Control.MOUSE_FILTER_PASS
	badges_hbox.add_child(_license_label)

	# Installed badge - positioned absolutely in TOP-LEFT area (same height as like button)
	_installed_badge = Label.new()
	_installed_badge.text = "Installed"
	_installed_badge.add_theme_font_size_override("font_size", 10)
	_installed_badge.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2))
	_installed_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_installed_badge.mouse_filter = Control.MOUSE_FILTER_PASS
	_installed_badge.visible = false
	_installed_badge.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_installed_badge.offset_left = 130
	_installed_badge.offset_top = 14
	_installed_badge.offset_right = 185
	_installed_badge.offset_bottom = 32
	add_child(_installed_badge)

	# Style the badge with background
	var badge_style = StyleBoxFlat.new()
	badge_style.bg_color = Color(0.4, 0.85, 0.4)
	badge_style.set_corner_radius_all(3)
	badge_style.content_margin_left = 4
	badge_style.content_margin_right = 4
	badge_style.content_margin_top = 2
	badge_style.content_margin_bottom = 2
	_installed_badge.add_theme_stylebox_override("normal", badge_style)

	# Update available badge - positioned absolutely in TOP-LEFT area (next to installed)
	_update_badge = Label.new()
	_update_badge.text = "Update"
	_update_badge.add_theme_font_size_override("font_size", 10)
	_update_badge.add_theme_color_override("font_color", Color(0.15, 0.15, 0.15))
	_update_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_update_badge.mouse_filter = Control.MOUSE_FILTER_PASS
	_update_badge.visible = false
	_update_badge.tooltip_text = "An update is available"
	_update_badge.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_update_badge.offset_left = 190
	_update_badge.offset_top = 14
	_update_badge.offset_right = 240
	_update_badge.offset_bottom = 32
	add_child(_update_badge)

	# Style the update badge with orange background
	var update_badge_style = StyleBoxFlat.new()
	update_badge_style.bg_color = Color(0.95, 0.7, 0.2)
	update_badge_style.set_corner_radius_all(3)
	update_badge_style.content_margin_left = 4
	update_badge_style.content_margin_right = 4
	update_badge_style.content_margin_top = 2
	update_badge_style.content_margin_bottom = 2
	_update_badge.add_theme_stylebox_override("normal", update_badge_style)

	# Bottom spacer - balances top spacer to push content slightly below center
	var bottom_spacer = Control.new()
	bottom_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bottom_spacer.size_flags_stretch_ratio = 0.38
	center_vbox.add_child(bottom_spacer)

	# Plugin enable/disable toggle (positioned in BOTTOM-right, hidden by default)
	_plugin_toggle_btn = Button.new()
	_plugin_toggle_btn.text = "OFF"
	_plugin_toggle_btn.toggle_mode = true
	_plugin_toggle_btn.custom_minimum_size = Vector2(44, 22)
	_plugin_toggle_btn.add_theme_font_size_override("font_size", 10)
	_plugin_toggle_btn.tooltip_text = "Enable/Disable plugin"
	_plugin_toggle_btn.toggled.connect(_on_plugin_toggle_pressed)
	_plugin_toggle_btn.visible = false
	_plugin_toggle_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_plugin_toggle_btn.offset_left = -52
	_plugin_toggle_btn.offset_top = -34
	_plugin_toggle_btn.offset_right = -8
	_plugin_toggle_btn.offset_bottom = -12
	add_child(_plugin_toggle_btn)

	# Style the toggle button
	var toggle_style_off = StyleBoxFlat.new()
	toggle_style_off.bg_color = Color(0.25, 0.25, 0.28)
	toggle_style_off.set_corner_radius_all(4)
	toggle_style_off.set_border_width_all(1)
	toggle_style_off.border_color = Color(0.35, 0.35, 0.38)
	_plugin_toggle_btn.add_theme_stylebox_override("normal", toggle_style_off)
	_plugin_toggle_btn.add_theme_stylebox_override("hover", toggle_style_off)

	var toggle_style_on = StyleBoxFlat.new()
	toggle_style_on.bg_color = Color(0.2, 0.5, 0.3)
	toggle_style_on.set_corner_radius_all(4)
	toggle_style_on.set_border_width_all(1)
	toggle_style_on.border_color = Color(0.3, 0.65, 0.4)
	_plugin_toggle_btn.add_theme_stylebox_override("pressed", toggle_style_on)
	_plugin_toggle_btn.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_plugin_toggle_btn.add_theme_color_override("font_hover_color", Color(0.9, 0.9, 0.9))
	_plugin_toggle_btn.add_theme_color_override("font_pressed_color", Color(0.9, 1.0, 0.9))

	# Like button container - anchored top-right, contains the dynamically-sized button
	var like_container = Control.new()
	like_container.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	like_container.offset_left = -120
	like_container.offset_top = -11
	like_container.offset_right = -4
	like_container.offset_bottom = 15
	add_child(like_container)

	# Like button inside container - aligned to right edge
	_like_button = LikeButton.new()
	_like_button.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_like_button.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_like_button.like_clicked.connect(_on_favorite_pressed)
	_like_button.set_clickable(true)
	like_container.add_child(_like_button)

	# Keep favorite button for compatibility (hidden, replaced by like_button)
	_favorite_btn = Button.new()
	_favorite_btn.visible = false
	add_child(_favorite_btn)


func _build_ui_modern() -> void:
	## Build the modern vertical card layout (image top, info bottom) - Fab/Unreal style
	# Background panel with rounded corners - use explicit size instead of anchors
	_bg_panel = Panel.new()
	_bg_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_bg_panel)
	_update_bg_style()

	# Main VBox layout - use explicit size instead of anchors
	var main_vbox = VBoxContainer.new()
	main_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", 0)
	main_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	main_vbox.clip_contents = true  # Clip children to prevent overflow
	add_child(main_vbox)

	# Image container - Panel with clip_contents and rounded top corners
	# Image takes ~68% of card height
	# Force explicit size to prevent overflow
	var img_height = int(_modern_size.y * 0.68)
	_image_container = Panel.new()
	_image_container.custom_minimum_size = Vector2(_modern_size.x, img_height)
	_image_container.size = Vector2(_modern_size.x, img_height)
	_image_container.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_image_container.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_image_container.mouse_filter = Control.MOUSE_FILTER_PASS
	_image_container.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	# Style with rounded top corners and border (top, left, right - not bottom)
	_image_container_style = StyleBoxFlat.new()
	_image_container_style.bg_color = Color(0.16, 0.16, 0.18)  # Same as card bg
	_image_container_style.set_corner_radius_all(0)
	_image_container_style.corner_radius_top_left = 10
	_image_container_style.corner_radius_top_right = 10
	# Border on top, left, right (not bottom) - same color as bg_panel border
	_image_container_style.border_width_top = 1
	_image_container_style.border_width_left = 1
	_image_container_style.border_width_right = 1
	_image_container_style.border_width_bottom = 0
	_image_container_style.border_color = Color(0.22, 0.22, 0.25)
	_image_container.add_theme_stylebox_override("panel", _image_container_style)
	main_vbox.add_child(_image_container)

	# Skeleton loading placeholder - offset to leave space for border
	_icon_placeholder = Panel.new()
	_icon_placeholder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon_placeholder.offset_top = 1
	_icon_placeholder.offset_left = 1
	_icon_placeholder.offset_right = -1
	_icon_placeholder.mouse_filter = Control.MOUSE_FILTER_PASS
	_placeholder_style = StyleBoxFlat.new()
	_placeholder_style.bg_color = Color(0.2, 0.2, 0.25, 1.0)
	_placeholder_style.set_corner_radius_all(0)
	_placeholder_style.corner_radius_top_left = 9
	_placeholder_style.corner_radius_top_right = 9
	_icon_placeholder.add_theme_stylebox_override("panel", _placeholder_style)
	_image_container.add_child(_icon_placeholder)
	_start_shimmer_animation()

	# Icon/Image - offset to leave space for border, clip to prevent overflow
	_icon_rect = TextureRect.new()
	_icon_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon_rect.offset_top = 1
	_icon_rect.offset_left = 1
	_icon_rect.offset_right = -1
	_icon_rect.offset_bottom = 0  # Don't extend below container
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_rect.mouse_filter = Control.MOUSE_FILTER_PASS
	_icon_rect.clip_contents = true
	_image_container.add_child(_icon_rect)

	# Like button container - anchored bottom-right, contains the dynamically-sized button
	var like_container = Control.new()
	like_container.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	like_container.offset_left = -120
	like_container.offset_top = -51
	like_container.offset_right = -6
	like_container.offset_bottom = -29
	add_child(like_container)

	# Like button inside container - aligned to right edge
	_like_button = LikeButton.new()
	_like_button.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_like_button.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_like_button.like_clicked.connect(_on_favorite_pressed)
	_like_button.set_clickable(true)
	like_container.add_child(_like_button)

	# Keep favorite button for compatibility (hidden)
	_favorite_btn = Button.new()
	_favorite_btn.visible = false
	add_child(_favorite_btn)

	# Info section at bottom - very tight margins like Fab
	var info_margin = MarginContainer.new()
	info_margin.custom_minimum_size.x = _modern_size.x
	info_margin.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	info_margin.add_theme_constant_override("margin_left", 4)
	info_margin.add_theme_constant_override("margin_right", 4)
	info_margin.add_theme_constant_override("margin_top", 2)
	info_margin.add_theme_constant_override("margin_bottom", 4)
	info_margin.mouse_filter = Control.MOUSE_FILTER_PASS
	main_vbox.add_child(info_margin)

	var info_vbox = VBoxContainer.new()
	info_vbox.add_theme_constant_override("separation", -8)
	info_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	info_margin.add_child(info_vbox)

	# Scale font sizes based on card width (base is 180px)
	var scale_factor = _modern_size.x / 180.0
	var title_font_size = int(11 * scale_factor)
	var author_font_size = int(10 * scale_factor)
	var license_font_size = int(9 * scale_factor)

	var editor_theme = EditorInterface.get_editor_theme() if Engine.is_editor_hint() else null

	# Title
	_title_label = Label.new()
	_title_label.text = "Asset Name"
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title_label.add_theme_font_size_override("font_size", title_font_size)
	if editor_theme and editor_theme.has_font("bold", "EditorFonts"):
		_title_label.add_theme_font_override("font", editor_theme.get_font("bold", "EditorFonts"))
	_title_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
	_title_label.mouse_filter = Control.MOUSE_FILTER_PASS
	info_vbox.add_child(_title_label)

	# Author
	_author_label = Label.new()
	_author_label.text = "Author"
	_author_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_author_label.add_theme_font_size_override("font_size", author_font_size)
	_author_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_author_label.mouse_filter = Control.MOUSE_FILTER_PASS
	info_vbox.add_child(_author_label)

	# License (fourth line)
	_license_label = Label.new()
	_license_label.text = "MIT"
	_license_label.add_theme_font_size_override("font_size", license_font_size)
	_license_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	if editor_theme and editor_theme.has_font("bold", "EditorFonts"):
		_license_label.add_theme_font_override("font", editor_theme.get_font("bold", "EditorFonts"))
	_license_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_license_label.mouse_filter = Control.MOUSE_FILTER_PASS
	info_vbox.add_child(_license_label)

	# Hidden elements for compatibility
	_price_label = Label.new()
	_price_label.visible = false
	add_child(_price_label)

	_rating_container = HBoxContainer.new()
	_rating_container.visible = false
	add_child(_rating_container)

	_source_badge = Label.new()
	_source_badge.visible = false
	add_child(_source_badge)

	_installed_badge = Label.new()
	_installed_badge.visible = false
	add_child(_installed_badge)

	_update_badge = Label.new()
	_update_badge.visible = false
	add_child(_update_badge)

	_plugin_toggle_btn = Button.new()
	_plugin_toggle_btn.visible = false
	add_child(_plugin_toggle_btn)


func _update_bg_style() -> void:
	var style = StyleBoxFlat.new()

	if _card_type == CardType.MODERN:
		# Modern style: darker bg, more rounded
		if _is_selected:
			style.bg_color = Color(0.22, 0.26, 0.32)
			style.set_border_width_all(2)
			style.border_color = Color(0.4, 0.6, 0.9)
		elif _is_hovered:
			style.bg_color = Color(0.2, 0.2, 0.24)
			style.set_border_width_all(1)
			style.border_color = Color(0.35, 0.35, 0.4)
		else:
			style.bg_color = Color(0.16, 0.16, 0.18)
			style.set_border_width_all(1)
			style.border_color = Color(0.22, 0.22, 0.25)
		style.set_corner_radius_all(10)
	else:
		# Classic style
		if _is_selected:
			style.bg_color = Color(0.2, 0.28, 0.38)
			style.set_border_width_all(1)
			style.border_color = Color(0.4, 0.6, 0.9)
		elif _is_hovered:
			style.bg_color = Color(0.22, 0.22, 0.26)
			style.set_border_width_all(1)
			style.border_color = Color(0.32, 0.32, 0.38)
		else:
			style.bg_color = Color(0.18, 0.18, 0.21)
			style.set_border_width_all(1)
			style.border_color = Color(0.25, 0.25, 0.28)
		style.set_corner_radius_all(4)

	if _bg_panel:
		_bg_panel.add_theme_stylebox_override("panel", style)

	# Update image container border to match (for MODERN cards)
	if _card_type == CardType.MODERN and _image_container_style:
		if _is_selected:
			_image_container_style.border_width_top = 2
			_image_container_style.border_width_left = 2
			_image_container_style.border_width_right = 2
			_image_container_style.border_color = Color(0.4, 0.6, 0.9)
		elif _is_hovered:
			_image_container_style.border_width_top = 1
			_image_container_style.border_width_left = 1
			_image_container_style.border_width_right = 1
			_image_container_style.border_color = Color(0.35, 0.35, 0.4)
		else:
			_image_container_style.border_width_top = 1
			_image_container_style.border_width_left = 1
			_image_container_style.border_width_right = 1
			_image_container_style.border_color = Color(0.22, 0.22, 0.25)


func _on_mouse_entered() -> void:
	_is_hovered = true
	_update_bg_style()


func _on_mouse_exited() -> void:
	_is_hovered = false
	_update_bg_style()


func _on_favorite_pressed() -> void:
	favorite_clicked.emit(_info)


func _on_plugin_toggle_pressed(pressed: bool) -> void:
	_is_plugin_enabled = pressed
	_update_plugin_toggle_display()
	plugin_toggled.emit(_info, _is_plugin_enabled)


func setup(info: Dictionary, is_favorite: bool = false, is_installed: bool = false) -> void:
	_info = info
	_is_favorite = is_favorite
	_is_installed = is_installed
	_update_display()


func _update_display() -> void:
	if not _title_label:
		return  # UI not built yet

	_title_label.text = _info.get("title", "Unknown")

	if _card_type == CardType.MODERN:
		_author_label.text = _info.get("author", "Unknown")
		# License
		if _license_label:
			_license_label.text = _info.get("license", "MIT")
		# Update source icon
		if _source_icon and Engine.is_editor_hint():
			var theme = EditorInterface.get_editor_theme()
			if theme:
				var source = _info.get("source", "")
				match source:
					"Godot AssetLib":
						_source_icon.texture = theme.get_icon("AssetLib", "EditorIcons")
					"Godot Store Beta":
						_source_icon.texture = theme.get_icon("GodotStore", "EditorIcons") if theme.has_icon("GodotStore", "EditorIcons") else theme.get_icon("Node", "EditorIcons")
					"Godot Shaders":
						_source_icon.texture = theme.get_icon("Shader", "EditorIcons")
					_:
						_source_icon.texture = theme.get_icon("AssetLib", "EditorIcons")
	else:
		_author_label.text = "by %s" % _info.get("author", "Unknown")
		# Source badge
		var source = _info.get("source", "")
		match source:
			"Godot AssetLib":
				_source_badge.text = "AssetLib"
				_source_badge.add_theme_color_override("font_color", Color(0.4, 0.6, 0.9))
			"Godot Store Beta":
				_source_badge.text = "Beta"
				_source_badge.add_theme_color_override("font_color", Color(0.9, 0.6, 0.2))
			"Local":
				_source_badge.text = "Local"
				_source_badge.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			"Installed":
				_source_badge.text = "Installed"
				_source_badge.add_theme_color_override("font_color", Color(0.5, 0.7, 0.5))
			"This Plugin":
				_source_badge.text = "This Plugin"
				_source_badge.add_theme_color_override("font_color", Color(0.7, 0.5, 0.9))
			_:
				_source_badge.text = source
				_source_badge.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))

		_license_label.text = _info.get("license", "MIT")

	_update_favorite_display()
	_update_installed_display()


func _update_favorite_display() -> void:
	if not _favorite_btn:
		return
	if _is_favorite:
		_favorite_btn.text = "♥"
		if _card_type == CardType.MODERN:
			_favorite_btn.add_theme_color_override("font_color", Color(1.0, 0.3, 0.4))
		else:
			_favorite_btn.add_theme_color_override("font_color", Color(1.0, 0.3, 0.4))
		_favorite_btn.tooltip_text = "Remove from favorites"
	else:
		_favorite_btn.text = "♡"
		if _card_type == CardType.MODERN:
			_favorite_btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
		else:
			_favorite_btn.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
		_favorite_btn.tooltip_text = "Add to favorites"


func set_favorite(is_fav: bool) -> void:
	_is_favorite = is_fav
	_update_favorite_display()


func set_favorite_visible(visible: bool) -> void:
	if _favorite_btn:
		_favorite_btn.visible = visible


func is_favorite() -> bool:
	return _is_favorite


func _update_installed_display() -> void:
	if not _installed_badge:
		return
	if _card_type == CardType.CLASSIC:
		_installed_badge.visible = _is_installed


func set_installed(is_inst: bool) -> void:
	_is_installed = is_inst
	_update_installed_display()


func is_installed() -> bool:
	return _is_installed


func set_update_available(has_update: bool, new_version: String = "") -> void:
	_has_update = has_update
	if _update_badge and _card_type == CardType.CLASSIC:
		_update_badge.visible = has_update
		if has_update and not new_version.is_empty():
			_update_badge.text = "Update"
			_update_badge.tooltip_text = "Update available: %s" % new_version


func has_update_available() -> bool:
	return _has_update


func set_plugin_visible(visible: bool) -> void:
	_is_plugin = visible
	if _plugin_toggle_btn and _card_type == CardType.CLASSIC:
		# Never show toggle for AssetPlus itself (could break the plugin)
		var source = _info.get("source", "")
		if source == "This Plugin":
			_plugin_toggle_btn.visible = false
		else:
			_plugin_toggle_btn.visible = visible


func set_plugin_enabled(enabled: bool) -> void:
	_is_plugin_enabled = enabled
	_update_plugin_toggle_display()


func is_plugin_enabled() -> bool:
	return _is_plugin_enabled


func _update_plugin_toggle_display() -> void:
	if not _plugin_toggle_btn or _card_type == CardType.MODERN:
		return
	_plugin_toggle_btn.set_pressed_no_signal(_is_plugin_enabled)

	var style = StyleBoxFlat.new()
	style.set_corner_radius_all(10)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 2
	style.content_margin_bottom = 2

	if _is_plugin_enabled:
		_plugin_toggle_btn.text = "ON"
		style.bg_color = Color(0.25, 0.55, 0.25)
		_plugin_toggle_btn.add_theme_color_override("font_color", Color(0.85, 1.0, 0.85))
		_plugin_toggle_btn.add_theme_color_override("font_pressed_color", Color(0.85, 1.0, 0.85))
		_plugin_toggle_btn.tooltip_text = "Plugin enabled - Click to disable"
	else:
		_plugin_toggle_btn.text = "OFF"
		style.bg_color = Color(0.45, 0.25, 0.25)
		_plugin_toggle_btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.85))
		_plugin_toggle_btn.add_theme_color_override("font_pressed_color", Color(1.0, 0.85, 0.85))
		_plugin_toggle_btn.tooltip_text = "Plugin disabled - Click to enable"

	_plugin_toggle_btn.add_theme_stylebox_override("normal", style)
	_plugin_toggle_btn.add_theme_stylebox_override("hover", style)
	_plugin_toggle_btn.add_theme_stylebox_override("pressed", style)
	_plugin_toggle_btn.add_theme_stylebox_override("focus", style)


func set_icon(texture: Texture2D) -> void:
	if _icon_rect:
		_icon_rect.texture = texture
		if _icon_placeholder and texture:
			_icon_placeholder.visible = false
			_stop_shimmer_animation()
		# For MODERN cards, use CENTERED for square images to prevent over-zooming
		if _card_type == CardType.MODERN and texture:
			var img_size = texture.get_size()
			var ratio = img_size.x / max(img_size.y, 1.0)
			# Square images (ratio between 0.9 and 1.1) should not be cropped/zoomed
			if ratio > 0.9 and ratio < 1.1:
				_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			else:
				_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED


func _start_shimmer_animation() -> void:
	if not _icon_placeholder or not _placeholder_style:
		return
	_stop_shimmer_animation()
	_shimmer_tween = create_tween()
	_shimmer_tween.set_loops()
	var base_color = Color(0.2, 0.2, 0.25, 1.0)
	var light_color = Color(0.28, 0.28, 0.33, 1.0)
	_shimmer_tween.tween_property(_placeholder_style, "bg_color", light_color, 0.6).set_trans(Tween.TRANS_SINE)
	_shimmer_tween.tween_property(_placeholder_style, "bg_color", base_color, 0.6).set_trans(Tween.TRANS_SINE)


func _stop_shimmer_animation() -> void:
	if _shimmer_tween and _shimmer_tween.is_valid():
		_shimmer_tween.kill()
		_shimmer_tween = null


func get_info() -> Dictionary:
	return _info


func get_asset_id() -> String:
	return _info.get("asset_id", "")


func set_like_count(count: int) -> void:
	## Update like count display
	if not _like_button or not is_instance_valid(_like_button):
		return

	_like_button.set_like_count(count)


func set_liked(liked: bool, animate: bool = false) -> void:
	## Update liked state (red heart if liked, grey if not)
	if not _like_button or not is_instance_valid(_like_button):
		return

	_like_button.set_liked(liked, animate)


func set_always_show_count(show: bool) -> void:
	## Set whether to show "0" when count is 0 (for Store view)
	if not _like_button or not is_instance_valid(_like_button):
		return

	_like_button.set_always_show_count(show)


func set_like_button_visible(visible: bool) -> void:
	## Show or hide the like button entirely (for local items without source)
	if not _like_button or not is_instance_valid(_like_button):
		return

	_like_button.visible = visible
