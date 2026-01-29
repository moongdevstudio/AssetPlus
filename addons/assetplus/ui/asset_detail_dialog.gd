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

const SOURCE_GODOT = "Godot AssetLib"
const SOURCE_GODOT_BETA = "Godot Store Beta"
const SOURCE_SHADERS = "Godot Shaders"

var _icon_rect: TextureRect
var _title_label: Label
var _author_label: Label
var _version_label: Label
var _category_label: Label
var _license_label: Label
var _source_btn: Button  # Clickable source link
var _description: RichTextLabel
var _install_btn: Button
var _update_btn: Button
var _open_browser_btn: Button
var _favorite_btn: Button
var _explore_btn: MenuButton
var _explore_popup: PopupMenu
var _remove_global_btn: Button
var _add_to_global_btn: Button
var _edit_global_btn: Button
var _extract_package_btn: Button
var _loading_label: Label
var _file_list_btn: Button

var _asset_info: Dictionary = {}
var _is_favorite: bool = false
var _is_installed: bool = false
var _has_update: bool = false
var _update_version: String = ""
var _download_url: String = ""
var _http_request: HTTPRequest
var _tracked_files: Array = []  # Array of {path: String, uid: String}


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

	# Icon
	var icon_panel = PanelContainer.new()
	var icon_style = StyleBoxFlat.new()
	icon_style.bg_color = Color(0.12, 0.12, 0.15)
	icon_style.set_corner_radius_all(8)
	icon_panel.add_theme_stylebox_override("panel", icon_style)
	icon_panel.custom_minimum_size = Vector2(160, 160)
	left_vbox.add_child(icon_panel)

	var icon_center = CenterContainer.new()
	icon_panel.add_child(icon_center)

	_icon_rect = TextureRect.new()
	_icon_rect.custom_minimum_size = Vector2(128, 128)
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_center.add_child(_icon_rect)

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

	# Favorite button at the bottom
	_favorite_btn = Button.new()
	_favorite_btn.text = "Add to Favorites"
	_favorite_btn.icon = theme.get_icon("Favorites", "EditorIcons")
	_favorite_btn.pressed.connect(_on_favorite_pressed)
	left_vbox.add_child(_favorite_btn)

	# File list button - shows tracked files
	_file_list_btn = Button.new()
	_file_list_btn.text = "File List"
	_file_list_btn.icon = theme.get_icon("FileList", "EditorIcons")
	_file_list_btn.pressed.connect(_on_file_list_pressed)
	_file_list_btn.visible = false  # Only show when there are tracked files
	left_vbox.add_child(_file_list_btn)

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


func setup(info: Dictionary, is_favorite: bool = false, is_installed: bool = false, icon_texture: Texture2D = null) -> void:
	_asset_info = info
	_is_favorite = is_favorite
	_is_installed = is_installed
	_download_url = ""

	# Show basic info immediately
	_title_label.text = info.get("title", "Unknown")
	_author_label.text = info.get("author", "Unknown")
	_version_label.text = info.get("version", "-") if not info.get("version", "").is_empty() else "-"
	_category_label.text = info.get("category", "-") if not info.get("category", "").is_empty() else "-"
	_license_label.text = info.get("license", "MIT")

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

	_description.text = info.get("description", "Loading...")

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

	# Shaders can't be installed as addons - they need to be copied to project
	# GlobalFolder items can be installed from their .godotpackage file
	_install_btn.visible = source in [SOURCE_GODOT, SOURCE_GODOT_BETA, "GlobalFolder"]

	if _is_installed:
		_install_btn.text = "Uninstall"
		_install_btn.modulate = Color(1, 0.6, 0.6)
	else:
		_install_btn.text = "Install"
		_install_btn.modulate = Color.WHITE


func _update_favorite_button() -> void:
	if _is_favorite:
		_favorite_btn.text = "Remove from Favorites"
	else:
		_favorite_btn.text = "Add to Favorites"


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


func _fetch_beta_details() -> void:
	var browse_url = _asset_info.get("browse_url", "")
	if browse_url.is_empty():
		return

	_loading_label.visible = true

	if _http_request:
		_http_request.queue_free()

	_http_request = HTTPRequest.new()
	add_child(_http_request)

	_http_request.request_completed.connect(_on_beta_details_received)
	_http_request.request(browse_url)


func _on_beta_details_received(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_loading_label.visible = false

	if _http_request:
		_http_request.queue_free()
		_http_request = null

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_description.text = "Failed to load details."
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

	# Parse license from link text: href="...licenses/mit/">MIT</a>
	var license_regex = RegEx.new()
	license_regex.compile('licenses/[^"]*">([A-Za-z0-9._+ -]+)</a>')
	var license_match = license_regex.search(html)
	if license_match:
		var lic = license_match.get_string(1).strip_edges()
		if not lic.is_empty():
			_license_label.text = lic
			_asset_info["license"] = lic

	# Parse tags from tag links (for reference, but don't overwrite category)
	# Beta Store doesn't provide proper categories, so we keep the original if available
	# or set a default based on the source
	if _asset_info.get("category", "").is_empty():
		_asset_info["category"] = "Tools"  # Default category for Beta Store
		_category_label.text = "Tools"

	# Parse short description from aside panel: <p class="by">...</p> followed by <p>description</p>
	var desc_regex = RegEx.new()
	desc_regex.compile('<p class="by">[^<]*<a[^>]*>[^<]*</a></p>\\s*<p>([^<]+)</p>')
	var desc_match = desc_regex.search(html)
	if desc_match:
		var desc = desc_match.get_string(1).strip_edges()
		if not desc.is_empty():
			_description.text = desc
			_asset_info["description"] = desc
	else:
		_description.text = _asset_info.get("description", "No description available.")

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

	# Parse description from entry-content
	var desc_regex = RegEx.new()
	desc_regex.compile('class="[^"]*entry-content[^"]*"[^>]*>([\\s\\S]*?)</div>')
	var desc_match = desc_regex.search(html)
	if desc_match:
		var desc = _clean_html(desc_match.get_string(1))
		if not desc.is_empty():
			_description.text = desc
			_asset_info["description"] = desc
	else:
		# Try article content
		var article_regex = RegEx.new()
		article_regex.compile('<article[^>]*>([\\s\\S]*?)</article>')
		var article_match = article_regex.search(html)
		if article_match:
			var content = _clean_html(article_match.get_string(1))
			# Remove title and short strings
			var lines = content.split(".")
			var desc_parts: Array = []
			for line in lines:
				line = line.strip_edges()
				if line.length() > 30:
					desc_parts.append(line)
			if desc_parts.size() > 0:
				_description.text = ". ".join(desc_parts) + "."
				_asset_info["description"] = _description.text

	if _description.text == "Loading..." or _description.text.is_empty():
		_description.text = "A shader for Godot. Visit the page for more details and to copy the shader code."


func _clean_html(text: String) -> String:
	# Remove HTML tags
	var strip_regex = RegEx.new()
	strip_regex.compile('<[^>]+>')
	text = strip_regex.sub(text, " ", true)
	# Decode HTML entities
	text = text.replace("&nbsp;", " ")
	text = text.replace("&amp;", "&")
	text = text.replace("&lt;", "<")
	text = text.replace("&gt;", ">")
	text = text.replace("&quot;", "\"")
	text = text.replace("&#39;", "'")
	# Clean whitespace
	var ws_regex = RegEx.new()
	ws_regex.compile('\\s+')
	text = ws_regex.sub(text, " ", true)
	return text.strip_edges()


# ===== ACTIONS =====

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

			# Existence indicator
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


