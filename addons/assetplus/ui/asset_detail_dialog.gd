@tool
extends AcceptDialog

## Detail popup for an asset - fetches full details and handles installation

signal install_requested(asset_info: Dictionary)
signal uninstall_requested(asset_info: Dictionary)
signal update_requested(asset_info: Dictionary)
signal favorite_toggled(asset_info: Dictionary, is_favorite: bool)
signal remove_from_global_folder_requested(asset_info: Dictionary)
signal add_to_global_folder_requested(asset_info: Dictionary)
signal extract_package_requested(asset_info: Dictionary, target_folder: String)
signal metadata_edited(asset_info: Dictionary, new_metadata: Dictionary)

const SettingsDialog = preload("res://addons/assetplus/ui/settings_dialog.gd")
const ImageGalleryViewer = preload("res://addons/assetplus/ui/image_gallery_viewer.gd")

const SOURCE_GODOT = "Godot AssetLib"
const SOURCE_GODOT_BETA = "Godot Store Beta"
const SOURCE_SHADERS = "Godot Shaders"

var _icon_rect: TextureRect
var _icon_panel: PanelContainer
var _gallery_btn: Button
var _title_label: Label
var _author_label: Label
var _version_label: Label
var _category_label: Label
var _license_label: Label
var _date_label: Label
var _date_row_label: Label  # The "Uploaded:" label, to hide when no date
var _source_btn: Button  # Clickable source link
var _description: RichTextLabel
var _install_btn: Button
var _update_btn: Button
var _open_browser_btn: Button
var _favorite_btn: Button
var _like_count_label: Label
var _explore_btn: MenuButton
var _explore_popup: PopupMenu
var _remove_global_btn: Button
var _add_to_global_btn: Button
var _edit_global_btn: Button
var _extract_package_btn: Button
var _loading_label: Label
var _file_list_btn: Button
var _download_shader_btn: Button  # Download button for shaders
var _install_demo_btn: Button  # Install demo project button for shaders with GitHub demos
var _demo_project_url: String = ""  # GitHub URL for demo project

var _asset_info: Dictionary = {}
var _shader_html: String = ""  # Store HTML for shader code extraction
var _is_favorite: bool = false


func get_asset_id() -> String:
	return _asset_info.get("asset_id", "")
var _is_installed: bool = false
var _has_update: bool = false
var _update_version: String = ""
var _download_url: String = ""
var _http_request: HTTPRequest
var _tracked_files: Array = []  # Array of {path: String, uid: String}
var _gallery_images: Array = []  # Array of {url: String, thumbnail_url: String, texture: Texture2D}


func _init() -> void:
	title = "Asset Details"
	size = Vector2i(600, 500)
	ok_button_text = "Close"


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	var main_hbox = HBoxContainer.new()
	main_hbox.add_theme_constant_override("separation", 20)
	add_child(main_hbox)

	# Left side - icon and buttons
	var left_vbox = VBoxContainer.new()
	left_vbox.add_theme_constant_override("separation", 12)
	left_vbox.custom_minimum_size.x = 180
	main_hbox.add_child(left_vbox)

	# Icon - use clip_children to ensure rounded corners work with image
	_icon_panel = PanelContainer.new()
	var icon_style = StyleBoxFlat.new()
	icon_style.bg_color = Color(0.12, 0.12, 0.15)
	icon_style.set_corner_radius_all(8)
	_icon_panel.add_theme_stylebox_override("panel", icon_style)
	_icon_panel.custom_minimum_size = Vector2(180, 180)
	_icon_panel.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	left_vbox.add_child(_icon_panel)

	_icon_rect = TextureRect.new()
	_icon_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	_icon_rect.gui_input.connect(_on_icon_clicked)
	_icon_panel.add_child(_icon_rect)

	# Gallery button overlay (bottom-right corner of image)
	# Use a Control wrapper to position properly inside PanelContainer
	var gallery_wrapper = Control.new()
	gallery_wrapper.set_anchors_preset(Control.PRESET_FULL_RECT)
	gallery_wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon_panel.add_child(gallery_wrapper)

	_gallery_btn = Button.new()
	_gallery_btn.text = "1/1"
	_gallery_btn.tooltip_text = "View gallery"
	_gallery_btn.add_theme_font_size_override("font_size", 11)
	_gallery_btn.size = Vector2(36, 22)
	# Position at bottom-right
	_gallery_btn.anchor_left = 1.0
	_gallery_btn.anchor_right = 1.0
	_gallery_btn.anchor_top = 1.0
	_gallery_btn.anchor_bottom = 1.0
	_gallery_btn.offset_left = -42
	_gallery_btn.offset_right = -6
	_gallery_btn.offset_top = -28
	_gallery_btn.offset_bottom = -6
	# Dark semi-transparent background
	var gallery_btn_style = StyleBoxFlat.new()
	gallery_btn_style.bg_color = Color(0, 0, 0, 0.75)
	gallery_btn_style.set_corner_radius_all(4)
	gallery_btn_style.content_margin_left = 6
	gallery_btn_style.content_margin_right = 6
	gallery_btn_style.content_margin_top = 2
	gallery_btn_style.content_margin_bottom = 2
	_gallery_btn.add_theme_stylebox_override("normal", gallery_btn_style)
	_gallery_btn.add_theme_stylebox_override("pressed", gallery_btn_style)
	var gallery_btn_hover = StyleBoxFlat.new()
	gallery_btn_hover.bg_color = Color(0.2, 0.45, 0.9, 0.9)
	gallery_btn_hover.set_corner_radius_all(4)
	gallery_btn_hover.content_margin_left = 6
	gallery_btn_hover.content_margin_right = 6
	gallery_btn_hover.content_margin_top = 2
	gallery_btn_hover.content_margin_bottom = 2
	_gallery_btn.add_theme_stylebox_override("hover", gallery_btn_hover)
	_gallery_btn.pressed.connect(_on_gallery_pressed)
	_gallery_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	gallery_wrapper.add_child(_gallery_btn)

	# Get editor theme for icons
	var theme = EditorInterface.get_editor_theme()

	# Update button (green, visible when update available) - BEFORE Install so it appears above
	_update_btn = Button.new()
	_update_btn.text = "Update"
	_update_btn.icon = theme.get_icon("Reload", "EditorIcons")
	_update_btn.pressed.connect(_on_update_pressed)
	_update_btn.visible = false  # Only show when update available
	# Green style for update button
	var update_style = StyleBoxFlat.new()
	update_style.bg_color = Color(0.2, 0.5, 0.2)
	update_style.set_corner_radius_all(4)
	update_style.content_margin_left = 10
	update_style.content_margin_right = 10
	update_style.content_margin_top = 5
	update_style.content_margin_bottom = 5
	_update_btn.add_theme_stylebox_override("normal", update_style)
	var update_hover_style = StyleBoxFlat.new()
	update_hover_style.bg_color = Color(0.25, 0.6, 0.25)
	update_hover_style.set_corner_radius_all(4)
	update_hover_style.content_margin_left = 10
	update_hover_style.content_margin_right = 10
	update_hover_style.content_margin_top = 5
	update_hover_style.content_margin_bottom = 5
	_update_btn.add_theme_stylebox_override("hover", update_hover_style)
	left_vbox.add_child(_update_btn)

	# Install/Uninstall button
	_install_btn = Button.new()
	_install_btn.text = "Install"
	_install_btn.icon = theme.get_icon("AssetLib", "EditorIcons")
	_install_btn.pressed.connect(_on_install_pressed)
	left_vbox.add_child(_install_btn)

	_open_browser_btn = Button.new()
	_open_browser_btn.text = "Open in Browser"
	_open_browser_btn.icon = theme.get_icon("ExternalLink", "EditorIcons")
	_open_browser_btn.pressed.connect(_on_open_browser_pressed)
	_open_browser_btn.visible = false  # Only show for web sources
	left_vbox.add_child(_open_browser_btn)

	_add_to_global_btn = Button.new()
	_add_to_global_btn.text = "Add to Global Folder"
	_add_to_global_btn.icon = theme.get_icon("Folder", "EditorIcons")
	_add_to_global_btn.pressed.connect(_on_add_to_global_pressed)
	_add_to_global_btn.visible = false  # Only show when installed
	left_vbox.add_child(_add_to_global_btn)

	# Explore menu button (combines "Open in Explorer" and "Open in Godot")
	_explore_btn = MenuButton.new()
	_explore_btn.text = "Explore..."
	_explore_btn.icon = theme.get_icon("Filesystem", "EditorIcons")
	_explore_btn.flat = false  # Same style as other buttons
	_explore_btn.visible = false  # Only show when installed
	left_vbox.add_child(_explore_btn)

	_explore_popup = _explore_btn.get_popup()
	_explore_popup.add_icon_item(theme.get_icon("FileTree", "EditorIcons"), "In Godot FileSystem", 0)
	_explore_popup.add_icon_item(theme.get_icon("Filesystem", "EditorIcons"), "In OS File Explorer", 1)
	_explore_popup.id_pressed.connect(_on_explore_menu_pressed)

	_remove_global_btn = Button.new()
	_remove_global_btn.text = "Remove from Global"
	_remove_global_btn.icon = theme.get_icon("Remove", "EditorIcons")
	_remove_global_btn.pressed.connect(_on_remove_global_pressed)
	_remove_global_btn.modulate = Color(1, 0.6, 0.6)
	_remove_global_btn.visible = false  # Only show for global folder items
	left_vbox.add_child(_remove_global_btn)

	_edit_global_btn = Button.new()
	_edit_global_btn.text = "Edit Info"
	_edit_global_btn.icon = theme.get_icon("Edit", "EditorIcons")
	_edit_global_btn.pressed.connect(_on_edit_global_pressed)
	_edit_global_btn.visible = false  # Only show for global folder items
	left_vbox.add_child(_edit_global_btn)

	_extract_package_btn = Button.new()
	_extract_package_btn.text = "Extract Package..."
	_extract_package_btn.icon = theme.get_icon("Unlinked", "EditorIcons")
	_extract_package_btn.pressed.connect(_on_extract_package_pressed)
	_extract_package_btn.visible = false  # Only show for global folder items
	left_vbox.add_child(_extract_package_btn)

	# Favorite button (with heart icon, no like count displayed)
	_favorite_btn = Button.new()
	_favorite_btn.text = "  Add to Favorites"
	_favorite_btn.icon = theme.get_icon("Heart", "EditorIcons")
	_favorite_btn.pressed.connect(_on_favorite_pressed)
	left_vbox.add_child(_favorite_btn)

	# Keep _like_count_label for compatibility but hidden
	_like_count_label = Label.new()
	_like_count_label.visible = false
	add_child(_like_count_label)

	# File list button - shows tracked files
	_file_list_btn = Button.new()
	_file_list_btn.text = "File List"
	_file_list_btn.icon = theme.get_icon("FileList", "EditorIcons")
	_file_list_btn.pressed.connect(_on_file_list_pressed)
	_file_list_btn.visible = false  # Only show when there are tracked files
	left_vbox.add_child(_file_list_btn)

	# Download shader button - only for Godot Shaders source (acts as Install button)
	_download_shader_btn = Button.new()
	_download_shader_btn.text = "Install Shader"
	_download_shader_btn.icon = theme.get_icon("Shader", "EditorIcons")
	_download_shader_btn.pressed.connect(_on_download_shader_pressed)
	_download_shader_btn.visible = false  # Only show for shaders
	left_vbox.add_child(_download_shader_btn)

	# Install demo project button - only for shaders with GitHub demo links
	_install_demo_btn = Button.new()
	_install_demo_btn.text = "Install Demo Project"
	_install_demo_btn.icon = theme.get_icon("GitHub", "EditorIcons") if theme.has_icon("GitHub", "EditorIcons") else theme.get_icon("AssetLib", "EditorIcons")
	_install_demo_btn.pressed.connect(_on_install_demo_pressed)
	_install_demo_btn.visible = false  # Only show when demo URL is found
	left_vbox.add_child(_install_demo_btn)

	# Right side - info
	var right_vbox = VBoxContainer.new()
	right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_theme_constant_override("separation", 8)
	main_hbox.add_child(right_vbox)

	# Title row (title + loading indicator on the same line)
	var title_row = HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 12)
	right_vbox.add_child(title_row)

	_title_label = Label.new()
	_title_label.text = "Asset Name"
	_title_label.add_theme_font_size_override("font_size", 20)
	_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_title_label)

	_loading_label = Label.new()
	_loading_label.text = "Fetching..."
	_loading_label.add_theme_font_size_override("font_size", 11)
	_loading_label.add_theme_color_override("font_color", Color(0.5, 0.6, 0.8))
	_loading_label.visible = false
	_loading_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_row.add_child(_loading_label)

	# Meta info grid
	var meta_grid = GridContainer.new()
	meta_grid.columns = 2
	meta_grid.add_theme_constant_override("h_separation", 12)
	meta_grid.add_theme_constant_override("v_separation", 4)
	right_vbox.add_child(meta_grid)

	_add_meta_row(meta_grid, "Author:", "_author_label")

	_add_meta_row(meta_grid, "Version:", "_version_label")
	_add_meta_row(meta_grid, "Category:", "_category_label")
	_add_meta_row(meta_grid, "License:", "_license_label")

	# Date row (shows "-" when no date, updated when fetch completes)
	_date_row_label = Label.new()
	_date_row_label.text = "Uploaded:"
	_date_row_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	meta_grid.add_child(_date_row_label)

	_date_label = Label.new()
	_date_label.text = "-"
	meta_grid.add_child(_date_label)

	# Source row - clickable button for web sources
	var source_label = Label.new()
	source_label.text = "Source:"
	source_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	meta_grid.add_child(source_label)

	_source_btn = Button.new()
	_source_btn.flat = true
	_source_btn.text = "-"
	_source_btn.add_theme_color_override("font_color", Color(0.4, 0.7, 1.0))
	_source_btn.add_theme_color_override("font_hover_color", Color(0.6, 0.85, 1.0))
	_source_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_source_btn.pressed.connect(_on_source_pressed)
	meta_grid.add_child(_source_btn)

	right_vbox.add_child(HSeparator.new())

	# Description header
	var desc_label = Label.new()
	desc_label.text = "Description"
	desc_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	right_vbox.add_child(desc_label)

	# Description
	_description = RichTextLabel.new()
	_description.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_description.bbcode_enabled = true
	_description.scroll_active = true
	right_vbox.add_child(_description)


func _add_meta_row(grid: GridContainer, label_text: String, var_name: String) -> void:
	var label = Label.new()
	label.text = label_text
	label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	grid.add_child(label)

	var value = Label.new()
	value.text = "-"
	grid.add_child(value)

	set(var_name, value)


func _format_date(date_str: String) -> String:
	## Format a date string to a more readable format
	## Handles formats: "2024-01-15 12:34:56", "2024-01-15T12:34:56Z", "2024-01-15"
	if date_str.is_empty():
		return "-"

	# Remove time part and timezone for cleaner display
	var date_only = date_str
	if "T" in date_str:
		date_only = date_str.split("T")[0]
	elif " " in date_str:
		date_only = date_str.split(" ")[0]

	# Parse YYYY-MM-DD format
	var parts = date_only.split("-")
	if parts.size() >= 3:
		var year = parts[0]
		var month_num = int(parts[1])
		var day = parts[2]
		var months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
		if month_num >= 1 and month_num <= 12:
			return "%s %s, %s" % [months[month_num], day, year]

	# Fallback: return as-is
	return date_str


func setup(info: Dictionary, is_favorite: bool = false, is_installed: bool = false, icon_texture: Texture2D = null) -> void:
	_asset_info = info
	_is_favorite = is_favorite
	_is_installed = is_installed
	_download_url = ""
	_shader_html = ""  # Reset shader HTML

	# Hide download shader button by default (will be shown after shader details are fetched)
	if _download_shader_btn:
		_download_shader_btn.visible = false
	# Hide install demo button by default (will be shown if demo URL is found)
	if _install_demo_btn:
		_install_demo_btn.visible = false
	_demo_project_url = ""

	# Show basic info immediately
	_title_label.text = info.get("title", "Unknown")
	_author_label.text = info.get("author", "Unknown")
	_version_label.text = info.get("version", "-") if not info.get("version", "").is_empty() else "-"
	_category_label.text = info.get("category", "-") if not info.get("category", "").is_empty() else "-"
	_license_label.text = info.get("license", "MIT")

	# Show date if available (hide row if no date)
	var raw_date = info.get("modify_date", "")
	var is_package_date = false
	if raw_date.is_empty():
		raw_date = info.get("package_date", "")  # For packages, use file creation date
		is_package_date = not raw_date.is_empty()
	if not raw_date.is_empty():
		_date_label.text = _format_date(raw_date)
		_date_row_label.text = "Created:" if is_package_date else "Uploaded:"
	else:
		# No date yet - show "-" (will be updated when fetch completes)
		_date_label.text = "-"
		_date_row_label.text = "Uploaded:"

	# Setup source button - make it clickable only for web sources
	var source = info.get("source", "-")
	var original_source = info.get("original_source", "")
	var original_url = info.get("original_browse_url", "")
	if original_url.is_empty():
		original_url = info.get("original_url", "")

	var theme = EditorInterface.get_editor_theme()
	var web_icon = theme.get_icon("ExternalLink", "EditorIcons") if theme else null

	# For GlobalFolder items with original source, show "GlobalFolder (Original)" with clickable original
	if source == "GlobalFolder" and not original_source.is_empty():
		_source_btn.text = "GlobalFolder (%s)" % original_source
		if not original_url.is_empty():
			_source_btn.icon = web_icon
			_source_btn.add_theme_color_override("font_color", Color(0.4, 0.7, 1.0))
			_source_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			_source_btn.disabled = false
			_source_btn.tooltip_text = "Click to open original: %s" % original_url
		else:
			_source_btn.icon = null
			_source_btn.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
			_source_btn.mouse_default_cursor_shape = Control.CURSOR_ARROW
			_source_btn.disabled = true
			_source_btn.tooltip_text = ""
	else:
		_source_btn.text = source
		var has_url = not info.get("browse_url", "").is_empty() or not info.get("url", "").is_empty()
		var is_local_source = source in ["Local", "Installed", "GlobalFolder"]
		if has_url and not is_local_source:
			_source_btn.icon = web_icon
			_source_btn.add_theme_color_override("font_color", Color(0.4, 0.7, 1.0))
			_source_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			_source_btn.disabled = false
			_source_btn.tooltip_text = ""
		else:
			_source_btn.icon = null
			_source_btn.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
			_source_btn.mouse_default_cursor_shape = Control.CURSOR_ARROW
			_source_btn.disabled = true
			_source_btn.tooltip_text = ""

	var desc = info.get("description", "Loading...")
	_description.text = desc if desc != null else "Loading..."

	title = info.get("title", "Asset Details")

	if icon_texture:
		_icon_rect.texture = icon_texture
	else:
		# Use Godot icon as fallback placeholder
		_icon_rect.texture = EditorInterface.get_editor_theme().get_icon("Godot", "EditorIcons")

	# Check if this is AssetPlus itself (special handling)
	var is_assetplus = info.get("is_assetplus", false) or info.get("asset_id", "") == "assetplus-self"

	_update_favorite_button()
	_update_install_button()

	# Hide certain buttons for AssetPlus itself
	if is_assetplus:
		_favorite_btn.visible = false
		_install_btn.visible = false  # Can't uninstall AssetPlus from within AssetPlus
		_add_to_global_btn.visible = false

	# Show remove, edit, and extract buttons for global folder items
	_remove_global_btn.visible = source == "GlobalFolder" and not is_assetplus
	_edit_global_btn.visible = source == "GlobalFolder" and not is_assetplus
	_extract_package_btn.visible = source == "GlobalFolder" and not is_assetplus

	# For GlobalFolder items, load file list from the .godotpackage
	if source == "GlobalFolder":
		var godotpackage_path = info.get("godotpackage_path", "")
		if not godotpackage_path.is_empty() and FileAccess.file_exists(godotpackage_path):
			var files = _extract_files_from_godotpackage(godotpackage_path)
			if files.size() > 0:
				set_tracked_files(files)

	# Note: "Add to Global Folder" button visibility is handled by _update_install_button()

	# Fetch full details based on source
	if source == SOURCE_GODOT:
		_fetch_assetlib_details()
	elif source == SOURCE_GODOT_BETA:
		_fetch_beta_details()
	elif source == SOURCE_SHADERS:
		_fetch_shader_details()
	else:
		_description.text = info.get("description", "No description available.")


# Legacy functions - kept for reference but no longer used
# The installed status is now passed from main_panel which uses a registry

func _legacy_get_addon_folder_name() -> String:
	# Try to guess addon folder name from asset info (unreliable)
	var slug = _asset_info.get("asset_id", "")

	# For beta store, slug is publisher/name
	if "/" in slug:
		slug = slug.split("/")[1]

	# Common transformations
	slug = slug.replace(" ", "-").replace("_", "-").to_lower()
	return slug


func _update_install_button() -> void:
	var source = _asset_info.get("source", "")

	# Show "Explore..." menu button only when installed
	_explore_btn.visible = _is_installed

	# Show "Add to Global Folder" button for installed items (but not GlobalFolder items)
	_add_to_global_btn.visible = _is_installed and source != "GlobalFolder"

	# Show "Open in Browser" for web sources (always visible for Shaders since they can't be installed)
	var has_url = not _asset_info.get("browse_url", "").is_empty() or not _asset_info.get("url", "").is_empty()
	var is_web_source = source in [SOURCE_GODOT, SOURCE_GODOT_BETA, SOURCE_SHADERS, "GitHub"]
	_open_browser_btn.visible = has_url and is_web_source

	# Local/Installed plugins: only show uninstall button (can't reinstall from dialog)
	if source in ["Local", "Installed"]:
		_install_btn.visible = _is_installed
		_install_btn.text = "Uninstall"
		_install_btn.modulate = Color(1, 0.6, 0.6)
		return

	# GitHub assets: can reinstall if we have the URL
	if source == "GitHub":
		var github_url = _asset_info.get("url", "")
		_install_btn.visible = _is_installed or not github_url.is_empty()
		if _is_installed:
			_install_btn.text = "Uninstall"
			_install_btn.modulate = Color(1, 0.6, 0.6)
		else:
			_install_btn.text = "Install from GitHub"
			_install_btn.modulate = Color.WHITE
		return

	# Shaders: show Uninstall if installed, Install button is handled separately
	# GlobalFolder items can be installed from their .godotpackage file
	if source == SOURCE_SHADERS:
		# For shaders, only show button if installed (for uninstall)
		# Install is done via the separate "Install Shader" button
		_install_btn.visible = _is_installed
		if _is_installed:
			_install_btn.text = "Uninstall"
			_install_btn.modulate = Color(1, 0.6, 0.6)
		return

	_install_btn.visible = source in [SOURCE_GODOT, SOURCE_GODOT_BETA, "GlobalFolder"]

	if _is_installed:
		_install_btn.text = "Uninstall"
		_install_btn.modulate = Color(1, 0.6, 0.6)
	else:
		_install_btn.text = "Install"
		_install_btn.modulate = Color.WHITE


func _update_favorite_button() -> void:
	if _is_favorite:
		_favorite_btn.text = "  Remove from Favorites"
	else:
		_favorite_btn.text = "  Add to Favorites"


# ===== FETCH DETAILS =====

func _fetch_assetlib_details() -> void:
	var asset_id = _asset_info.get("asset_id", "")
	if asset_id.is_empty():
		return

	_loading_label.visible = true

	if _http_request:
		_http_request.queue_free()

	_http_request = HTTPRequest.new()
	add_child(_http_request)

	var url = "https://godotengine.org/asset-library/api/asset/%s" % asset_id
	_http_request.request_completed.connect(_on_assetlib_details_received)
	_http_request.request(url)


func _on_assetlib_details_received(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_loading_label.visible = false

	if _http_request:
		_http_request.queue_free()
		_http_request = null

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_description.text = "Failed to load details."
		return

	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		return

	var data = json.data
	if data is Dictionary:
		# Update with full details
		_author_label.text = data.get("author", _author_label.text)

		# Format version with Godot compatibility info
		var version_string = data.get("version_string", "-")
		var godot_version = data.get("godot_version", "")
		if not godot_version.is_empty():
			version_string += " | Godot %s" % godot_version
		_version_label.text = version_string

		_category_label.text = data.get("category", "-")
		_license_label.text = data.get("cost", "MIT")  # AssetLib uses "cost" for license
		_description.text = data.get("description", "No description available.")

		# Store download URL
		_download_url = data.get("download_url", "")

		# Update asset info with full data
		_asset_info["version"] = version_string
		_asset_info["godot_version"] = godot_version
		_asset_info["category"] = data.get("category", "")
		_asset_info["description"] = data.get("description", "")
		_asset_info["download_url"] = _download_url

		# Update date if available
		var modify_date = data.get("modify_date", "")
		if not modify_date.is_empty():
			_asset_info["modify_date"] = modify_date
			_date_label.text = _format_date(modify_date)
			_date_row_label.text = "Uploaded:"

		# Extract preview images if available
		var previews = data.get("previews", [])
		if previews is Array and previews.size() > 0:
			_gallery_images.clear()
			for preview in previews:
				if preview is Dictionary:
					var preview_url = preview.get("link", "")
					var thumb_url = preview.get("thumbnail", preview_url)
					if not preview_url.is_empty():
						_gallery_images.append({
							"url": preview_url,
							"thumbnail_url": thumb_url,
							"texture": null
						})
			_update_gallery_button()


func _fetch_beta_details() -> void:
	# Use JSON API instead of scraping HTML for better data (including date)
	var asset_id = _asset_info.get("asset_id", "")
	if asset_id.is_empty():
		return

	_loading_label.visible = true

	if _http_request:
		_http_request.queue_free()

	_http_request = HTTPRequest.new()
	add_child(_http_request)

	# API URL: https://store-beta.godotengine.org/api/v1/assets/{publisher}/{slug}/
	var api_url = "https://store-beta.godotengine.org/api/v1/assets/%s/" % asset_id
	_http_request.request_completed.connect(_on_beta_details_received)
	_http_request.request(api_url)


func _on_beta_details_received(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if _http_request:
		_http_request.queue_free()
		_http_request = null

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_loading_label.visible = false
		_description.text = "Failed to load details."
		return

	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		_loading_label.visible = false
		_description.text = "Failed to parse details."
		return

	var data = json.data
	if not data is Dictionary:
		_loading_label.visible = false
		_description.text = "Invalid response format."
		return

	# Update description
	var desc = data.get("description", "")
	if not desc.is_empty():
		_description.text = desc
		_asset_info["description"] = desc
	else:
		_description.text = _asset_info.get("description", "No description available.")

	# Update license
	var license_type = data.get("license_type", "")
	if not license_type.is_empty():
		_license_label.text = license_type
		_asset_info["license"] = license_type

	# Update category from tags
	var tags = data.get("tags", [])
	if tags is Array and tags.size() > 0:
		var tag_to_category = {
			"3d": "3D", "2d": "2D", "tool": "Tools", "audio": "Audio",
			"template": "Templates", "materials": "Materials", "vfx": "VFX"
		}
		var categories: Array[String] = []
		for tag in tags:
			var tag_slug = tag.get("slug", "") if tag is Dictionary else str(tag)
			if tag_to_category.has(tag_slug):
				var cat = tag_to_category[tag_slug]
				if cat not in categories:
					categories.append(cat)
		if categories.size() > 0:
			var cat_str = ", ".join(categories)
			_category_label.text = cat_str
			_asset_info["category"] = cat_str
	elif _asset_info.get("category", "").is_empty():
		_asset_info["category"] = "Tools"
		_category_label.text = "Tools"

	# Update date (Store Beta uses "last_updated" not "updated_at")
	var updated_at = data.get("last_updated", "")
	if not updated_at.is_empty():
		_asset_info["modify_date"] = updated_at
		_date_label.text = _format_date(updated_at)
		_date_row_label.text = "Uploaded:"

	# Parse gallery images from media array
	_gallery_images.clear()
	var media = data.get("media", [])
	if media is Array:
		for item in media:
			if item is Dictionary:
				var media_url = item.get("url", "")
				if media_url.begins_with("/"):
					media_url = "https://store-beta.godotengine.org" + media_url
				if not media_url.is_empty():
					_gallery_images.append({
						"url": media_url,
						"thumbnail_url": media_url,
						"texture": null
					})
	_update_gallery_button()

	# Fetch HTML page to get version info (not available in JSON API)
	_fetch_beta_versions()


func _fetch_beta_versions() -> void:
	## Fetch Store Beta HTML page to extract version and download info
	var browse_url = _asset_info.get("browse_url", "")
	if browse_url.is_empty():
		_loading_label.visible = false
		return

	if _http_request:
		_http_request.queue_free()

	_http_request = HTTPRequest.new()
	add_child(_http_request)

	_http_request.request_completed.connect(_on_beta_versions_received)
	_http_request.request(browse_url)


func _on_beta_versions_received(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_loading_label.visible = false

	if _http_request:
		_http_request.queue_free()
		_http_request = null

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return

	var html = body.get_string_from_utf8()

	# Parse version and Godot version from dropdown option
	# data-version="v1.0.0" data-min-display-version="4.0" data-max-display-version="Undefined"
	var version_regex = RegEx.new()
	version_regex.compile('data-version="([^"]+)"[^>]*data-min-display-version="([^"]+)"[^>]*data-max-display-version="([^"]+)"')
	var version_match = version_regex.search(html)
	if version_match:
		var asset_version = version_match.get_string(1)
		var min_godot = version_match.get_string(2)
		var max_godot = version_match.get_string(3)

		# Format: v1.0.0 | Godot 4.0-4.6 or v1.0.0 | Godot 4.0+
		var version_text = asset_version
		if min_godot != "Undefined" and max_godot != "Undefined":
			version_text += " | Godot %s-%s" % [min_godot, max_godot]
		elif min_godot != "Undefined":
			version_text += " | Godot %s+" % min_godot
		elif max_godot != "Undefined":
			version_text += " | Godot <=%s" % max_godot

		_version_label.text = version_text
		_asset_info["version"] = version_text

	# Parse download link: /asset/publisher/slug/download/ID/
	var download_regex = RegEx.new()
	download_regex.compile('/asset/([^/]+)/([^/]+)/download/([0-9]+)/')
	var download_match = download_regex.search(html)
	if download_match:
		var publisher = download_match.get_string(1)
		var slug = download_match.get_string(2)
		var download_id = download_match.get_string(3)
		_download_url = "https://store-beta.godotengine.org/asset/%s/%s/download/%s/" % [publisher, slug, download_id]
		_asset_info["download_url"] = _download_url


func _fetch_shader_details() -> void:
	var browse_url = _asset_info.get("browse_url", "")
	if browse_url.is_empty():
		return

	_loading_label.visible = true

	if _http_request:
		_http_request.queue_free()

	_http_request = HTTPRequest.new()
	add_child(_http_request)

	_http_request.request_completed.connect(_on_shader_details_received)
	_http_request.request(browse_url)


func _on_shader_details_received(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_loading_label.visible = false

	if _http_request:
		_http_request.queue_free()
		_http_request = null

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_description.text = "Failed to load shader details."
		return

	var html = body.get_string_from_utf8()

	# Store HTML for shader code extraction
	_shader_html = html

	# Show download button for shaders (only if not already installed)
	if _download_shader_btn:
		_download_shader_btn.visible = not _is_installed

	# Shader category is already set correctly in main_panel.gd based on shader type
	# Don't overwrite it with page tags - just update the label if category exists
	var existing_cat = _asset_info.get("category", "")
	if not existing_cat.is_empty():
		_category_label.text = existing_cat

	# Parse author from author link
	var author_regex = RegEx.new()
	author_regex.compile('class="[^"]*author[^"]*"[^>]*href="[^"]*">([^<]+)</a>')
	var author_match = author_regex.search(html)
	if author_match:
		_author_label.text = author_match.get_string(1).strip_edges()
		_asset_info["author"] = author_match.get_string(1).strip_edges()

	# Parse description - extract from content between entry-content div and code block
	var desc_found = ""

	# Find the code block position
	var code_block_idx = html.find('class="language-glsl"')
	if code_block_idx < 0:
		code_block_idx = html.find('class="code-toolbar"')
	if code_block_idx < 0:
		code_block_idx = html.find("<h5>Shader code</h5>")

	if code_block_idx > 0:
		# Find entry-content div before the code block
		var entry_content_idx = html.rfind('entry-content', code_block_idx)
		if entry_content_idx > 0 and entry_content_idx < code_block_idx:
			# Get content between entry-content and code block
			var between = html.substr(entry_content_idx, code_block_idx - entry_content_idx)

			# Collect all elements with their positions to maintain order
			var elements: Array = []  # [{pos: int, text: String, type: String}]

			# Extract paragraphs with positions
			var p_regex = RegEx.new()
			p_regex.compile('<p[^>]*>([\\s\\S]*?)</p>')
			for p_match in p_regex.search_all(between):
				var text = _clean_html(p_match.get_string(1))
				if not text.is_empty() and text.length() > 3 and text != "&nbsp;" and text != " ":
					elements.append({"pos": p_match.get_start(), "text": text, "type": "p"})

			# Extract headings with positions
			var h_regex = RegEx.new()
			h_regex.compile('<h[2-6][^>]*>([\\s\\S]*?)</h[2-6]>')
			for h_match in h_regex.search_all(between):
				var text = _clean_html(h_match.get_string(1))
				if not text.is_empty() and text.length() > 2:
					elements.append({"pos": h_match.get_start(), "text": "**" + text + "**", "type": "h"})

			# Extract list items with positions - handle nested lists properly
			var li_regex = RegEx.new()
			li_regex.compile('<li[^>]*>([\\s\\S]*?)</li>')
			for li_match in li_regex.search_all(between):
				var li_content = li_match.get_string(1)
				# Check if this li contains a nested ul/ol - if so, extract only the text before it
				var nested_ul_idx = li_content.find("<ul")
				var nested_ol_idx = li_content.find("<ol")
				var nested_idx = -1
				if nested_ul_idx >= 0 and nested_ol_idx >= 0:
					nested_idx = mini(nested_ul_idx, nested_ol_idx)
				elif nested_ul_idx >= 0:
					nested_idx = nested_ul_idx
				elif nested_ol_idx >= 0:
					nested_idx = nested_ol_idx

				if nested_idx > 0:
					# Has nested list - only take text before it
					li_content = li_content.substr(0, nested_idx)

				var text = _clean_html(li_content)
				if not text.is_empty() and text.length() > 2:
					# Detect nesting depth by counting open ul/ol tags before this li
					var before_li = between.substr(0, li_match.get_start())
					var ul_opens = before_li.count("<ul") + before_li.count("<ol")
					var ul_closes = before_li.count("</ul") + before_li.count("</ol")
					var depth = ul_opens - ul_closes
					var indent = "  ".repeat(maxi(0, depth - 1))  # -1 because first level has no indent
					var bullet = "◦" if depth > 1 else "•"  # Different bullet for nested
					elements.append({"pos": li_match.get_start(), "text": indent + bullet + " " + text, "type": "li"})

			# Sort by position to maintain original order
			elements.sort_custom(func(a, b): return a.pos < b.pos)

			# Build description - join with appropriate spacing
			var result_lines: Array = []
			var prev_type = ""
			for elem in elements:
				var text = elem.text

				if result_lines.is_empty():
					# First element - just add it
					result_lines.append(text)
				elif elem.type == "li" and prev_type == "li":
					# Consecutive list items - single newline
					result_lines.append(text)
				elif elem.type == "li" and prev_type == "h":
					# List item right after heading - single newline (they're related)
					result_lines.append(text)
				elif elem.type == "h":
					# Heading - add blank line before it
					result_lines.append("")
					result_lines.append(text)
				else:
					# Paragraph or other - add blank line before
					result_lines.append("")
					result_lines.append(text)

				prev_type = elem.type

			if result_lines.size() > 0:
				desc_found = "\n".join(result_lines)

	# Fallback: og:description meta tag
	if desc_found.is_empty():
		var og_desc_regex = RegEx.new()
		og_desc_regex.compile('og:description"\\s+content="([^"]*)"')
		var og_desc_match = og_desc_regex.search(html)
		if og_desc_match:
			desc_found = og_desc_match.get_string(1).strip_edges()

	if not desc_found.is_empty():
		# Decode HTML entities
		desc_found = _decode_html_entities(desc_found)
		_description.text = desc_found
		_asset_info["description"] = desc_found

	if _description.text == "Loading..." or _description.text.is_empty():
		_description.text = "A shader for Godot. Visit the page for more details and to copy the shader code."

	# Parse date from the page - look for the "updated" time element or published date
	var date_str = ""
	# First try: Look for the updated datetime (e.g., datetime="2023-01-03T10:16:25+00:00")
	var updated_regex = RegEx.new()
	updated_regex.compile('class="updated"[^>]*datetime="(\\d{4}-\\d{2}-\\d{2})')
	var updated_match = updated_regex.search(html)
	if updated_match:
		date_str = updated_match.get_string(1)  # Gets "2023-01-03"
	else:
		# Fallback: Look for published date
		var published_regex = RegEx.new()
		published_regex.compile('class="entry-date published"[^>]*datetime="(\\d{4}-\\d{2}-\\d{2})')
		var published_match = published_regex.search(html)
		if published_match:
			date_str = published_match.get_string(1)

	if not date_str.is_empty():
		_asset_info["modify_date"] = date_str
		# Update date label (not version label)
		if _date_label:
			_date_label.text = _format_date(date_str)

	# Parse "Get demo project" link (GitHub URL)
	# Format: <a href="https://github.com/...">...<span>...</span>Get demo project</a>
	_demo_project_url = ""
	var demo_regex = RegEx.new()
	# Look for link with href to GitHub that contains "Get demo project" text (with possible tags in between)
	demo_regex.compile('<a[^>]*href="(https?://github\\.com/[^"]+)"[^>]*>[\\s\\S]*?[Gg]et [Dd]emo [Pp]roject')
	var demo_match = demo_regex.search(html)
	if demo_match:
		_demo_project_url = demo_match.get_string(1)

	# Show/hide the Install Demo button
	if _install_demo_btn:
		_install_demo_btn.visible = not _demo_project_url.is_empty()

	# Parse gallery images from shader page
	_gallery_images.clear()
	var img_regex = RegEx.new()
	# Look for images in featured image, content, or any img tags
	img_regex.compile('(?:src|href)=["\']?(https?://[^"\'\\s>]+\\.(?:png|jpg|jpeg|webp|gif))["\']?')
	var img_matches = img_regex.search_all(html)
	var seen_urls: Dictionary = {}
	for img_match in img_matches:
		var img_url = img_match.get_string(1)
		if seen_urls.has(img_url):
			continue
		# Skip small icons and UI images
		if "icon" in img_url.to_lower() or "logo" in img_url.to_lower() or "avatar" in img_url.to_lower():
			continue
		seen_urls[img_url] = true
		_gallery_images.append({
			"url": img_url,
			"thumbnail_url": img_url,
			"texture": null
		})
	_update_gallery_button()


func _decode_html_entities(text: String) -> String:
	## Decode common HTML entities to their character equivalents
	# Named entities
	text = text.replace("&nbsp;", " ")
	text = text.replace("&amp;", "&")
	text = text.replace("&lt;", "<")
	text = text.replace("&gt;", ">")
	text = text.replace("&quot;", "\"")
	text = text.replace("&apos;", "'")
	text = text.replace("&hellip;", "...")
	text = text.replace("&mdash;", "—")
	text = text.replace("&ndash;", "–")
	text = text.replace("&lsquo;", "'")
	text = text.replace("&rsquo;", "'")
	text = text.replace("&ldquo;", "\"")
	text = text.replace("&rdquo;", "\"")
	# Numeric entities (common ones)
	text = text.replace("&#39;", "'")
	text = text.replace("&#039;", "'")
	text = text.replace("&#8211;", "–")  # en-dash
	text = text.replace("&#8212;", "—")  # em-dash
	text = text.replace("&#8216;", "'")  # left single quote
	text = text.replace("&#8217;", "'")  # right single quote (apostrophe)
	text = text.replace("&#8218;", ",")  # single low quote
	text = text.replace("&#8220;", "\"") # left double quote
	text = text.replace("&#8221;", "\"") # right double quote
	text = text.replace("&#8230;", "...") # ellipsis
	return text


func _clean_html(text: String) -> String:
	# Remove HTML tags
	var strip_regex = RegEx.new()
	strip_regex.compile('<[^>]+>')
	text = strip_regex.sub(text, " ", true)
	# Decode HTML entities
	text = _decode_html_entities(text)
	# Clean whitespace
	var ws_regex = RegEx.new()
	ws_regex.compile('\\s+')
	text = ws_regex.sub(text, " ", true)
	return text.strip_edges()


func _extract_shader_code(html: String) -> String:
	## Extract shader code from HTML page
	## Looks for code blocks containing shader_type declarations

	# Try to find code inside <pre><code> blocks (most common format)
	var code_regex = RegEx.new()
	# Match code inside <code> tags, capturing the content
	code_regex.compile('<code[^>]*>([\\s\\S]*?)</code>')
	var matches = code_regex.search_all(html)

	for match in matches:
		var code_content = match.get_string(1)
		# Decode HTML entities in code
		code_content = code_content.replace("&lt;", "<")
		code_content = code_content.replace("&gt;", ">")
		code_content = code_content.replace("&amp;", "&")
		code_content = code_content.replace("&quot;", "\"")
		code_content = code_content.replace("&#39;", "'")
		code_content = code_content.replace("&nbsp;", " ")

		# Check if this looks like shader code
		if "shader_type" in code_content:
			# Clean up the code - remove any remaining HTML tags
			var tag_regex = RegEx.new()
			tag_regex.compile('<[^>]+>')
			code_content = tag_regex.sub(code_content, "", true)
			return code_content.strip_edges()

	# Fallback: try to find shader_type directly in any pre/code block
	var pre_regex = RegEx.new()
	pre_regex.compile('<pre[^>]*>([\\s\\S]*?)</pre>')
	matches = pre_regex.search_all(html)

	for match in matches:
		var pre_content = match.get_string(1)
		pre_content = pre_content.replace("&lt;", "<")
		pre_content = pre_content.replace("&gt;", ">")
		pre_content = pre_content.replace("&amp;", "&")

		if "shader_type" in pre_content:
			var tag_regex = RegEx.new()
			tag_regex.compile('<[^>]+>')
			pre_content = tag_regex.sub(pre_content, "", true)
			return pre_content.strip_edges()

	return ""


# ===== ACTIONS =====

func _on_download_shader_pressed() -> void:
	## Handle shader install button press - emit install signal with shader data
	if _shader_html.is_empty():
		var error_dialog = AcceptDialog.new()
		error_dialog.title = "Error"
		error_dialog.dialog_text = "Shader code not loaded yet. Please wait for the page to load."
		error_dialog.confirmed.connect(func(): error_dialog.queue_free())
		EditorInterface.get_base_control().add_child(error_dialog)
		error_dialog.popup_centered()
		return

	var shader_code = _extract_shader_code(_shader_html)
	if shader_code.is_empty():
		var error_dialog = AcceptDialog.new()
		error_dialog.title = "Error"
		error_dialog.dialog_text = "Could not extract shader code from the page.\nPlease visit the page in browser and copy the code manually."
		error_dialog.confirmed.connect(func(): error_dialog.queue_free())
		EditorInterface.get_base_control().add_child(error_dialog)
		error_dialog.popup_centered()
		return

	# Add shader-specific data to asset_info for installation
	var install_info = _asset_info.duplicate()
	install_info["shader_code"] = shader_code
	# Use the displayed description text directly (already formatted with bullet points etc.)
	var desc = _asset_info.get("description", "")
	if desc.is_empty():
		desc = _description.text
	# Don't include the default placeholder text
	if desc == "A shader for Godot. Visit the page for more details and to copy the shader code.":
		desc = ""
	install_info["shader_description"] = desc

	# Emit install signal - main_panel will handle the install dialog
	install_requested.emit(install_info)


func _on_install_demo_pressed() -> void:
	## Handle install demo project button - trigger GitHub import with the demo URL
	if _demo_project_url.is_empty():
		return

	# Create asset info for the GitHub demo project
	var demo_info = {
		"title": _asset_info.get("title", "Demo") + " (Demo Project)",
		"author": _asset_info.get("author", "Unknown"),
		"source": "GitHub",
		"url": _demo_project_url,
		"browse_url": _demo_project_url,
		"description": "Demo project for " + _asset_info.get("title", "shader"),
		"category": "Demo"
	}

	# Emit install signal - main_panel will handle the GitHub import
	install_requested.emit(demo_info)


func _on_install_pressed() -> void:
	if _is_installed:
		uninstall_requested.emit(_asset_info)
	else:
		var source = _asset_info.get("source", "")
		# GitHub assets use the stored URL for reinstall
		if source == "GitHub":
			var github_url = _asset_info.get("url", "")
			if not github_url.is_empty():
				install_requested.emit(_asset_info)
			else:
				OS.shell_open(_asset_info.get("browse_url", ""))
		# GlobalFolder items install from their .godotpackage file
		elif source == "GlobalFolder":
			install_requested.emit(_asset_info)
		elif _download_url.is_empty():
			# Fallback to browse URL
			OS.shell_open(_asset_info.get("browse_url", ""))
		else:
			install_requested.emit(_asset_info)


func _on_favorite_pressed() -> void:
	if _is_favorite:
		# Show confirmation dialog before removing
		var confirm = ConfirmationDialog.new()
		confirm.title = "Remove from Favorites"
		confirm.dialog_text = "Remove \"%s\" from favorites?" % _asset_info.get("title", "this asset")
		confirm.ok_button_text = "Remove"
		confirm.confirmed.connect(func():
			_is_favorite = false
			_update_favorite_button()
			favorite_toggled.emit(_asset_info, _is_favorite)
			confirm.queue_free()
		)
		confirm.canceled.connect(func():
			confirm.queue_free()
		)
		EditorInterface.get_base_control().add_child(confirm)
		confirm.popup_centered()
	else:
		# Add to favorites directly
		_is_favorite = true
		_update_favorite_button()
		favorite_toggled.emit(_asset_info, _is_favorite)


func _on_open_pressed() -> void:
	# Try browse_url first, then fall back to url (for GitHub favorites)
	var url = _asset_info.get("browse_url", "")
	if url.is_empty():
		url = _asset_info.get("url", "")
	if not url.is_empty():
		OS.shell_open(url)


func _on_source_pressed() -> void:
	# Open the source URL in browser (only called for web sources)
	# For GlobalFolder items, try original URLs first
	var url = ""
	if _asset_info.get("source", "") == "GlobalFolder":
		url = _asset_info.get("original_browse_url", "")
		if url.is_empty():
			url = _asset_info.get("original_url", "")
	if url.is_empty():
		url = _asset_info.get("browse_url", "")
	if url.is_empty():
		url = _asset_info.get("url", "")
	if not url.is_empty():
		OS.shell_open(url)


func _on_open_browser_pressed() -> void:
	# Open the asset page in browser
	var url = _asset_info.get("browse_url", "")
	if url.is_empty():
		url = _asset_info.get("url", "")
	if not url.is_empty():
		OS.shell_open(url)


func _on_update_pressed() -> void:
	## Handle update button press - emit signal to main panel
	update_requested.emit(_asset_info)


func _on_explore_menu_pressed(id: int) -> void:
	## Handle explore menu item selection
	match id:
		0:  # In Godot FileSystem
			_open_in_godot()
		1:  # In OS File Explorer
			_open_in_explorer()


func _open_in_explorer() -> void:
	# Get the installed path(s)
	var paths = _asset_info.get("installed_paths", [])
	if paths.is_empty():
		var single_path = _asset_info.get("installed_path", "")
		if not single_path.is_empty():
			paths = [single_path]

	if paths.is_empty():
		return

	# Open the first path in native file explorer
	var path_to_open: String = paths[0]
	var global_path = ProjectSettings.globalize_path(path_to_open)

	# Use shell_show_in_file_manager to open the folder in explorer
	OS.shell_show_in_file_manager(global_path)


func _open_in_godot() -> void:
	# Get the installed path(s)
	var paths = _asset_info.get("installed_paths", [])
	if paths.is_empty():
		var single_path = _asset_info.get("installed_path", "")
		if not single_path.is_empty():
			paths = [single_path]

	if paths.is_empty():
		return

	# Navigate to the first path in Godot's FileSystem dock
	var path_to_open: String = paths[0]

	# Use EditorInterface to navigate to the path and highlight it
	EditorInterface.get_file_system_dock().navigate_to_path(path_to_open)


func set_installed(installed: bool, installed_paths: Array = []) -> void:
	_is_installed = installed
	# Update installed_paths in asset_info so "Add to Global Folder" works correctly
	if installed and installed_paths.size() > 0:
		_asset_info["installed_paths"] = installed_paths
	elif not installed:
		_asset_info.erase("installed_paths")
	_update_install_button()


func set_update_available(has_update: bool, new_version: String = "") -> void:
	## Set whether an update is available for this asset
	_has_update = has_update
	_update_version = new_version
	if _update_btn:
		_update_btn.visible = has_update
		if has_update and not new_version.is_empty():
			_update_btn.text = "Update to %s" % new_version
			_update_btn.tooltip_text = "Update available: %s" % new_version
		else:
			_update_btn.text = "Update"
			_update_btn.tooltip_text = ""


func set_like_count(count: int) -> void:
	## Update like count display
	if _like_count_label:
		_like_count_label.text = str(count) if count > 0 else "0"


func _on_remove_global_pressed() -> void:
	remove_from_global_folder_requested.emit(_asset_info)
	hide()


func _on_add_to_global_pressed() -> void:
	add_to_global_folder_requested.emit(_asset_info)
	hide()


func _on_extract_package_pressed() -> void:
	# Open folder selection dialog
	var file_dialog = EditorFileDialog.new()
	file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	file_dialog.title = "Select folder to extract package to"

	file_dialog.dir_selected.connect(func(dir: String):
		extract_package_requested.emit(_asset_info, dir)
		file_dialog.queue_free()
		hide()
	)

	file_dialog.canceled.connect(func():
		file_dialog.queue_free()
	)

	EditorInterface.get_base_control().add_child(file_dialog)
	file_dialog.popup_centered(Vector2i(800, 600))


func _on_edit_global_pressed() -> void:
	# Show edit dialog for global folder item metadata
	var edit_dialog = AcceptDialog.new()
	edit_dialog.title = "Edit Package Info"
	edit_dialog.size = Vector2i(500, 500)
	edit_dialog.ok_button_text = "Save"

	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 10)
	edit_dialog.add_child(main_vbox)

	# Icon section
	var icon_hbox = HBoxContainer.new()
	icon_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(icon_hbox)

	var icon_preview = TextureRect.new()
	icon_preview.custom_minimum_size = Vector2(64, 64)
	icon_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_preview.texture = _icon_rect.texture  # Use current icon
	icon_hbox.add_child(icon_preview)

	var icon_vbox = VBoxContainer.new()
	icon_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	icon_hbox.add_child(icon_vbox)

	var icon_label = Label.new()
	icon_label.text = "Package Icon"
	icon_vbox.add_child(icon_label)

	var icon_btn_hbox = HBoxContainer.new()
	icon_btn_hbox.add_theme_constant_override("separation", 5)
	icon_vbox.add_child(icon_btn_hbox)

	var load_thumb_btn = Button.new()
	load_thumb_btn.text = "Load Thumbnail..."
	icon_btn_hbox.add_child(load_thumb_btn)

	var change_icon_btn = Button.new()
	change_icon_btn.text = "Change Icon..."
	icon_btn_hbox.add_child(change_icon_btn)

	var remove_icon_btn = Button.new()
	remove_icon_btn.text = "Remove"
	remove_icon_btn.modulate = Color(1, 0.7, 0.7)
	icon_btn_hbox.add_child(remove_icon_btn)

	# Track new icon data using a Dictionary so lambdas can modify it
	# (GDScript lambdas capture by value, not reference, so we need a container)
	var icon_state := {"data": PackedByteArray(), "remove": false}

	# Load Thumbnail button - opens thumbnail selector dialog with package contents
	load_thumb_btn.pressed.connect(func():
		_show_thumbnail_selector_dialog(icon_preview, icon_state)
	)

	change_icon_btn.pressed.connect(func():
		var file_dialog = FileDialog.new()
		file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		file_dialog.filters = ["*.png ; PNG Images", "*.jpg,*.jpeg ; JPEG Images"]
		file_dialog.title = "Select Icon Image"

		file_dialog.file_selected.connect(func(path: String):
			var img = Image.load_from_file(path)
			if img:
				# Resize to 128x128 if larger
				if img.get_width() > 128 or img.get_height() > 128:
					img.resize(128, 128, Image.INTERPOLATE_LANCZOS)
				icon_state["data"] = img.save_png_to_buffer()
				icon_preview.texture = ImageTexture.create_from_image(img)
				icon_state["remove"] = false
			file_dialog.queue_free()
		)

		file_dialog.canceled.connect(func():
			file_dialog.queue_free()
		)

		EditorInterface.get_base_control().add_child(file_dialog)
		file_dialog.popup_centered(Vector2i(600, 400))
	)

	remove_icon_btn.pressed.connect(func():
		icon_preview.texture = EditorInterface.get_editor_theme().get_icon("Godot", "EditorIcons")
		icon_state["data"] = PackedByteArray()
		icon_state["remove"] = true
	)

	# Separator
	var sep = HSeparator.new()
	main_vbox.add_child(sep)

	var grid = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	main_vbox.add_child(grid)

	# Name
	var name_label = Label.new()
	name_label.text = "Name:"
	grid.add_child(name_label)
	var name_edit = LineEdit.new()
	name_edit.text = _asset_info.get("title", "")
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(name_edit)

	# Author
	var author_label = Label.new()
	author_label.text = "Author:"
	grid.add_child(author_label)
	var author_edit = LineEdit.new()
	author_edit.text = _asset_info.get("author", "")
	author_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(author_edit)

	# Version
	var version_label = Label.new()
	version_label.text = "Version:"
	grid.add_child(version_label)
	var version_edit = LineEdit.new()
	version_edit.text = _asset_info.get("version", "")
	version_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(version_edit)

	# Category
	var category_label = Label.new()
	category_label.text = "Category:"
	grid.add_child(category_label)
	var category_edit = LineEdit.new()
	category_edit.text = _asset_info.get("category", "")
	category_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(category_edit)

	# License
	var license_label = Label.new()
	license_label.text = "License:"
	grid.add_child(license_label)
	var license_edit = LineEdit.new()
	license_edit.text = _asset_info.get("license", "")
	license_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(license_edit)

	# Description
	var desc_label = Label.new()
	desc_label.text = "Description:"
	main_vbox.add_child(desc_label)
	var desc_edit = TextEdit.new()
	desc_edit.text = _asset_info.get("description", "")
	desc_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	desc_edit.custom_minimum_size.y = 80
	main_vbox.add_child(desc_edit)

	edit_dialog.confirmed.connect(func():
		var new_metadata = {
			"name": name_edit.text.strip_edges(),
			"author": author_edit.text.strip_edges(),
			"version": version_edit.text.strip_edges(),
			"category": category_edit.text.strip_edges(),
			"license": license_edit.text.strip_edges(),
			"description": desc_edit.text.strip_edges(),
			"_new_icon_data": icon_state["data"],
			"_remove_icon": icon_state["remove"]
		}
		metadata_edited.emit(_asset_info, new_metadata)
		# Update local display
		_title_label.text = new_metadata["name"]
		_author_label.text = new_metadata["author"]
		_version_label.text = new_metadata["version"] if not new_metadata["version"].is_empty() else "-"
		_category_label.text = new_metadata["category"] if not new_metadata["category"].is_empty() else "-"
		_license_label.text = new_metadata["license"] if not new_metadata["license"].is_empty() else "MIT"
		_description.text = new_metadata["description"]
		title = new_metadata["name"]
		# Update icon display
		var icon_data: PackedByteArray = icon_state["data"]
		if icon_data.size() > 0:
			var img = Image.new()
			if img.load_png_from_buffer(icon_data) == OK:
				_icon_rect.texture = ImageTexture.create_from_image(img)
		elif icon_state["remove"]:
			_icon_rect.texture = EditorInterface.get_editor_theme().get_icon("Godot", "EditorIcons")
		edit_dialog.queue_free()
	)

	edit_dialog.canceled.connect(func():
		edit_dialog.queue_free()
	)

	EditorInterface.get_base_control().add_child(edit_dialog)
	edit_dialog.popup_centered()


func _extract_files_from_godotpackage(zip_path: String) -> Array:
	## Extract file list from a .godotpackage (ZIP) file
	## Returns array of {path: String, uid: String}
	var files: Array = []

	var zip = ZIPReader.new()
	var err = zip.open(zip_path)
	if err != OK:
		return files

	var zip_files = zip.get_files()
	for zip_file in zip_files:
		# Skip directories and manifest
		if zip_file.ends_with("/") or zip_file == "manifest.json":
			continue
		# Skip hidden files and metadata
		if zip_file.get_file().begins_with("."):
			continue

		# Extract just the path (remove root folder prefix if any)
		var rel_path = zip_file
		# Common pattern: root_folder/actual_path
		var slash_idx = zip_file.find("/")
		if slash_idx > 0:
			rel_path = zip_file.substr(slash_idx + 1)

		if rel_path.is_empty():
			continue

		files.append({
			"path": rel_path,
			"uid": ""  # UIDs not stored in zip paths
		})

	zip.close()
	return files


func set_tracked_files(files: Array) -> void:
	## Set the tracked files for this asset (array of {path: String, uid: String})
	_tracked_files = files
	_file_list_btn.visible = files.size() > 0
	if files.size() > 0:
		_file_list_btn.text = "File List (%d)" % files.size()


func _on_file_list_pressed() -> void:
	## Show a popup with all tracked files organized by type
	var popup = AcceptDialog.new()
	popup.title = "Tracked Files - %s" % _asset_info.get("title", "Asset")
	popup.size = Vector2i(700, 500)
	popup.ok_button_text = "Close"

	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 10)
	popup.add_child(main_vbox)

	# Header with count
	var header = Label.new()
	header.text = "%d tracked files" % _tracked_files.size()
	header.add_theme_font_size_override("font_size", 14)
	main_vbox.add_child(header)

	# Organize files by type
	var files_by_type: Dictionary = {}
	for file_entry in _tracked_files:
		var path: String = file_entry.get("path", "")
		if path.is_empty():
			continue
		var ext = path.get_extension().to_lower()
		var type_name = _get_file_type_name(ext)
		if not files_by_type.has(type_name):
			files_by_type[type_name] = []
		files_by_type[type_name].append(file_entry)

	# Create scroll container for file list
	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	main_vbox.add_child(scroll)

	var scroll_vbox = VBoxContainer.new()
	scroll_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(scroll_vbox)

	# Sort type names by priority (important files first, import/other at the end)
	var type_priority = {
		"Scripts": 0,
		"Scenes": 1,
		"Resources": 2,
		"Shaders": 3,
		"Textures": 4,
		"3D Models": 5,
		"Audio": 6,
		"Fonts": 7,
		"Text/Config": 8,
		"Import Files": 98,
		"Other": 99
	}
	var type_names = files_by_type.keys()
	type_names.sort_custom(func(a, b):
		var pa = type_priority.get(a, 50)
		var pb = type_priority.get(b, 50)
		return pa < pb
	)

	for type_name in type_names:
		var files_array: Array = files_by_type[type_name]

		# Type header
		var type_header = HBoxContainer.new()
		type_header.add_theme_constant_override("separation", 8)
		scroll_vbox.add_child(type_header)

		var type_icon = TextureRect.new()
		type_icon.custom_minimum_size = Vector2(16, 16)
		type_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		type_icon.texture = _get_icon_for_type(type_name)
		type_header.add_child(type_icon)

		var type_label = Label.new()
		type_label.text = "%s (%d)" % [type_name, files_array.size()]
		type_label.add_theme_font_size_override("font_size", 13)
		type_label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
		type_header.add_child(type_label)

		# File list for this type
		var file_container = VBoxContainer.new()
		file_container.add_theme_constant_override("separation", 2)
		scroll_vbox.add_child(file_container)

		for file_entry in files_array:
			var path: String = file_entry.get("path", "")
			var uid: String = file_entry.get("uid", "")

			var file_hbox = HBoxContainer.new()
			file_hbox.add_theme_constant_override("separation", 4)
			file_container.add_child(file_hbox)

			# Indent
			var spacer = Control.new()
			spacer.custom_minimum_size.x = 24
			file_hbox.add_child(spacer)

			# Existence indicator - only show for installed assets, not for GlobalFolder packages
			var source = _asset_info.get("source", "")
			var show_existence = _is_installed or source not in ["GlobalFolder"]

			if show_existence:
				var exists_indicator = Label.new()
				var global_path = ProjectSettings.globalize_path(path)
				if FileAccess.file_exists(global_path):
					exists_indicator.text = "✓"
					exists_indicator.add_theme_color_override("font_color", Color(0.4, 0.9, 0.4))
					exists_indicator.tooltip_text = "File exists"
				else:
					exists_indicator.text = "✗"
					exists_indicator.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
					exists_indicator.tooltip_text = "File NOT found!"
				exists_indicator.custom_minimum_size.x = 16
				file_hbox.add_child(exists_indicator)
			else:
				# For GlobalFolder packages not installed, just show a bullet point
				var bullet = Label.new()
				bullet.text = "•"
				bullet.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
				bullet.custom_minimum_size.x = 16
				file_hbox.add_child(bullet)

			# Path label (clickable)
			var path_btn = Button.new()
			path_btn.flat = true
			path_btn.text = path
			path_btn.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
			path_btn.add_theme_color_override("font_hover_color", Color(0.9, 0.9, 0.9))
			path_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			path_btn.tooltip_text = "Click to navigate to file"
			path_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			path_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			var file_path = path  # Capture for lambda
			path_btn.pressed.connect(func():
				if FileAccess.file_exists(ProjectSettings.globalize_path(file_path)):
					EditorInterface.get_file_system_dock().navigate_to_path(file_path)
			)
			file_hbox.add_child(path_btn)

			# UID badge if present
			if not uid.is_empty():
				var uid_label = Label.new()
				uid_label.text = "UID"
				uid_label.add_theme_font_size_override("font_size", 10)
				uid_label.add_theme_color_override("font_color", Color(0.5, 0.7, 0.5))
				uid_label.tooltip_text = uid
				file_hbox.add_child(uid_label)

		# Add separator between types
		scroll_vbox.add_child(HSeparator.new())

	popup.canceled.connect(func():
		popup.queue_free()
	)

	popup.confirmed.connect(func():
		popup.queue_free()
	)

	EditorInterface.get_base_control().add_child(popup)
	popup.popup_centered()


func _get_file_type_name(ext: String) -> String:
	## Return a human-readable type name for a file extension
	match ext:
		"gd":
			return "Scripts"
		"tscn":
			return "Scenes"
		"tres", "res":
			return "Resources"
		"png", "jpg", "jpeg", "webp", "svg", "bmp", "tga":
			return "Textures"
		"glb", "gltf", "obj", "fbx", "dae", "blend":
			return "3D Models"
		"wav", "ogg", "mp3":
			return "Audio"
		"ttf", "otf", "woff", "woff2":
			return "Fonts"
		"gdshader", "shader":
			return "Shaders"
		"md", "txt", "json", "cfg", "ini":
			return "Text/Config"
		"import":
			return "Import Files"
		_:
			return "Other"


func _get_icon_for_type(type_name: String) -> Texture2D:
	## Return an appropriate editor icon for a file type
	var theme = EditorInterface.get_editor_theme()
	match type_name:
		"Scripts":
			return theme.get_icon("Script", "EditorIcons")
		"Scenes":
			return theme.get_icon("PackedScene", "EditorIcons")
		"Resources":
			return theme.get_icon("ResourcePreloader", "EditorIcons")
		"Textures":
			return theme.get_icon("ImageTexture", "EditorIcons")
		"3D Models":
			return theme.get_icon("Mesh", "EditorIcons")
		"Audio":
			return theme.get_icon("AudioStreamPlayer", "EditorIcons")
		"Fonts":
			return theme.get_icon("Font", "EditorIcons")
		"Shaders":
			return theme.get_icon("Shader", "EditorIcons")
		"Text/Config":
			return theme.get_icon("TextFile", "EditorIcons")
		"Import Files":
			return theme.get_icon("ImportCheck", "EditorIcons")
		_:
			return theme.get_icon("File", "EditorIcons")


func _on_icon_clicked(event: InputEvent) -> void:
	## Open gallery when clicking on the icon image
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_on_gallery_pressed()


func _on_gallery_pressed() -> void:
	## Open the image gallery viewer
	var images: Array = []
	var main_url = _asset_info.get("icon_url", "")

	# Check if main image is already in gallery images (avoid duplicates)
	var main_in_gallery = false
	for img in _gallery_images:
		if img.get("url", "") == main_url:
			main_in_gallery = true
			break

	# Add main image first if not already in gallery
	if not main_in_gallery and (not main_url.is_empty() or _icon_rect.texture):
		images.append({
			"url": main_url,
			"texture": _icon_rect.texture
		})

	# Add gallery images
	for img in _gallery_images:
		# Pass the current texture if this is the main image
		if img.get("url", "") == main_url and _icon_rect.texture:
			images.append({
				"url": img.get("url", ""),
				"thumbnail_url": img.get("thumbnail_url", ""),
				"texture": _icon_rect.texture
			})
		else:
			images.append(img)

	if images.is_empty():
		return

	# Create gallery viewer as a popup window for proper z-ordering
	var gallery = ImageGalleryViewer.new()
	# Add to editor popup parent for proper z-index above dialogs
	var popup_parent = get_tree().root
	popup_parent.add_child(gallery)
	gallery.setup(images, 0)
	gallery.closed.connect(func(): pass)  # Gallery handles its own cleanup


func set_gallery_images(images: Array) -> void:
	## Set additional gallery images (called after fetching details)
	_gallery_images = images
	_update_gallery_button()


func _update_gallery_button() -> void:
	## Update gallery button text with image count
	var count = _gallery_images.size()
	# Add 1 for main image if it's not already in gallery
	var main_url = _asset_info.get("icon_url", "")
	var main_in_gallery = false
	for img in _gallery_images:
		if img.get("url", "") == main_url:
			main_in_gallery = true
			break
	if not main_in_gallery and (not main_url.is_empty() or _icon_rect.texture):
		count += 1

	if count <= 1:
		_gallery_btn.text = "1/1"
	else:
		_gallery_btn.text = "1/%d" % count


func _show_thumbnail_selector_dialog(icon_preview: TextureRect, icon_state: Dictionary) -> void:
	## Show a dialog to select thumbnail source from package contents
	var package_path = _asset_info.get("godotpackage_path", "")
	if package_path.is_empty():
		package_path = _asset_info.get("local_path", "")
	if package_path.is_empty():
		SettingsDialog.debug_print("AssetPlus: No package path found for thumbnail selection")
		return

	# Extract previewable files from the package
	var thumb_sources: Array[Dictionary] = []
	var zip = ZIPReader.new()
	var err = zip.open(package_path)
	if err != OK:
		push_warning("AssetPlus: Cannot open package for thumbnail selection: %s" % package_path)
		return

	var files = zip.get_files()
	var pack_root = ""

	# Find pack_root from manifest if available
	for f in files:
		if f == "manifest.json":
			var manifest_data = zip.read_file(f)
			if manifest_data.size() > 0:
				var json = JSON.new()
				if json.parse(manifest_data.get_string_from_utf8()) == OK:
					pack_root = json.data.get("pack_root", "")
			break

	# Scan for previewable files
	for file_path in files:
		var rel_path = file_path
		if not pack_root.is_empty() and file_path.begins_with(pack_root):
			rel_path = file_path.substr(pack_root.length())

		var ext = file_path.get_extension().to_lower()
		var file_name = file_path.get_file()

		if ext in ["tscn", "scn"]:
			thumb_sources.append({"path": file_path, "type": "scene", "name": file_name})
		elif ext in ["glb", "gltf", "obj", "fbx"]:
			thumb_sources.append({"path": file_path, "type": "model3d", "name": file_name})
		elif ext in ["tres", "res"]:
			# Check if it's a material by reading first lines
			var content = zip.read_file(file_path)
			if content.size() > 0:
				var header = content.slice(0, min(500, content.size())).get_string_from_utf8()
				if "StandardMaterial3D" in header or "ShaderMaterial" in header or "ORMMaterial3D" in header:
					thumb_sources.append({"path": file_path, "type": "material", "name": file_name})
		elif ext in ["png", "jpg", "jpeg", "webp"]:
			thumb_sources.append({"path": file_path, "type": "image", "name": file_name})

	zip.close()

	if thumb_sources.is_empty():
		var no_source_dialog = AcceptDialog.new()
		no_source_dialog.title = "No Thumbnail Sources"
		no_source_dialog.dialog_text = "No previewable files found in this package.\n(scenes, 3D models, materials, or images)"
		no_source_dialog.confirmed.connect(func(): no_source_dialog.queue_free())
		EditorInterface.get_base_control().add_child(no_source_dialog)
		no_source_dialog.popup_centered()
		return

	# Sort sources by priority
	thumb_sources.sort_custom(func(a, b):
		var type_priority = {"scene": 0, "model3d": 1, "material": 2, "image": 3}
		var pa = type_priority.get(a["type"], 99)
		var pb = type_priority.get(b["type"], 99)
		if pa != pb:
			return pa < pb
		return a["name"].length() < b["name"].length()
	)

	# Show selection dialog
	var dialog = AcceptDialog.new()
	dialog.title = "Select Thumbnail Source"
	dialog.size = Vector2i(550, 400)
	dialog.ok_button_text = "Apply"

	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 10)
	dialog.add_child(main_vbox)

	var thumb_state = {"selected_angle": 0, "selected_source": 0}

	# Angle options
	var thumb_options = [
		{"name": "Isometric", "dir": Vector3(1, 0.6, 1).normalized(), "zoom": 0.6},
		{"name": "Front", "dir": Vector3(0, 0, 1), "zoom": 0.45},
		{"name": "Side", "dir": Vector3(1, 0, 0), "zoom": 0.45},
		{"name": "Top", "dir": Vector3(0, 1, 0.01).normalized(), "zoom": 0.6},
		{"name": "3/4 View", "dir": Vector3(1, 0.3, 0.5).normalized(), "zoom": 0.5},
	]

	# Source selector
	var source_label = Label.new()
	source_label.text = "Thumbnail source:"
	main_vbox.add_child(source_label)

	var source_option = OptionButton.new()
	source_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in range(thumb_sources.size()):
		var src = thumb_sources[i]
		var type_label = ""
		match src["type"]:
			"scene": type_label = "Scene: "
			"model3d": type_label = "3D Model: "
			"material": type_label = "Material: "
			"image": type_label = "Image: "
		source_option.add_item(type_label + src["name"], i)
	main_vbox.add_child(source_option)

	# Angle label
	var angle_label = Label.new()
	var current_type = thumb_sources[0]["type"] if thumb_sources.size() > 0 else "image"
	angle_label.text = "Thumbnail angle:" if current_type in ["model3d", "scene"] else "Preview:"
	angle_label.name = "AngleLabel"
	main_vbox.add_child(angle_label)

	# Angle buttons container
	var thumb_hbox = HBoxContainer.new()
	thumb_hbox.add_theme_constant_override("separation", 8)
	thumb_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	thumb_hbox.name = "ThumbHBox"
	main_vbox.add_child(thumb_hbox)

	var thumb_buttons: Array[Button] = []

	# Function to rebuild buttons based on source type
	var rebuild_buttons = func(source_type: String):
		# Clear existing buttons
		for child in thumb_hbox.get_children():
			child.queue_free()
		thumb_buttons.clear()
		await dialog.get_tree().process_frame

		thumb_state["selected_angle"] = 0

		if source_type == "model3d":
			# 3D models: show all angle options
			for i in range(thumb_options.size()):
				var opt = thumb_options[i]
				var thumb_vbox = VBoxContainer.new()
				thumb_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
				thumb_hbox.add_child(thumb_vbox)

				var btn = Button.new()
				btn.custom_minimum_size = Vector2(80, 80)
				btn.toggle_mode = true
				btn.button_pressed = (i == 0)
				btn.tooltip_text = opt["name"]
				btn.text = "..."
				thumb_vbox.add_child(btn)
				thumb_buttons.append(btn)

				var lbl = Label.new()
				lbl.text = opt["name"]
				lbl.add_theme_font_size_override("font_size", 10)
				lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				thumb_vbox.add_child(lbl)

				var idx = i
				btn.pressed.connect(func():
					thumb_state["selected_angle"] = idx
					for j in range(thumb_buttons.size()):
						thumb_buttons[j].button_pressed = (j == idx)
				)
		elif source_type == "image":
			# Images: single preview button
			var thumb_vbox = VBoxContainer.new()
			thumb_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
			thumb_hbox.add_child(thumb_vbox)

			var btn = Button.new()
			btn.custom_minimum_size = Vector2(128, 128)
			btn.toggle_mode = true
			btn.button_pressed = true
			btn.tooltip_text = "Image preview"
			btn.text = "..."
			thumb_vbox.add_child(btn)
			thumb_buttons.append(btn)

			var lbl = Label.new()
			lbl.text = "Image"
			lbl.add_theme_font_size_override("font_size", 10)
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			thumb_vbox.add_child(lbl)

		elif source_type == "scene":
			# Scenes: show all angle options like 3D models
			for i in range(thumb_options.size()):
				var opt = thumb_options[i]
				var thumb_vbox = VBoxContainer.new()
				thumb_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
				thumb_hbox.add_child(thumb_vbox)

				var btn = Button.new()
				btn.custom_minimum_size = Vector2(80, 80)
				btn.toggle_mode = true
				btn.button_pressed = (i == 0)
				btn.tooltip_text = opt["name"]
				btn.text = "..."
				thumb_vbox.add_child(btn)
				thumb_buttons.append(btn)

				var lbl = Label.new()
				lbl.text = opt["name"]
				lbl.add_theme_font_size_override("font_size", 10)
				lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				thumb_vbox.add_child(lbl)

				var idx = i
				btn.pressed.connect(func():
					thumb_state["selected_angle"] = idx
					for j in range(thumb_buttons.size()):
						thumb_buttons[j].button_pressed = (j == idx)
				)

		elif source_type == "material":
			# Materials: single preview button
			var thumb_vbox = VBoxContainer.new()
			thumb_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
			thumb_hbox.add_child(thumb_vbox)

			var btn = Button.new()
			btn.custom_minimum_size = Vector2(128, 128)
			btn.toggle_mode = true
			btn.button_pressed = true
			btn.tooltip_text = "Material preview"
			btn.text = "..."
			thumb_vbox.add_child(btn)
			thumb_buttons.append(btn)

			var lbl = Label.new()
			lbl.text = "Material"
			lbl.add_theme_font_size_override("font_size", 10)
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			thumb_vbox.add_child(lbl)

	# Source changed handler - rebuild buttons and preview on demand
	source_option.item_selected.connect(func(idx: int):
		thumb_state["selected_source"] = idx
		var src = thumb_sources[idx]
		# Update angle label
		var a_label = dialog.find_child("AngleLabel", true, false) as Label
		if a_label:
			a_label.text = "Thumbnail angle:" if src["type"] in ["model3d", "scene"] else "Preview:"
		# Rebuild buttons for this type
		await rebuild_buttons.call(src["type"])
		# Generate previews for this source
		_generate_single_source_previews(package_path, src, thumb_options, thumb_buttons)
	)

	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()

	# Build initial buttons and generate previews for first source
	await rebuild_buttons.call(thumb_sources[0]["type"])
	_generate_single_source_previews(package_path, thumb_sources[0], thumb_options, thumb_buttons)

	dialog.confirmed.connect(func():
		# Generate final thumbnail at selected angle
		var src = thumb_sources[thumb_state["selected_source"]]
		var angle_idx = thumb_state["selected_angle"]
		var opt = thumb_options[angle_idx]
		var cam_dir = opt.get("dir", Vector3(1, 0.6, 1).normalized())
		var zoom = opt.get("zoom", 1.0)

		var png_data = await _generate_single_source_final(package_path, src, cam_dir, zoom, 256)
		if not png_data.is_empty():
			icon_state["data"] = png_data
			icon_state["remove"] = false
			var img = Image.new()
			if img.load_png_from_buffer(png_data) == OK:
				icon_preview.texture = ImageTexture.create_from_image(img)

		dialog.queue_free()
	)

	dialog.canceled.connect(func():
		dialog.queue_free()
	)


func _extract_single_file_from_package(package_path: String, file_path: String) -> String:
	## Extract a single file from package to user://assetplus_temp/
	## Returns the temp file path or empty string on failure
	SettingsDialog.debug_print_verbose("AssetPlus: Extracting '%s' from '%s'" % [file_path, package_path])

	var zip = ZIPReader.new()
	var err = zip.open(package_path)
	if err != OK:
		SettingsDialog.debug_print("AssetPlus: Failed to open package: %s (error %d)" % [package_path, err])
		return ""

	var content = zip.read_file(file_path)
	zip.close()

	if content.is_empty():
		SettingsDialog.debug_print("AssetPlus: File not found or empty in package: %s" % file_path)
		return ""

	var temp_dir = "user://assetplus_temp/"
	if not DirAccess.dir_exists_absolute(temp_dir):
		DirAccess.make_dir_absolute(temp_dir)

	var temp_path = temp_dir + file_path.get_file()
	var file = FileAccess.open(temp_path, FileAccess.WRITE)
	if not file:
		SettingsDialog.debug_print("AssetPlus: Failed to create temp file: %s" % temp_path)
		return ""

	file.store_buffer(content)
	file.close()

	SettingsDialog.debug_print_verbose("AssetPlus: Extracted to %s (%d bytes)" % [temp_path, content.size()])
	return temp_path


func _extract_scene_with_deps_to_res(package_path: String, target_file: String) -> String:
	## Extract a scene/material with its dependencies to res://addons/assetplus/_temp/
	## Returns the res:// path to the target file, or empty string on failure
	var zip = ZIPReader.new()
	var err = zip.open(package_path)
	if err != OK:
		SettingsDialog.debug_print("AssetPlus: Failed to open package for scene extraction")
		return ""

	var temp_dir = "res://addons/assetplus/_temp/"

	# Clean up any previous temp folder
	if DirAccess.dir_exists_absolute(temp_dir):
		_remove_dir_recursive(temp_dir)

	# Create temp directory
	DirAccess.make_dir_recursive_absolute(temp_dir)

	var files_in_package = zip.get_files()
	var pack_root = ""
	var target_res_path = ""

	# Find pack_root from manifest if available
	for f in files_in_package:
		if f == "manifest.json":
			var manifest_data = zip.read_file(f)
			if manifest_data.size() > 0:
				var json = JSON.new()
				if json.parse(manifest_data.get_string_from_utf8()) == OK:
					pack_root = json.data.get("pack_root", "")
			break

	# Read target file content to find its dependencies
	var target_content = zip.read_file(target_file)
	if target_content.is_empty():
		zip.close()
		return ""

	var target_text = target_content.get_string_from_utf8()

	# Find all ext_resource paths referenced in the file
	var deps_to_extract: Array[String] = [target_file]
	var regex = RegEx.new()
	regex.compile('path\\s*=\\s*"(res://[^"]+)"')
	var matches = regex.search_all(target_text)
	for match in matches:
		var dep_path = match.get_string(1)
		# Find corresponding file in package
		for pkg_file in files_in_package:
			if pkg_file.ends_with(dep_path.get_file()):
				if pkg_file not in deps_to_extract:
					deps_to_extract.append(pkg_file)
				break

	# Also check for load/preload paths
	var load_regex = RegEx.new()
	load_regex.compile('(?:load|preload)\\s*\\(\\s*["\']([^"\']+)["\']')
	matches = load_regex.search_all(target_text)
	for match in matches:
		var dep_path = match.get_string(1)
		for pkg_file in files_in_package:
			if pkg_file.ends_with(dep_path.get_file()):
				if pkg_file not in deps_to_extract:
					deps_to_extract.append(pkg_file)
				break

	SettingsDialog.debug_print_verbose("AssetPlus: Extracting scene with %d dependencies" % deps_to_extract.size())

	# Extract all needed files
	for file_path in deps_to_extract:
		var content = zip.read_file(file_path)
		if content.is_empty():
			continue

		# Calculate relative path (remove pack_root if present)
		var rel_path = file_path
		if not pack_root.is_empty() and file_path.begins_with(pack_root):
			rel_path = file_path.substr(pack_root.length())

		var dest_path = temp_dir + rel_path

		# Create directory structure
		var dest_dir = dest_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(dest_dir):
			DirAccess.make_dir_recursive_absolute(dest_dir)

		# Write file
		var file = FileAccess.open(dest_path, FileAccess.WRITE)
		if file:
			file.store_buffer(content)
			file.close()

		# Track target file path
		if file_path == target_file:
			target_res_path = dest_path

	zip.close()

	# Scan filesystem to make Godot aware of new files
	if Engine.is_editor_hint():
		var fs = EditorInterface.get_resource_filesystem()
		if fs:
			fs.scan()
			# Wait for scan with timeout
			for i in range(50):  # Max 5 seconds
				await get_tree().create_timer(0.1).timeout
				if not fs.is_scanning():
					break

	return target_res_path


func _cleanup_res_temp() -> void:
	## Clean up the res:// temp folder
	var temp_dir = "res://addons/assetplus/_temp/"
	if DirAccess.dir_exists_absolute(temp_dir):
		_remove_dir_recursive(temp_dir)
		# Don't scan filesystem here to avoid crashes


func _remove_dir_recursive(path: String) -> void:
	## Recursively remove a directory and all its contents
	var dir = DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path = path.path_join(file_name)
			if dir.current_is_dir():
				_remove_dir_recursive(full_path)
			else:
				DirAccess.remove_absolute(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()

	DirAccess.remove_absolute(path)


func _generate_single_source_previews(package_path: String, source: Dictionary, thumb_options: Array, thumb_buttons: Array[Button]) -> void:
	## Generate previews for a single source - extracts only that file on demand
	var source_type = source.get("type", "image")
	var source_file = source.get("path", "")

	# Show loading state
	for btn in thumb_buttons:
		if is_instance_valid(btn):
			btn.text = "..."
			btn.icon = null

	if source_type == "image":
		# Images: extract to user:// and load directly
		var temp_path = _extract_single_file_from_package(package_path, source_file)
		if temp_path.is_empty():
			if thumb_buttons.size() > 0 and is_instance_valid(thumb_buttons[0]):
				thumb_buttons[0].text = "Err"
			return

		var png_data: PackedByteArray = _load_image_as_png(temp_path, 128)
		if thumb_buttons.size() > 0 and is_instance_valid(thumb_buttons[0]):
			if not png_data.is_empty():
				var img = Image.new()
				if img.load_png_from_buffer(png_data) == OK:
					var tex = ImageTexture.create_from_image(img)
					thumb_buttons[0].icon = tex
					thumb_buttons[0].text = ""
					thumb_buttons[0].expand_icon = true
			else:
				thumb_buttons[0].text = "Err"

		# Cleanup
		if FileAccess.file_exists(temp_path):
			DirAccess.remove_absolute(temp_path)

	elif source_type == "model3d":
		# 3D models: extract to user:// and use GLTFDocument directly
		var temp_path = _extract_single_file_from_package(package_path, source_file)
		if temp_path.is_empty():
			for btn in thumb_buttons:
				if is_instance_valid(btn):
					btn.text = "Err"
			return

		for i in range(thumb_options.size()):
			if i >= thumb_buttons.size() or not is_instance_valid(thumb_buttons[i]):
				break
			var opt = thumb_options[i]
			var cam_dir: Vector3 = opt.get("dir", Vector3(1, 0.6, 1).normalized())
			var zoom: float = opt.get("zoom", 1.0)

			var png_data: PackedByteArray = await _render_glb_from_user(temp_path, cam_dir, zoom, 128)

			if not is_instance_valid(thumb_buttons[i]):
				break
			if not png_data.is_empty():
				var img = Image.new()
				if img.load_png_from_buffer(png_data) == OK:
					var tex = ImageTexture.create_from_image(img)
					thumb_buttons[i].icon = tex
					thumb_buttons[i].text = ""
					thumb_buttons[i].expand_icon = true
			else:
				thumb_buttons[i].text = opt["name"].substr(0, 3)

		# Cleanup
		if FileAccess.file_exists(temp_path):
			DirAccess.remove_absolute(temp_path)

	elif source_type == "scene":
		# Scenes: extract to res:// with dependencies
		var res_path = await _extract_scene_with_deps_to_res(package_path, source_file)
		if res_path.is_empty():
			for btn in thumb_buttons:
				if is_instance_valid(btn):
					btn.text = "Err"
			return

		for i in range(thumb_options.size()):
			if i >= thumb_buttons.size() or not is_instance_valid(thumb_buttons[i]):
				break
			var opt = thumb_options[i]
			var cam_dir: Vector3 = opt.get("dir", Vector3(1, 0.6, 1).normalized())
			var zoom: float = opt.get("zoom", 1.0)

			var png_data: PackedByteArray = await _render_scene_preview(res_path, cam_dir, zoom, 128)

			if not is_instance_valid(thumb_buttons[i]):
				break
			if not png_data.is_empty():
				var img = Image.new()
				if img.load_png_from_buffer(png_data) == OK:
					var tex = ImageTexture.create_from_image(img)
					thumb_buttons[i].icon = tex
					thumb_buttons[i].text = ""
					thumb_buttons[i].expand_icon = true
			else:
				thumb_buttons[i].text = opt["name"].substr(0, 3)

		# Cleanup
		_cleanup_res_temp()

	elif source_type == "material":
		# Materials: extract to res:// with dependencies
		var res_path = await _extract_scene_with_deps_to_res(package_path, source_file)
		if res_path.is_empty():
			if thumb_buttons.size() > 0 and is_instance_valid(thumb_buttons[0]):
				thumb_buttons[0].text = "Err"
			return

		var png_data: PackedByteArray = await _render_material_preview(res_path, 128)
		if thumb_buttons.size() > 0 and is_instance_valid(thumb_buttons[0]):
			if not png_data.is_empty():
				var img = Image.new()
				if img.load_png_from_buffer(png_data) == OK:
					var tex = ImageTexture.create_from_image(img)
					thumb_buttons[0].icon = tex
					thumb_buttons[0].text = ""
					thumb_buttons[0].expand_icon = true
			else:
				thumb_buttons[0].text = "Err"

		# Cleanup
		_cleanup_res_temp()


func _generate_single_source_final(package_path: String, source: Dictionary, cam_dir: Vector3, zoom: float, size: int) -> PackedByteArray:
	## Generate final high-quality thumbnail for a single source
	var source_type = source.get("type", "image")
	var source_file = source.get("path", "")
	var png_data: PackedByteArray

	if source_type == "image":
		var temp_path = _extract_single_file_from_package(package_path, source_file)
		if temp_path.is_empty():
			return PackedByteArray()
		png_data = _load_image_as_png(temp_path, size)
		if FileAccess.file_exists(temp_path):
			DirAccess.remove_absolute(temp_path)

	elif source_type == "model3d":
		var temp_path = _extract_single_file_from_package(package_path, source_file)
		if temp_path.is_empty():
			return PackedByteArray()
		png_data = await _render_glb_from_user(temp_path, cam_dir, zoom, size)
		if FileAccess.file_exists(temp_path):
			DirAccess.remove_absolute(temp_path)

	elif source_type == "scene":
		var res_path = await _extract_scene_with_deps_to_res(package_path, source_file)
		if res_path.is_empty():
			return PackedByteArray()
		png_data = await _render_scene_preview(res_path, cam_dir, zoom, size)
		_cleanup_res_temp()

	elif source_type == "material":
		var res_path = await _extract_scene_with_deps_to_res(package_path, source_file)
		if res_path.is_empty():
			return PackedByteArray()
		png_data = await _render_material_preview(res_path, size)
		_cleanup_res_temp()

	return png_data


func _load_image_as_png(image_path: String, size: int) -> PackedByteArray:
	## Load an image file and return as PNG data
	var img = Image.new()
	var err = img.load(image_path)
	if err != OK:
		return PackedByteArray()

	var img_size = img.get_size()
	if img_size.x > size or img_size.y > size:
		var scale_factor = min(float(size) / img_size.x, float(size) / img_size.y)
		var new_size = Vector2i(int(img_size.x * scale_factor), int(img_size.y * scale_factor))
		img.resize(new_size.x, new_size.y, Image.INTERPOLATE_LANCZOS)

	return img.save_png_to_buffer()


func _render_glb_from_user(file_path: String, cam_dir: Vector3, zoom_factor: float, size: int) -> PackedByteArray:
	## Render a GLB/GLTF model from user:// path using GLTFDocument
	## GLTFDocument can load from absolute filesystem paths
	var ext = file_path.get_extension().to_lower()
	if ext not in ["glb", "gltf"]:
		SettingsDialog.debug_print("AssetPlus: _render_glb_from_user only supports GLB/GLTF, got: %s" % ext)
		return PackedByteArray()

	# Verify file exists
	if not FileAccess.file_exists(file_path):
		SettingsDialog.debug_print("AssetPlus: GLB file not found: %s" % file_path)
		return PackedByteArray()

	# Convert to absolute filesystem path
	var global_path = ProjectSettings.globalize_path(file_path)
	SettingsDialog.debug_print_verbose("AssetPlus: Loading GLB from global path: %s" % global_path)

	# Load with GLTFDocument
	var gltf_doc = GLTFDocument.new()
	var gltf_state = GLTFState.new()

	var err = gltf_doc.append_from_file(global_path, gltf_state)
	if err != OK:
		SettingsDialog.debug_print("AssetPlus: GLTFDocument failed to load: %s (error %d)" % [global_path, err])
		return PackedByteArray()

	var model_instance = gltf_doc.generate_scene(gltf_state) as Node3D
	if model_instance == null:
		SettingsDialog.debug_print("AssetPlus: GLTFDocument.generate_scene returned null")
		return PackedByteArray()

	# Create viewport for rendering
	var viewport = SubViewport.new()
	viewport.size = Vector2i(size * 2, size * 2)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.own_world_3d = true

	EditorInterface.get_base_control().add_child(viewport)

	var root_node = Node3D.new()
	viewport.add_child(root_node)
	root_node.add_child(model_instance)

	# Calculate AABB for camera positioning
	var aabb = _get_scene_aabb(root_node)
	var center = aabb.get_center()

	if aabb.size.length() < 0.001:
		center = Vector3.ZERO
		aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))

	var fov = 50.0
	var margin = 1.2
	var max_extent = aabb.get_longest_axis_size()
	var dist = (max_extent * margin) / sin(deg_to_rad(fov / 2.0))
	dist = max(dist, 1.0)
	dist *= zoom_factor

	var cam_pos = center + cam_dir * dist

	var cam = Camera3D.new()
	cam.fov = fov
	viewport.add_child(cam)
	cam.current = true
	cam.global_position = cam_pos
	cam.look_at(center)

	# Add lights
	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 45, 0)
	light.light_energy = 1.5
	viewport.add_child(light)

	var light2 = DirectionalLight3D.new()
	light2.rotation_degrees = Vector3(-30, -135, 0)
	light2.light_energy = 0.5
	viewport.add_child(light2)

	# Render - wait for multiple frames to ensure model is loaded
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	for i in range(5):
		await RenderingServer.frame_post_draw

	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	var image = viewport.get_texture().get_image()
	viewport.queue_free()

	if image == null or image.is_empty():
		return PackedByteArray()

	image.resize(size, size, Image.INTERPOLATE_LANCZOS)
	return image.save_png_to_buffer()


func _render_model_from_file(file_path: String, cam_dir: Vector3, zoom_factor: float, size: int) -> PackedByteArray:
	## Render a 3D model preview from a file path (supports user:// paths)
	## Uses GLTFDocument for GLB/GLTF files
	var ext = file_path.get_extension().to_lower()

	# For GLB/GLTF files, use GLTFDocument to load directly from file
	var model_instance: Node3D = null

	if ext in ["glb", "gltf"]:
		var gltf_doc = GLTFDocument.new()
		var gltf_state = GLTFState.new()

		# Convert user:// path to absolute filesystem path
		var global_path = ProjectSettings.globalize_path(file_path)
		SettingsDialog.debug_print_verbose("AssetPlus: Loading GLB - user path: %s" % file_path)
		SettingsDialog.debug_print_verbose("AssetPlus: Loading GLB - global path: %s" % global_path)

		if not FileAccess.file_exists(file_path):
			SettingsDialog.debug_print("AssetPlus: GLB file does not exist at user path: %s" % file_path)
			return PackedByteArray()

		# Verify the global path exists too
		var fa = FileAccess.open(file_path, FileAccess.READ)
		if fa == null:
			SettingsDialog.debug_print("AssetPlus: Cannot open GLB file: %s" % file_path)
			return PackedByteArray()
		var file_size = fa.get_length()
		fa.close()
		SettingsDialog.debug_print_verbose("AssetPlus: GLB file size: %d bytes" % file_size)

		var err = gltf_doc.append_from_file(global_path, gltf_state)
		if err != OK:
			SettingsDialog.debug_print("AssetPlus: GLTFDocument.append_from_file failed with error: %d for path: %s" % [err, global_path])
			return PackedByteArray()

		model_instance = gltf_doc.generate_scene(gltf_state) as Node3D
		if model_instance == null:
			SettingsDialog.debug_print("AssetPlus: GLTFDocument.generate_scene returned null")
			return PackedByteArray()

		SettingsDialog.debug_print_verbose("AssetPlus: GLB model loaded successfully")
	else:
		# For other formats (OBJ, FBX), try regular load if in res://
		if not ResourceLoader.exists(file_path):
			return PackedByteArray()
		var resource = load(file_path)
		if resource == null:
			return PackedByteArray()
		if resource is PackedScene:
			model_instance = resource.instantiate() as Node3D
		elif resource is Mesh:
			model_instance = MeshInstance3D.new()
			(model_instance as MeshInstance3D).mesh = resource

	if model_instance == null:
		return PackedByteArray()

	var viewport = SubViewport.new()
	viewport.size = Vector2i(size * 2, size * 2)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.own_world_3d = true

	EditorInterface.get_base_control().add_child(viewport)

	var root_node = Node3D.new()
	viewport.add_child(root_node)
	root_node.add_child(model_instance)

	var aabb = _get_scene_aabb(root_node)
	var center = aabb.get_center()

	if aabb.size.length() < 0.001:
		center = Vector3.ZERO
		aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))

	var fov = 50.0
	var margin = 1.2
	var max_extent = aabb.get_longest_axis_size()
	var dist = (max_extent * margin) / sin(deg_to_rad(fov / 2.0))
	dist = max(dist, 1.0)
	dist *= zoom_factor

	var cam_pos = center + cam_dir * dist

	var cam = Camera3D.new()
	cam.fov = fov
	viewport.add_child(cam)
	cam.current = true
	cam.global_position = cam_pos
	cam.look_at(center)

	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 45, 0)
	light.light_energy = 1.5
	viewport.add_child(light)

	var light2 = DirectionalLight3D.new()
	light2.rotation_degrees = Vector3(-30, -135, 0)
	light2.light_energy = 0.5
	viewport.add_child(light2)

	# Render
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	var image = viewport.get_texture().get_image()
	viewport.queue_free()

	if image == null or image.is_empty():
		return PackedByteArray()

	image.resize(size, size, Image.INTERPOLATE_LANCZOS)
	return image.save_png_to_buffer()


func _render_model_from_res(model_path: String, cam_dir: Vector3, zoom_factor: float, size: int) -> PackedByteArray:
	## Render a 3D model preview from a res:// path
	if not ResourceLoader.exists(model_path):
		SettingsDialog.debug_print("AssetPlus: Model not found: %s" % model_path)
		return PackedByteArray()

	var resource = load(model_path)
	if resource == null:
		SettingsDialog.debug_print("AssetPlus: Failed to load model: %s" % model_path)
		return PackedByteArray()

	var viewport = SubViewport.new()
	viewport.size = Vector2i(size * 2, size * 2)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.own_world_3d = true

	EditorInterface.get_base_control().add_child(viewport)

	var root_node = Node3D.new()
	viewport.add_child(root_node)

	var model_instance: Node3D = null
	if resource is PackedScene:
		model_instance = resource.instantiate() as Node3D
	elif resource is Mesh:
		model_instance = MeshInstance3D.new()
		(model_instance as MeshInstance3D).mesh = resource
	elif resource is ArrayMesh:
		model_instance = MeshInstance3D.new()
		(model_instance as MeshInstance3D).mesh = resource

	if model_instance == null:
		viewport.queue_free()
		return PackedByteArray()

	root_node.add_child(model_instance)

	var aabb = _get_scene_aabb(root_node)
	var center = aabb.get_center()

	if aabb.size.length() < 0.001:
		center = Vector3.ZERO
		aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))

	var fov = 50.0
	var margin = 1.2
	var max_extent = aabb.get_longest_axis_size()
	var dist = (max_extent * margin) / sin(deg_to_rad(fov / 2.0))
	dist = max(dist, 1.0)
	dist *= zoom_factor

	var cam_pos = center + cam_dir * dist

	var cam = Camera3D.new()
	cam.fov = fov
	viewport.add_child(cam)
	cam.current = true
	cam.global_position = cam_pos
	cam.look_at(center)

	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 45, 0)
	light.light_energy = 1.5
	viewport.add_child(light)

	var light2 = DirectionalLight3D.new()
	light2.rotation_degrees = Vector3(-30, -135, 0)
	light2.light_energy = 0.5
	viewport.add_child(light2)

	# Render
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	var image = viewport.get_texture().get_image()
	viewport.queue_free()

	if image == null or image.is_empty():
		return PackedByteArray()

	image.resize(size, size, Image.INTERPOLATE_LANCZOS)
	return image.save_png_to_buffer()


func _render_scene_preview(scene_path: String, cam_dir: Vector3, zoom_factor: float, size: int) -> PackedByteArray:
	## Render a scene preview from a res:// path
	if not ResourceLoader.exists(scene_path):
		SettingsDialog.debug_print("AssetPlus: Scene not found: %s" % scene_path)
		return PackedByteArray()

	var packed_scene = load(scene_path) as PackedScene
	if packed_scene == null:
		SettingsDialog.debug_print("AssetPlus: Failed to load scene: %s" % scene_path)
		return PackedByteArray()

	var viewport = SubViewport.new()
	viewport.size = Vector2i(size * 2, size * 2)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.own_world_3d = true

	EditorInterface.get_base_control().add_child(viewport)

	var instance = packed_scene.instantiate()
	if instance == null:
		viewport.queue_free()
		return PackedByteArray()

	viewport.add_child(instance)

	# Setup camera for 3D content
	if instance is Node3D or _has_3d_content(instance):
		var aabb = _get_scene_aabb(instance)
		var center = aabb.get_center()

		if aabb.size.length() < 0.001:
			center = Vector3.ZERO
			aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))

		var fov = 50.0
		var margin = 1.2
		var max_extent = aabb.get_longest_axis_size()
		var dist = (max_extent * margin) / sin(deg_to_rad(fov / 2.0))
		dist = max(dist, 1.0)
		dist *= zoom_factor

		var cam_pos = center + cam_dir * dist

		var cam = Camera3D.new()
		cam.fov = fov
		viewport.add_child(cam)
		cam.current = true
		cam.global_position = cam_pos
		cam.look_at(center)

		var light = DirectionalLight3D.new()
		light.rotation_degrees = Vector3(-45, 45, 0)
		light.light_energy = 1.5
		viewport.add_child(light)

		var light2 = DirectionalLight3D.new()
		light2.rotation_degrees = Vector3(-30, -135, 0)
		light2.light_energy = 0.5
		viewport.add_child(light2)

	# Render
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	var image = viewport.get_texture().get_image()
	viewport.queue_free()

	if image == null or image.is_empty():
		return PackedByteArray()

	image.resize(size, size, Image.INTERPOLATE_LANCZOS)
	return image.save_png_to_buffer()


func _render_material_preview(material_path: String, size: int) -> PackedByteArray:
	## Render a material preview from a res:// path
	if not ResourceLoader.exists(material_path):
		SettingsDialog.debug_print("AssetPlus: Material not found: %s" % material_path)
		return PackedByteArray()

	var material = load(material_path)
	if material == null or not (material is Material):
		SettingsDialog.debug_print("AssetPlus: Failed to load material or not a Material: %s" % material_path)
		return PackedByteArray()

	var viewport = SubViewport.new()
	viewport.size = Vector2i(size * 2, size * 2)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.own_world_3d = true

	EditorInterface.get_base_control().add_child(viewport)

	# Create a sphere mesh with the material
	var mesh_instance = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	mesh_instance.mesh = sphere
	mesh_instance.material_override = material
	viewport.add_child(mesh_instance)

	# Camera positioned to frame the sphere
	var cam = Camera3D.new()
	cam.fov = 50.0
	viewport.add_child(cam)
	cam.current = true
	cam.global_position = Vector3(2.5, 1.5, 2.5)
	cam.look_at(Vector3.ZERO)

	# Lighting
	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 45, 0)
	light.light_energy = 1.5
	viewport.add_child(light)

	var light2 = DirectionalLight3D.new()
	light2.rotation_degrees = Vector3(-30, -135, 0)
	light2.light_energy = 0.5
	viewport.add_child(light2)

	# Render
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	var image = viewport.get_texture().get_image()
	viewport.queue_free()

	if image == null or image.is_empty():
		return PackedByteArray()

	image.resize(size, size, Image.INTERPOLATE_LANCZOS)
	return image.save_png_to_buffer()


func _has_3d_content(node: Node) -> bool:
	if node is Node3D:
		return true
	for child in node.get_children():
		if _has_3d_content(child):
			return true
	return false


func _get_scene_aabb(node: Node) -> AABB:
	## Get combined AABB for all meshes in the scene
	var result = AABB()
	var first = true

	if node is MeshInstance3D:
		var local_aabb = node.get_aabb()
		if local_aabb.size.length() > 0.0001:
			var xform = node.global_transform
			var corners: Array[Vector3] = []
			for i in range(8):
				corners.append(xform * local_aabb.get_endpoint(i))
			var global_aabb = AABB(corners[0], Vector3.ZERO)
			for c in corners:
				global_aabb = global_aabb.expand(c)
			if first:
				result = global_aabb
				first = false
			else:
				result = result.merge(global_aabb)

	for child in node.get_children():
		var child_aabb = _get_scene_aabb(child)
		if child_aabb.size.length() > 0.0001:
			if first:
				result = child_aabb
				first = false
			else:
				result = result.merge(child_aabb)

	return result
