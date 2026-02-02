@tool
extends ConfirmationDialog

## Installation dialog - downloads and installs addons (based on godot_package approach)

const SettingsDialog = preload("res://addons/assetplus/ui/settings_dialog.gd")

signal installation_complete(success: bool, addon_paths: Array, tracked_uids: Array)

enum State { IDLE, DOWNLOADING, READY, INSTALLING, DONE, ERROR }

var _state: State = State.IDLE
var _asset_info: Dictionary = {}
var _download_url: String = ""
var _zip_path: String = ""
var _zip_reader: ZIPReader = null

var _tree: Tree
var _progress_bar: ProgressBar
var _status_label: Label
var _file_count_label: Label
var _http_request: HTTPRequest
var _all_btn: Button
var _none_btn: Button
var _change_folder_btn: Button
var _install_root_btn: Button
var _install_path_label: Label
var _category_buttons_container: HBoxContainer
var _category_buttons: Dictionary = {}  # category_name -> Button
var _custom_install_root: String = ""  # Custom install root folder
var _default_install_root: String = ""  # Default install root (to restore when toggling off)
var _is_install_at_root: bool = false  # Whether "Install at Root" is active

var _zip_files: Array = []  # Array of {zip_path, rel_path, is_dir, selected}
var _template_addon_files: Array = []  # Addons found in templates - installed to res://addons/
var _addon_root: String = ""
var _plugin_folder: String = ""
var _tree_items: Dictionary = {}
var _folder_items: Dictionary = {}  # Track top-level folders for quick selection
var _download_timer: Timer = null
var _download_start_time: int = 0
var _last_downloaded_bytes: int = 0
var _last_speed_check_time: int = 0
var _current_speed: float = 0.0  # Smoothed download speed
var _redirect_count: int = 0  # Count HTTP redirects for display (1/X, 2/X...)
var _max_redirects: int = 10  # Maximum redirects before aborting (security limit)
var _final_download_started: bool = false  # True when we're on the final download (not a redirect)
var _max_progress_reached: float = 0.0  # Track maximum progress to avoid going backwards

# Installation tracking for error reporting
var _install_succeeded: Array[String] = []
var _install_failed: Array[Dictionary] = []  # [{path: String, error: String}]

# Cached regex patterns for path adaptation (performance)
static var _load_regex: RegEx
static var _preload_regex: RegEx
static var _extresource_regex: RegEx

# Package type detection
enum PackageType { PLUGIN, PROJECT, ASSET, GODOTPACKAGE }
var _package_type: PackageType = PackageType.ASSET
var _project_settings: Dictionary = {}  # Parsed from project.godot (input_map, autoload)
var _original_autoloads: Dictionary = {}  # Original autoload paths (before adaptation)
var _project_godot_path: String = ""  # Path to project.godot in ZIP
var _template_folder: String = ""  # Folder name for templates (e.g., "my_template")
var _godotpackage_manifest: Dictionary = {}  # Manifest from .godotpackage file
var _asset_folder_name: String = ""  # Folder name for assets (used when changing install folder)


func _init() -> void:
	title = "Install Asset"
	size = Vector2i(620, 650)  # Increased height by 30%
	ok_button_text = "Install"
	get_ok_button().disabled = true
	# Keep dialog visible during installation to show progress
	dialog_hide_on_ok = false
	# Initialize cached regex patterns
	_init_regex_patterns()


static func _init_regex_patterns() -> void:
	## Initialize regex patterns once for performance
	if _load_regex == null:
		_load_regex = RegEx.new()
		_load_regex.compile('(?<!pre)load\\s*\\(\\s*["\']([^"\']+)["\']\\s*\\)')
	if _preload_regex == null:
		_preload_regex = RegEx.new()
		_preload_regex.compile('preload\\s*\\(\\s*["\']([^"\']+)["\']\\s*\\)')
	if _extresource_regex == null:
		_extresource_regex = RegEx.new()
		_extresource_regex.compile('(ExtResource|path)\\s*[=(]\\s*["\']([^"\']+)["\']')


static func _is_path_safe(rel_path: String) -> bool:
	## Validate a relative path is safe (no path traversal attacks)
	## Returns false if path contains dangerous patterns
	if rel_path.is_empty():
		return false

	# Reject absolute paths
	if rel_path.begins_with("/") or rel_path.begins_with("\\"):
		return false
	# Windows absolute paths (C:\, D:\, etc.)
	if rel_path.length() >= 2 and rel_path[1] == ':':
		return false

	# Reject path traversal patterns
	if rel_path.contains(".."):  # Parent directory
		return false
	if rel_path.contains("./"):  # Current directory prefix
		return false
	if rel_path.contains(".\\"):  # Windows current directory
		return false
	if rel_path.contains("/./"):  # Embedded current directory
		return false

	# Reject paths starting with .
	if rel_path.begins_with("."):
		return false

	# Reject null bytes (could truncate path)
	if rel_path.find(char(0)) != -1:
		return false

	return true


static func _sanitize_package_name(name: String) -> String:
	## Sanitize a package name to only contain safe characters
	## Returns sanitized name or empty string if completely invalid
	var sanitized = ""
	for c in name:
		if c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_- ":
			sanitized += c
	return sanitized.strip_edges()


static func _validate_manifest(manifest: Dictionary) -> Dictionary:
	## Validate and sanitize manifest content
	## Returns {valid: bool, errors: Array[String], sanitized: Dictionary}
	var errors: Array[String] = []
	var sanitized: Dictionary = {}

	# Validate required fields
	var name = manifest.get("name", "")
	if name.is_empty():
		errors.append("Missing package name")
	else:
		var safe_name = _sanitize_package_name(name)
		if safe_name.is_empty():
			errors.append("Invalid package name (contains only special characters)")
		elif safe_name != name:
			sanitized["name"] = safe_name
		else:
			sanitized["name"] = name

	# Validate type
	var pkg_type = manifest.get("type", "asset").to_lower()
	if pkg_type not in ["plugin", "addon", "asset", "template", "project", "demo"]:
		pkg_type = "asset"
	sanitized["type"] = pkg_type

	# Validate autoloads
	var autoloads = manifest.get("autoloads", {})
	if autoloads is Dictionary:
		var safe_autoloads: Dictionary = {}
		for al_name in autoloads:
			var al_value = autoloads[al_name]
			# Validate autoload name (alphanumeric + underscore only)
			var safe_al_name = ""
			for c in str(al_name):
				if c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_":
					safe_al_name += c
			if safe_al_name.is_empty():
				errors.append("Invalid autoload name: %s" % al_name)
				continue
			# Validate autoload path
			var path_str = str(al_value)
			var script_path = path_str.trim_prefix("*")
			if not script_path.begins_with("res://"):
				errors.append("Autoload '%s' has invalid path (must start with res://)" % al_name)
				continue
			if not _is_path_safe(script_path.substr(6)):  # Remove res://
				errors.append("Autoload '%s' has unsafe path" % al_name)
				continue
			safe_autoloads[safe_al_name] = al_value
		sanitized["autoloads"] = safe_autoloads
	else:
		sanitized["autoloads"] = {}

	# Copy other safe fields
	sanitized["version"] = str(manifest.get("version", "1.0.0"))
	sanitized["author"] = str(manifest.get("author", ""))
	sanitized["godot_version"] = str(manifest.get("godot_version", ""))
	sanitized["pack_root"] = str(manifest.get("pack_root", ""))
	sanitized["source_folder"] = str(manifest.get("source_folder", ""))
	sanitized["files"] = manifest.get("files", [])
	sanitized["input_actions"] = manifest.get("input_actions", {})

	return {
		"valid": errors.is_empty(),
		"errors": errors,
		"sanitized": sanitized
	}


func _ready() -> void:
	_build_ui()
	confirmed.connect(_on_confirmed)
	canceled.connect(_on_canceled)


func _on_canceled() -> void:
	_cleanup_resources()


func _build_ui() -> void:
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)

	# Status label
	_status_label = Label.new()
	_status_label.text = "Preparing download..."
	vbox.add_child(_status_label)

	# Progress bar
	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size.y = 20
	_progress_bar.value = 0
	vbox.add_child(_progress_bar)

	# Selection buttons row (All / None)
	var select_hbox = HBoxContainer.new()
	select_hbox.add_theme_constant_override("separation", 8)
	vbox.add_child(select_hbox)

	_all_btn = Button.new()
	_all_btn.text = "All"
	_all_btn.custom_minimum_size.x = 60
	_all_btn.pressed.connect(_on_select_all)
	select_hbox.add_child(_all_btn)

	_none_btn = Button.new()
	_none_btn.text = "None"
	_none_btn.custom_minimum_size.x = 60
	_none_btn.pressed.connect(_on_select_none)
	select_hbox.add_child(_none_btn)

	# Separator
	var separator = VSeparator.new()
	select_hbox.add_child(separator)

	# Change folder button
	_change_folder_btn = Button.new()
	_change_folder_btn.text = "Change Folder..."
	_change_folder_btn.pressed.connect(_on_change_folder_pressed)
	select_hbox.add_child(_change_folder_btn)

	# Install at root button (for templates/projects) - toggle button
	_install_root_btn = Button.new()
	_install_root_btn.text = "Install at Root"
	_install_root_btn.toggle_mode = true
	_install_root_btn.tooltip_text = "Install directly to res:// (useful for templates)\nClick again to restore default path"
	_install_root_btn.pressed.connect(_on_install_root_pressed)
	_install_root_btn.visible = false  # Only show for templates
	select_hbox.add_child(_install_root_btn)

	# Install path label
	_install_path_label = Label.new()
	_install_path_label.text = "Install to: res://"
	_install_path_label.add_theme_color_override("font_color", Color(0.5, 0.7, 0.9))
	_install_path_label.add_theme_font_size_override("font_size", 12)
	_install_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_install_path_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	select_hbox.add_child(_install_path_label)

	# Category quick buttons (populated dynamically)
	_category_buttons_container = HBoxContainer.new()
	_category_buttons_container.add_theme_constant_override("separation", 4)
	vbox.add_child(_category_buttons_container)

	# Files tree label
	var tree_label = Label.new()
	tree_label.text = "Package contents:"
	tree_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(tree_label)

	# Files tree with checkboxes
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.columns = 1
	_tree.set_column_expand(0, true)
	_tree.hide_root = false
	_tree.item_edited.connect(_on_item_edited)
	vbox.add_child(_tree)

	# File count
	_file_count_label = Label.new()
	_file_count_label.text = "0 files"
	_file_count_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	vbox.add_child(_file_count_label)


func setup(asset_info: Dictionary) -> void:
	_asset_info = asset_info
	_download_url = asset_info.get("download_url", "")

	title = "Install: %s" % asset_info.get("title", "Asset")

	# Reset custom install root and template folder
	_custom_install_root = ""
	_template_folder = ""
	_default_install_root = ""
	_is_install_at_root = false

	# Check if this is an update with a specific target path
	# update_target_path is the EXACT folder to replace (e.g., res://addons/script_splitter or res://Packages/script_splitter)
	var update_target_path = asset_info.get("update_target_path", "")
	if not update_target_path.is_empty():
		# Store the target path for deletion of old folder before install
		_asset_info["_update_target_path"] = update_target_path

		# Check if asset is at its default location (res://addons/) or has been moved
		if update_target_path.begins_with("res://addons/"):
			# Plugin is at default location - DON'T set _custom_install_root because:
			# - ZIP contains paths like "addons/script_splitter/..."
			# - rel_path already has "addons/" prefix
			# - Normal install to res:// + rel_path works correctly
			SettingsDialog.debug_print("Update mode: plugin at default location %s (no custom install root)" % update_target_path)
		else:
			# Asset has been moved to a custom location
			# We need to strip the "addons/" prefix from rel_path and install to the moved location
			# Store info about the moved location for _build_plugin_file_list to handle
			_asset_info["_update_moved_location"] = true
			_asset_info["_update_install_parent"] = update_target_path.get_base_dir()  # e.g., "res://Packages"
			_asset_info["_update_folder_name"] = update_target_path.get_file()  # e.g., "script_splitter"
			SettingsDialog.debug_print("Update mode: asset moved to %s, parent=%s, folder=%s" % [
				update_target_path,
				_asset_info["_update_install_parent"],
				_asset_info["_update_folder_name"]
			])

		if _install_path_label:
			_install_path_label.text = "Update: %s" % update_target_path
	else:
		if _install_path_label:
			_install_path_label.text = "Install to: res://"

	if _install_root_btn:
		_install_root_btn.button_pressed = false
		_install_root_btn.visible = false

	# Cleanup any previous resources
	_cleanup_resources()

	if _download_url.is_empty():
		_set_error("No download URL available")
		return

	_redirect_count = 0  # Reset redirect count for new download
	_final_download_started = false  # Not yet on final download
	_max_progress_reached = 0.0  # Reset max progress
	_start_download()


func setup_from_local_zip(zip_path: String, asset_info: Dictionary = {}) -> void:
	## Setup dialog from a local ZIP file (no download needed)
	var file_name = zip_path.get_file().get_basename()

	# Build asset info for local import
	_asset_info = {
		"title": asset_info.get("title", file_name),
		"author": asset_info.get("author", "Local Import"),
		"source": asset_info.get("source", "Local"),
		"license": asset_info.get("license", "Unknown"),
		"asset_id": asset_info.get("asset_id", "local_%d" % Time.get_unix_time_from_system())
	}

	title = "Install: %s" % _asset_info.get("title", "Asset")

	# Reset custom install root and template folder
	_custom_install_root = ""
	_template_folder = ""
	_default_install_root = ""
	_is_install_at_root = false
	if _install_path_label:
		_install_path_label.text = "Install to: res://"
	if _install_root_btn:
		_install_root_btn.button_pressed = false
		_install_root_btn.visible = false

	# Cleanup any previous resources
	_cleanup_resources()

	# Copy the local ZIP to a temp location (same as downloaded ZIPs)
	var timestamp = Time.get_unix_time_from_system()
	_zip_path = "user://temp_asset_%d.zip" % timestamp

	# Copy file
	var src_file = FileAccess.open(zip_path, FileAccess.READ)
	if src_file == null:
		_set_error("Cannot open ZIP file: %s" % zip_path)
		return

	var content = src_file.get_buffer(src_file.get_length())
	src_file.close()

	var dst_file = FileAccess.open(_zip_path, FileAccess.WRITE)
	if dst_file == null:
		_set_error("Cannot create temp file")
		return

	dst_file.store_buffer(content)
	dst_file.close()

	_progress_bar.value = 100
	_status_label.text = "Analyzing package..."

	call_deferred("_analyze_zip")


func setup_from_local_folder(folder_path: String, asset_info: Dictionary = {}) -> void:
	## Setup dialog from a local folder (creates temporary ZIP)
	var folder_name = folder_path.get_file()
	if folder_name.is_empty():
		folder_name = folder_path.rstrip("/\\").get_file()

	# Build asset info for local import
	_asset_info = {
		"title": asset_info.get("title", folder_name),
		"author": asset_info.get("author", "Local Import"),
		"source": asset_info.get("source", "Local"),
		"license": asset_info.get("license", "Unknown"),
		"asset_id": asset_info.get("asset_id", "local_%d" % Time.get_unix_time_from_system())
	}

	title = "Install: %s" % _asset_info.get("title", "Asset")

	# Reset custom install root and template folder
	_custom_install_root = ""
	_template_folder = ""
	_default_install_root = ""
	_is_install_at_root = false
	if _install_path_label:
		_install_path_label.text = "Install to: res://"
	if _install_root_btn:
		_install_root_btn.button_pressed = false
		_install_root_btn.visible = false

	# Cleanup any previous resources
	_cleanup_resources()

	_status_label.text = "Creating package from folder..."
	_progress_bar.value = 0

	# Create a temporary ZIP from the folder
	var timestamp = Time.get_unix_time_from_system()
	_zip_path = "user://temp_asset_%d.zip" % timestamp

	var zip_writer = ZIPPacker.new()
	var err = zip_writer.open(_zip_path)
	if err != OK:
		_set_error("Cannot create temporary ZIP")
		return

	# Recursively add all files from the folder
	var files_added = _add_folder_to_zip(zip_writer, folder_path, folder_name)
	zip_writer.close()

	if files_added == 0:
		_set_error("Folder is empty or cannot be read")
		return

	_progress_bar.value = 100
	_status_label.text = "Analyzing package..."

	call_deferred("_analyze_zip")


func setup_from_local_godotpackage(godotpackage_path: String, asset_info: Dictionary = {}) -> void:
	## Setup dialog from a local .godotpackage file
	# First read the manifest to get package info
	var reader = ZIPReader.new()
	var err = reader.open(godotpackage_path)
	if err != OK:
		_set_error("Cannot open .godotpackage file: %s" % godotpackage_path)
		return

	if not reader.file_exists("manifest.json"):
		reader.close()
		_set_error("Invalid .godotpackage file: missing manifest.json")
		return

	var manifest_data = reader.read_file("manifest.json")
	reader.close()

	var json = JSON.new()
	err = json.parse(manifest_data.get_string_from_utf8())
	if err != OK:
		_set_error("Invalid manifest.json in .godotpackage file")
		return

	if not json.data is Dictionary:
		_set_error("Invalid manifest format")
		return

	# Validate and sanitize manifest
	var validation = _validate_manifest(json.data)
	if not validation["valid"]:
		var error_list = "\n".join(validation["errors"])
		push_warning("AssetPlus: Manifest validation warnings:\n%s" % error_list)
	_godotpackage_manifest = validation["sanitized"]
	# Keep original data for fields not in sanitized
	for key in json.data:
		if not _godotpackage_manifest.has(key):
			_godotpackage_manifest[key] = json.data[key]

	# Build asset info from manifest
	var pkg_name = _godotpackage_manifest.get("name", godotpackage_path.get_file().get_basename())
	_asset_info = {
		"title": asset_info.get("title", pkg_name),
		"author": asset_info.get("author", _godotpackage_manifest.get("author", "Unknown")),
		"source": "GodotPackage",
		"license": asset_info.get("license", _godotpackage_manifest.get("license", "Unknown")),
		"version": _godotpackage_manifest.get("version", ""),
		"description": _godotpackage_manifest.get("description", ""),
		"asset_id": asset_info.get("asset_id", "godotpackage_%s_%d" % [pkg_name.to_lower().replace(" ", "_"), Time.get_unix_time_from_system()])
	}

	title = "Install: %s" % _asset_info.get("title", "Package")

	# Reset custom install root and template folder
	_custom_install_root = ""
	_template_folder = ""
	_default_install_root = ""
	_is_install_at_root = false
	if _install_path_label:
		_install_path_label.text = "Install to: res://"
	if _install_root_btn:
		_install_root_btn.button_pressed = false
		_install_root_btn.visible = false

	# Cleanup any previous resources
	_cleanup_resources()

	# Copy the godotpackage file to a temp location
	var timestamp = Time.get_unix_time_from_system()
	_zip_path = "user://temp_asset_%d.zip" % timestamp

	var src_file = FileAccess.open(godotpackage_path, FileAccess.READ)
	if src_file == null:
		_set_error("Cannot open .godotpackage file: %s" % godotpackage_path)
		return

	var content = src_file.get_buffer(src_file.get_length())
	src_file.close()

	var dst_file = FileAccess.open(_zip_path, FileAccess.WRITE)
	if dst_file == null:
		_set_error("Cannot create temp file")
		return

	dst_file.store_buffer(content)
	dst_file.close()

	_progress_bar.value = 100
	_status_label.text = "Analyzing package..."

	# Force package type to GDPKG before analysis
	_package_type = PackageType.GODOTPACKAGE

	call_deferred("_analyze_zip")


func setup_from_shader(asset_info: Dictionary) -> void:
	## Setup dialog for installing a shader from Godot Shaders
	## asset_info must contain: shader_code, title, and optionally shader_description
	var shader_code = asset_info.get("shader_code", "")
	if shader_code.is_empty():
		_set_error("No shader code provided")
		return

	var shader_title = asset_info.get("title", "shader")
	var shader_name = _sanitize_shader_name(shader_title)
	if shader_name.is_empty():
		shader_name = "shader"

	_asset_info = {
		"title": shader_title,
		"author": asset_info.get("author", "Unknown"),
		"source": "Godot Shaders",
		"license": asset_info.get("license", "Unknown"),
		"version": asset_info.get("version", ""),
		"description": asset_info.get("shader_description", ""),
		"browse_url": asset_info.get("browse_url", ""),
		"category": asset_info.get("category", "Shader"),
		"modify_date": asset_info.get("modify_date", ""),
		"asset_id": asset_info.get("asset_id", "shader_%s_%d" % [shader_name, Time.get_unix_time_from_system()])
	}

	title = "Install Shader: %s" % shader_title

	# Set default install root to "shaders" folder
	_custom_install_root = "res://shaders"
	_template_folder = ""
	_default_install_root = "res://shaders"
	_is_install_at_root = false
	if _install_path_label:
		_install_path_label.text = "Install to: res://shaders/"
	if _install_root_btn:
		_install_root_btn.button_pressed = false
		_install_root_btn.visible = false

	# Cleanup any previous resources
	_cleanup_resources()

	# Create a temporary ZIP with shader files
	var timestamp = Time.get_unix_time_from_system()
	_zip_path = "user://temp_shader_%d.zip" % timestamp

	var zip_writer = ZIPPacker.new()
	var err = zip_writer.open(_zip_path)
	if err != OK:
		_set_error("Cannot create temp ZIP file")
		return

	# Add shader file: shaders/shader_name/shader_name.gdshader
	var shader_rel_path = "%s/%s.gdshader" % [shader_name, shader_name]
	zip_writer.start_file(shader_rel_path)
	zip_writer.write_file(shader_code.to_utf8_buffer())
	zip_writer.close_file()

	# Add howtouse.md: shaders/shader_name/howtouse.md
	var readme_content = _generate_shader_readme(_asset_info)
	var readme_rel_path = "%s/howtouse.md" % shader_name
	zip_writer.start_file(readme_rel_path)
	zip_writer.write_file(readme_content.to_utf8_buffer())
	zip_writer.close_file()

	zip_writer.close()

	_progress_bar.value = 100
	_status_label.text = "Ready to install shader..."

	# Force package type to ASSET (simple file extraction)
	_package_type = PackageType.ASSET
	_asset_folder_name = shader_name

	call_deferred("_analyze_zip")


func _sanitize_shader_name(name: String) -> String:
	## Sanitize a shader name to be used as a folder/file name
	var result = name.to_lower()
	# Replace spaces and special chars with underscores
	result = result.replace(" ", "_")
	result = result.replace("-", "_")
	# Remove any characters that aren't alphanumeric or underscore
	var clean_regex = RegEx.new()
	clean_regex.compile('[^a-z0-9_]')
	result = clean_regex.sub(result, "", true)
	# Remove consecutive underscores
	while "__" in result:
		result = result.replace("__", "_")
	# Trim underscores from ends
	result = result.strip_edges()
	while result.begins_with("_"):
		result = result.substr(1)
	while result.ends_with("_"):
		result = result.substr(0, result.length() - 1)
	return result


func _generate_shader_readme(info: Dictionary) -> String:
	## Generate a howtouse.md file content from shader info
	var md = "# %s\n\n" % info.get("title", "Shader")

	# Add metadata
	md += "**Author:** %s\n\n" % info.get("author", "Unknown")
	md += "**Category:** %s\n\n" % info.get("category", "Shader")
	md += "**License:** %s\n\n" % info.get("license", "Unknown")

	# Add date if available
	var modify_date = info.get("modify_date", "")
	if not modify_date.is_empty():
		md += "**Last Updated:** %s\n\n" % modify_date

	# Add source link
	var browse_url = info.get("browse_url", "")
	if not browse_url.is_empty():
		md += "**Source:** [Godot Shaders](%s)\n\n" % browse_url

	md += "---\n\n"

	var description = info.get("description", "")
	if not description.is_empty():
		md += "## Description\n\n"
		md += description + "\n\n"
		md += "---\n\n"

	# Only add generic "How to Use" if description doesn't already contain usage instructions
	if description.is_empty() or (not "how to use" in description.to_lower() and not "how to" in description.to_lower()):
		md += "## How to Use\n\n"
		md += "1. Create a new ShaderMaterial in Godot\n"
		md += "2. Assign the `.gdshader` file to the material's Shader property\n"
		md += "3. Apply the material to your node (Sprite2D, MeshInstance3D, etc.)\n"
		md += "4. Adjust the shader parameters in the Inspector\n"

	return md


func _add_folder_to_zip(zip_writer: ZIPPacker, folder_path: String, base_name: String, current_rel: String = "") -> int:
	## Recursively add folder contents to ZIP, returns number of files added
	var files_added = 0
	var dir = DirAccess.open(folder_path)
	if dir == null:
		return 0

	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path = folder_path.path_join(file_name)
			var rel_path = base_name + "/" + current_rel + file_name if current_rel.is_empty() else base_name + "/" + current_rel + "/" + file_name

			if dir.current_is_dir():
				# Recurse into subdirectory
				var sub_rel = file_name if current_rel.is_empty() else current_rel + "/" + file_name
				files_added += _add_folder_to_zip(zip_writer, full_path, base_name, sub_rel + "/")
			else:
				# Add file to ZIP
				var file = FileAccess.open(full_path, FileAccess.READ)
				if file:
					var content = file.get_buffer(file.get_length())
					file.close()

					zip_writer.start_file(rel_path)
					zip_writer.write_file(content)
					zip_writer.close_file()
					files_added += 1

		file_name = dir.get_next()

	dir.list_dir_end()
	return files_added


func _cleanup_resources() -> void:
	# Stop download timer
	_stop_download_timer()

	# Close zip reader if open
	if _zip_reader != null:
		_zip_reader.close()
		_zip_reader = null

	# Cancel and cleanup HTTP request
	if _http_request != null:
		_http_request.cancel_request()
		_http_request.queue_free()
		_http_request = null

	# Delete old temp file if exists
	if not _zip_path.is_empty():
		var old_path = ProjectSettings.globalize_path(_zip_path)
		if FileAccess.file_exists(old_path):
			DirAccess.remove_absolute(old_path)
		_zip_path = ""


func _start_download() -> void:
	_state = State.DOWNLOADING
	_update_folder_buttons_state()
	_redirect_count += 1
	if _redirect_count > 1:
		_status_label.text = "Connecting... (%d/%d)" % [_redirect_count, _max_redirects]
	else:
		_status_label.text = "Connecting..."
		# Only reset progress bar on first download, not on redirects
		_progress_bar.value = 0

	if _http_request:
		_http_request.cancel_request()
		_http_request.queue_free()

	# Use unique filename with timestamp to avoid conflicts
	var timestamp = Time.get_unix_time_from_system()
	_zip_path = "user://temp_asset_%d.zip" % timestamp

	_http_request = HTTPRequest.new()
	_http_request.use_threads = true
	_http_request.download_file = ProjectSettings.globalize_path(_zip_path)
	add_child(_http_request)

	_http_request.request_completed.connect(_on_download_complete)

	# Start progress tracking timer (only reset counters on first download, not redirects)
	if _redirect_count <= 1:
		_download_start_time = Time.get_ticks_msec()
		_last_speed_check_time = _download_start_time
		_last_downloaded_bytes = 0
		_current_speed = 0.0

	if _download_timer:
		_download_timer.queue_free()
	_download_timer = Timer.new()
	_download_timer.wait_time = 0.05  # Update every 50ms for smoother progress
	_download_timer.timeout.connect(_update_download_progress)
	add_child(_download_timer)
	_download_timer.start()

	var err = _http_request.request(_download_url)
	if err != OK:
		_stop_download_timer()
		_set_error("Failed to start download: %s" % error_string(err))


func _stop_download_timer() -> void:
	if _download_timer:
		_download_timer.stop()
		_download_timer.queue_free()
		_download_timer = null


func _format_size(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	elif bytes < 1024 * 1024:
		return "%.1f KB" % (bytes / 1024.0)
	else:
		return "%.2f MB" % (bytes / (1024.0 * 1024.0))


func _update_download_progress() -> void:
	if not _http_request or _state != State.DOWNLOADING:
		_stop_download_timer()
		return

	var downloaded = _http_request.get_downloaded_bytes()
	var total = _http_request.get_body_size()
	var current_time = Time.get_ticks_msec()

	# Detect if this is a real download (not just a redirect response)
	# Redirects have small body size, real downloads have significant data
	if total > 1000 or downloaded > 1000:
		_final_download_started = true

	# Calculate instantaneous speed with smoothing (only for real downloads)
	if _final_download_started:
		var time_delta_ms = current_time - _last_speed_check_time
		if time_delta_ms >= 200:  # Update speed every 200ms for stability
			var bytes_delta = downloaded - _last_downloaded_bytes
			if bytes_delta > 0 and time_delta_ms > 0:
				var instant_speed = (bytes_delta / (time_delta_ms / 1000.0))
				# Smooth speed using exponential moving average
				if _current_speed <= 0:
					_current_speed = instant_speed
				else:
					_current_speed = _current_speed * 0.6 + instant_speed * 0.4
			_last_downloaded_bytes = downloaded
			_last_speed_check_time = current_time

	# Only update progress bar once we're in the final download
	if _final_download_started and total > 0:
		var percent = (float(downloaded) / total) * 100.0
		# Never let progress go backwards
		if percent > _max_progress_reached:
			_max_progress_reached = percent
			_progress_bar.value = percent

		var speed_str = ""
		var elapsed_ms = current_time - _download_start_time
		if elapsed_ms > 300 and _current_speed > 0:
			speed_str = " @ %s/s" % _format_size(int(_current_speed))

		_status_label.text = "Downloading: %s / %s (%.0f%%)%s" % [
			_format_size(downloaded),
			_format_size(total),
			_max_progress_reached,
			speed_str
		]
	elif _final_download_started and downloaded > 0:
		# Unknown total size - show bytes downloaded
		var speed_str = ""
		if _current_speed > 0:
			speed_str = " @ %s/s" % _format_size(int(_current_speed))
		_status_label.text = "Downloading: %s...%s" % [_format_size(downloaded), speed_str]
		# Keep bar stable when size unknown
		if _progress_bar.value < 10:
			_progress_bar.value = 10
	else:
		# Still in redirect phase or connecting
		_status_label.text = "Connecting..."


func _on_download_complete(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_stop_download_timer()

	if _http_request:
		_http_request.queue_free()
		_http_request = null

	# Handle redirect with depth limit to prevent infinite loops
	if code == 302 or code == 301:
		# Note: _redirect_count is incremented in _start_download(), not here
		if _redirect_count >= _max_redirects:
			_set_error("Too many redirects (%d). Possible redirect loop." % _redirect_count)
			return
		for header in headers:
			if header.to_lower().begins_with("location:"):
				var redirect_url = header.substr(9).strip_edges()
				_download_url = redirect_url
				SettingsDialog.debug_print("HTTP redirect %d/%d to: %s" % [_redirect_count, _max_redirects, redirect_url])
				_start_download()
				return

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_set_error("Download failed (HTTP %d)" % code)
		return

	_progress_bar.value = 100
	_status_label.text = "Download complete. Analyzing package..."

	call_deferred("_analyze_zip")


func _analyze_zip() -> void:
	_zip_files.clear()
	_template_addon_files.clear()
	_addon_root = ""
	_plugin_folder = ""
	_tree_items.clear()
	# Keep GDPKG type if already set from setup_from_local_godotpackage
	var keep_godotpackage = (_package_type == PackageType.GODOTPACKAGE)
	if not keep_godotpackage:
		_package_type = PackageType.ASSET
	_project_settings.clear()
	_project_godot_path = ""
	_template_folder = ""

	_zip_reader = ZIPReader.new()
	var err = _zip_reader.open(ProjectSettings.globalize_path(_zip_path))
	if err != OK:
		_set_error("Failed to open ZIP file")
		return

	var files = _zip_reader.get_files()
	if files.is_empty():
		_set_error("ZIP file is empty")
		return

	# Check if this is a GDPKG file (has manifest.json and we don't have it loaded yet)
	if not keep_godotpackage and _zip_reader.file_exists("manifest.json"):
		var manifest_data = _zip_reader.read_file("manifest.json")
		var json = JSON.new()
		if json.parse(manifest_data.get_string_from_utf8()) == OK and json.data is Dictionary:
			# Validate and sanitize manifest
			var validation = _validate_manifest(json.data)
			if not validation["valid"]:
				var error_list = "\n".join(validation["errors"])
				push_warning("AssetPlus: Manifest validation warnings:\n%s" % error_list)
			_godotpackage_manifest = validation["sanitized"]
			for key in json.data:
				if not _godotpackage_manifest.has(key):
					_godotpackage_manifest[key] = json.data[key]
			# Check if it looks like a godotpackage (has pack_root or files array)
			if _godotpackage_manifest.has("pack_root") or _godotpackage_manifest.has("files"):
				_package_type = PackageType.GODOTPACKAGE
				keep_godotpackage = true

	# Detect package type - always scan even for GODOTPACKAGE to properly detect plugins
	var has_plugin_cfg = false
	var has_project_godot = false
	var has_gdextension = false
	var gdextension_path = ""
	var gdextension_addon_root = ""
	var gdextension_addon_folder = ""
	var project_root = ""

	for f in files:
		if f.ends_with("plugin.cfg"):
			has_plugin_cfg = true
			# Found a plugin - determine the addon root
			if "/addons/" in f:
				var addons_idx = f.find("/addons/")
				_addon_root = f.substr(0, addons_idx + 1)
				var after_root = f.substr(addons_idx + 1)
				var parts = after_root.split("/")
				if parts.size() >= 2:
					_plugin_folder = parts[1]
			elif f.begins_with("addons/"):
				_addon_root = ""
				var parts = f.split("/")
				if parts.size() >= 2:
					_plugin_folder = parts[1]
			else:
				var parts = f.split("/")
				if parts.size() >= 2:
					_addon_root = parts[0] + "/"
					_plugin_folder = parts[0]
				elif parts.size() == 1:
					_plugin_folder = "addon"

		# Detect GDExtension files (for packages without plugin.cfg)
		if f.ends_with(".gdextension"):
			has_gdextension = true
			gdextension_path = f
			# Check if it's in a */addons/*/ structure
			if "/addons/" in f:
				var addons_idx = f.find("/addons/")
				gdextension_addon_root = f.substr(0, addons_idx + 1)
				var after_addons = f.substr(addons_idx + 8)  # Skip "/addons/"
				var slash_idx = after_addons.find("/")
				if slash_idx > 0:
					gdextension_addon_folder = after_addons.substr(0, slash_idx)

		if f.ends_with("project.godot"):
			has_project_godot = true
			_project_godot_path = f
			# Determine project root
			if f == "project.godot":
				project_root = ""
			else:
				project_root = f.substr(0, f.length() - 13)  # Remove "project.godot"

	# Determine package type - projects/templates take priority over plugins
	# BUT if we already have a valid GODOTPACKAGE with manifest, keep it!
	# The manifest's "type" field will be used in _build_godotpackage_file_list
	if keep_godotpackage:
		# Already a valid GODOTPACKAGE - don't override, let _build_godotpackage_file_list handle it
		pass
	elif has_project_godot:
		_package_type = PackageType.PROJECT
		# Parse project.godot for input_map and autoload
		_parse_project_godot()
	elif has_plugin_cfg:
		_package_type = PackageType.PLUGIN
	elif has_gdextension and not gdextension_addon_folder.is_empty():
		# GDExtension without plugin.cfg but with */addons/*/ structure
		# Treat it like a plugin - install to addons/
		_package_type = PackageType.PLUGIN
		_addon_root = gdextension_addon_root
		_plugin_folder = gdextension_addon_folder
		SettingsDialog.debug_print("Install: Detected GDExtension addon: %s (root: %s)" % [_plugin_folder, _addon_root])
	else:
		_package_type = PackageType.ASSET
		# Set default install path to assets/ (folder name will be determined in _build_asset_file_list)
		if _custom_install_root.is_empty():
			_custom_install_root = "res://assets"
			if _install_path_label:
				_install_path_label.text = "Install to: res://assets/"

	SettingsDialog.debug_print("Install: Package type = %s" % PackageType.keys()[_package_type])

	# Show/hide "Install at Root" button based on package type
	if _install_root_btn:
		# Show for templates/projects, godotpackages, and assets - hide only for plugins
		_install_root_btn.visible = (_package_type != PackageType.PLUGIN)

	# Build file list based on package type
	match _package_type:
		PackageType.PLUGIN:
			_build_plugin_file_list(files)
		PackageType.PROJECT:
			_build_project_file_list(files, project_root)
			# For projects, default install path is res://templates/ instead of res://
			if _custom_install_root.is_empty():
				_custom_install_root = "res://templates"
				if _install_path_label:
					_install_path_label.text = "Install to: res://templates/"
		PackageType.ASSET:
			_build_asset_file_list(files)
		PackageType.GODOTPACKAGE:
			_build_godotpackage_file_list(files)

	# Save the default install root for "Install at Root" toggle restoration
	if _default_install_root.is_empty():
		_default_install_root = _custom_install_root

	if _zip_files.is_empty():
		_set_error("No files found in package")
		return

	_populate_tree()

	_state = State.READY
	_update_folder_buttons_state()
	_status_label.text = "Ready to install. Select files to install:"
	get_ok_button().disabled = false


func _parse_project_godot() -> void:
	SettingsDialog.debug_print_verbose(" ========== PARSING project.godot ==========")
	if _project_godot_path.is_empty():
		SettingsDialog.debug_print_verbose(" No project.godot path set!")
		return

	SettingsDialog.debug_print_verbose(" Reading project.godot from: %s" % _project_godot_path)
	var content = _zip_reader.read_file(_project_godot_path)
	if content.is_empty():
		SettingsDialog.debug_print_verbose(" project.godot content is empty!")
		return

	var text = content.get_string_from_utf8()
	var lines = text.split("\n")
	SettingsDialog.debug_print_verbose(" project.godot has %d lines, %d bytes" % [lines.size(), text.length()])

	var current_section = ""
	var input_map: Dictionary = {}
	var autoloads: Dictionary = {}

	var i = 0
	while i < lines.size():
		var line = lines[i].strip_edges()
		i += 1

		if line.is_empty() or line.begins_with(";"):
			continue

		# Section header
		if line.begins_with("[") and line.ends_with("]"):
			current_section = line.substr(1, line.length() - 2)
			SettingsDialog.debug_print_verbose(" Entered section: [%s]" % current_section)
			continue

		# Parse key=value
		var eq_idx = line.find("=")
		if eq_idx > 0:
			var key = line.substr(0, eq_idx).strip_edges()
			var value = line.substr(eq_idx + 1).strip_edges()

			# Handle multi-line values (for input actions with { } or [ ])
			if value.begins_with("{") or value.begins_with("["):
				# Count braces/brackets to find the complete value
				var brace_count = 0
				var bracket_count = 0
				var complete_value = value

				# Count in the first line
				for c in value:
					if c == '{':
						brace_count += 1
					elif c == '}':
						brace_count -= 1
					elif c == '[':
						bracket_count += 1
					elif c == ']':
						bracket_count -= 1

				# Keep reading lines until balanced
				var lines_read = 0
				while (brace_count > 0 or bracket_count > 0) and i < lines.size():
					var next_line = lines[i]
					i += 1
					lines_read += 1
					complete_value += next_line

					for c in next_line:
						if c == '{':
							brace_count += 1
						elif c == '}':
							brace_count -= 1
						elif c == '[':
							bracket_count += 1
						elif c == ']':
							bracket_count -= 1

				value = complete_value
				if current_section == "input":
					SettingsDialog.debug_print_verbose(" Multi-line input '%s' read %d extra lines, total length: %d" % [key, lines_read, value.length()])

			if current_section == "input":
				input_map[key] = value
				SettingsDialog.debug_print_verbose(" Found input action '%s' (value length: %d)" % [key, value.length()])
				SettingsDialog.debug_print_verbose("   Value preview: %s..." % value.left(150))
			elif current_section == "autoload":
				# Remove surrounding quotes if present
				var autoload_value = value
				if autoload_value.begins_with('"') and autoload_value.ends_with('"'):
					autoload_value = autoload_value.substr(1, autoload_value.length() - 2)
				autoloads[key] = autoload_value
				SettingsDialog.debug_print_verbose(" Found autoload '%s' = %s" % [key, autoload_value])

	_project_settings["input_map"] = input_map

	# Store original autoloads for later adaptation
	# We keep the originals so we can re-adapt when the user changes the install folder
	_original_autoloads = autoloads.duplicate()
	_project_settings["autoload"] = autoloads

	SettingsDialog.debug_print_verbose(" ========== PARSING COMPLETE ==========")
	SettingsDialog.debug_print("Install: Found %d input actions, %d autoloads" % [input_map.size(), autoloads.size()])
	for action_name in input_map:
		SettingsDialog.debug_print_verbose(" Input action list: '%s'" % action_name)


func _build_plugin_file_list(files: PackedStringArray) -> void:
	# Original plugin handling - install to addons/
	# Note: rel_path already includes "addons/" prefix, so _custom_install_root stays empty
	# Files install to res:// + rel_path = res://addons/...

	# Check if this is an update to a moved location
	var is_moved_update = _asset_info.get("_update_moved_location", false)
	var moved_parent = _asset_info.get("_update_install_parent", "")  # e.g., "res://Packages"
	var moved_folder = _asset_info.get("_update_folder_name", "")  # e.g., "script_splitter"

	if is_moved_update and not moved_parent.is_empty():
		# For moved assets, set custom install root to the new parent
		_custom_install_root = moved_parent
		if _install_path_label:
			_install_path_label.text = "Update to: %s/%s/" % [moved_parent, moved_folder]
		SettingsDialog.debug_print("Plugin update to moved location: %s/%s" % [moved_parent, moved_folder])
	else:
		if _install_path_label:
			_install_path_label.text = "Install to: res://addons/"

	for file_path in files:
		if file_path.ends_with("/"):
			continue

		var rel_path = ""

		if not _addon_root.is_empty() and file_path.begins_with(_addon_root):
			rel_path = file_path.substr(_addon_root.length())
		elif _addon_root.is_empty():
			rel_path = file_path

		if not rel_path.is_empty():
			if not rel_path.begins_with("addons/"):
				var addons_idx = rel_path.find("addons/")
				if addons_idx >= 0:
					rel_path = rel_path.substr(addons_idx)
				elif not _plugin_folder.is_empty():
					rel_path = "addons/%s/%s" % [_plugin_folder, rel_path]
				else:
					continue

			# For moved updates, strip "addons/" prefix and use folder name from moved location
			# rel_path is like "addons/script_splitter/file.gd" -> "script_splitter/file.gd"
			if is_moved_update and not moved_folder.is_empty():
				if rel_path.begins_with("addons/"):
					var after_addons = rel_path.substr(7)  # Remove "addons/"
					# Get the original folder name from the path
					var slash_idx = after_addons.find("/")
					if slash_idx > 0:
						# Replace original folder name with moved folder name
						var rest_of_path = after_addons.substr(slash_idx)  # e.g., "/file.gd"
						rel_path = moved_folder + rest_of_path  # e.g., "script_splitter/file.gd"
					else:
						# No subfolder, just use the file
						rel_path = moved_folder + "/" + after_addons

			_zip_files.append({
				"zip_path": file_path,
				"rel_path": rel_path,
				"is_dir": false,
				"selected": true
			})


func _build_project_file_list(files: PackedStringArray, project_root: String) -> void:
	# Project/Template - include all files except project.godot itself
	# Addons (files in addons/ folder) are separated and installed to res://addons/
	# Create a subfolder based on asset title
	var folder_name = _asset_info.get("title", "template").to_snake_case()
	folder_name = folder_name.replace(" ", "_").replace("-", "_")
	var regex = RegEx.new()
	regex.compile("[^a-z0-9_]")
	folder_name = regex.sub(folder_name, "", true)
	if folder_name.is_empty():
		folder_name = "template"

	# Store template folder name for later use (when changing install folder)
	_template_folder = folder_name

	# Set full install path
	_custom_install_root = "res://templates/%s" % folder_name
	if _install_path_label:
		_install_path_label.text = "Install to: %s/" % _custom_install_root

	# Clear addon files list
	_template_addon_files.clear()

	for file_path in files:
		if file_path.ends_with("/"):
			continue

		# Skip project.godot - we'll handle its settings separately
		if file_path.ends_with("project.godot"):
			continue

		var rel_path = ""
		if not project_root.is_empty() and file_path.begins_with(project_root):
			rel_path = file_path.substr(project_root.length())
		else:
			rel_path = file_path

		if rel_path.is_empty():
			continue

		# Check if this file is in addons/ folder - separate it
		if rel_path.begins_with("addons/"):
			_template_addon_files.append({
				"zip_path": file_path,
				"rel_path": rel_path,  # Keep addons/plugin_name/... path
				"is_dir": false,
				"selected": true
			})
		else:
			_zip_files.append({
				"zip_path": file_path,
				"rel_path": rel_path,
				"is_dir": false,
				"selected": true
			})

	if not _template_addon_files.is_empty():
		SettingsDialog.debug_print("Install: Found %d addon files to install separately to res://addons/" % _template_addon_files.size())


func _build_asset_file_list(files: PackedStringArray) -> void:
	# Generic asset - include all files, install to assets/ folder
	# Check if there's a common root folder in the ZIP
	var common_root = ""
	var all_have_common_root = true

	for file_path in files:
		if file_path.ends_with("/"):
			continue
		var parts = file_path.split("/")
		if parts.size() > 1:
			if common_root.is_empty():
				common_root = parts[0]
			elif parts[0] != common_root:
				all_have_common_root = false
				break
		else:
			# File at root level - no common folder
			all_have_common_root = false
			break

	# If ZIP already has a common root folder, keep it as-is
	# Otherwise, create a folder from asset title
	var asset_folder = ""
	var base_install_path = _custom_install_root if not _custom_install_root.is_empty() else "res://assets"
	if all_have_common_root and not common_root.is_empty():
		# ZIP already has a folder structure - use it
		asset_folder = ""  # Don't add extra folder
		_asset_folder_name = common_root  # Store for folder change
		if _install_path_label:
			_install_path_label.text = "Install to: %s/%s/" % [base_install_path, common_root]
	else:
		# No common root - create folder from asset title
		asset_folder = _asset_info.get("title", "asset").to_snake_case()
		asset_folder = asset_folder.replace(" ", "_").replace("-", "_")
		var regex = RegEx.new()
		regex.compile("[^a-z0-9_]")
		asset_folder = regex.sub(asset_folder, "", true)
		if asset_folder.is_empty():
			asset_folder = "asset"
		_asset_folder_name = asset_folder  # Store for folder change
		if _install_path_label:
			_install_path_label.text = "Install to: %s/%s/" % [base_install_path, asset_folder]

	for file_path in files:
		if file_path.ends_with("/"):
			continue

		var rel_path = file_path
		# If we need to add a folder prefix (no common root in ZIP)
		if not asset_folder.is_empty():
			rel_path = asset_folder + "/" + file_path

		if not rel_path.is_empty():
			_zip_files.append({
				"zip_path": file_path,
				"rel_path": rel_path,
				"is_dir": false,
				"selected": true
			})


func _build_godotpackage_file_list(files: PackedStringArray) -> void:
	## Build file list from .godotpackage package using manifest
	## Universal logic - _custom_install_root is always the full path
	var pack_root = _godotpackage_manifest.get("pack_root", "files/")
	if not pack_root.ends_with("/"):
		pack_root += "/"

	var pkg_name = _godotpackage_manifest.get("name", "package")
	var preserve_structure = _godotpackage_manifest.get("preserve_structure", false)

	SettingsDialog.debug_print("GDPKG: pack_root='%s', pkg_name='%s', preserve_structure=%s" % [pack_root, pkg_name, preserve_structure])
	SettingsDialog.debug_print("GDPKG: manifest type='%s'" % _godotpackage_manifest.get("type", "<not set>"))

	# Determine package sub-type from manifest
	var pkg_type = _godotpackage_manifest.get("type", "")

	# If no type in manifest, try to detect from files
	if pkg_type.is_empty():
		SettingsDialog.debug_print("GDPKG: No type in manifest, detecting from files...")
		for file_path in files:
			var file_in_pack = file_path.substr(pack_root.length()) if file_path.begins_with(pack_root) else file_path
			if file_in_pack.ends_with("plugin.cfg"):
				pkg_type = "plugin"
				SettingsDialog.debug_print("GDPKG: Detected plugin from file: %s" % file_path)
				break
			elif file_in_pack.ends_with("project.godot"):
				pkg_type = "template"
				SettingsDialog.debug_print("GDPKG: Detected template from file: %s" % file_path)
				break
		if pkg_type.is_empty():
			pkg_type = "asset"
			SettingsDialog.debug_print("GDPKG: No plugin.cfg or project.godot found, defaulting to asset")

	SettingsDialog.debug_print("GDPKG: Final type='%s'" % pkg_type)

	# For plugins, we need to add the plugin folder name to rel_path
	var plugin_folder_prefix = ""

	# Set install path based on type - _custom_install_root is always the FULL path
	# Reset install at root state
	_is_install_at_root = false
	if _install_root_btn:
		_install_root_btn.button_pressed = false
		_update_install_root_button_style()

	# For preserve_structure packages, files are installed to a subfolder with structure preserved
	# After installation, paths in scenes/scripts will be rewritten to point to the new location
	match pkg_type:
		"plugin", "addon":
			if _install_path_label:
				_install_path_label.text = "Install to: res://addons/%s/" % pkg_name
			_custom_install_root = "res://addons"
			_default_install_root = _custom_install_root
			# Plugin files need to go into addons/pkg_name/
			plugin_folder_prefix = pkg_name + "/"
		"template", "project":
			if _install_path_label:
				_install_path_label.text = "Install to: res://templates/%s/" % pkg_name.to_snake_case()
			_custom_install_root = "res://templates/%s" % pkg_name.to_snake_case()
			_default_install_root = _custom_install_root
			if _install_root_btn:
				_install_root_btn.visible = true
		_:
			if _install_path_label:
				_install_path_label.text = "Install to: res://Packages/%s/" % pkg_name
			_custom_install_root = "res://Packages/%s" % pkg_name
			_default_install_root = _custom_install_root

	for file_path in files:
		# Skip manifest
		if file_path == "manifest.json":
			continue
		# Skip directories
		if file_path.ends_with("/"):
			continue
		# Only include files under pack_root
		if not file_path.begins_with(pack_root):
			continue

		# Get relative path (remove pack_root prefix)
		var rel_path = file_path.substr(pack_root.length())

		# For plugins, prepend the plugin folder name
		if not plugin_folder_prefix.is_empty():
			rel_path = plugin_folder_prefix + rel_path

		if not rel_path.is_empty():
			_zip_files.append({
				"zip_path": file_path,
				"rel_path": rel_path,
				"is_dir": false,
				"selected": true
			})

	SettingsDialog.debug_print("Install: GDPKG '%s' type='%s', %d files, install to: %s" % [pkg_name, pkg_type, _zip_files.size(), _custom_install_root])
	if _zip_files.size() > 0:
		SettingsDialog.debug_print("GDPKG: First file rel_path: '%s'" % _zip_files[0]["rel_path"])
		if _zip_files.size() > 1:
			SettingsDialog.debug_print("GDPKG: Second file rel_path: '%s'" % _zip_files[1]["rel_path"])

	# Extract autoloads from manifest
	var manifest_autoloads = _godotpackage_manifest.get("autoloads", {})
	if manifest_autoloads.size() > 0:
		SettingsDialog.debug_print("GDPKG: Found %d autoloads in manifest" % manifest_autoloads.size())
		# Store autoloads in _project_settings so they appear in the tree and get imported
		# Adapt paths to install location
		var adapted_autoloads: Dictionary = {}
		for autoload_name in manifest_autoloads:
			var autoload_value: String = manifest_autoloads[autoload_name]
			# Adapt the path based on install location
			var adapted_value = _adapt_autoload_path(autoload_value, pkg_type, pkg_name)
			adapted_autoloads[autoload_name] = adapted_value
			SettingsDialog.debug_print("GDPKG: Autoload '%s': %s -> %s" % [autoload_name, autoload_value, adapted_value])
		_project_settings["autoload"] = adapted_autoloads

	# Extract input_actions from manifest
	var manifest_input_actions = _godotpackage_manifest.get("input_actions", {})
	if manifest_input_actions.size() > 0:
		SettingsDialog.debug_print("GDPKG: Found %d input actions in manifest" % manifest_input_actions.size())
		_project_settings["input"] = manifest_input_actions


## File category definitions
const FILE_CATEGORIES = {
	"Scripts": [".gd", ".cs", ".cpp", ".c", ".h", ".hpp"],
	"Scenes": [".tscn", ".scn", ".escn"],
	"Resources": [".tres", ".res"],
	"Shaders": [".gdshader", ".shader", ".gdshaderinc"],
	"Images": [".png", ".jpg", ".jpeg", ".webp", ".svg", ".bmp", ".tga", ".hdr", ".exr"],
	"3D Models": [".glb", ".gltf", ".obj", ".fbx", ".dae", ".blend"],
	"Audio": [".wav", ".ogg", ".mp3", ".opus"],
	"Fonts": [".ttf", ".otf", ".woff", ".woff2", ".fnt"],
	"Documentation": [".md", ".txt", ".rst", ".html", ".pdf"],
	"Translations": [".po", ".pot", ".csv", ".translation"],
	"Data": [".json", ".xml", ".yaml", ".yml", ".cfg", ".ini", ".toml"],
	"Plugins": [".dll", ".so", ".dylib", ".gdextension"],
	"UID": [".uid"],
}

## Category icons (emoji)
const CATEGORY_ICONS = {
	"Scripts": "📜",
	"Scenes": "🎬",
	"Resources": "📦",
	"Shaders": "✨",
	"Images": "🖼",
	"3D Models": "🎲",
	"Audio": "🔊",
	"Fonts": "🔤",
	"Documentation": "📄",
	"Translations": "🌍",
	"Data": "📊",
	"Plugins": "🔌",
	"UID": "🔗",
	"Other": "📁",
}


func _get_file_category(file_path: String) -> String:
	var ext = file_path.get_extension().to_lower()
	if ext.is_empty():
		return "Other"

	ext = "." + ext

	for category in FILE_CATEGORIES:
		if ext in FILE_CATEGORIES[category]:
			return category

	return "Other"


func _populate_tree() -> void:
	_tree.clear()
	_tree_items.clear()
	_folder_items.clear()

	var root = _tree.create_item()
	root.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
	root.set_text(0, _asset_info.get("title", "Package"))
	root.set_editable(0, true)
	root.set_checked(0, true)
	root.set_meta("is_root", true)

	# For PROJECT and GODOTPACKAGE packages, add Input Maps and Autoloads at the TOP
	# (if they have any in _project_settings)
	if _package_type == PackageType.PROJECT or _package_type == PackageType.GODOTPACKAGE:
		var has_input = not _project_settings.get("input_map", {}).is_empty() or not _project_settings.get("input", {}).is_empty()
		var has_autoloads = not _project_settings.get("autoload", {}).is_empty()
		if has_input or has_autoloads:
			_add_project_settings_to_tree(root)

	# For PROJECT packages with addons, add Addons section
	if _package_type == PackageType.PROJECT and not _template_addon_files.is_empty():
		_add_addons_to_tree(root)

	# Group files by category
	var categories: Dictionary = {}
	for file_info in _zip_files:
		var rel_path: String = file_info["rel_path"]
		var category = _get_file_category(rel_path)

		if not categories.has(category):
			categories[category] = []
		categories[category].append(file_info)

	# Sort categories - put important ones first, UID and Other at the end
	var category_order = ["Scripts", "Scenes", "Resources", "Shaders", "Images", "3D Models", "Audio", "Fonts", "Documentation", "Translations", "Data", "Plugins", "UID", "Other"]
	var sorted_categories: Array = []
	for cat in category_order:
		if categories.has(cat):
			sorted_categories.append(cat)

	# Create category items
	for category in sorted_categories:
		var files = categories[category]
		if files.is_empty():
			continue

		# Create category item with icon
		var cat_item = _tree.create_item(root)
		cat_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		var icon = CATEGORY_ICONS.get(category, "📁")
		cat_item.set_text(0, "%s %s (%d)" % [icon, category, files.size()])
		cat_item.set_editable(0, true)
		cat_item.set_checked(0, true)
		cat_item.set_meta("is_folder", true)
		cat_item.set_meta("is_category", true)
		cat_item.set_meta("category_name", category)
		_folder_items[category] = cat_item

		# Sort files within category
		files.sort_custom(func(a, b): return a["rel_path"] < b["rel_path"])

		# Add files to category
		for file_info in files:
			var rel_path: String = file_info["rel_path"]
			var file_name = rel_path.get_file()

			var file_item = _tree.create_item(cat_item)
			file_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			file_item.set_text(0, file_name)
			file_item.set_tooltip_text(0, rel_path)  # Show full path in tooltip
			file_item.set_editable(0, true)
			file_item.set_checked(0, true)
			file_item.set_meta("is_folder", false)
			file_item.set_meta("file_info", file_info)

			_tree_items[rel_path] = file_item

	# Collapse all categories by default
	root.set_collapsed(false)
	var child = root.get_first_child()
	while child:
		child.set_collapsed(true)
		child = child.get_next()

	# Create category quick-toggle buttons
	_create_category_buttons(sorted_categories)

	_update_counts()


func _add_project_settings_to_tree(root: TreeItem) -> void:
	# Add Input Maps section at the top
	# Note: PROJECT type uses "input_map", GODOTPACKAGE uses "input" from manifest
	var input_map = _project_settings.get("input_map", {})
	if input_map.is_empty():
		input_map = _project_settings.get("input", {})
	if not input_map.is_empty():
		var input_item = _tree.create_item(root)
		input_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		input_item.set_text(0, "⌨ Input Actions (%d)" % input_map.size())
		input_item.set_editable(0, true)
		input_item.set_checked(0, true)
		input_item.set_meta("is_folder", true)
		input_item.set_meta("is_project_settings", true)
		input_item.set_meta("settings_type", "input_map")
		input_item.set_collapsed(true)
		_folder_items["__input_map__"] = input_item

		# Add individual input actions
		var sorted_keys = input_map.keys()
		sorted_keys.sort()
		for action_name in sorted_keys:
			var action_item = _tree.create_item(input_item)
			action_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			action_item.set_text(0, action_name)
			action_item.set_tooltip_text(0, str(input_map[action_name]))
			action_item.set_editable(0, true)
			action_item.set_checked(0, true)
			action_item.set_meta("is_folder", false)
			action_item.set_meta("is_input_action", true)
			action_item.set_meta("action_name", action_name)
			action_item.set_meta("action_value", input_map[action_name])

	# Add Autoloads section
	# For PROJECT templates, use original autoloads and adapt them
	var autoloads: Dictionary
	if _package_type == PackageType.PROJECT and not _original_autoloads.is_empty():
		# Always adapt from originals, so changing install folder works correctly
		autoloads = {}
		for autoload_name in _original_autoloads:
			var autoload_value: String = _original_autoloads[autoload_name]
			# Adapt the path based on template folder
			var pkg_type = "template"  # PROJECT templates are type "template"
			var pkg_name = _template_folder if not _template_folder.is_empty() else "template"
			var adapted_value = _adapt_autoload_path(autoload_value, pkg_type, pkg_name)
			autoloads[autoload_name] = adapted_value
			SettingsDialog.debug_print("PROJECT: Autoload '%s': %s -> %s" % [autoload_name, autoload_value, adapted_value])
	else:
		# For other package types, use autoloads from _project_settings
		autoloads = _project_settings.get("autoload", {})

	if not autoloads.is_empty():

		var autoload_item = _tree.create_item(root)
		autoload_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		autoload_item.set_text(0, "⚡ Autoloads (%d)" % autoloads.size())
		autoload_item.set_editable(0, true)
		autoload_item.set_checked(0, true)
		autoload_item.set_meta("is_folder", true)
		autoload_item.set_meta("is_project_settings", true)
		autoload_item.set_meta("settings_type", "autoload")
		autoload_item.set_collapsed(true)
		_folder_items["__autoload__"] = autoload_item

		# Add individual autoloads
		var sorted_autoloads = autoloads.keys()
		sorted_autoloads.sort()
		for autoload_name in sorted_autoloads:
			var al_item = _tree.create_item(autoload_item)
			al_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			al_item.set_text(0, autoload_name)
			al_item.set_tooltip_text(0, str(autoloads[autoload_name]))
			al_item.set_editable(0, true)
			al_item.set_checked(0, true)
			al_item.set_meta("is_folder", false)
			al_item.set_meta("is_autoload", true)
			al_item.set_meta("autoload_name", autoload_name)
			al_item.set_meta("autoload_value", autoloads[autoload_name])


func _add_addons_to_tree(root: TreeItem) -> void:
	## Add addons section for templates that contain plugins
	## Groups addons by plugin name (addons/plugin_name/...)
	if _template_addon_files.is_empty():
		return

	# Group addon files by plugin folder name
	var addon_plugins: Dictionary = {}  # plugin_name -> Array of file_info
	for file_info in _template_addon_files:
		var rel_path: String = file_info["rel_path"]
		# rel_path is like "addons/plugin_name/file.gd"
		var parts = rel_path.split("/")
		if parts.size() >= 2:
			var plugin_name = parts[1]  # "plugin_name"
			if not addon_plugins.has(plugin_name):
				addon_plugins[plugin_name] = []
			addon_plugins[plugin_name].append(file_info)

	# Create main Addons section
	var addons_item = _tree.create_item(root)
	addons_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
	addons_item.set_text(0, "🧩 Addons → res://addons/ (%d plugins)" % addon_plugins.size())
	addons_item.set_editable(0, true)
	addons_item.set_checked(0, true)
	addons_item.set_meta("is_folder", true)
	addons_item.set_meta("is_addons_section", true)
	addons_item.set_collapsed(true)
	_folder_items["__addons__"] = addons_item

	# Add each plugin as a sub-folder
	var sorted_plugins = addon_plugins.keys()
	sorted_plugins.sort()
	for plugin_name in sorted_plugins:
		var plugin_files: Array = addon_plugins[plugin_name]

		# Create plugin folder item
		var plugin_item = _tree.create_item(addons_item)
		plugin_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		plugin_item.set_text(0, "📦 %s (%d files)" % [plugin_name, plugin_files.size()])
		plugin_item.set_tooltip_text(0, "Will be installed to: res://addons/%s/" % plugin_name)
		plugin_item.set_editable(0, true)
		plugin_item.set_checked(0, true)
		plugin_item.set_meta("is_folder", true)
		plugin_item.set_meta("is_addon_plugin", true)
		plugin_item.set_meta("plugin_name", plugin_name)
		plugin_item.set_collapsed(true)  # Collapsed by default
		_folder_items["__addon_" + plugin_name] = plugin_item

		# Sort and add files within this plugin
		plugin_files.sort_custom(func(a, b): return a["rel_path"] < b["rel_path"])
		for file_info in plugin_files:
			var rel_path: String = file_info["rel_path"]
			var file_name = rel_path.get_file()

			var file_item = _tree.create_item(plugin_item)
			file_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			file_item.set_text(0, file_name)
			file_item.set_tooltip_text(0, rel_path)
			file_item.set_editable(0, true)
			file_item.set_checked(0, true)
			file_item.set_meta("is_folder", false)
			file_item.set_meta("is_addon_file", true)
			file_item.set_meta("file_info", file_info)

			_tree_items["addon:" + rel_path] = file_item


func _create_category_buttons(categories: Array) -> void:
	# Clear existing buttons
	for btn_name in _category_buttons:
		_category_buttons[btn_name].queue_free()
	_category_buttons.clear()

	# Don't create buttons if only one or two categories
	if categories.size() <= 2:
		return

	for category in categories:
		var btn = Button.new()
		btn.text = category
		btn.toggle_mode = true
		btn.button_pressed = true
		btn.custom_minimum_size.x = 60
		btn.add_theme_font_size_override("font_size", 11)

		var cat_name = category
		btn.toggled.connect(func(pressed): _on_category_button_toggled(cat_name, pressed))

		_category_buttons_container.add_child(btn)
		_category_buttons[category] = btn

		# Apply initial color (active = green)
		_update_category_button_color(btn, true)


func _update_category_button_color(btn: Button, active: bool) -> void:
	if active:
		# Green when active
		btn.add_theme_color_override("font_color", Color(0.4, 0.85, 0.4))
		btn.add_theme_color_override("font_hover_color", Color(0.5, 0.95, 0.5))
		btn.add_theme_color_override("font_pressed_color", Color(0.4, 0.85, 0.4))
	else:
		# Grey when inactive
		btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		btn.add_theme_color_override("font_hover_color", Color(0.6, 0.6, 0.6))
		btn.add_theme_color_override("font_pressed_color", Color(0.5, 0.5, 0.5))


func _on_category_button_toggled(category: String, pressed: bool) -> void:
	# Toggle all files in this category
	if not _folder_items.has(category):
		return

	var cat_item: TreeItem = _folder_items[category]
	cat_item.set_checked(0, pressed)
	_set_children_checked(cat_item, pressed)
	_update_parent_states(cat_item)
	_update_counts()

	# Update button color
	if _category_buttons.has(category):
		_update_category_button_color(_category_buttons[category], pressed)


func _on_item_edited() -> void:
	var item = _tree.get_edited()
	if item == null:
		return

	var is_checked = item.is_checked(0)

	if item.get_meta("is_root", false) or item.get_meta("is_folder", false):
		_set_children_checked(item, is_checked)

		# Sync category button if this is a category
		if item.get_meta("is_category", false):
			var cat_name = item.get_meta("category_name", "")
			if _category_buttons.has(cat_name):
				_category_buttons[cat_name].set_pressed_no_signal(is_checked)
				_update_category_button_color(_category_buttons[cat_name], is_checked)

	if not item.get_meta("is_folder", false) and not item.get_meta("is_root", false):
		var file_info = item.get_meta("file_info", null)
		if file_info:
			file_info["selected"] = is_checked

	_update_parent_states(item)
	_update_counts()


func _set_children_checked(item: TreeItem, checked: bool) -> void:
	var child = item.get_first_child()
	while child:
		child.set_checked(0, checked)

		# Only update file_info if it exists (not for project settings items)
		if child.has_meta("file_info"):
			var file_info = child.get_meta("file_info")
			if file_info:
				file_info["selected"] = checked

		if child.get_meta("is_folder", false):
			_set_children_checked(child, checked)

		child = child.get_next()


func _update_parent_states(item: TreeItem) -> void:
	var parent = item.get_parent()
	if parent == null:
		return

	var all_checked = true
	var any_checked = false

	var child = parent.get_first_child()
	while child:
		if child.is_checked(0):
			any_checked = true
		else:
			all_checked = false
		child = child.get_next()

	parent.set_checked(0, all_checked or any_checked)

	# Sync category button if parent is a category
	if parent.get_meta("is_category", false):
		var cat_name = parent.get_meta("category_name", "")
		if _category_buttons.has(cat_name):
			_category_buttons[cat_name].set_pressed_no_signal(all_checked)
			_update_category_button_color(_category_buttons[cat_name], all_checked)

	_update_parent_states(parent)


func _update_counts() -> void:
	var selected_count = 0
	var total_files = 0

	for file_info in _zip_files:
		total_files += 1
		if file_info["selected"]:
			selected_count += 1

	# Also count addon files for templates
	for file_info in _template_addon_files:
		total_files += 1
		if file_info["selected"]:
			selected_count += 1

	_file_count_label.text = "%d / %d files selected" % [selected_count, total_files]
	get_ok_button().disabled = selected_count == 0


func _on_select_all() -> void:
	# Select all files
	for file_info in _zip_files:
		file_info["selected"] = true

	# Update tree checkboxes
	var root = _tree.get_root()
	if root:
		_set_children_checked(root, true)
		root.set_checked(0, true)

	# Update all category buttons
	for cat_name in _category_buttons:
		_category_buttons[cat_name].set_pressed_no_signal(true)
		_update_category_button_color(_category_buttons[cat_name], true)

	_update_counts()


func _on_select_none() -> void:
	# Deselect all files
	for file_info in _zip_files:
		file_info["selected"] = false

	# Update tree checkboxes
	var root = _tree.get_root()
	if root:
		_set_children_checked(root, false)
		root.set_checked(0, false)

	# Update all category buttons
	for cat_name in _category_buttons:
		_category_buttons[cat_name].set_pressed_no_signal(false)
		_update_category_button_color(_category_buttons[cat_name], false)

	_update_counts()


func _on_change_folder_pressed() -> void:
	var dialog = EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.title = "Select Installation Folder"

	if not _custom_install_root.is_empty():
		dialog.current_dir = _custom_install_root.get_base_dir()
	else:
		dialog.current_dir = "res://"

	dialog.dir_selected.connect(func(dir: String):
		# Always append the appropriate subfolder based on package type
		# This ensures the package has its own folder even when user changes location
		match _package_type:
			PackageType.GODOTPACKAGE:
				if not _godotpackage_manifest.is_empty():
					var pkg_name = _godotpackage_manifest.get("name", "package")
					_custom_install_root = dir.path_join(pkg_name)
				else:
					_custom_install_root = dir
			PackageType.ASSET:
				# For assets from the store, the rel_path already includes the folder name
				# So we just use the selected directory directly
				_custom_install_root = dir
			PackageType.PROJECT:
				if not _template_folder.is_empty():
					_custom_install_root = dir.path_join(_template_folder)
				else:
					_custom_install_root = dir
			_:
				_custom_install_root = dir
		if not _custom_install_root.ends_with("/"):
			_custom_install_root += "/"
		# Update label to show actual install path with asset folder if applicable
		if _package_type == PackageType.ASSET and not _asset_folder_name.is_empty():
			_install_path_label.text = "Install to: %s%s/" % [_custom_install_root, _asset_folder_name]
		else:
			_install_path_label.text = "Install to: %s" % _custom_install_root

		# Deactivate "Install at Root" button since user manually changed folder
		_is_install_at_root = false
		if _install_root_btn:
			_install_root_btn.button_pressed = false
			_update_install_root_button_style()

		# For PROJECT templates, rebuild the tree to update autoload paths
		if _package_type == PackageType.PROJECT:
			SettingsDialog.debug_print("PROJECT: Rebuilding tree with new install path: %s" % _custom_install_root)
			_populate_tree()

		dialog.queue_free()
	)

	dialog.canceled.connect(func():
		dialog.queue_free()
	)

	add_child(dialog)
	dialog.popup_centered(Vector2i(600, 400))


func _on_install_root_pressed() -> void:
	# Toggle behavior - if already at root, restore default
	if _is_install_at_root:
		# Restore default path
		_is_install_at_root = false
		_install_root_btn.button_pressed = false
		_custom_install_root = _default_install_root
		# Update label - for assets, include the folder name
		if _package_type == PackageType.ASSET and not _asset_folder_name.is_empty():
			var path = _custom_install_root.rstrip("/") + "/" + _asset_folder_name + "/"
			_install_path_label.text = "Install to: %s" % path
		else:
			_install_path_label.text = "Install to: %s" % _custom_install_root
		_update_install_root_button_style()
	else:
		# Show confirmation dialog before installing at root
		var confirm = ConfirmationDialog.new()
		confirm.title = "Install at Root?"
		confirm.dialog_text = "This will install all files directly into res:// (project root).\n\nFiles will NOT be placed in a subfolder.\nThis can clutter your project root.\n\nAre you sure?"
		confirm.ok_button_text = "Yes, Install at Root"
		confirm.cancel_button_text = "Cancel"

		confirm.confirmed.connect(func():
			_is_install_at_root = true
			_install_root_btn.button_pressed = true
			_custom_install_root = "res://"
			_install_path_label.text = "Install to: res:// (root)"
			_update_install_root_button_style()
			confirm.queue_free()
		)

		confirm.canceled.connect(func():
			# Reset button state since user canceled
			_install_root_btn.button_pressed = false
			confirm.queue_free()
		)

		add_child(confirm)
		confirm.popup_centered()


func _update_install_root_button_style() -> void:
	if not _install_root_btn:
		return
	if _is_install_at_root:
		# Active style - highlight the button
		var style = StyleBoxFlat.new()
		style.bg_color = Color(0.3, 0.5, 0.3)
		style.set_border_width_all(1)
		style.border_color = Color(0.4, 0.7, 0.4)
		style.set_corner_radius_all(4)
		_install_root_btn.add_theme_stylebox_override("normal", style)
		_install_root_btn.add_theme_stylebox_override("hover", style)
		_install_root_btn.add_theme_stylebox_override("pressed", style)
	else:
		# Reset to default style
		_install_root_btn.remove_theme_stylebox_override("normal")
		_install_root_btn.remove_theme_stylebox_override("hover")
		_install_root_btn.remove_theme_stylebox_override("pressed")


func _update_folder_buttons_state() -> void:
	# Disable folder buttons during download/install, enable when ready
	var enabled = _state == State.READY
	if _change_folder_btn:
		_change_folder_btn.disabled = not enabled
	if _install_root_btn:
		_install_root_btn.disabled = not enabled


func _on_confirmed() -> void:
	# If installation is done, just close the dialog
	if _state == State.DONE:
		hide()
		queue_free()
		return

	_state = State.INSTALLING
	_update_folder_buttons_state()
	get_ok_button().disabled = true
	_status_label.text = "Installing..."
	_progress_bar.value = 0

	SettingsDialog.debug_print(" >>>>>> INSTALL UI: Setting status to 'Installing...'")
	SettingsDialog.debug_print(" >>>>>> INSTALL UI: _status_label.text = '%s'" % _status_label.text)
	SettingsDialog.debug_print(" >>>>>> INSTALL UI: _status_label.visible = %s" % _status_label.visible)
	SettingsDialog.debug_print(" >>>>>> INSTALL UI: Dialog visible = %s" % visible)

	# Allow UI to update before starting installation
	await get_tree().process_frame
	SettingsDialog.debug_print(" >>>>>> INSTALL UI: After process_frame, starting installation...")

	# Get selected files
	var selected_files: Array = []
	for file_info in _zip_files:
		if file_info["selected"]:
			selected_files.append(file_info)

	# Get selected addon files (for templates with addons)
	var selected_addon_files: Array = []
	for file_info in _template_addon_files:
		if file_info["selected"]:
			selected_addon_files.append(file_info)

	# Get selected project settings (input actions and autoloads)
	var selected_input_actions: Dictionary = {}
	var selected_autoloads: Dictionary = {}
	SettingsDialog.debug_print("COLLECT CHECK: _package_type=%d, _project_settings keys=%s" % [_package_type, str(_project_settings.keys())])
	SettingsDialog.debug_print("COLLECT CHECK: _project_settings.autoload=%s" % str(_project_settings.get("autoload", {})))
	if _package_type == PackageType.PROJECT or _package_type == PackageType.GODOTPACKAGE:
		SettingsDialog.debug_print("COLLECT CHECK: Calling _collect_selected_project_settings...")
		_collect_selected_project_settings(selected_input_actions, selected_autoloads)
		SettingsDialog.debug_print("COLLECT CHECK: After collection - input=%d, autoloads=%d" % [selected_input_actions.size(), selected_autoloads.size()])
		for al_name in selected_autoloads:
			SettingsDialog.debug_print("COLLECT CHECK: Autoload collected: '%s' = '%s'" % [al_name, selected_autoloads[al_name]])
	else:
		SettingsDialog.debug_print("COLLECT CHECK: Skipped - package type does not match")

	var total = selected_files.size() + selected_addon_files.size()
	var done = 0

	# Determine install root
	var install_root = _custom_install_root if not _custom_install_root.is_empty() else "res://"

	# Collect ALL unique installed folder paths
	var installed_paths: Array = []
	var seen_folders: Dictionary = {}

	# For PLUGIN: collect addons/ paths (or moved location for updates)
	# For ASSET: collect assets/<folder>/ path
	# For PROJECT: collect the root path
	# For GODOTPACKAGE: collect plugin folder (rel_path starts with plugin name, installed to addons/)
	var is_moved_update = _asset_info.get("_update_moved_location", false)

	match _package_type:
		PackageType.PLUGIN:
			if is_moved_update:
				# For moved updates, rel_path is like "folder_name/file.gd" and install_root is the parent
				for file_info in selected_files:
					var rel_path: String = file_info["rel_path"]
					var parts = rel_path.split("/")
					if parts.size() >= 1:
						var folder_name = parts[0]
						if not seen_folders.has(folder_name):
							seen_folders[folder_name] = true
							installed_paths.append(install_root.path_join(folder_name))
			else:
				# Normal plugin install - rel_path starts with "addons/"
				for file_info in selected_files:
					var rel_path: String = file_info["rel_path"]
					if rel_path.begins_with("addons/"):
						var parts = rel_path.split("/")
						if parts.size() >= 2:
							var folder_name = parts[1]
							if not seen_folders.has(folder_name):
								seen_folders[folder_name] = true
								installed_paths.append(install_root.path_join("addons/" + folder_name))

		PackageType.GODOTPACKAGE:
			# For GODOTPACKAGE, behavior depends on the manifest type
			var gdpkg_type = _godotpackage_manifest.get("type", "").to_lower()
			if gdpkg_type in ["asset", "project"]:
				# For assets/projects, install_root IS the target folder (e.g., res://Packages/projectile)
				# Just use install_root directly as the single path
				installed_paths.append(install_root.trim_suffix("/"))
			else:
				# For plugins, rel_path starts with plugin name directly (e.g., "primes/api/file.gd")
				# install_root is "res://addons", so append plugin_name
				for file_info in selected_files:
					var rel_path: String = file_info["rel_path"]
					var parts = rel_path.split("/")
					if parts.size() >= 1:
						var plugin_name = parts[0]
						if not seen_folders.has(plugin_name):
							seen_folders[plugin_name] = true
							installed_paths.append(install_root.path_join(plugin_name))

		PackageType.ASSET:
			# For assets with custom install root, include the asset folder name
			if not _custom_install_root.is_empty():
				var asset_root = _custom_install_root.trim_suffix("/")
				if not _asset_folder_name.is_empty():
					asset_root = asset_root.path_join(_asset_folder_name)
				installed_paths.append(asset_root)
			else:
				# Default: collect the top-level folder under assets/
				for file_info in selected_files:
					var rel_path: String = file_info["rel_path"]
					var parts = rel_path.split("/")
					if parts.size() >= 1:
						var folder_name = parts[0]
						if not seen_folders.has(folder_name):
							seen_folders[folder_name] = true
							installed_paths.append(install_root.path_join(folder_name))

		PackageType.PROJECT:
			# For templates with custom install root, use the custom root as the main path
			if not _custom_install_root.is_empty():
				installed_paths.append(_custom_install_root.trim_suffix("/"))
			else:
				# Default: collect top-level folders
				for file_info in selected_files:
					var rel_path: String = file_info["rel_path"]
					var parts = rel_path.split("/")
					if parts.size() >= 1:
						var folder_name = parts[0]
						if not seen_folders.has(folder_name):
							seen_folders[folder_name] = true
							installed_paths.append(install_root.path_join(folder_name))
			# Also collect addon paths (installed to res://addons/)
			for file_info in selected_addon_files:
				var rel_path: String = file_info["rel_path"]
				# rel_path is like "addons/plugin_name/..."
				var parts = rel_path.split("/")
				if parts.size() >= 2:
					var addon_folder = "addons/" + parts[1]
					if not seen_folders.has(addon_folder):
						seen_folders[addon_folder] = true
						installed_paths.append("res://" + addon_folder)

	# Reset installation tracking
	_install_succeeded.clear()
	_install_failed.clear()

	# For updates: disable plugin if enabled, then delete the old folder before installing new version
	var update_target_path = _asset_info.get("_update_target_path", "")
	var plugin_was_enabled := false
	var plugin_to_reenable := ""
	if not update_target_path.is_empty():
		# Check if this is a plugin and if it's enabled
		if update_target_path.begins_with("res://addons/"):
			var plugin_name = update_target_path.get_file()
			var plugin_cfg_path = update_target_path.path_join("plugin.cfg")
			if FileAccess.file_exists(plugin_cfg_path):
				# Check if plugin is enabled
				if EditorInterface.is_plugin_enabled(plugin_name):
					plugin_was_enabled = true
					plugin_to_reenable = plugin_name
					SettingsDialog.debug_print("Update: Disabling plugin '%s' before update" % plugin_name)
					_status_label.text = "Disabling plugin..."
					await get_tree().process_frame
					EditorInterface.set_plugin_enabled(plugin_name, false)
					# Wait a bit for Godot to fully disable the plugin
					await get_tree().create_timer(0.3).timeout

		SettingsDialog.debug_print("Update: Deleting old folder before install: %s" % update_target_path)
		_status_label.text = "Removing old version..."
		await get_tree().process_frame
		var delete_success = _delete_directory_recursive(update_target_path)
		if delete_success:
			SettingsDialog.debug_print("Update: Successfully deleted old folder: %s" % update_target_path)
		else:
			SettingsDialog.debug_print("Update: Failed to delete old folder (may not exist): %s" % update_target_path)

	for file_info in selected_files:
		var zip_path: String = file_info["zip_path"]
		var rel_path: String = file_info["rel_path"]

		# SECURITY: Validate path to prevent path traversal attacks
		if not _is_path_safe(rel_path):
			var error_msg = "Unsafe path rejected (possible path traversal): %s" % rel_path
			push_error("AssetPlus: " + error_msg)
			_install_failed.append({"path": rel_path, "error": error_msg})
			continue

		# Update status with current file
		_status_label.text = "Installing: %s" % rel_path.get_file()

		# Read from zip
		var content = _zip_reader.read_file(zip_path)

		# Target path - use custom install root if set
		var target_path = install_root.path_join(rel_path) if install_root != "res://" else "res://" + rel_path

		# Create directory
		var target_dir = target_path.get_base_dir()
		var global_target_dir = ProjectSettings.globalize_path(target_dir)
		if not DirAccess.dir_exists_absolute(global_target_dir):
			var err = DirAccess.make_dir_recursive_absolute(global_target_dir)
			if err != OK:
				var error_msg = "Failed to create directory: %s (error: %s)" % [target_dir, error_string(err)]
				push_warning("AssetPlus: " + error_msg)
				_install_failed.append({"path": rel_path, "error": error_msg})
				continue

		# Write file
		var file = FileAccess.open(target_path, FileAccess.WRITE)
		if file == null:
			var error_msg = "Failed to write file: %s (error: %s)" % [target_path, error_string(FileAccess.get_open_error())]
			push_warning("AssetPlus: " + error_msg)
			_install_failed.append({"path": rel_path, "error": error_msg})
			continue

		file.store_buffer(content)
		file.close()
		_install_succeeded.append(target_path)

		done += 1
		_progress_bar.value = (float(done) / total) * 100

		# Allow UI to update every 10 files to show progress
		if done % 10 == 0:
			await get_tree().process_frame

	# Install addon files to res://addons/ (for templates with plugins)
	for file_info in selected_addon_files:
		var zip_path: String = file_info["zip_path"]
		var rel_path: String = file_info["rel_path"]  # Already has "addons/plugin_name/..."

		# SECURITY: Validate path to prevent path traversal attacks
		if not _is_path_safe(rel_path):
			var error_msg = "Unsafe addon path rejected: %s" % rel_path
			push_error("AssetPlus: " + error_msg)
			_install_failed.append({"path": rel_path, "error": error_msg})
			continue

		# Update status
		_status_label.text = "Installing addon: %s" % rel_path.get_file()

		# Read from zip
		var content = _zip_reader.read_file(zip_path)

		# Target path - addons go to res://addons/ directly
		var target_path = "res://" + rel_path

		# Create directory
		var target_dir = target_path.get_base_dir()
		var global_target_dir = ProjectSettings.globalize_path(target_dir)
		if not DirAccess.dir_exists_absolute(global_target_dir):
			var err = DirAccess.make_dir_recursive_absolute(global_target_dir)
			if err != OK:
				var error_msg = "Failed to create addon directory: %s (error: %s)" % [target_dir, error_string(err)]
				push_warning("AssetPlus: " + error_msg)
				_install_failed.append({"path": rel_path, "error": error_msg})
				continue

		# Write file
		var file = FileAccess.open(target_path, FileAccess.WRITE)
		if file == null:
			var error_msg = "Failed to write addon file: %s (error: %s)" % [target_path, error_string(FileAccess.get_open_error())]
			push_warning("AssetPlus: " + error_msg)
			_install_failed.append({"path": rel_path, "error": error_msg})
			continue

		file.store_buffer(content)
		file.close()
		_install_succeeded.append(target_path)

		done += 1
		_progress_bar.value = (float(done) / total) * 100

		if done % 10 == 0:
			await get_tree().process_frame

	# Adapt load/preload paths in scripts (for templates with custom install root)
	_adapt_script_paths_in_files(install_root)

	# Adapt .gdextension files if install path differs from default addons/ path
	# Skip for plugins installed to res://addons/ (install_root is empty or res://)
	if not install_root.is_empty() and install_root != "res://" and not install_root.begins_with("res://addons"):
		_adapt_gdextension_paths(install_root, installed_paths)

	# Import project settings (input actions and autoloads)
	var imported_inputs_count := 0
	SettingsDialog.debug_print("IMPORT CHECK: _package_type=%d (PROJECT=%d, GODOTPACKAGE=%d)" % [_package_type, PackageType.PROJECT, PackageType.GODOTPACKAGE])
	SettingsDialog.debug_print("IMPORT CHECK: selected_input_actions=%d, selected_autoloads=%d" % [selected_input_actions.size(), selected_autoloads.size()])
	if _package_type == PackageType.PROJECT or _package_type == PackageType.GODOTPACKAGE:
		SettingsDialog.debug_print("IMPORT CHECK: Calling _import_project_settings...")
		imported_inputs_count = _import_project_settings(selected_input_actions, selected_autoloads)
	else:
		SettingsDialog.debug_print("IMPORT CHECK: Skipped - package type does not match")

	# Cleanup zip reader and temp file
	if _zip_reader != null:
		_zip_reader.close()
		_zip_reader = null

	if not _zip_path.is_empty():
		var temp_file = ProjectSettings.globalize_path(_zip_path)
		if FileAccess.file_exists(temp_file):
			DirAccess.remove_absolute(temp_file)
		_zip_path = ""

	_progress_bar.value = 100
	_state = State.DONE
	_status_label.text = _build_completion_message(imported_inputs_count)

	# IMPORTANT: Create version.cfg and persist installation BEFORE filesystem scan
	# Godot's filesystem scan causes script reload which cancels any pending signal handlers
	_create_version_cfg_for_installed_paths(installed_paths)

	# Copy embedded icon from .godotpackage to the installed folder
	_copy_embedded_icon_to_installed(installed_paths)

	# Pre-collect file paths for tracking (UIDs will be empty but paths are tracked)
	# This allows recovery after script reload even without UIDs
	var pre_tracked: Array = []
	for file_path in _install_succeeded:
		pre_tracked.append({"path": file_path, "uid": ""})
	_persist_pending_installation(installed_paths, pre_tracked)

	# Close dialog immediately
	hide()

	# Wait a frame to let dialog close
	await get_tree().process_frame

	# Scan filesystem to register new files and assign UIDs
	SettingsDialog.debug_print("Starting filesystem scan...")
	var fs = EditorInterface.get_resource_filesystem()
	if fs.has_method("scan_sources"):
		fs.scan_sources()
	else:
		fs.scan()

	# Wait for filesystem scan to complete (uses signal, not fixed timer)
	SettingsDialog.debug_print("Waiting for filesystem scan...")
	if is_inside_tree():
		await _wait_for_filesystem_scan_complete()
	else:
		SettingsDialog.debug_print("WARNING: Dialog no longer in tree, skipping scan wait")
	SettingsDialog.debug_print("Filesystem scan done")

	# Re-enable plugin if it was enabled before the update
	if plugin_was_enabled and not plugin_to_reenable.is_empty():
		SettingsDialog.debug_print("Update: Re-enabling plugin '%s' after update" % plugin_to_reenable)
		# Wait a bit before re-enabling to ensure files are fully registered
		await get_tree().create_timer(0.2).timeout
		EditorInterface.set_plugin_enabled(plugin_to_reenable, true)
		SettingsDialog.debug_print("Update: Plugin '%s' re-enabled" % plugin_to_reenable)

	# Collect ALL installed files (with UIDs when available, without for files like .md, LICENSE, etc.)
	var tracked_uids: Array = []
	SettingsDialog.debug_print_verbose("_install_succeeded contains %d files" % _install_succeeded.size())
	for file_path in _install_succeeded:
		var uid = _get_file_uid(file_path)
		# Track ALL files, not just those with UIDs
		# Files without UIDs (like .md, LICENSE, .sh) are tracked by path only
		tracked_uids.append({"path": file_path, "uid": uid})

	# Detect files generated by Godot during import (e.g., textures extracted from GLB)
	var generated_files = _detect_godot_generated_files(installed_paths, _install_succeeded)
	if generated_files.size() > 0:
		SettingsDialog.debug_print_verbose("Detected %d Godot-generated files" % generated_files.size())
		for gen_file in generated_files:
			var uid = _get_file_uid(gen_file)
			tracked_uids.append({"path": gen_file, "uid": uid})

	# Update pending installation with UIDs (version.cfg was already created before scan)
	_persist_pending_installation(installed_paths, tracked_uids)

	# Emit signal with tracked files
	SettingsDialog.debug_print_verbose("Emitting installation_complete - paths=%d, tracked_files=%d" % [installed_paths.size(), tracked_uids.size()])
	installation_complete.emit(true, installed_paths, tracked_uids)

	# Show completion notification
	var completion_msg = _build_completion_message(imported_inputs_count)
	_show_completion_notification(completion_msg)

	# Queue free the dialog
	queue_free()


func _build_completion_message(inputs_imported: int) -> String:
	## Build a completion message including any errors that occurred
	var msg = "Installation complete!"

	if _install_failed.size() > 0:
		msg = "Installation completed with %d error(s)!" % _install_failed.size()
		# Show first few errors
		var errors_to_show = mini(_install_failed.size(), 3)
		for i in range(errors_to_show):
			var err = _install_failed[i]
			msg += "\n• %s" % err.get("path", "Unknown").get_file()
		if _install_failed.size() > 3:
			msg += "\n  ...and %d more (see Output log)" % (_install_failed.size() - 3)

	if inputs_imported > 0:
		msg += "\nInput actions will appear in Project Settings after editor restart."

	return msg


func _show_completion_notification(message: String) -> void:
	## Show a toast notification for installation completion
	var notification = AcceptDialog.new()
	notification.title = "Installation Complete"
	notification.dialog_text = message
	notification.dialog_autowrap = true
	notification.borderless = false
	notification.unresizable = false
	notification.min_size = Vector2i(400, 150)

	# Add to editor base control
	EditorInterface.get_base_control().add_child(notification)

	# Center and show
	notification.popup_centered()

	# Auto-close after 3 seconds
	await get_tree().create_timer(3.0).timeout
	if is_instance_valid(notification):
		notification.hide()
		notification.queue_free()


func _detect_godot_generated_files(installed_folders: Array, original_files: Array) -> Array:
	## Detect files generated by Godot during import (e.g., textures extracted from GLB models)
	## Returns array of file paths that were generated but not in the original install list
	var generated_files: Array = []

	# Build a set of original files for fast lookup
	var original_set: Dictionary = {}
	for f in original_files:
		original_set[f] = true

	# Scan each installed folder for all current files
	for folder_path in installed_folders:
		var global_folder = ProjectSettings.globalize_path(folder_path)
		if not DirAccess.dir_exists_absolute(global_folder):
			continue

		var all_files = _scan_folder_recursive(folder_path)
		for file_path in all_files:
			# Skip .import files - they're metadata, not actual content
			if file_path.ends_with(".import"):
				continue
			# If this file wasn't in the original install list, it was generated
			if not original_set.has(file_path):
				generated_files.append(file_path)

	return generated_files


func _scan_folder_recursive(folder_path: String) -> Array:
	## Recursively scan a folder and return all file paths
	var files: Array = []
	var global_path = ProjectSettings.globalize_path(folder_path)
	var dir = DirAccess.open(global_path)
	if dir == null:
		return files

	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path = folder_path.path_join(file_name)
			if dir.current_is_dir():
				# Recurse into subdirectory
				files.append_array(_scan_folder_recursive(full_path))
			else:
				files.append(full_path)
		file_name = dir.get_next()

	dir.list_dir_end()
	return files


func _delete_directory_recursive(dir_path: String) -> bool:
	## Recursively delete a directory and all its contents
	var global_path = ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(global_path):
		return false

	var dir = DirAccess.open(global_path)
	if dir == null:
		return false

	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path = dir_path.path_join(file_name)
			var full_global_path = global_path.path_join(file_name)
			if dir.current_is_dir():
				# Recurse into subdirectory
				_delete_directory_recursive(full_path)
			else:
				# Delete file
				DirAccess.remove_absolute(full_global_path)
		file_name = dir.get_next()

	dir.list_dir_end()

	# Delete the now-empty directory
	var err = DirAccess.remove_absolute(global_path)
	return err == OK


func _wait_for_filesystem_scan_complete() -> void:
	## Wait for Godot's filesystem scan to complete (including imports)
	## Uses filesystem_changed signal with a timeout fallback
	var fs = EditorInterface.get_resource_filesystem()
	if fs == null:
		await get_tree().create_timer(0.5).timeout
		return

	# Wait for scanning to finish (check is_scanning)
	var max_wait_time := 10.0  # Maximum 10 seconds
	var check_interval := 0.2  # Check every 200ms
	var elapsed := 0.0

	SettingsDialog.debug_print_verbose("Waiting for filesystem scan to complete...")

	while fs.is_scanning() and elapsed < max_wait_time:
		await get_tree().create_timer(check_interval).timeout
		elapsed += check_interval

	if elapsed >= max_wait_time:
		SettingsDialog.debug_print_verbose("Filesystem scan timeout after %.1fs" % max_wait_time)
	else:
		SettingsDialog.debug_print_verbose("Filesystem scan completed in %.1fs" % elapsed)

	# Extra delay to ensure all imports are processed
	# (GLB imports can take a moment after scanning stops)
	await get_tree().create_timer(0.3).timeout


func _collect_selected_project_settings(input_actions: Dictionary, autoloads: Dictionary) -> void:
	# Walk the tree and collect selected input actions and autoloads
	SettingsDialog.debug_print_verbose(" ========== COLLECTING SELECTED PROJECT SETTINGS ==========")
	var root = _tree.get_root()
	if not root:
		SettingsDialog.debug_print_verbose(" No tree root!")
		return

	var child = root.get_first_child()
	var items_checked := 0
	while child:
		SettingsDialog.debug_print_verbose(" Checking child: '%s' is_project_settings=%s" % [child.get_text(0), child.get_meta("is_project_settings", false)])
		if child.get_meta("is_project_settings", false):
			var settings_type = child.get_meta("settings_type", "")
			SettingsDialog.debug_print_verbose(" Settings type: '%s'" % settings_type)
			var sub_child = child.get_first_child()
			while sub_child:
				var is_checked = sub_child.is_checked(0)
				SettingsDialog.debug_print_verbose("   Sub-item '%s' checked=%s" % [sub_child.get_text(0), is_checked])
				if is_checked:
					items_checked += 1
					if settings_type == "input_map" and sub_child.get_meta("is_input_action", false):
						var action_name = sub_child.get_meta("action_name", "")
						var action_value = sub_child.get_meta("action_value", "")
						SettingsDialog.debug_print_verbose("   -> Input action '%s' value length: %d" % [action_name, str(action_value).length()])
						if not action_name.is_empty():
							input_actions[action_name] = action_value
					elif settings_type == "autoload" and sub_child.get_meta("is_autoload", false):
						var autoload_name = sub_child.get_meta("autoload_name", "")
						var autoload_value = sub_child.get_meta("autoload_value", "")
						SettingsDialog.debug_print_verbose("   -> Autoload '%s' = %s" % [autoload_name, autoload_value])
						if not autoload_name.is_empty():
							autoloads[autoload_name] = autoload_value
				sub_child = sub_child.get_next()
		child = child.get_next()

	SettingsDialog.debug_print_verbose(" Collected %d input actions, %d autoloads (from %d checked items)" % [input_actions.size(), autoloads.size(), items_checked])
	SettingsDialog.debug_print_verbose(" ========== COLLECTION COMPLETE ==========")


func _import_project_settings(input_actions: Dictionary, autoloads: Dictionary) -> int:
	## Returns the number of input actions that were added or merged
	if input_actions.is_empty() and autoloads.is_empty():
		SettingsDialog.debug_print_verbose(" No input actions or autoloads to import")
		return 0

	SettingsDialog.debug_print(" ========== IMPORTING PROJECT SETTINGS ==========")
	SettingsDialog.debug_print(" Importing %d input actions, %d autoloads" % [input_actions.size(), autoloads.size()])

	# Debug: List all input actions we're trying to import
	for action_name in input_actions:
		SettingsDialog.debug_print_verbose(" Input action to import: '%s'" % action_name)

	var actions_added := 0
	var actions_merged := 0
	var actions_failed := 0

	# Import input actions
	for action_name in input_actions:
		var value_str: String = input_actions[action_name]
		SettingsDialog.debug_print_verbose(" ---- Processing action '%s' ----" % action_name)
		SettingsDialog.debug_print_verbose(" Raw value string (first 300 chars): %s" % value_str.left(300))

		# Parse the input action value - it's in Godot's variant format
		# Format: {"deadzone": 0.5, "events": [Object(InputEventKey, ...)]}
		var parsed_value = _parse_input_action_value(value_str)
		if parsed_value == null or not parsed_value.has("events"):
			push_warning("AssetPlus: Failed to parse input action '%s': %s" % [action_name, value_str])
			actions_failed += 1
			continue

		var events_array: Array = parsed_value.get("events", [])
		SettingsDialog.debug_print_verbose(" Parsed %d events for action '%s'" % [events_array.size(), action_name])

		# Debug each event
		for idx in range(events_array.size()):
			var ev = events_array[idx]
			if ev == null:
				SettingsDialog.debug_print_verbose("   Event %d: NULL!" % idx)
			elif ev is InputEventKey:
				var key_ev = ev as InputEventKey
				SettingsDialog.debug_print_verbose("   Event %d: InputEventKey keycode=%d (%s) physical=%d" % [idx, key_ev.keycode, OS.get_keycode_string(key_ev.keycode), key_ev.physical_keycode])
			elif ev is InputEventMouseButton:
				var mouse_ev = ev as InputEventMouseButton
				SettingsDialog.debug_print_verbose("   Event %d: InputEventMouseButton button=%d" % [idx, mouse_ev.button_index])
			elif ev is InputEventJoypadButton:
				var joy_ev = ev as InputEventJoypadButton
				SettingsDialog.debug_print_verbose("   Event %d: InputEventJoypadButton button=%d" % [idx, joy_ev.button_index])
			elif ev is InputEventJoypadMotion:
				var motion_ev = ev as InputEventJoypadMotion
				SettingsDialog.debug_print_verbose("   Event %d: InputEventJoypadMotion axis=%d value=%.2f" % [idx, motion_ev.axis, motion_ev.axis_value])
			else:
				SettingsDialog.debug_print_verbose("   Event %d: %s" % [idx, ev.get_class() if ev else "NULL"])

		var setting_path = "input/" + action_name
		SettingsDialog.debug_print_verbose(" Checking if setting exists: '%s'" % setting_path)
		SettingsDialog.debug_print_verbose(" has_setting result: %s" % ProjectSettings.has_setting(setting_path))

		if ProjectSettings.has_setting(setting_path):
			# Action already exists - merge events instead of skipping
			var existing_value = ProjectSettings.get_setting(setting_path)
			SettingsDialog.debug_print_verbose(" Existing value type: %s" % typeof(existing_value))
			if existing_value is Dictionary and existing_value.has("events"):
				var existing_events: Array = existing_value.get("events", [])
				var new_events: Array = parsed_value.get("events", [])
				var added_count = 0

				SettingsDialog.debug_print_verbose(" Existing has %d events, new has %d events" % [existing_events.size(), new_events.size()])

				for new_event in new_events:
					# Check if this event already exists (by comparing key properties)
					var is_duplicate = false
					for existing_event in existing_events:
						if _are_events_equal(new_event, existing_event):
							is_duplicate = true
							break

					if not is_duplicate:
						existing_events.append(new_event)
						added_count += 1

				if added_count > 0:
					# Add new events to InputMap directly (for immediate visibility)
					for new_event in new_events:
						var is_duplicate = false
						for existing_event in InputMap.action_get_events(action_name):
							if _are_events_equal(new_event, existing_event):
								is_duplicate = true
								break
						if not is_duplicate and new_event is InputEvent:
							InputMap.action_add_event(action_name, new_event)
							SettingsDialog.debug_print_verbose("   InputMap.action_add_event() for merge")

					# Save to ProjectSettings for persistence
					existing_value["events"] = existing_events
					ProjectSettings.set_setting(setting_path, existing_value)
					SettingsDialog.debug_print(" Merged %d new events into existing action '%s'" % [added_count, action_name])
					actions_merged += 1
				else:
					SettingsDialog.debug_print(" Input action '%s' already has all events, skipping" % action_name)
			else:
				SettingsDialog.debug_print(" Input action '%s' exists but has invalid format, skipping" % action_name)
		else:
			# New action - add using InputMap API first (for immediate visibility)
			var deadzone: float = parsed_value.get("deadzone", 0.5)
			SettingsDialog.debug_print_verbose(" Adding NEW action '%s' via InputMap API..." % action_name)

			# Step 1: Add to InputMap directly (makes it visible immediately)
			if not InputMap.has_action(action_name):
				InputMap.add_action(action_name, deadzone)
				SettingsDialog.debug_print_verbose("   InputMap.add_action() called")

			# Step 2: Add all events to InputMap
			for event in events_array:
				if event is InputEvent:
					InputMap.action_add_event(action_name, event)
					SettingsDialog.debug_print_verbose("   InputMap.action_add_event() called")

			# Step 3: Save to ProjectSettings for persistence
			SettingsDialog.debug_print_verbose(" Saving to ProjectSettings for persistence...")
			ProjectSettings.set_setting(setting_path, parsed_value)
			actions_added += 1
			SettingsDialog.debug_print(" Added input action '%s' with %d events" % [action_name, events_array.size()])

			# Verify it was added to both
			SettingsDialog.debug_print_verbose(" Verification - InputMap.has_action(): %s" % InputMap.has_action(action_name))
			if ProjectSettings.has_setting(setting_path):
				var verify = ProjectSettings.get_setting(setting_path)
				SettingsDialog.debug_print_verbose(" Verification - ProjectSettings exists, value type: %s" % typeof(verify))
				if verify is Dictionary:
					var verify_events = verify.get("events", [])
					SettingsDialog.debug_print_verbose(" Verification - events count: %d" % verify_events.size())
			else:
				SettingsDialog.debug_print_verbose(" ERROR - Setting was NOT added to ProjectSettings!")

	SettingsDialog.debug_print(" Input actions summary: %d added, %d merged, %d failed" % [actions_added, actions_merged, actions_failed])

	# Import autoloads
	# NOTE: Autoload paths are ALREADY adapted by _adapt_autoload_path when extracted from manifest
	# Do NOT call _adapt_path_to_install_root again - it would double the path!
	SettingsDialog.debug_print(" ---- Processing autoloads ----")
	for autoload_name in autoloads:
		var value_str: String = autoloads[autoload_name]
		if ProjectSettings.has_setting("autoload/" + autoload_name):
			SettingsDialog.debug_print(" Autoload '%s' already exists, skipping" % autoload_name)
			continue

		# The value is already properly formatted (e.g., "*res://Packages/pkg/scripts/script.gd")
		# Just clean up any extra quotes and use it directly
		var final_value = value_str.strip_edges()
		if final_value.begins_with("\"") and final_value.ends_with("\""):
			final_value = final_value.substr(1, final_value.length() - 2)

		ProjectSettings.set_setting("autoload/" + autoload_name, final_value)
		SettingsDialog.debug_print(" Added autoload '%s' -> %s" % [autoload_name, final_value])

	# Save the project settings
	SettingsDialog.debug_print(" ---- Saving ProjectSettings ----")
	var save_result = ProjectSettings.save()
	SettingsDialog.debug_print_verbose(" ProjectSettings.save() returned: %d (OK=%d)" % [save_result, OK])

	# Verify the file was written by checking project.godot
	var project_path = ProjectSettings.globalize_path("res://project.godot")
	SettingsDialog.debug_print_verbose(" project.godot path: %s" % project_path)
	if FileAccess.file_exists(project_path):
		var file = FileAccess.open(project_path, FileAccess.READ)
		if file:
			var content = file.get_as_text()
			file.close()
			# Check if our input actions are in the file
			SettingsDialog.debug_print_verbose(" project.godot size: %d bytes" % content.length())
			if content.find("[input]") != -1:
				SettingsDialog.debug_print_verbose(" [input] section FOUND in project.godot")
				# Extract and show the input section
				var input_start = content.find("[input]")
				var input_end = content.find("\n[", input_start + 1)
				if input_end == -1:
					input_end = content.length()
				var input_section = content.substr(input_start, mini(500, input_end - input_start))
				SettingsDialog.debug_print_verbose(" Input section (first 500 chars):\n%s" % input_section)
			else:
				SettingsDialog.debug_print_verbose(" [input] section NOT FOUND in project.godot!")
		else:
			SettingsDialog.debug_print_verbose(" Could not open project.godot for reading")
	else:
		SettingsDialog.debug_print_verbose(" project.godot not found!")

	# Force InputMap to reload from ProjectSettings
	# This makes the changes visible in Project Settings > Input Map immediately
	SettingsDialog.debug_print(" ---- Reloading InputMap from ProjectSettings ----")
	InputMap.load_from_project_settings()
	SettingsDialog.debug_print(" InputMap.load_from_project_settings() called")

	SettingsDialog.debug_print(" ========== PROJECT SETTINGS IMPORT COMPLETE ==========")

	return actions_added + actions_merged


func _sync_input_map_from_settings(input_actions: Dictionary) -> void:
	## Sync the InputMap at runtime to reflect newly added actions
	## This makes the changes visible immediately without reloading the project
	SettingsDialog.debug_print_verbose(" Syncing %d actions to InputMap" % input_actions.size())

	for action_name in input_actions:
		var setting_path = "input/" + action_name

		# Get the value we just set in ProjectSettings
		if not ProjectSettings.has_setting(setting_path):
			SettingsDialog.debug_print_verbose(" Setting '%s' not found, skipping sync" % setting_path)
			continue

		var action_data = ProjectSettings.get_setting(setting_path)
		if not action_data is Dictionary:
			SettingsDialog.debug_print_verbose(" Setting '%s' is not a Dictionary, skipping" % setting_path)
			continue

		var events: Array = action_data.get("events", [])
		var deadzone: float = action_data.get("deadzone", 0.5)

		SettingsDialog.debug_print_verbose(" Syncing action '%s' with %d events, deadzone=%.2f" % [action_name, events.size(), deadzone])

		# Check if action already exists in InputMap
		if InputMap.has_action(action_name):
			SettingsDialog.debug_print_verbose(" Action '%s' already in InputMap, adding new events" % action_name)
			# Add new events that don't exist yet
			for event in events:
				if event != null and not InputMap.action_has_event(action_name, event):
					InputMap.action_add_event(action_name, event)
					SettingsDialog.debug_print_verbose(" Added event to existing action '%s': %s" % [action_name, event.get_class()])
		else:
			SettingsDialog.debug_print_verbose(" Creating new action '%s' in InputMap" % action_name)
			# Create new action
			InputMap.add_action(action_name, deadzone)
			for event in events:
				if event != null:
					InputMap.action_add_event(action_name, event)
					SettingsDialog.debug_print_verbose(" Added event to new action '%s': %s" % [action_name, event.get_class()])

		# Verify the action was added
		if InputMap.has_action(action_name):
			var action_events = InputMap.action_get_events(action_name)
			SettingsDialog.debug_print_verbose(" Verification - InputMap now has action '%s' with %d events" % [action_name, action_events.size()])
		else:
			SettingsDialog.debug_print_verbose(" ERROR - Action '%s' was NOT added to InputMap!" % action_name)


func _are_events_equal(event1: InputEvent, event2: InputEvent) -> bool:
	## Compare two InputEvents to check if they represent the same input
	if event1 == null or event2 == null:
		return false
	if event1.get_class() != event2.get_class():
		return false

	# Compare based on event type
	if event1 is InputEventKey:
		var k1 = event1 as InputEventKey
		var k2 = event2 as InputEventKey
		return k1.keycode == k2.keycode and k1.physical_keycode == k2.physical_keycode
	elif event1 is InputEventMouseButton:
		var m1 = event1 as InputEventMouseButton
		var m2 = event2 as InputEventMouseButton
		return m1.button_index == m2.button_index
	elif event1 is InputEventJoypadButton:
		var j1 = event1 as InputEventJoypadButton
		var j2 = event2 as InputEventJoypadButton
		return j1.button_index == j2.button_index
	elif event1 is InputEventJoypadMotion:
		var jm1 = event1 as InputEventJoypadMotion
		var jm2 = event2 as InputEventJoypadMotion
		return jm1.axis == jm2.axis and sign(jm1.axis_value) == sign(jm2.axis_value)

	return false


func _parse_input_action_value(value_str: String) -> Dictionary:
	## Parse an input action value from project.godot format
	## Format: {"deadzone": 0.5, "events": [Object(InputEventKey, ...)]}

	SettingsDialog.debug_print_verbose(" Parsing input value (len=%d): %s..." % [value_str.length(), value_str.left(200)])

	# First try str_to_var - it works for simple cases
	var parsed = str_to_var(value_str)
	if parsed != null and parsed is Dictionary and parsed.has("events"):
		# Check if events were properly parsed (not null)
		var events_valid = true
		var events_array = parsed.get("events", [])
		SettingsDialog.debug_print_verbose(" str_to_var succeeded, events count: %d" % events_array.size())
		for event in events_array:
			if event == null:
				events_valid = false
				break
		if events_valid and events_array.size() > 0:
			SettingsDialog.debug_print_verbose(" Using str_to_var result")
			return parsed

	SettingsDialog.debug_print_verbose(" str_to_var failed or events invalid, trying manual parsing")

	# Manual parsing for complex Object() format
	var result: Dictionary = {"deadzone": 0.5, "events": []}

	# Extract deadzone
	var deadzone_regex = RegEx.new()
	deadzone_regex.compile('"deadzone"\\s*:\\s*([0-9.]+)')
	var deadzone_match = deadzone_regex.search(value_str)
	if deadzone_match:
		result["deadzone"] = float(deadzone_match.get_string(1))

	# Extract all Object(...) declarations manually (handles nested parens)
	var object_declarations = _extract_object_declarations(value_str)
	SettingsDialog.debug_print_verbose(" Found %d Object() declarations" % object_declarations.size())

	for obj_str in object_declarations:
		var event = _parse_object_declaration(obj_str)
		if event != null:
			result["events"].append(event)
			SettingsDialog.debug_print_verbose(" Created event of type: %s" % event.get_class())

	SettingsDialog.debug_print_verbose(" Final events count: %d" % result["events"].size())
	return result


func _extract_object_declarations(value_str: String) -> Array:
	## Extract all Object(...) declarations from a string, handling nested parentheses
	var declarations: Array = []
	var idx = 0

	while idx < value_str.length():
		var start = value_str.find("Object(", idx)
		if start == -1:
			break

		# Find the matching closing parenthesis
		var depth = 0
		var end = start + 7  # Start after "Object("
		var found_open = false

		for i in range(start, value_str.length()):
			var c = value_str[i]
			if c == '(':
				depth += 1
				found_open = true
			elif c == ')':
				depth -= 1
				if depth == 0 and found_open:
					end = i + 1
					break

		if depth == 0:
			var obj_str = value_str.substr(start, end - start)
			declarations.append(obj_str)
			idx = end
		else:
			idx = start + 1

	return declarations


func _parse_object_declaration(obj_str: String) -> InputEvent:
	## Parse a single Object(ClassName, props...) declaration
	# Format: Object(InputEventKey,"prop":value,"prop2":value2)

	# Extract class name - it's the first thing after Object(
	var content_start = obj_str.find("(") + 1
	var first_comma = obj_str.find(",", content_start)
	if first_comma == -1:
		return null

	var event_class = obj_str.substr(content_start, first_comma - content_start).strip_edges()
	var props_str = obj_str.substr(first_comma + 1, obj_str.length() - first_comma - 2)  # Remove trailing )

	return _create_input_event(event_class, props_str)


func _create_input_event(event_class: String, props_str: String) -> InputEvent:
	## Create an InputEvent from class name and properties string
	var event: InputEvent = null

	SettingsDialog.debug_print_verbose(" Creating event class: '%s'" % event_class)
	SettingsDialog.debug_print_verbose(" Props string (first 200 chars): %s" % props_str.left(200))

	match event_class:
		"InputEventKey":
			event = InputEventKey.new()
		"InputEventMouseButton":
			event = InputEventMouseButton.new()
		"InputEventJoypadButton":
			event = InputEventJoypadButton.new()
		"InputEventJoypadMotion":
			event = InputEventJoypadMotion.new()
		_:
			push_warning("AssetPlus: Unknown input event type: '%s'" % event_class)
			return null

	# Parse properties manually - split by comma, then by colon
	# Format: "key":value,"key2":value2
	var props = _parse_properties_string(props_str)
	SettingsDialog.debug_print_verbose(" Parsed %d properties from string" % props.size())

	# Debug: show all parsed properties
	for prop_name in props:
		var prop_value = props[prop_name]
		SettingsDialog.debug_print_verbose("   Property '%s' = %s (type: %s)" % [prop_name, str(prop_value), typeof(prop_value)])

	# Set properties on the event
	var props_set := 0
	for prop_name in props:
		var prop_value = props[prop_name]
		# Set the property on the event if it exists
		if prop_name in ["keycode", "physical_keycode", "unicode", "button_index", "axis", "axis_value", "device", "alt_pressed", "shift_pressed", "ctrl_pressed", "meta_pressed", "pressed", "echo", "key_label", "location", "window_id", "resource_local_to_scene", "resource_name"]:
			# Check if the event actually has this property before setting
			if event.get(prop_name) != null or prop_name in event.get_property_list().map(func(p): return p.name):
				event.set(prop_name, prop_value)
				props_set += 1
				SettingsDialog.debug_print_verbose("   -> Set '%s' = %s" % [prop_name, str(prop_value)])
			else:
				SettingsDialog.debug_print_verbose("   -> Skipped '%s' (not a valid property for %s)" % [prop_name, event_class])

	SettingsDialog.debug_print_verbose(" Set %d properties on event" % props_set)

	# Debug: show final event state
	if event is InputEventKey:
		var key_ev = event as InputEventKey
		SettingsDialog.debug_print_verbose(" Final InputEventKey: keycode=%d (%s) physical=%d unicode=%d" % [key_ev.keycode, OS.get_keycode_string(key_ev.keycode) if key_ev.keycode > 0 else "NONE", key_ev.physical_keycode, key_ev.unicode])
	elif event is InputEventMouseButton:
		var mouse_ev = event as InputEventMouseButton
		SettingsDialog.debug_print_verbose(" Final InputEventMouseButton: button_index=%d" % mouse_ev.button_index)
	elif event is InputEventJoypadButton:
		var joy_ev = event as InputEventJoypadButton
		SettingsDialog.debug_print_verbose(" Final InputEventJoypadButton: button_index=%d" % joy_ev.button_index)
	elif event is InputEventJoypadMotion:
		var motion_ev = event as InputEventJoypadMotion
		SettingsDialog.debug_print_verbose(" Final InputEventJoypadMotion: axis=%d value=%.2f" % [motion_ev.axis, motion_ev.axis_value])

	return event


func _parse_properties_string(props_str: String) -> Dictionary:
	## Parse a properties string like "key":value,"key2":value2 into a Dictionary
	var props: Dictionary = {}

	# Remove newlines and normalize whitespace
	var normalized = props_str.replace("\n", " ").replace("\r", " ").replace("\t", " ")

	# State machine to parse "key":value pairs, handling quoted strings
	var i = 0
	while i < normalized.length():
		# Skip whitespace and commas
		while i < normalized.length() and normalized[i] in [' ', ',']:
			i += 1
		if i >= normalized.length():
			break

		# Expect opening quote for key
		if normalized[i] != '"':
			i += 1
			continue

		# Find key (between quotes)
		var key_start = i + 1
		var key_end = normalized.find('"', key_start)
		if key_end == -1:
			SettingsDialog.debug_print_verbose("PROPS: Could not find closing quote for key at pos %d" % key_start)
			break
		var key = normalized.substr(key_start, key_end - key_start)

		# Find colon
		i = key_end + 1
		while i < normalized.length() and normalized[i] in [' ', ':']:
			i += 1
		if i >= normalized.length():
			SettingsDialog.debug_print_verbose("PROPS: Reached end after key '%s'" % key)
			break

		# Parse value
		var value_start = i
		var value_end = i
		var value

		if normalized[i] == '"':
			# String value - find closing quote
			value_start = i + 1
			value_end = normalized.find('"', value_start)
			if value_end == -1:
				SettingsDialog.debug_print_verbose("PROPS: Could not find closing quote for string value of '%s'" % key)
				break
			value = normalized.substr(value_start, value_end - value_start)
			i = value_end + 1
		else:
			# Non-string value - read until comma or closing paren (for nested objects)
			# Need to handle nested parentheses
			var paren_depth = 0
			while value_end < normalized.length():
				var c = normalized[value_end]
				if c == '(':
					paren_depth += 1
				elif c == ')':
					if paren_depth > 0:
						paren_depth -= 1
					else:
						# This is the closing paren of the outer Object()
						break
				elif c == ',' and paren_depth == 0:
					break
				value_end += 1
			var value_str = normalized.substr(value_start, value_end - value_start).strip_edges()
			value = _parse_property_value(value_str)
			i = value_end

		props[key] = value

	return props


func _parse_property_value(value_str: String):
	## Parse a property value string into the appropriate type
	value_str = value_str.strip_edges()

	# Boolean
	if value_str == "true":
		return true
	if value_str == "false":
		return false

	# String (quoted)
	if value_str.begins_with('"') and value_str.ends_with('"'):
		return value_str.substr(1, value_str.length() - 2)

	# Integer
	if value_str.is_valid_int():
		return int(value_str)

	# Float
	if value_str.is_valid_float():
		return float(value_str)

	return value_str


func _adapt_path_to_install_root(original_path: String, install_root: String) -> String:
	## Adapt a res:// path to the new install root
	## For preserve_structure packages: check if the path is in the package files list
	## For other packages: res://source_folder/xxx -> res://install_root/xxx
	if not original_path.begins_with("res://"):
		return original_path

	# Get the relative part after res://
	var relative_part = original_path.substr(6)  # Remove "res://"

	# Check if this is a preserve_structure package
	var preserve_structure = _godotpackage_manifest.get("preserve_structure", false)
	var manifest_files: Array = _godotpackage_manifest.get("files", [])
	var common_root: String = _godotpackage_manifest.get("common_root", "")

	if preserve_structure and manifest_files.size() > 0:
		# For preserve_structure packages, check if the path is in the package
		# The manifest "files" array contains paths relative to common_root
		# But the original .tscn files reference the FULL path (with common_root)

		# First, try to match the path after stripping common_root
		var path_without_root = relative_part
		if not common_root.is_empty() and relative_part.begins_with(common_root):
			path_without_root = relative_part.substr(common_root.length())

		if path_without_root in manifest_files:
			# This file is in the package, adapt its path
			var install_relative = ""
			if install_root.begins_with("res://"):
				install_relative = install_root.substr(6)
			else:
				install_relative = install_root
			install_relative = install_relative.trim_suffix("/")

			if install_relative.is_empty():
				return "res://" + path_without_root
			else:
				return "res://" + install_relative + "/" + path_without_root
		else:
			# This path is not in the package, leave it unchanged
			# (it might be a built-in Godot path or external dependency)
			return original_path

	# Legacy/default behavior for non-preserve_structure packages
	# Get source folder from manifest (the original folder name when exported)
	var source_folder = _godotpackage_manifest.get("source_folder", "")

	# If the path starts with source_folder, remove it
	if not source_folder.is_empty() and relative_part.begins_with(source_folder + "/"):
		relative_part = relative_part.substr(source_folder.length() + 1)

	# Get the install root relative to res://
	var install_relative = ""
	if install_root.begins_with("res://"):
		install_relative = install_root.substr(6)  # Remove "res://"
	else:
		install_relative = install_root

	# Ensure no double slashes
	if install_relative.ends_with("/"):
		install_relative = install_relative.trim_suffix("/")

	# Build the new path
	if install_relative.is_empty():
		return "res://" + relative_part
	else:
		return "res://" + install_relative + "/" + relative_part


func _adapt_autoload_path(autoload_value: String, pkg_type: String, pkg_name: String) -> String:
	## Adapt an autoload path from manifest to the actual install location
	## autoload_value format: "*res://path/script.gd" (with * for enabled) or "res://path/script.gd"

	var enabled_prefix = ""
	var path = autoload_value

	if path.begins_with("*"):
		enabled_prefix = "*"
		path = path.substr(1)

	if not path.begins_with("res://"):
		return autoload_value  # Not a res:// path, return as-is

	# Get the script path relative to res://
	var script_rel = path.substr(6)  # Remove "res://"

	SettingsDialog.debug_print("AUTOLOAD ADAPT: input='%s', pkg_type='%s', pkg_name='%s'" % [autoload_value, pkg_type, pkg_name])
	SettingsDialog.debug_print("AUTOLOAD ADAPT: script_rel='%s', _custom_install_root='%s'" % [script_rel, _custom_install_root])

	# Strip the original package folder from script_rel
	# For .godotpackage files, strip pack_root prefix if present
	var pack_root = _godotpackage_manifest.get("pack_root", "")
	if not pack_root.is_empty():
		# pack_root is like "files/" or "Packages/pkg_name/"
		# Remove "res://" prefix if pack_root has it
		if pack_root.begins_with("res://"):
			pack_root = pack_root.substr(6)
		# Remove trailing slash for comparison
		var pack_root_clean = pack_root.rstrip("/")
		if script_rel.begins_with(pack_root_clean + "/"):
			script_rel = script_rel.substr(pack_root_clean.length() + 1)
			SettingsDialog.debug_print("AUTOLOAD ADAPT: stripped pack_root, new script_rel='%s'" % script_rel)

	# Also try to strip common folder prefixes like "Packages/pkg_name/", "addons/pkg_name/", etc.
	var prefixes_to_try = [
		"Packages/%s/" % pkg_name,
		"addons/%s/" % pkg_name,
		"templates/%s/" % pkg_name,
		pkg_name + "/"
	]
	for prefix in prefixes_to_try:
		if script_rel.begins_with(prefix):
			script_rel = script_rel.substr(prefix.length())
			SettingsDialog.debug_print("AUTOLOAD ADAPT: stripped prefix '%s', new script_rel='%s'" % [prefix, script_rel])
			break

	# Build the new path based on package type
	var new_path: String
	match pkg_type:
		"plugin", "addon":
			# Plugins go to res://addons/pkg_name/
			new_path = "res://addons/%s/%s" % [pkg_name, script_rel]
		"template", "project", "demo":
			# Templates go to custom location or default
			var install_folder = _custom_install_root if not _custom_install_root.is_empty() else "res://templates/%s" % pkg_name.to_snake_case()
			new_path = install_folder.rstrip("/") + "/" + script_rel
			if not new_path.begins_with("res://"):
				new_path = "res://" + new_path
		_:
			# Assets go to custom location or default
			var install_folder = _custom_install_root if not _custom_install_root.is_empty() else "res://Packages/%s" % pkg_name
			new_path = install_folder.rstrip("/") + "/" + script_rel
			if not new_path.begins_with("res://"):
				new_path = "res://" + new_path

	SettingsDialog.debug_print("AUTOLOAD ADAPT: result='%s'" % (enabled_prefix + new_path))
	return enabled_prefix + new_path


func _adapt_script_paths_in_files(install_root: String) -> void:
	## Scan all installed files and adapt res:// paths
	## Handles: .gd (load/preload), .tscn/.tres (ExtResource, path=)
	## Runs when installing to a custom path (not res:// root)

	# Skip for plugins - they should always install to addons/ and paths are correct
	if _package_type == PackageType.PLUGIN:
		return

	# Also skip if this is a godotpackage with type "plugin" or "addon"
	var pkg_type = _godotpackage_manifest.get("type", "").to_lower()
	if pkg_type in ["plugin", "addon"]:
		return

	SettingsDialog.debug_print(" Adapting res:// paths in installed files...")

	# Initialize cached regex if needed
	_init_regex_patterns()

	# Create additional regex patterns (cached as static would be overkill for these)
	var gd_regex = RegEx.new()
	gd_regex.compile('(load|preload)\\s*\\(\\s*["\']res://([^"\']+)["\']\\s*\\)')
	var scene_regex = RegEx.new()
	scene_regex.compile('(path\\s*=\\s*"|ExtResource\\s*\\(\\s*")res://([^"]+)"')
	var cfg_regex = RegEx.new()
	cfg_regex.compile('=\\s*"res://([^"]+)"')

	var files_updated := 0
	var paths_replaced := 0

	for file_info in _zip_files:
		if not file_info["selected"]:
			continue

		var rel_path: String = file_info["rel_path"]

		# Skip files in addons/ - they should have correct internal paths
		if rel_path.begins_with("addons/"):
			continue

		var ext = rel_path.get_extension().to_lower()

		# Only process text-based files that may contain res:// paths
		if ext not in ["gd", "tscn", "tres", "cfg"]:
			continue

		# Get the installed path
		var installed_path = install_root.path_join(rel_path) if install_root != "res://" else "res://" + rel_path

		# Read the file
		var file = FileAccess.open(installed_path, FileAccess.READ)
		if file == null:
			continue

		var content = file.get_as_text()
		file.close()

		var replaced_count = 0

		# Use regex to find and replace - building replacement map first to avoid issues
		var replacements: Array[Dictionary] = []  # [{from: String, to: String}]

		# Different patterns for different file types
		match ext:
			"gd":
				var matches = gd_regex.search_all(content)
				for m in matches:
					var full_match = m.get_string(0)
					var func_name = m.get_string(1)
					var original_path = "res://" + m.get_string(2)
					var new_path = _adapt_path_to_install_root(original_path, install_root)

					if new_path != original_path:
						var new_call = '%s("%s")' % [func_name, new_path]
						replacements.append({"from": full_match, "to": new_call})

			"tscn", "tres":
				var matches = scene_regex.search_all(content)
				for m in matches:
					var full_match = m.get_string(0)
					var prefix = m.get_string(1)
					var original_path = "res://" + m.get_string(2)
					var new_path = _adapt_path_to_install_root(original_path, install_root)

					if new_path != original_path:
						var new_match = '%s%s"' % [prefix, new_path]
						replacements.append({"from": full_match, "to": new_match})

				# Also remove UIDs from ext_resource lines that had their paths changed
				# This forces Godot to use the new path instead of cached UID references
				# Pattern: uid="uid://xxxxx" (we'll remove these from modified resources)
				var preserve_structure = _godotpackage_manifest.get("preserve_structure", false)
				if preserve_structure:
					var uid_regex = RegEx.new()
					uid_regex.compile(' uid="uid://[^"]+"')
					var uid_matches = uid_regex.search_all(content)
					for um in uid_matches:
						var uid_str = um.get_string(0)
						replacements.append({"from": uid_str, "to": ""})

			"cfg":
				var matches = cfg_regex.search_all(content)
				for m in matches:
					var full_match = m.get_string(0)
					var original_path = "res://" + m.get_string(1)
					var new_path = _adapt_path_to_install_root(original_path, install_root)

					if new_path != original_path:
						var new_match = '="%s"' % new_path
						replacements.append({"from": full_match, "to": new_match})

		# Apply replacements (longer strings first to avoid partial replacements)
		if replacements.size() > 0:
			replacements.sort_custom(func(a, b): return a["from"].length() > b["from"].length())
			var new_content = content
			for r in replacements:
				# Only replace exact matches to avoid substring issues
				var idx = new_content.find(r["from"])
				if idx != -1:
					new_content = new_content.substr(0, idx) + r["to"] + new_content.substr(idx + r["from"].length())
					replaced_count += 1

			# Write back if changes were made
			if replaced_count > 0:
				var write_file = FileAccess.open(installed_path, FileAccess.WRITE)
				if write_file:
					write_file.store_string(new_content)
					write_file.close()
					files_updated += 1
					paths_replaced += replaced_count

	if files_updated > 0:
		SettingsDialog.debug_print(" Updated %d files with %d path replacements" % [files_updated, paths_replaced])


func _adapt_gdextension_paths(install_root: String, installed_paths: Array) -> void:
	## Adapt paths in .gdextension files when installing to a custom location
	## GDExtension files contain hardcoded res:// paths that need to match the install location

	# Find the addon folder name from installed paths
	var addon_folder := ""
	for path in installed_paths:
		if path.begins_with("res://"):
			# Extract the first folder component after res://
			var rel = path.substr(6)  # Remove "res://"
			var slash_pos = rel.find("/")
			if slash_pos > 0:
				addon_folder = rel.substr(0, slash_pos)
				break

	if addon_folder.is_empty():
		return

	# The actual install path
	var actual_install_path = install_root if install_root != "res://" else "res://"
	if actual_install_path == "res://":
		actual_install_path = "res://" + addon_folder

	# Search for .gdextension files in the installed folders
	for folder_path in installed_paths:
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder_path)):
			continue

		var gdext_files = _find_gdextension_files(folder_path)

		for gdext_path in gdext_files:
			_update_gdextension_file(gdext_path, actual_install_path)


func _find_gdextension_files(folder_path: String) -> Array:
	## Find all .gdextension files in a folder recursively
	var files: Array = []
	var dir = DirAccess.open(folder_path)
	if dir == null:
		return files

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while not file_name.is_empty():
		var full_path = folder_path.path_join(file_name)
		if dir.current_is_dir():
			if not file_name.begins_with("."):
				files.append_array(_find_gdextension_files(full_path))
		else:
			if file_name.ends_with(".gdextension"):
				files.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()

	return files


func _update_gdextension_file(gdext_path: String, actual_install_path: String) -> void:
	## Update paths in a .gdextension file to match the actual install location

	var file = FileAccess.open(gdext_path, FileAccess.READ)
	if file == null:
		SettingsDialog.debug_print(" Cannot read .gdextension file: %s" % gdext_path)
		return

	var content = file.get_as_text()
	file.close()

	# Check if paths need updating
	# GDExtension files typically have paths like res://addons/addonname/...
	# We need to replace the base path with the actual install path

	# Find what path pattern is used in the file (look for res://addons/ or res://something/)
	var regex = RegEx.new()
	regex.compile('res://([^/"]+)/')
	var match_result = regex.search(content)

	if match_result == null:
		return  # No res:// paths found

	var original_base_folder = match_result.get_string(1)  # e.g., "addons"
	var original_pattern = "res://" + original_base_folder + "/"

	# Determine what the new base path should be
	# actual_install_path is like "res://assets/terrabrush" or "res://addons/terrabrush"
	var new_base_path = actual_install_path
	if not new_base_path.ends_with("/"):
		# Get the parent folder path (e.g., res://assets/terrabrush -> res://assets/)
		var last_slash = new_base_path.rfind("/")
		if last_slash > 6:  # After "res://"
			new_base_path = new_base_path.substr(0, last_slash + 1)
		else:
			new_base_path = "res://"

	# Only update if the paths are different
	if original_pattern == new_base_path:
		return

	# Actually we need to be smarter - replace the full addon path pattern
	# e.g., res://addons/terrabrush/ -> res://assets/terrabrush/

	# Find the full addon path in the file (res://addons/addonname/)
	var addon_path_regex = RegEx.new()
	addon_path_regex.compile('res://[^"\\s]+/')
	var all_paths = addon_path_regex.search_all(content)

	if all_paths.is_empty():
		return

	# Find the most common base path (the addon's root)
	var path_counts: Dictionary = {}
	for m in all_paths:
		var path = m.get_string(0)
		# Extract up to the addon folder (e.g., res://addons/terrabrush/)
		var parts = path.split("/")
		if parts.size() >= 4:  # res: / / addons / addonname / ...
			var base = parts[0] + "//" + parts[2] + "/" + parts[3] + "/"
			path_counts[base] = path_counts.get(base, 0) + 1

	if path_counts.is_empty():
		return

	# Find the most common path (that's likely the addon root)
	var original_addon_path := ""
	var max_count := 0
	for path in path_counts:
		if path_counts[path] > max_count:
			max_count = path_counts[path]
			original_addon_path = path

	if original_addon_path.is_empty():
		return

	# Build the new addon path
	var new_addon_path = actual_install_path
	if not new_addon_path.ends_with("/"):
		new_addon_path += "/"

	# Only proceed if paths are actually different
	if original_addon_path == new_addon_path:
		return

	SettingsDialog.debug_print(" Adapting .gdextension: %s -> %s" % [original_addon_path, new_addon_path])

	# Replace all occurrences
	var new_content = content.replace(original_addon_path, new_addon_path)

	if new_content != content:
		var write_file = FileAccess.open(gdext_path, FileAccess.WRITE)
		if write_file:
			write_file.store_string(new_content)
			write_file.close()
			SettingsDialog.debug_print(" Updated .gdextension file: %s" % gdext_path)


func _collect_uids_for_paths(paths: Array) -> Array:
	## Collect ALL files in installed paths for tracking
	## Returns array of {path: String, uid: String} - uid may be empty for files without UIDs
	var tracked: Array = []

	for folder_path in paths:
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder_path)):
			continue

		# Recursively find ALL files to track
		var files_to_track = _find_all_files(folder_path)

		for file_path in files_to_track:
			var uid = _get_file_uid(file_path)
			# Track ALL files, even without UID (for .txt, .md, .cfg, etc.)
			tracked.append({"path": file_path, "uid": uid})

	var with_uid = tracked.filter(func(e): return not e.get("uid", "").is_empty()).size()
	SettingsDialog.debug_print(" Tracked %d files (%d with UIDs)" % [tracked.size(), with_uid])
	return tracked


func _find_all_files(folder_path: String) -> Array:
	## Find ALL files in a folder recursively (for tracking)
	var files: Array = []
	var dir = DirAccess.open(folder_path)
	if dir == null:
		return files

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while not file_name.is_empty():
		var full_path = folder_path.path_join(file_name)
		if dir.current_is_dir():
			if not file_name.begins_with("."):
				files.append_array(_find_all_files(full_path))
		else:
			# Skip .import and .uid files (they're auto-generated)
			if not file_name.ends_with(".import") and not file_name.ends_with(".uid"):
				files.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()

	return files


func _get_file_uid(file_path: String) -> String:
	## Get the UID string for a file if it exists
	# Method 1: Try ResourceLoader (works for most resources)
	# TEMPORARILY DISABLED - ResourceLoader.get_resource_uid() loads resources into cache
	# which may cause crashes when deleting in same session
	#if ResourceLoader.exists(file_path):
	#	var uid = ResourceLoader.get_resource_uid(file_path)
	#	if uid != ResourceUID.INVALID_ID:
	#		return ResourceUID.id_to_text(uid)

	# Method 2: Check for .uid file (scripts, scenes, tres)
	var uid_file_path = file_path + ".uid"
	if FileAccess.file_exists(uid_file_path):
		var uid_file = FileAccess.open(uid_file_path, FileAccess.READ)
		if uid_file:
			var uid_content = uid_file.get_line().strip_edges()
			uid_file.close()
			if uid_content.begins_with("uid://"):
				return uid_content

	# Method 3: Check .import file for imported resources (textures, models, etc.)
	var import_file_path = file_path + ".import"
	if FileAccess.file_exists(import_file_path):
		var import_file = FileAccess.open(import_file_path, FileAccess.READ)
		if import_file:
			var content = import_file.get_as_text()
			import_file.close()
			# Look for uid="uid://xxxxx" in the import file
			var uid_regex = RegEx.new()
			uid_regex.compile('uid="(uid://[^"]+)"')
			var match = uid_regex.search(content)
			if match:
				return match.get_string(1)

	return ""


func _set_error(message: String) -> void:
	_state = State.ERROR
	_update_folder_buttons_state()
	_status_label.text = "Error: %s" % message
	_progress_bar.value = 0
	get_ok_button().disabled = true
	# Cleanup resources on error
	_cleanup_resources()


func _trigger_filesystem_scan() -> void:
	## Called deferred after installation completes to scan filesystem
	## Mimics official Godot: EditorFileSystem::get_singleton()->scan_changes()
	if Engine.is_editor_hint():
		var fs = EditorInterface.get_resource_filesystem()
		# Try scan_sources() if it exists (GDScript binding of scan_changes)
		# Otherwise fall back to scan()
		if fs.has_method("scan_sources"):
			fs.scan_sources()
		else:
			fs.scan()


func _exit_tree() -> void:
	_cleanup_resources()


func _create_version_cfg_for_installed_paths(installed_paths: Array) -> void:
	## Create version.cfg for assets without plugin.cfg
	## This allows tracking updates for templates and non-plugin assets
	var version = _asset_info.get("version", "")
	var source = _asset_info.get("source", "")

	# For GODOTPACKAGE, get version from manifest if not in asset_info
	if version.is_empty() and _package_type == PackageType.GODOTPACKAGE:
		version = _godotpackage_manifest.get("version", "")

	# Use "unknown" if version is still empty
	if version.is_empty():
		version = "unknown"

	# For templates/assets with custom install root, create version.cfg at the actual install location
	# For ASSET type, include the asset folder name to get the real path
	if not _custom_install_root.is_empty() and _package_type in [PackageType.PROJECT, PackageType.ASSET]:
		var root_path = _custom_install_root.trim_suffix("/")
		# For assets, the actual install path includes the asset folder name
		if _package_type == PackageType.ASSET and not _asset_folder_name.is_empty():
			root_path = root_path.path_join(_asset_folder_name)
		var plugin_cfg_path = root_path + "/plugin.cfg"
		if not FileAccess.file_exists(plugin_cfg_path):
			var version_cfg_path = root_path + "/version.cfg"
			var cfg = ConfigFile.new()
			cfg.set_value("assetplus", "version", version)
			cfg.set_value("assetplus", "installed_at", Time.get_unix_time_from_system())
			if not source.is_empty():
				cfg.set_value("assetplus", "source", source)

			var err = cfg.save(version_cfg_path)
			if err == OK:
				SettingsDialog.debug_print("Created version.cfg at %s (version: %s)" % [root_path, version])
			else:
				SettingsDialog.debug_print("Failed to create version.cfg at %s: %d" % [root_path, err])
		return

	# For GODOTPACKAGE assets/projects, installed_paths should now contain a single root path
	# Create version.cfg there
	if _package_type == PackageType.GODOTPACKAGE:
		var gdpkg_type = _godotpackage_manifest.get("type", "").to_lower()
		if gdpkg_type in ["asset", "project"] and installed_paths.size() == 1:
			var root_path = installed_paths[0].trim_suffix("/") if installed_paths[0] is String else ""
			if not root_path.is_empty():
				var plugin_cfg_path = root_path + "/plugin.cfg"
				if not FileAccess.file_exists(plugin_cfg_path):
					var version_cfg_path = root_path + "/version.cfg"
					var cfg = ConfigFile.new()
					cfg.set_value("assetplus", "version", version)
					cfg.set_value("assetplus", "installed_at", Time.get_unix_time_from_system())
					if not source.is_empty():
						cfg.set_value("assetplus", "source", source)

					var err = cfg.save(version_cfg_path)
					if err == OK:
						SettingsDialog.debug_print("Created version.cfg for GDPKG at %s (version: %s)" % [root_path, version])
					else:
						SettingsDialog.debug_print("Failed to create version.cfg for GDPKG at %s: %d" % [root_path, err])
			return

	# Standard behavior for plugins and assets without custom root
	for addon_path in installed_paths:
		if addon_path is not String or addon_path.is_empty():
			continue

		# Skip if plugin.cfg exists (it already has version)
		var plugin_cfg_path = addon_path.trim_suffix("/") + "/plugin.cfg"
		if FileAccess.file_exists(plugin_cfg_path):
			continue

		# Create version.cfg
		var version_cfg_path = addon_path.trim_suffix("/") + "/version.cfg"
		var cfg = ConfigFile.new()
		cfg.set_value("assetplus", "version", version)
		cfg.set_value("assetplus", "installed_at", Time.get_unix_time_from_system())
		if not source.is_empty():
			cfg.set_value("assetplus", "source", source)

		var err = cfg.save(version_cfg_path)
		if err == OK:
			SettingsDialog.debug_print("Created version.cfg for %s (version: %s)" % [addon_path, version])
		else:
			SettingsDialog.debug_print("Failed to create version.cfg for %s: %d" % [addon_path, err])


func _copy_embedded_icon_to_installed(installed_paths: Array) -> void:
	## Copy icon.png from the .godotpackage to the installed folder (if present)
	## This allows the icon to be displayed for installed Global Folder assets
	if _package_type != PackageType.GODOTPACKAGE:
		return

	if _zip_path.is_empty():
		return

	# Check if icon.png exists in the package
	var reader = ZIPReader.new()
	var err = reader.open(_zip_path)
	if err != OK:
		return

	if not reader.file_exists("icon.png"):
		reader.close()
		return

	var icon_data = reader.read_file("icon.png")
	reader.close()

	if icon_data.size() == 0:
		return

	# Copy to the first installed path (the main folder)
	if installed_paths.size() > 0 and installed_paths[0] is String:
		var target_path = installed_paths[0].trim_suffix("/") + "/icon.png"
		# Always copy the icon from the package (overwrite if exists)
		var file = FileAccess.open(target_path, FileAccess.WRITE)
		if file:
			file.store_buffer(icon_data)
			file.close()
			SettingsDialog.debug_print("Copied embedded icon to %s" % target_path)


func _persist_pending_installation(installed_paths: Array, tracked_uids: Array) -> void:
	## Persist installation info to a file so main_panel can recover it after script reload
	## This is needed because Godot's script reload can cancel signal handlers
	var pending_path = "user://assetplus_pending_install.cfg"
	var cfg = ConfigFile.new()

	# Generate asset_id if missing
	var asset_id = _asset_info.get("asset_id", "")
	if asset_id.is_empty():
		asset_id = "installed_%d" % Time.get_unix_time_from_system()

	cfg.set_value("pending", "asset_id", asset_id)
	cfg.set_value("pending", "paths", installed_paths)
	cfg.set_value("pending", "info", _asset_info)
	cfg.set_value("pending", "uids", tracked_uids)
	cfg.set_value("pending", "timestamp", Time.get_unix_time_from_system())

	var err = cfg.save(pending_path)
	if err == OK:
		SettingsDialog.debug_print("Persisted pending installation for %s" % _asset_info.get("title", asset_id))
	else:
		SettingsDialog.debug_print("Failed to persist pending installation: %d" % err)