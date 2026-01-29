@tool
extends Control

## Card component for displaying an asset in the grid

signal clicked(info: Dictionary)
signal favorite_clicked(info: Dictionary)
signal plugin_toggled(info: Dictionary, enabled: bool)

var _icon_rect: TextureRect
var _icon_placeholder: ColorRect
var _shimmer_tween: Tween
var _title_label: Label
var _author_label: Label
var _source_badge: Label
var _license_label: Label
var _favorite_btn: Button
var _bg_panel: Panel
var _installed_badge: Label
var _update_badge: Label
var _plugin_toggle_btn: Button

var _info: Dictionary = {}
var _is_favorite: bool = false
var _is_hovered: bool = false
var _is_selected: bool = false
var _is_installed: bool = false
var _is_plugin: bool = false
var _is_plugin_enabled: bool = false
var _has_update: bool = false


func _init() -> void:
	custom_minimum_size = Vector2(300, 120)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	_build_ui()
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	# If setup was called before _ready, update display now
	if not _info.is_empty():
		_update_display()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			clicked.emit(_info)
			accept_event()


func _build_ui() -> void:
	# Background panel
	_bg_panel = Panel.new()
	_bg_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_bg_panel)
	_update_bg_style()

	# Main HBox layout (like native AssetLib)
	var main_hbox = HBoxContainer.new()
	main_hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_hbox.add_theme_constant_override("separation", 10)
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
	icon_container.custom_minimum_size = Vector2(96, 96)
	icon_container.mouse_filter = Control.MOUSE_FILTER_PASS
	left_margin.add_child(icon_container)

	# Skeleton loading placeholder
	_icon_placeholder = ColorRect.new()
	_icon_placeholder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon_placeholder.color = Color(0.2, 0.2, 0.25, 1.0)
	_icon_placeholder.mouse_filter = Control.MOUSE_FILTER_PASS
	icon_container.add_child(_icon_placeholder)
	_start_shimmer_animation()

	# Icon (on top of placeholder)
	_icon_rect = TextureRect.new()
	_icon_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_rect.mouse_filter = Control.MOUSE_FILTER_PASS
	icon_container.add_child(_icon_rect)

	# Center: title + author + badges
	var center_vbox = VBoxContainer.new()
	center_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_vbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	center_vbox.add_theme_constant_override("separation", 2)
	center_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	main_hbox.add_child(center_vbox)

	# Title
	_title_label = Label.new()
	_title_label.text = "Asset Name"
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title_label.add_theme_font_size_override("font_size", 15)
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

	# Right side: installed badge + favorite button
	var right_margin = MarginContainer.new()
	right_margin.add_theme_constant_override("margin_right", 8)
	right_margin.add_theme_constant_override("margin_top", 4)
	right_margin.mouse_filter = Control.MOUSE_FILTER_PASS
	main_hbox.add_child(right_margin)

	var right_vbox = VBoxContainer.new()
	right_vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	right_vbox.add_theme_constant_override("separation", 4)
	right_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	right_margin.add_child(right_vbox)

	# Installed badge
	_installed_badge = Label.new()
	_installed_badge.text = "Installed"
	_installed_badge.add_theme_font_size_override("font_size", 10)
	_installed_badge.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2))
	_installed_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_installed_badge.mouse_filter = Control.MOUSE_FILTER_PASS
	_installed_badge.visible = false
	right_vbox.add_child(_installed_badge)

	# Style the badge with background
	var badge_style = StyleBoxFlat.new()
	badge_style.bg_color = Color(0.4, 0.85, 0.4)
	badge_style.set_corner_radius_all(3)
	badge_style.content_margin_left = 4
	badge_style.content_margin_right = 4
	badge_style.content_margin_top = 2
	badge_style.content_margin_bottom = 2
	_installed_badge.add_theme_stylebox_override("normal", badge_style)

	# Update available badge
	_update_badge = Label.new()
	_update_badge.text = "Update"
	_update_badge.add_theme_font_size_override("font_size", 10)
	_update_badge.add_theme_color_override("font_color", Color(0.15, 0.15, 0.15))
	_update_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_update_badge.mouse_filter = Control.MOUSE_FILTER_PASS
	_update_badge.visible = false
	_update_badge.tooltip_text = "An update is available"
	right_vbox.add_child(_update_badge)

	# Style the update badge with orange background
	var update_badge_style = StyleBoxFlat.new()
	update_badge_style.bg_color = Color(0.95, 0.7, 0.2)
	update_badge_style.set_corner_radius_all(3)
	update_badge_style.content_margin_left = 4
	update_badge_style.content_margin_right = 4
	update_badge_style.content_margin_top = 2
	update_badge_style.content_margin_bottom = 2
	_update_badge.add_theme_stylebox_override("normal", update_badge_style)

	# Favorite button
	_favorite_btn = Button.new()
	_favorite_btn.text = "♡"
	_favorite_btn.flat = true
	_favorite_btn.custom_minimum_size = Vector2(28, 28)
	_favorite_btn.add_theme_font_size_override("font_size", 18)
	_favorite_btn.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	_favorite_btn.tooltip_text = "Add to favorites"
	_favorite_btn.pressed.connect(_on_favorite_pressed)
	right_vbox.add_child(_favorite_btn)

	# Plugin enable/disable toggle (hidden by default) - styled as ON/OFF switch
	_plugin_toggle_btn = Button.new()
	_plugin_toggle_btn.text = "OFF"
	_plugin_toggle_btn.toggle_mode = true
	_plugin_toggle_btn.custom_minimum_size = Vector2(38, 20)
	_plugin_toggle_btn.add_theme_font_size_override("font_size", 10)
	_plugin_toggle_btn.tooltip_text = "Enable/Disable plugin"
	_plugin_toggle_btn.toggled.connect(_on_plugin_toggle_pressed)
	_plugin_toggle_btn.visible = false
	right_vbox.add_child(_plugin_toggle_btn)


func _update_bg_style() -> void:
	var style = StyleBoxFlat.new()

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
	_bg_panel.add_theme_stylebox_override("panel", style)


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
	# Update display if UI is already built (called after _ready)
	# Otherwise _ready will call _update_display
	_update_display()


func _update_display() -> void:
	if not _title_label:
		return  # UI not built yet
	_title_label.text = _info.get("title", "Unknown")
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
		return  # UI not built yet
	if _is_favorite:
		_favorite_btn.text = "♥"
		_favorite_btn.add_theme_color_override("font_color", Color(1.0, 0.3, 0.4))
		_favorite_btn.tooltip_text = "Remove from favorites"
	else:
		_favorite_btn.text = "♡"
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
		return  # UI not built yet
	_installed_badge.visible = _is_installed


func set_installed(is_inst: bool) -> void:
	_is_installed = is_inst
	_update_installed_display()


func is_installed() -> bool:
	return _is_installed


func set_update_available(has_update: bool, new_version: String = "") -> void:
	_has_update = has_update
	if _update_badge:
		_update_badge.visible = has_update
		if has_update and not new_version.is_empty():
			_update_badge.text = "Update"
			_update_badge.tooltip_text = "Update available: %s" % new_version


func has_update_available() -> bool:
	return _has_update


func set_plugin_visible(visible: bool) -> void:
	_is_plugin = visible
	if _plugin_toggle_btn:
		_plugin_toggle_btn.visible = visible


func set_plugin_enabled(enabled: bool) -> void:
	_is_plugin_enabled = enabled
	_update_plugin_toggle_display()


func is_plugin_enabled() -> bool:
	return _is_plugin_enabled


func _update_plugin_toggle_display() -> void:
	if not _plugin_toggle_btn:
		return
	# Use set_pressed_no_signal to avoid triggering the toggled signal
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
		# Hide placeholder when icon is set
		if _icon_placeholder and texture:
			_icon_placeholder.visible = false
			_stop_shimmer_animation()


func _start_shimmer_animation() -> void:
	if not _icon_placeholder:
		return
	_stop_shimmer_animation()
	_shimmer_tween = create_tween()
	_shimmer_tween.set_loops()
	# Animate color to create shimmer effect
	var base_color = Color(0.2, 0.2, 0.25, 1.0)
	var light_color = Color(0.28, 0.28, 0.33, 1.0)
	_shimmer_tween.tween_property(_icon_placeholder, "color", light_color, 0.6).set_trans(Tween.TRANS_SINE)
	_shimmer_tween.tween_property(_icon_placeholder, "color", base_color, 0.6).set_trans(Tween.TRANS_SINE)


func _stop_shimmer_animation() -> void:
	if _shimmer_tween and _shimmer_tween.is_valid():
		_shimmer_tween.kill()
		_shimmer_tween = null


func get_info() -> Dictionary:
	return _info
