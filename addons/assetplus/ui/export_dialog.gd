@tool
extends AcceptDialog

## Export dialog - allows exporting local folders or project content as .zip or .godotpackage

const SettingsDialog = preload("res://addons/assetplus/ui/settings_dialog.gd")
const DependencyDetector = preload("res://addons/assetplus/dependency_detector.gd")

signal export_completed(success: bool, output_path: String)

enum ExportFormat { ZIP, GODOTPACKAGE }
enum ExportMode { FROM_FOLDER, FROM_PROJECT }

var _source_folder: String = ""
var _source_folders: Array[String] = []  # Multiple folders for multi-folder export
var _files: Array[Dictionary] = []  # [{path, rel_path, selected, size, category}]
var _export_mode: ExportMode = ExportMode.FROM_FOLDER

# Project export categories
var _project_categories: Dictionary = {}  # category_name -> Array[Dictionary]

# UI elements
var _tree: Tree
var _name_edit: LineEdit
var _version_edit: LineEdit
var _author_edit: LineEdit
var _format_option: OptionButton
var _output_label: Label
var _progress_bar: ProgressBar
var _status_label: Label
var _select_all_btn: Button
var _select_none_btn: Button
var _include_deps_check: CheckBox
var _deps_status_label: Label

# Dependencies tracking
var _include_dependencies: bool = false
var _dependency_files: Array[Dictionary] = []  # Files added via dependency detection
var _base_files: Array[Dictionary] = []  # Original files without dependencies

# Thumbnail selection
var _thumb_preview: TextureRect
var _thumb_choose_btn: Button
var _thumb_state: Dictionary = {"selected_angle": 0, "selected_source": 0}
var _thumb_sources: Array[Dictionary] = []  # [{path, type, name}]
var _thumb_options: Array[Dictionary] = [
	{"name": "Isometric", "dir": Vector3(1, 0.6, 1).normalized(), "zoom": 0.6},
	{"name": "Front", "dir": Vector3(0, 0, 1), "zoom": 0.45},
	{"name": "Side", "dir": Vector3(1, 0, 0), "zoom": 0.45},
	{"name": "Top", "dir": Vector3(0, 1, 0.01).normalized(), "zoom": 0.6},
	{"name": "3/4 View", "dir": Vector3(1, 0.3, 0.5).normalized(), "zoom": 0.5},
]
var _current_thumb_data: PackedByteArray = PackedByteArray()

# Deferred setup data
var _pending_folder_path: String = ""
var _pending_folder_paths: Array[String] = []  # For deferred multi-folder setup
var _pending_project_mode: bool = false

# Global folder mode - auto-export to this path without asking
var _target_global_folder: String = ""

# Original asset info for global folder export (preserves metadata)
var _original_asset_info: Dictionary = {}


func _init() -> void:
	title = "Export Package"
	size = Vector2i(700, 650)
	ok_button_text = "Export"


func _ready() -> void:
	_build_ui()
	confirmed.connect(_on_confirmed)

	# Process any pending setup
	if _pending_project_mode:
		_pending_project_mode = false
		_setup_from_project_internal()
	elif not _pending_folder_paths.is_empty():
		var paths = _pending_folder_paths.duplicate()
		_pending_folder_paths.clear()
		_setup_from_multiple_folders_internal(paths)
	elif not _pending_folder_path.is_empty():
		var path = _pending_folder_path
		_pending_folder_path = ""
		_setup_from_folder_internal(path)

	# Apply global folder mode settings if set
	if not _target_global_folder.is_empty():
		_format_option.select(ExportFormat.GODOTPACKAGE)
		_format_option.disabled = true
		title = "Add to Global Folder"


func _build_ui() -> void:
	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 10)
	add_child(main_vbox)

	# Top section: Thumbnail on left, metadata on right
	var top_hbox = HBoxContainer.new()
	top_hbox.add_theme_constant_override("separation", 15)
	main_vbox.add_child(top_hbox)

	# Thumbnail preview (left side)
	var thumb_vbox = VBoxContainer.new()
	thumb_vbox.add_theme_constant_override("separation", 5)
	top_hbox.add_child(thumb_vbox)

	_thumb_preview = TextureRect.new()
	_thumb_preview.custom_minimum_size = Vector2(100, 100)
	_thumb_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_thumb_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# Default placeholder
	var placeholder = PlaceholderTexture2D.new()
	placeholder.size = Vector2(100, 100)
	_thumb_preview.texture = placeholder
	thumb_vbox.add_child(_thumb_preview)

	_thumb_choose_btn = Button.new()
	_thumb_choose_btn.text = "Choose..."
	_thumb_choose_btn.pressed.connect(_on_choose_thumbnail)
	thumb_vbox.add_child(_thumb_choose_btn)

	# Metadata section (right side)
	var meta_grid = GridContainer.new()
	meta_grid.columns = 2
	meta_grid.add_theme_constant_override("h_separation", 10)
	meta_grid.add_theme_constant_override("v_separation", 6)
	meta_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_hbox.add_child(meta_grid)

	# Package name
	var name_label = Label.new()
	name_label.text = "Package Name:"
	meta_grid.add_child(name_label)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "MyPackage"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meta_grid.add_child(_name_edit)

	# Version
	var version_label = Label.new()
	version_label.text = "Version:"
	meta_grid.add_child(version_label)

	_version_edit = LineEdit.new()
	_version_edit.text = "1.0.0"
	_version_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meta_grid.add_child(_version_edit)

	# Author
	var author_label = Label.new()
	author_label.text = "Author:"
	meta_grid.add_child(author_label)

	_author_edit = LineEdit.new()
	_author_edit.placeholder_text = "Your name"
	_author_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meta_grid.add_child(_author_edit)

	# Export format
	var format_label = Label.new()
	format_label.text = "Format:"
	meta_grid.add_child(format_label)

	_format_option = OptionButton.new()
	_format_option.add_item(".zip (Standard)", ExportFormat.ZIP)
	_format_option.add_item(".godotpackage (With manifest)", ExportFormat.GODOTPACKAGE)
	_format_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meta_grid.add_child(_format_option)

	main_vbox.add_child(HSeparator.new())

	# Selection buttons
	var btn_bar = HBoxContainer.new()
	btn_bar.add_theme_constant_override("separation", 8)
	main_vbox.add_child(btn_bar)

	var select_label = Label.new()
	select_label.text = "Content to export:"
	btn_bar.add_child(select_label)

	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_bar.add_child(spacer)

	_include_deps_check = CheckBox.new()
	_include_deps_check.text = "Include dependencies"
	_include_deps_check.toggled.connect(_on_include_deps_toggled)
	btn_bar.add_child(_include_deps_check)

	_select_all_btn = Button.new()
	_select_all_btn.text = "Select All"
	_select_all_btn.pressed.connect(_on_select_all)
	btn_bar.add_child(_select_all_btn)

	_select_none_btn = Button.new()
	_select_none_btn.text = "Select None"
	_select_none_btn.pressed.connect(_on_select_none)
	btn_bar.add_child(_select_none_btn)

	# File tree
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = true
	_tree.columns = 2
	_tree.set_column_title(0, "Item")
	_tree.set_column_title(1, "Size")
	_tree.set_column_expand(0, true)
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, 80)
	_tree.item_edited.connect(_on_item_edited)
	main_vbox.add_child(_tree)

	# Output label with dependency status
	var output_hbox = HBoxContainer.new()
	output_hbox.add_theme_constant_override("separation", 8)
	main_vbox.add_child(output_hbox)

	_output_label = Label.new()
	_output_label.text = "0 files selected"
	output_hbox.add_child(_output_label)

	_deps_status_label = Label.new()
	_deps_status_label.text = "(0 dependencies not included)"
	_deps_status_label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
	output_hbox.add_child(_deps_status_label)

	# Progress bar
	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size.y = 20
	_progress_bar.value = 0
	_progress_bar.visible = false
	main_vbox.add_child(_progress_bar)

	# Status label
	_status_label = Label.new()
	_status_label.text = ""
	main_vbox.add_child(_status_label)


## Setup from a specific folder (existing functionality)
func setup(folder_path: String) -> void:
	if _name_edit == null:
		# UI not ready yet, defer setup
		_pending_folder_path = folder_path
		return
	_setup_from_folder_internal(folder_path)


func _setup_from_folder_internal(folder_path: String) -> void:
	_export_mode = ExportMode.FROM_FOLDER
	_source_folder = folder_path
	_files.clear()
	_base_files.clear()
	_dependency_files.clear()
	_include_dependencies = false
	if _include_deps_check:
		_include_deps_check.button_pressed = false

	# Set default name from folder
	var folder_name = folder_path.get_file()
	if folder_name.is_empty():
		folder_name = folder_path.get_base_dir().get_file()
	_name_edit.text = folder_name

	# Set default author from OS username
	var default_author = OS.get_environment("USERNAME")  # Windows
	if default_author.is_empty():
		default_author = OS.get_environment("USER")  # Linux/macOS
	if not default_author.is_empty() and _author_edit.text.is_empty():
		_author_edit.text = default_author

	# Scan folder for files
	_scan_folder(folder_path)

	# Store base files (before any dependency detection)
	_base_files = _files.duplicate(true)

	# Detect autoloads that reference scripts in this folder
	_detect_folder_autoloads(folder_path)

	_populate_tree_folder_mode()

	# Setup thumbnail selector after scanning files
	_setup_thumbnail_selector()

	# Check if there are potential dependencies and enable checkbox by default if so
	var potential_deps = _count_potential_dependencies()
	if potential_deps > 0 and _include_deps_check:
		_include_deps_check.button_pressed = true
		_include_dependencies = true
		_add_dependencies()
		_populate_tree_folder_mode()

	# Update file count label
	_update_file_count_label()

	title = "Export: %s" % folder_name


## Setup from multiple folders (for multi-folder export)
func setup_multiple_folders(folder_paths: Array[String]) -> void:
	if _name_edit == null:
		# UI not ready yet, defer setup
		_pending_folder_paths = folder_paths.duplicate()
		return
	_setup_from_multiple_folders_internal(folder_paths)


func _setup_from_multiple_folders_internal(folder_paths: Array[String]) -> void:
	_export_mode = ExportMode.FROM_FOLDER
	_source_folders = folder_paths.duplicate()
	_files.clear()
	_base_files.clear()
	_dependency_files.clear()
	_include_dependencies = false
	if _include_deps_check:
		_include_deps_check.button_pressed = false

	# Find common parent of all folders
	var common_parent = _find_common_parent_folder(folder_paths)
	_source_folder = common_parent

	# Set default name - if all folders have the same parent, use that parent's name
	# Otherwise use the first folder's name
	var folder_name = ""
	if folder_paths.size() == 1:
		folder_name = folder_paths[0].get_file()
	else:
		# Use common parent name or "MultiExport"
		folder_name = common_parent.get_file()
		if folder_name.is_empty():
			folder_name = "MultiExport"
	if folder_name.is_empty():
		folder_name = folder_paths[0].get_base_dir().get_file()
	_name_edit.text = folder_name

	# Set default author from OS username
	var default_author = OS.get_environment("USERNAME")  # Windows
	if default_author.is_empty():
		default_author = OS.get_environment("USER")  # Linux/macOS
	if not default_author.is_empty() and _author_edit.text.is_empty():
		_author_edit.text = default_author

	# Scan all folders - preserving folder structure relative to common parent
	for folder_path in folder_paths:
		_scan_folder_with_base(folder_path, common_parent)

	# Store base files (before any dependency detection)
	_base_files = _files.duplicate(true)

	# Detect autoloads that reference scripts in any of these folders
	for folder_path in folder_paths:
		_detect_folder_autoloads(folder_path)

	_populate_tree_folder_mode()

	# Setup thumbnail selector after scanning files
	_setup_thumbnail_selector()

	# Check if there are potential dependencies and enable checkbox by default if so
	var potential_deps = _count_potential_dependencies()
	if potential_deps > 0 and _include_deps_check:
		_include_deps_check.button_pressed = true
		_include_dependencies = true
		_add_dependencies()
		_populate_tree_folder_mode()

	# Update file count label
	_update_file_count_label()

	if folder_paths.size() == 1:
		title = "Export: %s" % folder_name
	else:
		title = "Export: %d folders" % folder_paths.size()


func _find_common_parent_folder(folder_paths: Array[String]) -> String:
	## Find the common parent directory of multiple folder paths
	if folder_paths.is_empty():
		return "res://"
	if folder_paths.size() == 1:
		return folder_paths[0]

	# Convert all paths to arrays of components
	var all_parts: Array[PackedStringArray] = []
	for path in folder_paths:
		var rel = path
		if path.begins_with("res://"):
			rel = path.substr(6)
		all_parts.append(rel.split("/"))

	# Find common prefix
	var common: PackedStringArray = []
	var min_len = all_parts[0].size()
	for parts in all_parts:
		if parts.size() < min_len:
			min_len = parts.size()

	for i in range(min_len):
		var part = all_parts[0][i]
		var all_match = true
		for parts in all_parts:
			if parts[i] != part:
				all_match = false
				break
		if all_match:
			common.append(part)
		else:
			break

	if common.is_empty():
		return "res://"

	return "res://" + "/".join(common)


func _scan_folder_with_base(path: String, base_folder: String) -> void:
	## Scan a folder, calculating rel_path relative to base_folder
	var dir = DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path = path.path_join(file_name)

			if dir.current_is_dir():
				_scan_folder_with_base(full_path, base_folder)
			else:
				# Calculate rel_path relative to base_folder
				var rel_path = full_path
				if full_path.begins_with(base_folder):
					rel_path = full_path.replace(base_folder, "").trim_prefix("/")
				elif full_path.begins_with("res://"):
					# Fallback: use path without res://
					rel_path = full_path.substr(6)

				var file_size = 0
				var f = FileAccess.open(full_path, FileAccess.READ)
				if f:
					file_size = f.get_length()
					f.close()

				_files.append({
					"path": full_path,
					"rel_path": rel_path,
					"selected": true,
					"size": file_size
				})

		file_name = dir.get_next()
	dir.list_dir_end()


## Setup from current project (new functionality)
func setup_from_project() -> void:
	if _name_edit == null:
		# UI not ready yet, defer setup
		_pending_project_mode = true
		return
	_setup_from_project_internal()


func _setup_from_project_internal() -> void:
	_export_mode = ExportMode.FROM_PROJECT
	_source_folder = "res://"
	_files.clear()
	_project_categories.clear()

	# Get project name
	var project_name = ProjectSettings.get_setting("application/config/name", "MyProject")
	_name_edit.text = project_name

	# Set default author from OS username
	var default_author = OS.get_environment("USERNAME")  # Windows
	if default_author.is_empty():
		default_author = OS.get_environment("USER")  # Linux/macOS
	if not default_author.is_empty() and _author_edit.text.is_empty():
		_author_edit.text = default_author

	# Scan project and organize by categories
	_scan_project()
	_populate_tree_project_mode()

	# Setup thumbnail selector after scanning files
	_setup_thumbnail_selector()

	title = "Export Project"


## Setup for exporting directly to global folder (auto-export, no save dialog)
## asset_info contains original asset metadata to preserve in the manifest
func setup_for_global_folder(folder_path: String, global_folder_path: String, asset_info: Dictionary = {}) -> void:
	_target_global_folder = global_folder_path
	_original_asset_info = asset_info
	if _name_edit == null:
		# UI not ready yet, defer setup
		_pending_folder_path = folder_path
		return
	_setup_from_folder_internal(folder_path)
	# Lock format to GODOTPACKAGE
	_format_option.select(ExportFormat.GODOTPACKAGE)
	_format_option.disabled = true
	title = "Add to Global Folder"
	# Pre-fill author from original asset info
	if not asset_info.get("author", "").is_empty():
		_author_edit.text = asset_info.get("author", "")


## Setup for exporting project directly to global folder
func setup_from_project_for_global_folder(global_folder_path: String) -> void:
	_target_global_folder = global_folder_path
	if _name_edit == null:
		# UI not ready yet, defer setup
		_pending_project_mode = true
		return
	_setup_from_project_internal()
	# Lock format to GODOTPACKAGE
	_format_option.select(ExportFormat.GODOTPACKAGE)
	_format_option.disabled = true
	title = "Add to Global Folder"


func _scan_folder(path: String) -> void:
	var dir = DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path = path.path_join(file_name)

			if dir.current_is_dir():
				_scan_folder(full_path)
			else:
				# Include all files (including .import and .uid for proper remapping)
				var rel_path = full_path.replace(_source_folder, "").trim_prefix("/")
				var file_size = 0
				var f = FileAccess.open(full_path, FileAccess.READ)
				if f:
					file_size = f.get_length()
					f.close()

				_files.append({
					"path": full_path,
					"rel_path": rel_path,
					"selected": true,
					"size": file_size
				})

		file_name = dir.get_next()
	dir.list_dir_end()


func _scan_project() -> void:
	# Initialize categories
	_project_categories = {
		"Addons": [],
		"Scripts": [],
		"Scenes": [],
		"Resources": [],
		"Models": [],
		"Textures": [],
		"Audio": [],
		"Shaders": [],
		"Input Actions": [],
		"Autoloads": [],
		"Other": []
	}

	# Scan project files
	_scan_project_folder("res://")

	# Add Input Actions from ProjectSettings
	_scan_input_actions()

	# Add Autoloads from ProjectSettings
	_scan_autoloads()


func _scan_project_folder(path: String) -> void:
	var dir = DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		if file_name != "." and file_name != ".." and not file_name.begins_with("."):
			var full_path = path.path_join(file_name)
			var rel_path = full_path.replace("res://", "")

			if dir.current_is_dir():
				# Skip .godot folder
				if file_name != ".godot":
					_scan_project_folder(full_path)
			else:
				# Skip system files
				if file_name.ends_with(".import") or file_name.ends_with(".uid") or file_name == "project.godot":
					file_name = dir.get_next()
					continue

				var file_size = 0
				var f = FileAccess.open(full_path, FileAccess.READ)
				if f:
					file_size = f.get_length()
					f.close()

				var category = _categorize_file(full_path, file_name)
				var file_info = {
					"path": full_path,
					"rel_path": rel_path,
					"selected": true,
					"size": file_size,
					"category": category
				}

				_files.append(file_info)
				_project_categories[category].append(file_info)

		file_name = dir.get_next()
	dir.list_dir_end()


func _categorize_file(full_path: String, file_name: String) -> String:
	var ext = file_name.get_extension().to_lower()

	# Check if it's in addons folder
	if full_path.begins_with("res://addons/"):
		return "Addons"

	# By extension
	match ext:
		"gd", "cs", "gdshader":
			if ext == "gdshader":
				return "Shaders"
			return "Scripts"
		"tscn":
			return "Scenes"
		"tres", "res":
			return "Resources"
		"glb", "gltf", "fbx", "obj", "dae", "blend":
			return "Models"
		"png", "jpg", "jpeg", "webp", "svg", "bmp", "tga", "hdr", "exr":
			return "Textures"
		"wav", "ogg", "mp3", "flac", "aiff":
			return "Audio"
		"gdshader", "shader":
			return "Shaders"
		_:
			return "Other"


func _scan_input_actions() -> void:
	# Get all input actions from ProjectSettings
	for setting in ProjectSettings.get_property_list():
		var name: String = setting.name
		if name.begins_with("input/"):
			var action_name = name.substr(6)  # Remove "input/"
			# Skip built-in actions
			if action_name.begins_with("ui_"):
				continue

			var action_value = ProjectSettings.get_setting(name)
			var file_info = {
				"path": "",  # No file path for input actions
				"rel_path": action_name,
				"selected": true,
				"size": 0,
				"category": "Input Actions",
				"is_input_action": true,
				"action_name": action_name,
				"action_value": action_value
			}
			_files.append(file_info)
			_project_categories["Input Actions"].append(file_info)


func _scan_autoloads() -> void:
	# Get all autoloads from ProjectSettings
	for setting in ProjectSettings.get_property_list():
		var name: String = setting.name
		if name.begins_with("autoload/"):
			var autoload_name = name.substr(9)  # Remove "autoload/"
			var autoload_value = ProjectSettings.get_setting(name)

			var file_info = {
				"path": "",  # Autoload path is in the value
				"rel_path": autoload_name,
				"selected": true,
				"size": 0,
				"category": "Autoloads",
				"is_autoload": true,
				"autoload_name": autoload_name,
				"autoload_value": autoload_value
			}
			_files.append(file_info)
			_project_categories["Autoloads"].append(file_info)


func _detect_folder_autoloads(folder_path: String) -> void:
	## Detect autoloads whose scripts are inside the given folder
	## This is used when exporting a folder (not full project)

	# Normalize folder path for comparison
	var normalized_folder = folder_path
	if not normalized_folder.ends_with("/"):
		normalized_folder += "/"

	var autoloads_found := 0

	for setting in ProjectSettings.get_property_list():
		var name: String = setting.name
		if name.begins_with("autoload/"):
			var autoload_name = name.substr(9)  # Remove "autoload/"
			var autoload_value: String = ProjectSettings.get_setting(name)

			# autoload_value format: "*res://path/to/script.gd" (with * for singleton)
			# or just "res://path/to/script.gd"
			var script_path = autoload_value
			if script_path.begins_with("*"):
				script_path = script_path.substr(1)

			# Check if this script is inside the folder we're exporting
			if script_path.begins_with(normalized_folder):
				# Calculate the relative path within the export
				var rel_script_path = script_path.substr(normalized_folder.length())

				# Rebuild the autoload value with the relative path
				# (will be adapted during import based on install location)
				var new_autoload_value = autoload_value
				if autoload_value.begins_with("*"):
					new_autoload_value = "*res://" + rel_script_path
				else:
					new_autoload_value = "res://" + rel_script_path

				var file_info = {
					"path": "",
					"rel_path": autoload_name,
					"selected": true,
					"size": 0,
					"category": "Autoloads",
					"is_autoload": true,
					"autoload_name": autoload_name,
					"autoload_value": new_autoload_value,
					"original_script_path": script_path
				}
				_files.append(file_info)
				autoloads_found += 1

	if autoloads_found > 0:
		SettingsDialog.debug_print(" Found %d autoloads in folder %s" % [autoloads_found, folder_path])


func _setup_thumbnail_selector() -> void:
	## Detect available thumbnail sources (scenes, materials, images, 3D models) and generate default preview
	_thumb_sources.clear()
	_thumb_state = {"selected_angle": 0, "selected_source": 0}
	_current_thumb_data = PackedByteArray()

	# Find previewable files
	var scenes: Array[String] = []
	var materials: Array[String] = []
	var images: Array[String] = []
	var models_3d: Array[String] = []

	for file_info in _files:
		var file_path: String = file_info.get("path", "")
		if file_path.is_empty():
			continue
		var ext = file_path.get_extension().to_lower()
		if ext in ["tscn", "scn"]:
			scenes.append(file_path)
		elif ext in ["tres", "res"]:
			if _is_material_resource(file_path):
				materials.append(file_path)
		elif ext in ["png", "jpg", "jpeg", "webp", "svg"]:
			images.append(file_path)
		elif ext in ["glb", "gltf", "obj", "fbx"]:
			models_3d.append(file_path)

	# Sort each category by name length (shorter = likely main asset)
	scenes.sort_custom(func(a, b): return a.get_file().length() < b.get_file().length())
	images.sort_custom(func(a, b): return a.get_file().length() < b.get_file().length())
	models_3d.sort_custom(func(a, b): return a.get_file().length() < b.get_file().length())

	# Build source list - priority: scenes > 3D models > materials > images
	for s in scenes:
		_thumb_sources.append({"path": s, "type": "scene", "name": s.get_file()})
	for m in models_3d:
		_thumb_sources.append({"path": m, "type": "model3d", "name": m.get_file()})
	for m in materials:
		_thumb_sources.append({"path": m, "type": "material", "name": m.get_file()})
	for img in images:
		_thumb_sources.append({"path": img, "type": "image", "name": img.get_file()})

	# Update button visibility
	_thumb_choose_btn.visible = not _thumb_sources.is_empty()

	if _thumb_sources.is_empty():
		# Show placeholder
		var placeholder = PlaceholderTexture2D.new()
		placeholder.size = Vector2(100, 100)
		_thumb_preview.texture = placeholder
		return

	# Generate default thumbnail (first source, isometric angle)
	_generate_default_thumbnail()


func _generate_default_thumbnail() -> void:
	## Generate the default thumbnail preview
	if _thumb_sources.is_empty():
		return

	var source = _thumb_sources[_thumb_state["selected_source"]]
	var source_path = source.get("path", "")
	var source_type = source.get("type", "scene")

	var png_data: PackedByteArray
	match source_type:
		"material":
			png_data = await _get_material_preview_async(source_path, 256)
		"image":
			png_data = await _get_image_preview_async(source_path, 256)
		"model3d":
			var angle_idx = _thumb_state["selected_angle"]
			var opt = _thumb_options[angle_idx]
			var cam_dir = opt.get("dir", Vector3(1, 0.6, 1).normalized())
			var zoom = opt.get("zoom", 1.0)
			png_data = await _get_model3d_preview_async(source_path, cam_dir, zoom)
		_:  # scene
			var angle_idx = _thumb_state["selected_angle"]
			var opt = _thumb_options[angle_idx]
			var cam_dir = opt.get("dir", Vector3(1, 0.6, 1).normalized())
			var zoom = opt.get("zoom", 1.0)
			png_data = await _get_scene_preview_async(source_path, cam_dir, zoom)

	_current_thumb_data = png_data
	_update_thumb_preview()


func _update_thumb_preview() -> void:
	## Update the thumbnail preview TextureRect
	if _current_thumb_data.is_empty():
		var placeholder = PlaceholderTexture2D.new()
		placeholder.size = Vector2(100, 100)
		_thumb_preview.texture = placeholder
		return

	var img = Image.new()
	if img.load_png_from_buffer(_current_thumb_data) == OK:
		var tex = ImageTexture.create_from_image(img)
		_thumb_preview.texture = tex


func _on_choose_thumbnail() -> void:
	## Open thumbnail selection dialog
	var dialog = AcceptDialog.new()
	dialog.title = "Choose Thumbnail"
	dialog.size = Vector2i(550, 400)
	dialog.ok_button_text = "Apply"

	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 10)
	dialog.add_child(main_vbox)

	# Source selector if multiple sources
	if _thumb_sources.size() > 1:
		var source_label = Label.new()
		source_label.text = "Thumbnail source:"
		main_vbox.add_child(source_label)

		var source_option = OptionButton.new()
		source_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for i in range(_thumb_sources.size()):
			var src = _thumb_sources[i]
			var type_label = ""
			match src["type"]:
				"scene": type_label = "Scene: "
				"model3d": type_label = "3D Model: "
				"material": type_label = "Material: "
				"image": type_label = "Image: "
				_: type_label = ""
			source_option.add_item(type_label + src["name"], i)
		source_option.select(_thumb_state["selected_source"])
		main_vbox.add_child(source_option)

		source_option.item_selected.connect(func(idx: int):
			_thumb_state["selected_source"] = idx
			_regenerate_dialog_previews(dialog, idx)
		)

	# Angle label
	var angle_label = Label.new()
	var current_source = _thumb_sources[_thumb_state["selected_source"]] if _thumb_sources.size() > 0 else {}
	angle_label.text = "Thumbnail angle:" if current_source.get("type", "scene") in ["scene", "model3d"] else "Thumbnail:"
	angle_label.name = "AngleLabel"
	main_vbox.add_child(angle_label)

	# Angle buttons
	var thumb_hbox = HBoxContainer.new()
	thumb_hbox.add_theme_constant_override("separation", 8)
	thumb_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	thumb_hbox.name = "ThumbHBox"
	main_vbox.add_child(thumb_hbox)

	var dialog_buttons: Array[Button] = []
	for i in range(_thumb_options.size()):
		var opt = _thumb_options[i]
		var thumb_vbox = VBoxContainer.new()
		thumb_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		thumb_hbox.add_child(thumb_vbox)

		var btn = Button.new()
		btn.custom_minimum_size = Vector2(80, 80)
		btn.toggle_mode = true
		btn.button_pressed = (i == _thumb_state["selected_angle"])
		btn.tooltip_text = opt["name"]
		btn.text = "..."
		thumb_vbox.add_child(btn)
		dialog_buttons.append(btn)

		var lbl = Label.new()
		lbl.text = opt["name"]
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		thumb_vbox.add_child(lbl)

		var idx = i
		btn.pressed.connect(func():
			_thumb_state["selected_angle"] = idx
			for j in range(dialog_buttons.size()):
				dialog_buttons[j].button_pressed = (j == idx)
		)

	# Store buttons for later access
	dialog.set_meta("buttons", dialog_buttons)

	# Generate previews
	_generate_dialog_previews(dialog_buttons, _thumb_state["selected_source"])

	dialog.confirmed.connect(func():
		# Apply selection and regenerate main preview
		_generate_default_thumbnail()
		dialog.queue_free()
	)

	dialog.canceled.connect(func():
		dialog.queue_free()
	)

	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func _regenerate_dialog_previews(dialog: AcceptDialog, source_idx: int) -> void:
	## Regenerate previews when source changes in dialog
	var buttons = dialog.get_meta("buttons", []) as Array
	var typed_buttons: Array[Button] = []
	for b in buttons:
		if b is Button:
			typed_buttons.append(b)

	# Update angle label
	var angle_label = dialog.find_child("AngleLabel", true, false) as Label
	if angle_label:
		var src = _thumb_sources[source_idx] if source_idx < _thumb_sources.size() else {}
		angle_label.text = "Thumbnail angle:" if src.get("type", "scene") == "scene" else "Thumbnail:"

	_generate_dialog_previews(typed_buttons, source_idx)


func _generate_dialog_previews(buttons: Array[Button], source_idx: int) -> void:
	## Generate thumbnail previews for the dialog buttons
	if source_idx >= _thumb_sources.size():
		return

	var source = _thumb_sources[source_idx]
	var source_path = source.get("path", "")
	var source_type = source.get("type", "scene")

	# For non-angle types (materials, images), show same preview on all buttons
	if source_type in ["material", "image"]:
		var png_data: PackedByteArray
		if source_type == "material":
			png_data = await _get_material_preview_fast(source_path)
		else:
			png_data = await _get_image_preview_async(source_path, 128)

		for i in range(buttons.size()):
			if not is_instance_valid(buttons[i]):
				return
			if not png_data.is_empty():
				var img = Image.new()
				if img.load_png_from_buffer(png_data) == OK:
					var tex = ImageTexture.create_from_image(img)
					buttons[i].icon = tex
					buttons[i].text = ""
					buttons[i].expand_icon = true
			else:
				buttons[i].text = source_type.substr(0, 3).capitalize()
	else:
		# For scenes and 3D models, generate preview for each angle
		for i in range(_thumb_options.size()):
			if i >= buttons.size() or not is_instance_valid(buttons[i]):
				return
			var opt = _thumb_options[i]
			var cam_dir: Vector3 = opt.get("dir", Vector3(1, 0.6, 1).normalized())
			var zoom: float = opt.get("zoom", 1.0)

			var png_data: PackedByteArray
			if source_type == "model3d":
				png_data = await _get_model3d_preview_fast(source_path, cam_dir, zoom)
			else:
				png_data = await _get_scene_preview_fast(source_path, cam_dir, zoom)

			if not is_instance_valid(buttons[i]):
				return
			if not png_data.is_empty():
				var img = Image.new()
				if img.load_png_from_buffer(png_data) == OK:
					var tex = ImageTexture.create_from_image(img)
					buttons[i].icon = tex
					buttons[i].text = ""
					buttons[i].expand_icon = true
			else:
				buttons[i].text = opt["name"].substr(0, 3)


func _populate_tree_folder_mode() -> void:
	_tree.clear()
	var root = _tree.create_item()
	var theme = EditorInterface.get_editor_theme()

	# Separate autoloads from regular files
	var autoloads: Array[Dictionary] = []
	var regular_files: Array[Dictionary] = []
	for file_info in _files:
		if file_info.get("is_autoload", false):
			autoloads.append(file_info)
		else:
			regular_files.append(file_info)

	# Group regular files by folder
	var folders: Dictionary = {}
	for file_info in regular_files:
		var rel_path: String = file_info["rel_path"]
		var parts = rel_path.split("/")
		var folder_path = ""

		if parts.size() > 1:
			folder_path = "/".join(parts.slice(0, parts.size() - 1))

		if not folders.has(folder_path):
			folders[folder_path] = []
		folders[folder_path].append(file_info)

	# Sort folders
	var folder_keys = folders.keys()
	folder_keys.sort()

	# Create tree items
	var folder_items: Dictionary = {}

	# First pass: determine which folders have selected files
	var folder_has_selected: Dictionary = {}
	for file_info in _files:
		if file_info["selected"]:
			var rel_path: String = file_info["rel_path"]
			var parts = rel_path.split("/")
			var current_path = ""
			for i in range(parts.size() - 1):
				if i > 0:
					current_path += "/"
				current_path += parts[i]
				folder_has_selected[current_path] = true

	for folder_path in folder_keys:
		var parent = root

		if not folder_path.is_empty():
			# Create parent folders if needed
			var parts = folder_path.split("/")
			var current_path = ""

			for i in range(parts.size()):
				if i > 0:
					current_path += "/"
				current_path += parts[i]

				if folder_items.has(current_path):
					parent = folder_items[current_path]
				else:
					var folder_item = _tree.create_item(parent)
					folder_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
					folder_item.set_text(0, parts[i] + "/")
					folder_item.set_checked(0, folder_has_selected.get(current_path, false))
					folder_item.set_editable(0, true)
					folder_item.set_icon(0, _get_folder_icon(parts[i]))
					folder_item.set_meta("is_folder", true)
					folder_item.set_meta("folder_path", current_path)
					# Collapse root-level folders by default
					if i == 0:
						folder_item.collapsed = true
					folder_items[current_path] = folder_item
					parent = folder_item

		# Add files to this folder
		for file_info in folders[folder_path]:
			var file_item = _tree.create_item(parent)
			var file_name = file_info["rel_path"].get_file()
			file_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			file_item.set_text(0, file_name)
			file_item.set_checked(0, file_info["selected"])
			file_item.set_editable(0, true)
			file_item.set_text(1, _format_size(file_info["size"]))
			file_item.set_icon(0, _get_file_icon(file_name))
			file_item.set_meta("is_folder", false)
			file_item.set_meta("file_info", file_info)

	# Add autoloads section if any were detected
	if autoloads.size() > 0:
		var autoload_icon = theme.get_icon("AutoPlay", "EditorIcons")
		var autoloads_section = _tree.create_item(root)
		autoloads_section.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		autoloads_section.set_text(0, "Autoloads (%d)" % autoloads.size())
		autoloads_section.set_checked(0, true)
		autoloads_section.set_editable(0, true)
		autoloads_section.set_icon(0, autoload_icon)
		autoloads_section.set_meta("is_folder", true)
		autoloads_section.set_meta("is_autoloads_section", true)
		autoloads_section.collapsed = true

		for autoload_info in autoloads:
			var autoload_item = _tree.create_item(autoloads_section)
			autoload_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			# Display as "AutoloadName -> script_path"
			var display_name = "%s -> %s" % [autoload_info["autoload_name"], autoload_info.get("original_script_path", autoload_info["autoload_value"])]
			autoload_item.set_text(0, display_name)
			autoload_item.set_checked(0, autoload_info["selected"])
			autoload_item.set_editable(0, true)
			autoload_item.set_icon(0, autoload_icon)
			autoload_item.set_meta("is_folder", false)
			autoload_item.set_meta("file_info", autoload_info)

	# Add dependency files section if any
	var dep_files: Array[Dictionary] = []
	for file_info in _files:
		if file_info.get("is_dependency", false):
			dep_files.append(file_info)

	if dep_files.size() > 0:
		var dep_icon = theme.get_icon("Unlinked", "EditorIcons")
		var dep_section = _tree.create_item(root)
		dep_section.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		dep_section.set_text(0, "Dependencies (%d)" % dep_files.size())
		dep_section.set_checked(0, true)
		dep_section.set_editable(0, true)
		dep_section.set_icon(0, dep_icon)
		dep_section.set_meta("is_folder", true)
		dep_section.set_meta("is_dependencies_section", true)
		dep_section.collapsed = true

		for dep_info in dep_files:
			var dep_item = _tree.create_item(dep_section)
			dep_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			dep_item.set_text(0, dep_info["path"].replace("res://", ""))
			dep_item.set_checked(0, dep_info["selected"])
			dep_item.set_editable(0, true)
			dep_item.set_text(1, _format_size(dep_info["size"]))
			dep_item.set_icon(0, _get_file_icon(dep_info["path"]))
			dep_item.set_meta("is_folder", false)
			dep_item.set_meta("file_info", dep_info)


func _populate_tree_project_mode() -> void:
	_tree.clear()
	var root = _tree.create_item()

	# Category order and icons
	var category_order = [
		"Addons",
		"Scenes",
		"Scripts",
		"Shaders",
		"Resources",
		"Models",
		"Textures",
		"Audio",
		"Input Actions",
		"Autoloads",
		"Other"
	]

	for category in category_order:
		var files_in_category = _project_categories.get(category, [])
		if files_in_category.is_empty():
			continue

		# Special handling for Addons - group by addon folder
		if category == "Addons":
			_populate_addons_category(root, files_in_category)
			continue

		# Special handling for Input Actions and Autoloads - flat list
		if category in ["Input Actions", "Autoloads"]:
			_populate_flat_category(root, category, files_in_category)
			continue

		# All other categories: show hierarchical folder structure
		_populate_category_with_folders(root, category, files_in_category)


func _populate_flat_category(root: TreeItem, category: String, files_in_category: Array) -> void:
	## Flat list for Input Actions and Autoloads
	var any_selected = false
	for file_info in files_in_category:
		if file_info["selected"]:
			any_selected = true
			break

	var cat_item = _tree.create_item(root)
	cat_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
	cat_item.set_text(0, "%s (%d)" % [category, files_in_category.size()])
	cat_item.set_checked(0, any_selected)
	cat_item.set_editable(0, true)
	cat_item.set_icon(0, _get_category_icon(category))
	cat_item.set_meta("is_category", true)
	cat_item.set_meta("category_name", category)

	var total_size = 0
	for file_info in files_in_category:
		total_size += file_info.get("size", 0)
	cat_item.set_text(1, _format_size(total_size))

	for file_info in files_in_category:
		var file_item = _tree.create_item(cat_item)
		var display_name: String
		if file_info.get("is_input_action", false):
			display_name = file_info["action_name"]
		elif file_info.get("is_autoload", false):
			display_name = "%s -> %s" % [file_info["autoload_name"], file_info["autoload_value"]]
		else:
			display_name = file_info["rel_path"]

		file_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		file_item.set_text(0, display_name)
		file_item.set_checked(0, file_info["selected"])
		file_item.set_editable(0, true)
		file_item.set_text(1, _format_size(file_info.get("size", 0)))
		file_item.set_icon(0, _get_file_icon(display_name))
		file_item.set_meta("is_folder", false)
		file_item.set_meta("file_info", file_info)

	cat_item.collapsed = true


func _populate_category_with_folders(root: TreeItem, category: String, files_in_category: Array) -> void:
	## Hierarchical folder view for Scenes, Scripts, Resources, etc.

	# Group files by folder path
	var folders: Dictionary = {}  # folder_path -> Array[file_info]
	for file_info in files_in_category:
		var rel_path: String = file_info["rel_path"]
		var folder_path = rel_path.get_base_dir()
		if not folders.has(folder_path):
			folders[folder_path] = []
		folders[folder_path].append(file_info)

	# Check if any file is selected
	var any_selected = false
	for file_info in files_in_category:
		if file_info["selected"]:
			any_selected = true
			break

	# Create category item
	var cat_item = _tree.create_item(root)
	cat_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
	cat_item.set_text(0, "%s (%d)" % [category, files_in_category.size()])
	cat_item.set_checked(0, any_selected)
	cat_item.set_editable(0, true)
	cat_item.set_icon(0, _get_category_icon(category))
	cat_item.set_meta("is_category", true)
	cat_item.set_meta("category_name", category)

	var total_size = 0
	for file_info in files_in_category:
		total_size += file_info.get("size", 0)
	cat_item.set_text(1, _format_size(total_size))

	# Build folder hierarchy
	var folder_items: Dictionary = {}  # folder_path -> TreeItem

	# First pass: determine which folders have selected files
	var folder_has_selected: Dictionary = {}
	for file_info in files_in_category:
		if file_info["selected"]:
			var rel_path: String = file_info["rel_path"]
			var parts = rel_path.split("/")
			var current_path = ""
			for i in range(parts.size() - 1):
				if i > 0:
					current_path += "/"
				current_path += parts[i]
				folder_has_selected[current_path] = true

	# Sort folder paths
	var folder_keys = folders.keys()
	folder_keys.sort()

	for folder_path in folder_keys:
		if folder_path.is_empty():
			# Files at root level - add directly to category
			for file_info in folders[folder_path]:
				var file_item = _tree.create_item(cat_item)
				var file_name = file_info["rel_path"].get_file()
				file_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
				file_item.set_text(0, file_name)
				file_item.set_checked(0, file_info["selected"])
				file_item.set_editable(0, true)
				file_item.set_text(1, _format_size(file_info.get("size", 0)))
				file_item.set_icon(0, _get_file_icon(file_name))
				file_item.set_meta("is_folder", false)
				file_item.set_meta("file_info", file_info)
			continue

		# Create folder hierarchy
		var parts = folder_path.split("/")
		var current_path = ""
		var parent: TreeItem = cat_item

		for i in range(parts.size()):
			if i > 0:
				current_path += "/"
			current_path += parts[i]

			if folder_items.has(current_path):
				parent = folder_items[current_path]
			else:
				var folder_item = _tree.create_item(parent)
				folder_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
				folder_item.set_text(0, parts[i] + "/")
				folder_item.set_checked(0, folder_has_selected.get(current_path, false))
				folder_item.set_editable(0, true)
				folder_item.set_icon(0, _get_folder_icon(parts[i]))
				folder_item.set_meta("is_folder", true)
				folder_item.set_meta("folder_path", current_path)
				folder_items[current_path] = folder_item
				# Collapse only root-level folders (direct children of category)
				if i == 0:
					folder_item.collapsed = true
				parent = folder_item

		# Add files to the deepest folder
		for file_info in folders[folder_path]:
			var file_item = _tree.create_item(parent)
			var file_name = file_info["rel_path"].get_file()
			file_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			file_item.set_text(0, file_name)
			file_item.set_checked(0, file_info["selected"])
			file_item.set_editable(0, true)
			file_item.set_text(1, _format_size(file_info.get("size", 0)))
			file_item.set_icon(0, _get_file_icon(file_name))
			file_item.set_meta("is_folder", false)
			file_item.set_meta("file_info", file_info)

	# Calculate folder sizes recursively
	_calculate_folder_sizes(cat_item)

	cat_item.collapsed = true


func _calculate_folder_sizes(parent: TreeItem) -> int:
	## Recursively calculate and set folder sizes
	var total_size = 0
	var child = parent.get_first_child()

	while child:
		if child.get_meta("is_folder", false):
			var folder_size = _calculate_folder_sizes(child)
			child.set_text(1, _format_size(folder_size))
			total_size += folder_size
		else:
			var file_info = child.get_meta("file_info", null)
			if file_info:
				total_size += file_info.get("size", 0)
		child = child.get_next()

	return total_size


func _populate_addons_category(root: TreeItem, files_in_category: Array) -> void:
	# Group files by addon folder name
	var addons_grouped: Dictionary = {}  # addon_name -> Array[file_info]

	for file_info in files_in_category:
		var rel_path: String = file_info["rel_path"]
		# Path format: addons/addon_name/...
		var parts = rel_path.split("/")
		if parts.size() >= 2 and parts[0] == "addons":
			var addon_name = parts[1]
			if not addons_grouped.has(addon_name):
				addons_grouped[addon_name] = []
			addons_grouped[addon_name].append(file_info)

	if addons_grouped.is_empty():
		return

	# Check if any file in category is selected
	var any_selected = false
	for file_info in files_in_category:
		if file_info["selected"]:
			any_selected = true
			break

	# Create main Addons category
	var cat_item = _tree.create_item(root)
	cat_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
	cat_item.set_text(0, "Addons (%d)" % addons_grouped.size())
	cat_item.set_checked(0, any_selected)
	cat_item.set_editable(0, true)
	cat_item.set_icon(0, _get_category_icon("Addons"))
	cat_item.set_meta("is_category", true)
	cat_item.set_meta("category_name", "Addons")

	# Calculate total size
	var total_size = 0
	for file_info in files_in_category:
		total_size += file_info.get("size", 0)
	cat_item.set_text(1, _format_size(total_size))

	# Sort addon names
	var addon_names = addons_grouped.keys()
	addon_names.sort()

	# Create a folder item for each addon
	for addon_name in addon_names:
		var addon_files: Array = addons_grouped[addon_name]

		# Calculate addon size and check if any selected
		var addon_size = 0
		var addon_any_selected = false
		for file_info in addon_files:
			addon_size += file_info.get("size", 0)
			if file_info["selected"]:
				addon_any_selected = true

		# Create addon folder item
		var addon_item = _tree.create_item(cat_item)
		addon_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		addon_item.set_text(0, "%s/ (%d files)" % [addon_name, addon_files.size()])
		addon_item.set_checked(0, addon_any_selected)
		addon_item.set_editable(0, true)
		addon_item.set_text(1, _format_size(addon_size))
		addon_item.set_icon(0, _get_category_icon("Addons"))
		addon_item.set_meta("is_addon_folder", true)
		addon_item.set_meta("addon_name", addon_name)

		# Add individual files as children (hidden by default)
		for file_info in addon_files:
			var file_item = _tree.create_item(addon_item)
			# Show path relative to addon folder
			var rel_path: String = file_info["rel_path"]
			var display_name = rel_path.replace("addons/%s/" % addon_name, "")

			file_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			file_item.set_text(0, display_name)
			file_item.set_checked(0, file_info["selected"])
			file_item.set_editable(0, true)
			file_item.set_text(1, _format_size(file_info.get("size", 0)))
			file_item.set_icon(0, _get_file_icon(display_name))
			file_item.set_meta("is_folder", false)
			file_item.set_meta("file_info", file_info)

		# Collapse addon folder by default
		addon_item.collapsed = true

	# Collapse main Addons category by default
	cat_item.collapsed = true


func _format_size(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	elif bytes < 1024 * 1024:
		return "%.1f KB" % (bytes / 1024.0)
	else:
		return "%.2f MB" % (bytes / (1024.0 * 1024.0))


func _get_category_icon(category: String) -> Texture2D:
	var theme = EditorInterface.get_editor_theme()
	match category:
		"Addons":
			return theme.get_icon("EditorPlugin", "EditorIcons")
		"Scripts":
			return theme.get_icon("Script", "EditorIcons")
		"Scenes":
			return theme.get_icon("PackedScene", "EditorIcons")
		"Shaders":
			return theme.get_icon("Shader", "EditorIcons")
		"Resources":
			return theme.get_icon("Object", "EditorIcons")
		"Models":
			return theme.get_icon("Mesh", "EditorIcons")
		"Textures":
			return theme.get_icon("ImageTexture", "EditorIcons")
		"Audio":
			return theme.get_icon("AudioStreamPlayer", "EditorIcons")
		"Input Actions":
			return theme.get_icon("InputEventKey", "EditorIcons")
		"Autoloads":
			return theme.get_icon("AutoPlay", "EditorIcons")
		"Other":
			return theme.get_icon("File", "EditorIcons")
		_:
			return theme.get_icon("Folder", "EditorIcons")


func _get_folder_icon(folder_name: String) -> Texture2D:
	## Get icon for a folder based on its name
	var theme = EditorInterface.get_editor_theme()
	var name_lower = folder_name.to_lower()

	match name_lower:
		"materials", "material":
			return theme.get_icon("StandardMaterial3D", "EditorIcons")
		"models", "model", "meshes", "mesh":
			return theme.get_icon("Mesh", "EditorIcons")
		"prefabs", "prefab", "scenes":
			return theme.get_icon("PackedScene", "EditorIcons")
		"textures", "texture", "images", "sprites":
			return theme.get_icon("ImageTexture", "EditorIcons")
		"scripts", "script", "src":
			return theme.get_icon("Script", "EditorIcons")
		"audio", "sounds", "sound", "music":
			return theme.get_icon("AudioStreamPlayer", "EditorIcons")
		"shaders", "shader":
			return theme.get_icon("Shader", "EditorIcons")
		"fonts", "font":
			return theme.get_icon("Font", "EditorIcons")
		"animations", "animation", "anim":
			return theme.get_icon("Animation", "EditorIcons")
		"resources", "resource", "res":
			return theme.get_icon("Object", "EditorIcons")
		"addons", "plugins":
			return theme.get_icon("EditorPlugin", "EditorIcons")
		_:
			return theme.get_icon("Folder", "EditorIcons")


func _get_file_icon(file_name: String) -> Texture2D:
	var theme = EditorInterface.get_editor_theme()
	var ext = file_name.get_extension().to_lower()

	match ext:
		"gd":
			return theme.get_icon("GDScript", "EditorIcons")
		"tscn":
			return theme.get_icon("PackedScene", "EditorIcons")
		"tres", "res":
			return theme.get_icon("Object", "EditorIcons")
		"shader", "gdshader":
			return theme.get_icon("Shader", "EditorIcons")
		"png", "jpg", "jpeg", "webp", "svg", "bmp", "tga", "hdr", "exr":
			return theme.get_icon("ImageTexture", "EditorIcons")
		"wav", "ogg", "mp3", "flac":
			return theme.get_icon("AudioStreamPlayer", "EditorIcons")
		"glb", "gltf", "fbx", "obj", "dae":
			return theme.get_icon("Mesh", "EditorIcons")
		"cfg":
			return theme.get_icon("TextFile", "EditorIcons")
		"json":
			return theme.get_icon("JSON", "EditorIcons")
		"md", "txt":
			return theme.get_icon("TextFile", "EditorIcons")
		_:
			return theme.get_icon("File", "EditorIcons")


func _on_item_edited() -> void:
	var item = _tree.get_edited()
	if item == null:
		return

	var is_checked = item.is_checked(0)

	if item.get_meta("is_folder", false) or item.get_meta("is_category", false) or item.get_meta("is_addon_folder", false):
		# Toggle all children
		_set_children_checked(item, is_checked)
	else:
		# Update file info
		var file_info = item.get_meta("file_info", null)
		if file_info:
			file_info["selected"] = is_checked

	_update_file_count_label()


func _set_children_checked(parent: TreeItem, checked: bool) -> void:
	var child = parent.get_first_child()
	while child:
		child.set_checked(0, checked)

		if child.get_meta("is_folder", false) or child.get_meta("is_category", false) or child.get_meta("is_addon_folder", false):
			_set_children_checked(child, checked)
		else:
			var file_info = child.get_meta("file_info", null)
			if file_info:
				file_info["selected"] = checked

		child = child.get_next()


func _on_select_all() -> void:
	for file_info in _files:
		file_info["selected"] = true
	if _export_mode == ExportMode.FROM_PROJECT:
		_populate_tree_project_mode()
	else:
		_populate_tree_folder_mode()
	_update_file_count_label()


func _on_select_none() -> void:
	for file_info in _files:
		file_info["selected"] = false
	if _export_mode == ExportMode.FROM_PROJECT:
		_populate_tree_project_mode()
	else:
		_populate_tree_folder_mode()
	_update_file_count_label()


func _on_include_deps_toggled(enabled: bool) -> void:
	_include_dependencies = enabled
	if enabled:
		_add_dependencies()
	else:
		_remove_dependencies()
	if _export_mode == ExportMode.FROM_PROJECT:
		_populate_tree_project_mode()
	else:
		_populate_tree_folder_mode()
	_update_file_count_label()


func _add_dependencies() -> void:
	## Detect and add dependencies for all selected files
	_dependency_files.clear()

	# Files that can have dependencies
	var dep_extensions = ["tscn", "scn", "tres", "res", "gd"]
	var all_deps: Dictionary = {}  # path -> true (to avoid duplicates)

	# Mark existing files
	for file_info in _base_files:
		all_deps[file_info["path"]] = true

	# Detect dependencies
	for file_info in _base_files:
		if not file_info["selected"]:
			continue
		var ext = file_info["path"].get_extension().to_lower()
		if ext not in dep_extensions:
			continue

		var deps = DependencyDetector.get_all_dependencies(file_info["path"], false, false)
		for dep in deps:
			if dep not in all_deps and FileAccess.file_exists(dep):
				all_deps[dep] = true
				# Add as dependency file
				var file_size = 0
				var f = FileAccess.open(dep, FileAccess.READ)
				if f:
					file_size = f.get_length()
					f.close()

				# Calculate relative path
				var rel_path = dep
				if dep.begins_with(_source_folder):
					# Dependency is inside source folder - use relative path
					rel_path = dep.replace(_source_folder, "").trim_prefix("/")
				elif dep.begins_with("res://"):
					# Dependency is outside source folder - use path without res://
					# This will be stored with full structure for proper dependency resolution
					rel_path = dep.substr(6)  # Remove "res://"

				var dep_info = {
					"path": dep,
					"rel_path": rel_path,
					"selected": true,
					"size": file_size,
					"is_dependency": true,
					"is_external": not dep.begins_with(_source_folder)  # Mark external deps
				}
				_dependency_files.append(dep_info)

	# Add dependency files to main list
	_files = _base_files.duplicate(true)
	_files.append_array(_dependency_files)


func _remove_dependencies() -> void:
	## Remove dependency files from the list
	_dependency_files.clear()
	_files = _base_files.duplicate(true)


func _update_file_count_label() -> void:
	## Update the output label with file count and dependency status
	var selected_count = 0
	var dep_count = 0

	for file_info in _files:
		if file_info["selected"]:
			selected_count += 1
			if file_info.get("is_dependency", false):
				dep_count += 1

	_output_label.text = "%d files selected" % selected_count

	# Count potential dependencies not included
	if not _include_dependencies:
		var potential_deps = _count_potential_dependencies()
		if potential_deps > 0:
			_deps_status_label.text = "(%d dependencies not included)" % potential_deps
			_deps_status_label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
			_deps_status_label.visible = true
		else:
			_deps_status_label.visible = false
	else:
		if dep_count > 0:
			_deps_status_label.text = "(%d dependencies included)" % dep_count
			_deps_status_label.add_theme_color_override("font_color", Color(0.4, 0.8, 0.4))
			_deps_status_label.visible = true
		else:
			_deps_status_label.visible = false


func _count_potential_dependencies() -> int:
	## Count how many dependencies would be added if "Include dependencies" was checked
	var dep_extensions = ["tscn", "scn", "tres", "res", "gd"]
	var all_deps: Dictionary = {}

	# Mark existing files
	for file_info in _files:
		all_deps[file_info["path"]] = true

	var count = 0
	for file_info in _files:
		if not file_info["selected"]:
			continue
		var ext = file_info["path"].get_extension().to_lower()
		if ext not in dep_extensions:
			continue

		var deps = DependencyDetector.get_all_dependencies(file_info["path"], false, false)
		for dep in deps:
			if dep not in all_deps and FileAccess.file_exists(dep):
				all_deps[dep] = true
				count += 1

	return count


static func _sanitize_package_name(name: String) -> String:
	## Sanitize a package name to only contain safe characters
	var sanitized = ""
	for c in name:
		if c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_- ":
			sanitized += c
	return sanitized.strip_edges()


func _on_confirmed() -> void:
	var package_name = _name_edit.text.strip_edges()
	if package_name.is_empty():
		_status_label.text = "Error: Package name is required"
		return

	# Validate and sanitize package name
	var sanitized_name = _sanitize_package_name(package_name)
	if sanitized_name.is_empty():
		_status_label.text = "Error: Package name contains only invalid characters.\nAllowed: letters, numbers, spaces, hyphens, underscores"
		return
	if sanitized_name != package_name:
		# Auto-fix the name and notify user
		_name_edit.text = sanitized_name
		package_name = sanitized_name
		_status_label.text = "Note: Package name was sanitized (removed special characters)"
		# Don't return - continue with export

	# Get selected files (exclude input actions and autoloads for file list)
	var selected_files: Array[Dictionary] = []
	var selected_input_actions: Array[Dictionary] = []
	var selected_autoloads: Array[Dictionary] = []

	for file_info in _files:
		if file_info["selected"]:
			if file_info.get("is_input_action", false):
				selected_input_actions.append(file_info)
			elif file_info.get("is_autoload", false):
				selected_autoloads.append(file_info)
			elif not file_info["path"].is_empty():
				selected_files.append(file_info)

	if selected_files.is_empty() and selected_input_actions.is_empty() and selected_autoloads.is_empty():
		_status_label.text = "Error: No content selected"
		return

	# Determine format and extension
	var format_idx = _format_option.selected
	var extension = ".zip" if format_idx == ExportFormat.ZIP else ".godotpackage"

	# If target global folder is set, export directly there
	if not _target_global_folder.is_empty():
		var output_path = _target_global_folder.path_join(package_name + ".godotpackage")
		# Check if package already exists
		if FileAccess.file_exists(output_path):
			_show_replace_confirmation(output_path, package_name, selected_files, selected_input_actions, selected_autoloads)
		else:
			_do_export(output_path, package_name, selected_files, selected_input_actions, selected_autoloads, ExportFormat.GODOTPACKAGE)
		return

	# Show save dialog
	var save_dialog = FileDialog.new()
	save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	save_dialog.access = FileDialog.ACCESS_FILESYSTEM
	save_dialog.title = "Save Package As"
	save_dialog.current_file = package_name + extension

	if extension == ".zip":
		save_dialog.add_filter("*.zip", "ZIP Archive")
	else:
		save_dialog.add_filter("*.godotpackage", "Godot Package")

	save_dialog.file_selected.connect(func(path: String):
		_do_export(path, package_name, selected_files, selected_input_actions, selected_autoloads, format_idx)
		save_dialog.queue_free()
	)

	save_dialog.canceled.connect(func():
		save_dialog.queue_free()
	)

	EditorInterface.get_base_control().add_child(save_dialog)
	save_dialog.popup_centered(Vector2i(600, 400))


func _show_replace_confirmation(output_path: String, package_name: String, files: Array[Dictionary], input_actions: Array[Dictionary], autoloads: Array[Dictionary]) -> void:
	## Show confirmation dialog when a package with the same name already exists
	var confirm = ConfirmationDialog.new()
	confirm.title = "Package Already Exists"
	confirm.dialog_text = "A package named '%s' already exists in the global folder.\n\nDo you want to replace it?" % package_name
	confirm.ok_button_text = "Replace"
	confirm.cancel_button_text = "Cancel"

	confirm.confirmed.connect(func():
		confirm.queue_free()
		_do_export(output_path, package_name, files, input_actions, autoloads, ExportFormat.GODOTPACKAGE)
	)

	confirm.canceled.connect(func():
		confirm.queue_free()
	)

	EditorInterface.get_base_control().add_child(confirm)
	confirm.popup_centered()


func _do_export(output_path: String, package_name: String, files: Array[Dictionary], input_actions: Array[Dictionary], autoloads: Array[Dictionary], format: int) -> void:
	await _do_export_async(output_path, package_name, files, input_actions, autoloads, format)


func _do_export_async(output_path: String, package_name: String, files: Array[Dictionary], input_actions: Array[Dictionary], autoloads: Array[Dictionary], format: int) -> void:
	_progress_bar.visible = true
	_progress_bar.value = 0
	_status_label.text = "Exporting..."
	get_ok_button().disabled = true

	# Create ZIP
	var writer = ZIPPacker.new()
	var err = writer.open(output_path)

	if err != OK:
		_status_label.text = "Error: Failed to create file: %s" % error_string(err)
		_progress_bar.visible = false
		get_ok_button().disabled = false
		return

	# Detect package type
	var pkg_type = "asset"  # Default
	if _export_mode == ExportMode.FROM_FOLDER:
		# Check if source folder is in addons/
		if "/addons/" in _source_folder or _source_folder.begins_with("res://addons/"):
			pkg_type = "plugin"
		# Also check if files contain plugin.cfg
		for file_info in files:
			if file_info["rel_path"].ends_with("plugin.cfg"):
				pkg_type = "plugin"
				break
			elif file_info["rel_path"].ends_with("project.godot"):
				pkg_type = "template"
				break

	# Check if we have external dependencies (dependencies outside the source folder)
	var has_external_deps = false
	for file_info in files:
		if file_info.get("is_external", false):
			has_external_deps = true
			break

	# If we have external dependencies, find common root for all files
	var common_root = ""
	if has_external_deps and _include_dependencies:
		var all_paths: Array[String] = []
		for file_info in files:
			all_paths.append(file_info["path"])
		common_root = _find_common_root_folder(all_paths)

	# Build manifest
	var manifest = {
		"name": package_name,
		"type": pkg_type,
		"version": _version_edit.text.strip_edges(),
		"author": _author_edit.text.strip_edges(),
		"created_at": Time.get_datetime_string_from_system(true),
		"pack_root": "%s/" % package_name,
		"godot_version": "%d.%d" % [Engine.get_version_info()["major"], Engine.get_version_info()["minor"]],
		"files": [],
		"input_actions": {},
		"autoloads": {}
	}

	# If we have external dependencies, use preserve_structure mode
	if has_external_deps and _include_dependencies:
		manifest["preserve_structure"] = true
		manifest["common_root"] = common_root

	# Add source folder path for path adaptation during import
	# This is the FULL path from res://, e.g., "Packages/godotmultemptestpreload"
	# Paths inside files are like res://Packages/godotmultemptestpreload/scripts/...
	# When importing, we need to replace the entire source_folder prefix with install_root
	if _export_mode == ExportMode.FROM_FOLDER and _source_folder != "res://":
		# Get full relative path from res:// (e.g., "Packages/godotmultemptestpreload")
		var source_relative = _source_folder.replace("res://", "").trim_suffix("/")
		if not source_relative.is_empty():
			manifest["source_folder"] = source_relative

	# Add original asset metadata if available (for global folder exports)
	if not _original_asset_info.is_empty():
		manifest["original_source"] = _original_asset_info.get("source", "")
		manifest["original_browse_url"] = _original_asset_info.get("browse_url", "")
		manifest["original_url"] = _original_asset_info.get("url", "")
		manifest["category"] = _original_asset_info.get("category", "")
		manifest["icon_url"] = _original_asset_info.get("icon_url", "")
		manifest["description"] = _original_asset_info.get("description", "")
		manifest["license"] = _original_asset_info.get("license", "")
		manifest["original_asset_id"] = _original_asset_info.get("asset_id", "")

	# Add files to manifest (with common_root stripped if applicable)
	for file_info in files:
		var rel_path = file_info["rel_path"]
		# When we have external deps, use absolute path (without res://) and strip common_root
		if has_external_deps and _include_dependencies:
			# Get the full path without res:// prefix
			var full_rel = file_info["path"]
			if full_rel.begins_with("res://"):
				full_rel = full_rel.substr(6)
			# Strip common_root if applicable
			if not common_root.is_empty() and full_rel.begins_with(common_root):
				rel_path = full_rel.substr(common_root.length())
			else:
				rel_path = full_rel
		manifest["files"].append(rel_path)

	# Add input actions to manifest
	for action_info in input_actions:
		manifest["input_actions"][action_info["action_name"]] = var_to_str(action_info["action_value"])

	# Add autoloads to manifest
	for autoload_info in autoloads:
		manifest["autoloads"][autoload_info["autoload_name"]] = autoload_info["autoload_value"]

	# If godotpackage format, add manifest
	if format == ExportFormat.GODOTPACKAGE:
		var manifest_json = JSON.stringify(manifest, "\t")
		err = writer.start_file("manifest.json")
		if err == OK:
			writer.write_file(manifest_json.to_utf8_buffer())
			writer.close_file()

		# Include icon if available
		var icon_png_data: PackedByteArray = []

		# First try: icon texture passed from main_panel
		var icon_tex = _original_asset_info.get("_icon_texture", null)
		if icon_tex is Texture2D:
			var img = icon_tex.get_image()
			if img:
				icon_png_data = img.save_png_to_buffer()

		# Second try: use current thumbnail data (already generated)
		if icon_png_data.is_empty() and not _current_thumb_data.is_empty():
			icon_png_data = _current_thumb_data

		# Third try: look for icon in the files being exported
		if icon_png_data.is_empty():
			icon_png_data = _find_icon_in_files(files)

		# Write icon to package
		if icon_png_data.size() > 0:
			err = writer.start_file("icon.png")
			if err == OK:
				writer.write_file(icon_png_data)
				writer.close_file()
				manifest["has_icon"] = true

	# Add files
	var total = files.size()
	var current = 0

	for file_info in files:
		current += 1
		_progress_bar.value = (float(current) / total) * 100
		_status_label.text = "Packaging: %s" % file_info["rel_path"].get_file()

		var file_path = file_info["path"]
		var rel_path = file_info["rel_path"]

		# For preserve_structure mode, use absolute path and strip common_root
		if has_external_deps and _include_dependencies:
			# Get the full path without res:// prefix
			var full_rel = file_path
			if full_rel.begins_with("res://"):
				full_rel = full_rel.substr(6)
			# Strip common_root if applicable
			if not common_root.is_empty() and full_rel.begins_with(common_root):
				rel_path = full_rel.substr(common_root.length())
			else:
				rel_path = full_rel

		# Path in zip
		var zip_path: String
		if format == ExportFormat.GODOTPACKAGE:
			zip_path = "%s/%s" % [package_name, rel_path]
		else:
			zip_path = rel_path

		# Read file
		var file = FileAccess.open(file_path, FileAccess.READ)
		if file == null:
			push_warning("AssetPlus Export: Cannot read file, skipping: %s" % file_path)
			continue

		var content = file.get_buffer(file.get_length())
		file.close()

		# Write to zip
		err = writer.start_file(zip_path)
		if err == OK:
			writer.write_file(content)
			writer.close_file()

	writer.close()

	_progress_bar.value = 100
	_status_label.text = "Export complete: %s" % output_path.get_file()
	get_ok_button().disabled = false

	# Stats
	var stats = "Exported: %d files" % files.size()
	if input_actions.size() > 0:
		stats += ", %d input actions" % input_actions.size()
	if autoloads.size() > 0:
		stats += ", %d autoloads" % autoloads.size()
	SettingsDialog.debug_print(" %s to %s" % [stats, output_path])

	export_completed.emit(true, output_path)


func _find_icon_in_files(files: Array[Dictionary]) -> PackedByteArray:
	## Search through the file list to find a suitable icon/thumbnail
	## Returns PNG data or empty array

	# Priority 1: Look for specifically named icons
	var priority_names = ["icon.png", "thumbnail.png", "preview.png", "cover.png", "logo.png"]
	for file_info in files:
		var file_name = file_info["path"].get_file().to_lower()
		if file_name in priority_names:
			var data = _read_image_as_png(file_info["path"])
			if data.size() > 0:
				return data

	# Also check for icon in addon folders (plugin icon)
	for file_info in files:
		var file_path: String = file_info["path"]
		if file_path.ends_with("/icon.png") or file_path.ends_with("/icon.svg"):
			var data = _read_image_as_png(file_path)
			if data.size() > 0:
				return data

	# Don't grab random textures - only use explicitly named icons
	return PackedByteArray()


func _read_image_as_png(image_path: String) -> PackedByteArray:
	## Read an image file and return PNG data
	var ext = image_path.get_extension().to_lower()

	if ext == "png":
		var file = FileAccess.open(image_path, FileAccess.READ)
		if file:
			var data = file.get_buffer(file.get_length())
			file.close()
			return data

	elif ext in ["svg", "jpg", "jpeg", "webp"]:
		# Load and convert to PNG
		var img = Image.new()
		var err = img.load(image_path)
		if err == OK:
			if img.get_width() > 256 or img.get_height() > 256:
				img.resize(256, 256, Image.INTERPOLATE_LANCZOS)
			return img.save_png_to_buffer()

	return PackedByteArray()


func _find_common_root_folder(files: Array[String]) -> String:
	## Find the common root folder that can be stripped from all file paths
	## Returns the path prefix to strip (without res://, with trailing slash)
	if files.is_empty():
		return ""

	# Convert all paths to relative (without res://)
	var rel_paths: Array[String] = []
	for f in files:
		var rel = f
		if f.begins_with("res://"):
			rel = f.substr(6)
		rel_paths.append(rel)

	# Find common directory prefix
	var first_dir = rel_paths[0].get_base_dir()
	if first_dir.is_empty():
		return ""

	var first_parts = first_dir.split("/")
	var common_parts: Array[String] = []

	# Check each component
	for i in range(first_parts.size()):
		var part = first_parts[i]
		if part.is_empty():
			continue

		var prefix = "/".join(PackedStringArray(common_parts + [part])) + "/"

		# Check if ALL files start with this prefix
		var all_match = true
		for rel_path in rel_paths:
			var file_dir = rel_path.get_base_dir() + "/"
			if not file_dir.begins_with(prefix):
				all_match = false
				break

		if all_match:
			common_parts.append(part)
		else:
			break

	if common_parts.is_empty():
		return ""

	return "/".join(PackedStringArray(common_parts)) + "/"


# ============================================================================
# Thumbnail generation functions
# ============================================================================

func _is_material_resource(file_path: String) -> bool:
	## Check if a .tres/.res file is a material
	if not FileAccess.file_exists(file_path):
		return false
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return false
	var header = file.get_line() + file.get_line() + file.get_line()
	file.close()
	return "StandardMaterial3D" in header or "ShaderMaterial" in header or "ORMMaterial3D" in header


func _get_material_preview_fast(material_path: String) -> PackedByteArray:
	## Generate a fast preview for a material (sphere with material applied)
	return await _get_material_preview_async(material_path, 128)


func _get_material_preview_async(material_path: String, size: int = 256) -> PackedByteArray:
	## Generate a preview for a material (sphere with material applied)
	if not ResourceLoader.exists(material_path):
		return PackedByteArray()

	var material = load(material_path)
	if material == null or not (material is Material):
		return PackedByteArray()

	var viewport = SubViewport.new()
	viewport.size = Vector2i(size, size)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.own_world_3d = true

	EditorInterface.get_base_control().add_child(viewport)

	var mesh_instance = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	mesh_instance.mesh = sphere
	mesh_instance.material_override = material
	viewport.add_child(mesh_instance)

	var cam = Camera3D.new()
	cam.fov = 50.0
	viewport.add_child(cam)
	cam.current = true
	cam.global_position = Vector3(2.5, 1.5, 2.5)
	cam.look_at(Vector3.ZERO)

	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 45, 0)
	light.light_energy = 1.5
	viewport.add_child(light)

	var light2 = DirectionalLight3D.new()
	light2.rotation_degrees = Vector3(-30, -135, 0)
	light2.light_energy = 0.5
	viewport.add_child(light2)

	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	var image = viewport.get_texture().get_image()
	viewport.queue_free()

	if image == null or image.is_empty():
		return PackedByteArray()

	if size != 256:
		image.resize(64, 64, Image.INTERPOLATE_BILINEAR)
	else:
		image.resize(256, 256, Image.INTERPOLATE_LANCZOS)

	return image.save_png_to_buffer()


func _get_scene_preview_fast(scene_path: String, cam_dir: Vector3, zoom_factor: float) -> PackedByteArray:
	## Fast preview generation for UI thumbnails (lower resolution, fewer frames)
	if not ResourceLoader.exists(scene_path):
		return PackedByteArray()

	var packed_scene = load(scene_path) as PackedScene
	if packed_scene == null:
		return PackedByteArray()

	var viewport = SubViewport.new()
	viewport.size = Vector2i(128, 128)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.own_world_3d = true

	EditorInterface.get_base_control().add_child(viewport)

	var instance = packed_scene.instantiate()
	if instance == null:
		viewport.queue_free()
		return PackedByteArray()

	viewport.add_child(instance)

	var is_3d = instance is Node3D or _has_3d_content(instance)

	if is_3d:
		var mesh_info = _get_largest_mesh_aabb(instance)
		var aabb = mesh_info["aabb"]
		var center = aabb.get_center()

		if aabb.size.length() < 0.001:
			var mesh_node = _find_first_mesh(instance)
			if mesh_node:
				center = mesh_node.global_position
				aabb = AABB(center - Vector3.ONE, Vector3.ONE * 2)
			else:
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

	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	var image = viewport.get_texture().get_image()
	viewport.queue_free()

	if image == null or image.is_empty():
		return PackedByteArray()

	image.resize(64, 64, Image.INTERPOLATE_BILINEAR)
	return image.save_png_to_buffer()


func _get_scene_preview_async(scene_path: String, cam_dir: Vector3 = Vector3(1, 0.6, 1).normalized(), zoom_factor: float = 1.0) -> PackedByteArray:
	## Render a scene preview using SubViewport for high quality
	if not ResourceLoader.exists(scene_path):
		return PackedByteArray()

	var packed_scene = load(scene_path) as PackedScene
	if packed_scene == null:
		return PackedByteArray()

	var viewport = SubViewport.new()
	viewport.size = Vector2i(512, 512)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.own_world_3d = true

	EditorInterface.get_base_control().add_child(viewport)

	var instance = packed_scene.instantiate()
	if instance == null:
		viewport.queue_free()
		return PackedByteArray()

	viewport.add_child(instance)

	var is_3d = instance is Node3D or _has_3d_content(instance)

	if is_3d:
		var mesh_info = _get_largest_mesh_aabb(instance)
		var aabb = mesh_info["aabb"]
		var center = aabb.get_center()

		if aabb.size.length() < 0.001:
			var mesh_node = _find_first_mesh(instance)
			if mesh_node:
				center = mesh_node.global_position
				aabb = AABB(center - Vector3.ONE, Vector3.ONE * 2)
			else:
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
	else:
		var cam = Camera2D.new()
		cam.enabled = true
		viewport.add_child(cam)

		var rect = _calculate_2d_bounds(instance)
		if rect.size.length() > 0:
			cam.position = rect.get_center()
			var max_dim = max(rect.size.x, rect.size.y)
			if max_dim > 0:
				cam.zoom = Vector2.ONE * (400.0 / max_dim)

	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	for i in range(5):
		await RenderingServer.frame_post_draw

	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	var image = viewport.get_texture().get_image()
	viewport.queue_free()

	if image == null or image.is_empty():
		return PackedByteArray()

	image.resize(256, 256, Image.INTERPOLATE_LANCZOS)
	return image.save_png_to_buffer()


func _has_3d_content(node: Node) -> bool:
	if node is Node3D:
		return true
	for child in node.get_children():
		if _has_3d_content(child):
			return true
	return false


func _find_first_mesh(node: Node) -> Node3D:
	if node is MeshInstance3D:
		return node
	if node is VisualInstance3D:
		return node
	for child in node.get_children():
		var found = _find_first_mesh(child)
		if found:
			return found
	return null


func _get_largest_mesh_aabb(node: Node) -> Dictionary:
	var result = {"aabb": AABB(), "count": 0, "name": "combined"}
	var flat_result = {"aabb": AABB(), "count": 0, "name": "flat"}

	_collect_mesh_aabbs(node, result, flat_result)

	if result["count"] == 0 and flat_result["count"] > 0:
		return flat_result

	return result


func _collect_mesh_aabbs(node: Node, result: Dictionary, flat_result: Dictionary) -> void:
	if node is MeshInstance3D:
		var local_aabb = node.get_aabb()

		if local_aabb.size.length() < 0.0001:
			return

		var min_dim = min(local_aabb.size.x, min(local_aabb.size.y, local_aabb.size.z))
		var max_dim = max(local_aabb.size.x, max(local_aabb.size.y, local_aabb.size.z))
		var is_flat = max_dim > 0 and min_dim / max_dim < 0.1

		var xform = node.global_transform
		var corners: Array[Vector3] = []
		for i in range(8):
			var corner = local_aabb.get_endpoint(i)
			corners.append(xform * corner)

		var global_aabb = AABB(corners[0], Vector3.ZERO)
		for c in corners:
			global_aabb = global_aabb.expand(c)

		var target = flat_result if is_flat else result
		if target["count"] == 0:
			target["aabb"] = global_aabb
		else:
			target["aabb"] = target["aabb"].merge(global_aabb)
		target["count"] += 1

	for child in node.get_children():
		_collect_mesh_aabbs(child, result, flat_result)


func _calculate_2d_bounds(node: Node) -> Rect2:
	var rect = Rect2()
	var first = true

	if node is Sprite2D and node.texture:
		var size = node.texture.get_size() * node.scale
		rect = Rect2(node.global_position - size / 2, size)
		first = false
	elif node is Control:
		rect = Rect2(node.global_position, node.size)
		first = false

	for child in node.get_children():
		var child_rect = _calculate_2d_bounds(child)
		if child_rect.size.length() > 0:
			if first:
				rect = child_rect
				first = false
			else:
				rect = rect.merge(child_rect)
	return rect


func _get_image_preview_async(image_path: String, size: int = 256) -> PackedByteArray:
	## Generate a preview from an image file (PNG, JPG, WEBP, SVG)
	if not FileAccess.file_exists(image_path):
		return PackedByteArray()

	var img = Image.new()
	var err = img.load(image_path)
	if err != OK:
		return PackedByteArray()

	# Resize to target size while maintaining aspect ratio
	var img_size = img.get_size()
	if img_size.x > size or img_size.y > size:
		var scale_factor = min(float(size) / img_size.x, float(size) / img_size.y)
		var new_size = Vector2i(int(img_size.x * scale_factor), int(img_size.y * scale_factor))
		img.resize(new_size.x, new_size.y, Image.INTERPOLATE_LANCZOS)

	return img.save_png_to_buffer()


func _get_model3d_preview_async(model_path: String, cam_dir: Vector3 = Vector3(1, 0.6, 1).normalized(), zoom_factor: float = 1.0) -> PackedByteArray:
	## Generate a preview for a 3D model file (GLB, GLTF, OBJ, FBX)
	if not ResourceLoader.exists(model_path):
		return PackedByteArray()

	# Load the 3D model
	var resource = load(model_path)
	if resource == null:
		return PackedByteArray()

	var viewport = SubViewport.new()
	viewport.size = Vector2i(512, 512)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.own_world_3d = true

	EditorInterface.get_base_control().add_child(viewport)

	# Create a Node3D to hold the model
	var root_node = Node3D.new()
	viewport.add_child(root_node)

	# Instantiate the model based on resource type
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

	# Calculate AABB for camera positioning
	var mesh_info = _get_largest_mesh_aabb(root_node)
	var aabb = mesh_info["aabb"]
	var center = aabb.get_center()

	if aabb.size.length() < 0.001:
		var mesh_node = _find_first_mesh(root_node)
		if mesh_node:
			center = mesh_node.global_position
			aabb = AABB(center - Vector3.ONE, Vector3.ONE * 2)
		else:
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

	# Render
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	for i in range(5):
		await RenderingServer.frame_post_draw

	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	var image = viewport.get_texture().get_image()
	viewport.queue_free()

	if image == null or image.is_empty():
		return PackedByteArray()

	image.resize(256, 256, Image.INTERPOLATE_LANCZOS)
	return image.save_png_to_buffer()


func _get_model3d_preview_fast(model_path: String, cam_dir: Vector3, zoom_factor: float) -> PackedByteArray:
	## Fast preview generation for 3D models (lower resolution)
	if not ResourceLoader.exists(model_path):
		return PackedByteArray()

	# Load the 3D model
	var resource = load(model_path)
	if resource == null:
		return PackedByteArray()

	var viewport = SubViewport.new()
	viewport.size = Vector2i(128, 128)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.own_world_3d = true

	EditorInterface.get_base_control().add_child(viewport)

	# Create a Node3D to hold the model
	var root_node = Node3D.new()
	viewport.add_child(root_node)

	# Instantiate the model based on resource type
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

	# Calculate AABB for camera positioning
	var mesh_info = _get_largest_mesh_aabb(root_node)
	var aabb = mesh_info["aabb"]
	var center = aabb.get_center()

	if aabb.size.length() < 0.001:
		var mesh_node = _find_first_mesh(root_node)
		if mesh_node:
			center = mesh_node.global_position
			aabb = AABB(center - Vector3.ONE, Vector3.ONE * 2)
		else:
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

	image.resize(64, 64, Image.INTERPOLATE_BILINEAR)
	return image.save_png_to_buffer()