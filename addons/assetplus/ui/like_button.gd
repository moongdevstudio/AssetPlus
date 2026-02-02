@tool
extends PanelContainer

## Like button with heart icon and counter (like Instagram/Facebook)
## Shows grey heart when not liked, blue bubble when user has liked
## Grey bubble with count when others liked but not the user

signal like_clicked()

var _heart_label: Label
var _count_label: Label
var _hbox: HBoxContainer
var _like_count: int = 0
var _is_liked: bool = false
var _clickable: bool = true
var _bg_style: StyleBoxFlat
var _anim_tween: Tween
var _always_show_count: bool = false  # If true, show "0" when count is 0

func _init() -> void:
	custom_minimum_size = Vector2(0, 22)  # Smaller height
	size_flags_horizontal = Control.SIZE_SHRINK_END  # Align to right, grow left
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Background style (blue bubble when count > 0, transparent otherwise)
	_bg_style = StyleBoxFlat.new()
	_bg_style.bg_color = Color(0, 0, 0, 0)  # Transparent by default
	_bg_style.set_corner_radius_all(11)
	_bg_style.set_border_width_all(1)
	_bg_style.border_color = Color(0.5, 0.5, 0.5, 0.6)  # Grey border
	_bg_style.content_margin_left = 6
	_bg_style.content_margin_right = 6
	_bg_style.content_margin_top = 2
	_bg_style.content_margin_bottom = 2
	add_theme_stylebox_override("panel", _bg_style)

	# HBox for heart + count
	_hbox = HBoxContainer.new()
	_hbox.add_theme_constant_override("separation", 2)  # Reduced gap between heart and count
	_hbox.size_flags_horizontal = Control.SIZE_SHRINK_END  # Align content to right
	add_child(_hbox)

	# Heart icon
	_heart_label = Label.new()
	_heart_label.text = "♥"
	_heart_label.add_theme_font_size_override("font_size", 16)
	_heart_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_heart_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_heart_label.pivot_offset = Vector2(8, 10)  # Center pivot for animation
	_hbox.add_child(_heart_label)

	# Count label
	_count_label = Label.new()
	_count_label.text = "0"
	_count_label.add_theme_font_size_override("font_size", 13)
	_count_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hbox.add_child(_count_label)

	# Make count bold
	if Engine.is_editor_hint():
		var editor_theme = EditorInterface.get_editor_theme()
		if editor_theme and editor_theme.has_font("bold", "EditorFonts"):
			_count_label.add_theme_font_override("font", editor_theme.get_font("bold", "EditorFonts"))


func _gui_input(event: InputEvent) -> void:
	if not _clickable:
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			like_clicked.emit()
			accept_event()


func set_like_count(count: int) -> void:
	_like_count = count
	_update_display()


func set_liked(liked: bool, animate: bool = false) -> void:
	var was_liked = _is_liked
	_is_liked = liked
	_update_display()

	# Play animation if we just liked (not unliked)
	if animate and liked and not was_liked:
		_play_like_animation()


func set_clickable(clickable: bool) -> void:
	_clickable = clickable
	mouse_filter = Control.MOUSE_FILTER_STOP if clickable else Control.MOUSE_FILTER_IGNORE


func set_always_show_count(show: bool) -> void:
	## If true, show "0" when count is 0 (for Store view)
	_always_show_count = show
	_update_display()


func _play_like_animation() -> void:
	## Play a pop/bounce animation on the heart when liked
	if not _heart_label or not is_inside_tree():
		return

	# Kill any existing animation
	if _anim_tween and _anim_tween.is_valid():
		_anim_tween.kill()

	_anim_tween = create_tween()
	_anim_tween.set_ease(Tween.EASE_OUT)
	_anim_tween.set_trans(Tween.TRANS_ELASTIC)

	# Scale up then back to normal (pop effect)
	_heart_label.scale = Vector2(1, 1)
	_anim_tween.tween_property(_heart_label, "scale", Vector2(1.5, 1.5), 0.15)
	_anim_tween.tween_property(_heart_label, "scale", Vector2(1.0, 1.0), 0.3)


func _update_display() -> void:
	if not _heart_label or not _count_label or not _bg_style:
		return

	# Update background (blue bubble ONLY if user has liked, not just because others liked)
	if _is_liked:
		_bg_style.bg_color = Color(0.35, 0.55, 0.7, 0.9)  # Muted blue bubble
		_heart_label.add_theme_color_override("font_color", Color(1, 1, 1, 1.0))  # White heart
		_count_label.add_theme_color_override("font_color", Color(1, 1, 1, 1.0))  # White count
	else:
		_bg_style.bg_color = Color(0.3, 0.3, 0.3, 0.4)  # Grey bubble
		_heart_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))  # Grey heart
		_count_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))  # Grey count

	# Update count text
	_count_label.text = str(_like_count)

	# Show count if > 0, or if _always_show_count is true
	_count_label.visible = _like_count > 0 or _always_show_count
