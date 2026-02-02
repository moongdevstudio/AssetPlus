@tool
extends EditorContextMenuPlugin

## Context menu plugin for FileSystem dock - adds AssetPlus options

const ExportDialog = preload("res://addons/assetplus/ui/export_dialog.gd")
const SettingsDialog = preload("res://addons/assetplus/ui/settings_dialog.gd")
const DependencyDetector = preload("res://addons/assetplus/dependency_detector.gd")

# File extensions that can have dependencies detected
const DEPENDENCY_EXTENSIONS = ["tscn", "scn", "tres", "res", "gd"]

# All file extensions that can be exported as assets
const EXPORTABLE_EXTENSIONS = [
	"tscn", "scn", "tres", "res", "gd",  # Godot files with potential dependencies
	"png", "jpg", "jpeg", "webp", "svg", "bmp", "tga",  # Images
	"glb", "gltf", "obj", "fbx", "dae", "blend",  # 3D models
	"wav", "ogg", "mp3",  # Audio
	"ttf", "otf", "woff", "woff2",  # Fonts
	"gdshader", "shader",  # Shaders
	"json", "cfg", "txt", "md"  # Config/text
]

var _selected_paths: PackedStringArray


func _popup_menu(paths: PackedStringArray) -> void:
	_selected_paths = paths

	if paths.is_empty():
		return

	var theme = EditorInterface.get_editor_theme()

	# Check what's in the selection
	var has_folder = false
	var has_dependency_file = false  # Files that can have dependencies (scenes, scripts, etc.)
	var has_exportable_file = false  # Any file that can be exported

	for path in paths:
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)):
			has_folder = true
		else:
			var ext = path.get_extension().to_lower()
			if ext in DEPENDENCY_EXTENSIONS:
				has_dependency_file = true
				has_exportable_file = true
			elif ext in EXPORTABLE_EXTENSIONS:
				has_exportable_file = true

	# Add "Export as .godotpackage" for folders
	if has_folder:
		var export_icon = theme.get_icon("Save", "EditorIcons")
		add_context_menu_item("Export as .godotpackage", _on_export_package, export_icon)

	# Add "Save as Asset" for individual files
	if has_exportable_file and not has_folder:
		var asset_icon = theme.get_icon("PackedScene", "EditorIcons")
		if has_dependency_file:
			add_context_menu_item("Save as Asset (with dependencies)", _on_save_as_asset, asset_icon)
		else:
			add_context_menu_item("Save as Asset", _on_save_as_asset, asset_icon)


func _on_export_package(_callback_data: Variant = null) -> void:
	if _selected_paths.is_empty():
		return

	# Collect all selected folders
	var folder_paths: Array[String] = []
	for path in _selected_paths:
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)):
			folder_paths.append(path)

	if folder_paths.is_empty():
		return

	# Check if global folder is configured
	var settings = SettingsDialog.get_settings()
	var global_folder = settings.get("global_asset_folder", "")

	if not global_folder.is_empty():
		# Ask if user wants to export to global folder
		var confirm = ConfirmationDialog.new()
		confirm.title = "Export to Global Folder?"
		confirm.dialog_text = "Do you want to export directly to your Global Folder?\n\n%s" % global_folder
		confirm.ok_button_text = "Yes, to Global Folder"
		confirm.cancel_button_text = "No, choose location"

		confirm.confirmed.connect(func():
			confirm.queue_free()
			_export_to_global_folder(folder_paths[0], global_folder)
		)

		confirm.canceled.connect(func():
			confirm.queue_free()
			_export_normal_multiple(folder_paths)
		)

		EditorInterface.get_base_control().add_child(confirm)
		confirm.popup_centered()
	else:
		# No global folder configured, just do normal export
		_export_normal_multiple(folder_paths)


func _export_to_global_folder(folder_path: String, global_folder: String) -> void:
	var dialog = ExportDialog.new()
	EditorInterface.get_base_control().add_child(dialog)
	dialog.setup_for_global_folder(folder_path, global_folder)
	dialog.popup_centered()


func _export_normal(folder_path: String) -> void:
	var dialog = ExportDialog.new()
	EditorInterface.get_base_control().add_child(dialog)
	dialog.setup(folder_path)
	dialog.popup_centered()


func _export_normal_multiple(folder_paths: Array[String]) -> void:
	var dialog = ExportDialog.new()
	EditorInterface.get_base_control().add_child(dialog)
	if folder_paths.size() == 1:
		dialog.setup(folder_paths[0])
	else:
		dialog.setup_multiple_folders(folder_paths)
	dialog.popup_centered()


func _on_save_as_asset(_callback_data: Variant = null) -> void:
	## Save selected file(s) as asset with automatic dependency detection
	if _selected_paths.is_empty():
		return

	# Collect all selected exportable files
	var files_to_export: Array[String] = []
	var files_with_deps: Array[String] = []  # Files that can have dependencies

	for path in _selected_paths:
		var ext = path.get_extension().to_lower()
		if ext in EXPORTABLE_EXTENSIONS:
			files_to_export.append(path)
			if ext in DEPENDENCY_EXTENSIONS:
				files_with_deps.append(path)

	if files_to_export.is_empty():
		return

	# Detect dependencies only for files that can have them
	var all_dependencies: Array[String] = []
	var dep_info: Dictionary = {}  # file -> its direct deps for display

	# First add all selected files
	for file_path in files_to_export:
		if file_path not in all_dependencies:
			all_dependencies.append(file_path)

	# Then detect dependencies for files that support it
	for file_path in files_with_deps:
		var info = DependencyDetector.get_dependencies_info(file_path)
		dep_info[file_path] = info.get("direct_deps", [])

		# Add all its dependencies
		for dep in info.get("all_deps", []):
			if dep not in all_dependencies:
				all_dependencies.append(dep)

	# Check for missing dependencies
	var missing: Array[String] = []
	for dep in all_dependencies:
		if not FileAccess.file_exists(dep):
			missing.append(dep)

	# Check if global folder is configured
	var settings = SettingsDialog.get_settings()
	var global_folder = settings.get("global_asset_folder", "")

	if not global_folder.is_empty():
		# Ask if user wants to export to global folder
		_show_save_as_asset_dialog(files_to_export, all_dependencies, missing, dep_info, global_folder)
	else:
		_show_save_as_asset_dialog(files_to_export, all_dependencies, missing, dep_info, "")


func _show_save_as_asset_dialog(
	main_files: Array[String],
	all_files: Array[String],
	missing: Array[String],
	dep_info: Dictionary,
	global_folder: String
) -> void:
	## Show a dialog letting user review dependencies before exporting
	var dialog = AcceptDialog.new()
	dialog.title = "Save as Asset"
	dialog.size = Vector2i(600, 700)
	dialog.ok_button_text = "Export"

	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 10)
	dialog.add_child(main_vbox)

	# Header
	var header = Label.new()
	var main_file_name = main_files[0].get_file() if main_files.size() == 1 else "%d files" % main_files.size()
	header.text = "Exporting: %s" % main_file_name
	header.add_theme_font_size_override("font_size", 16)
	main_vbox.add_child(header)

	# Dependency count
	var dep_count = all_files.size() - main_files.size()
	var dep_label = Label.new()
	if dep_count > 0:
		dep_label.text = "Found %d dependencies (total %d files)" % [dep_count, all_files.size()]
		dep_label.add_theme_color_override("font_color", Color(0.5, 0.8, 0.5))
	else:
		dep_label.text = "No external dependencies found"
		dep_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	main_vbox.add_child(dep_label)

	# Warning for missing files
	if missing.size() > 0:
		var warning = Label.new()
		warning.text = "⚠ %d dependencies are missing and will be skipped" % missing.size()
		warning.add_theme_color_override("font_color", Color(1, 0.7, 0.3))
		main_vbox.add_child(warning)

	main_vbox.add_child(HSeparator.new())

	# File list in scroll
	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	main_vbox.add_child(scroll)

	var file_vbox = VBoxContainer.new()
	file_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(file_vbox)

	# Categorize files
	var categories = DependencyDetector.categorize_files(all_files)
	var cat_order = ["Scenes", "Scripts", "Resources", "Shaders", "Textures", "3D Models", "Audio", "Fonts", "Config/Text", "Other"]

	for cat_name in cat_order:
		if not categories.has(cat_name):
			continue
		var cat_files: Array = categories[cat_name]

		# Category header
		var cat_header = Label.new()
		cat_header.text = "%s (%d)" % [cat_name, cat_files.size()]
		cat_header.add_theme_font_size_override("font_size", 13)
		cat_header.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
		file_vbox.add_child(cat_header)

		# Files
		for file_path in cat_files:
			var file_hbox = HBoxContainer.new()
			file_hbox.add_theme_constant_override("separation", 8)
			file_vbox.add_child(file_hbox)

			# Indent
			var spacer = Control.new()
			spacer.custom_minimum_size.x = 16
			file_hbox.add_child(spacer)

			# Status icon
			var status = Label.new()
			if file_path in missing:
				status.text = "✗"
				status.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
			elif file_path in main_files:
				status.text = "★"  # Main file
				status.add_theme_color_override("font_color", Color(1, 0.9, 0.3))
			else:
				status.text = "✓"
				status.add_theme_color_override("font_color", Color(0.5, 0.8, 0.5))
			file_hbox.add_child(status)

			# File path
			var path_label = Label.new()
			path_label.text = file_path.replace("res://", "")
			path_label.add_theme_font_size_override("font_size", 12)
			if file_path in missing:
				path_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			file_hbox.add_child(path_label)

	main_vbox.add_child(HSeparator.new())

	# Find all previewable assets (scenes, 3D models, materials, images)
	var scenes: Array[String] = []
	var models_3d: Array[String] = []
	var materials: Array[String] = []
	var images: Array[String] = []

	for f in all_files:
		var ext = f.get_extension().to_lower()
		if ext in ["tscn", "scn"]:
			scenes.append(f)
		elif ext in ["glb", "gltf", "obj", "fbx"]:
			models_3d.append(f)
		elif ext in ["tres", "res"]:
			# Check if it's a material
			if _is_material_resource(f):
				materials.append(f)
		elif ext in ["png", "jpg", "jpeg", "webp", "svg"]:
			images.append(f)

	# Sort scenes: prioritize main_files, then by name length (shorter = likely main asset)
	scenes.sort_custom(func(a, b):
		var a_main = a in main_files
		var b_main = b in main_files
		if a_main != b_main:
			return a_main  # main files first
		return a.get_file().length() < b.get_file().length()
	)

	# Sort 3D models: prioritize main_files, then by name length
	models_3d.sort_custom(func(a, b):
		var a_main = a in main_files
		var b_main = b in main_files
		if a_main != b_main:
			return a_main
		return a.get_file().length() < b.get_file().length()
	)

	# Sort images: prioritize main_files, then by name length
	images.sort_custom(func(a, b):
		var a_main = a in main_files
		var b_main = b in main_files
		if a_main != b_main:
			return a_main
		return a.get_file().length() < b.get_file().length()
	)

	# Use dictionary so closure can modify it (primitives aren't captured by reference)
	var thumb_state = {"selected_angle": 0, "selected_source": 0}

	# Build list of thumbnail sources - priority: scenes > 3D models > materials > images
	var thumb_sources: Array[Dictionary] = []
	for s in scenes:
		thumb_sources.append({"path": s, "type": "scene", "name": s.get_file()})
	for m in models_3d:
		thumb_sources.append({"path": m, "type": "model3d", "name": m.get_file()})
	for m in materials:
		thumb_sources.append({"path": m, "type": "material", "name": m.get_file()})
	for img in images:
		thumb_sources.append({"path": img, "type": "image", "name": img.get_file()})

	var thumb_options = [
		{"name": "Isometric", "dir": Vector3(1, 0.6, 1).normalized(), "zoom": 0.6},
		{"name": "Front", "dir": Vector3(0, 0, 1), "zoom": 0.45},
		{"name": "Side", "dir": Vector3(1, 0, 0), "zoom": 0.45},
		{"name": "Top", "dir": Vector3(0, 1, 0.01).normalized(), "zoom": 0.6},
		{"name": "3/4 View", "dir": Vector3(1, 0.3, 0.5).normalized(), "zoom": 0.5},
	]

	var current_source_path = thumb_sources[0]["path"] if thumb_sources.size() > 0 else ""
	var current_source_type = thumb_sources[0]["type"] if thumb_sources.size() > 0 else ""
	var thumb_buttons: Array[Button] = []

	if thumb_sources.size() > 0:
		# Source selector (if multiple sources available)
		if thumb_sources.size() > 1:
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

			source_option.item_selected.connect(func(idx: int):
				thumb_state["selected_source"] = idx
				current_source_path = thumb_sources[idx]["path"]
				current_source_type = thumb_sources[idx]["type"]
				# Regenerate previews for new source
				_generate_thumbnail_previews_for_source(
					thumb_sources[idx], thumb_options, thumb_buttons
				)
			)

		# Angle selector (only relevant for scenes and 3D models)
		var thumb_label = Label.new()
		thumb_label.text = "Thumbnail angle:" if current_source_type in ["scene", "model3d"] else "Thumbnail:"
		main_vbox.add_child(thumb_label)

		var thumb_hbox = HBoxContainer.new()
		thumb_hbox.add_theme_constant_override("separation", 8)
		thumb_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
		main_vbox.add_child(thumb_hbox)

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

		# Generate thumbnails asynchronously
		_generate_thumbnail_previews_for_source(thumb_sources[0], thumb_options, thumb_buttons)

	main_vbox.add_child(HSeparator.new())

	# Export location option
	var export_hbox = HBoxContainer.new()
	export_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(export_hbox)

	var location_label = Label.new()
	location_label.text = "Export to:"
	export_hbox.add_child(location_label)

	var location_option = OptionButton.new()
	location_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not global_folder.is_empty():
		location_option.add_item("Global Folder (%s)" % global_folder.get_file(), 0)
	location_option.add_item("Choose location...", 1)
	export_hbox.add_child(location_option)

	# Store data for export
	var export_data = {
		"files": all_files,
		"missing": missing,
		"main_files": main_files,
		"global_folder": global_folder,
		"location_option": location_option,
		"thumb_sources": thumb_sources,
		"thumb_options": thumb_options,
		"get_selected_angle": func(): return thumb_state["selected_angle"],
		"get_selected_source": func(): return thumb_state["selected_source"]
	}

	dialog.confirmed.connect(func():
		var selected = location_option.selected
		var use_global = (selected == 0 and not global_folder.is_empty())
		_do_save_as_asset(export_data, use_global)
		dialog.queue_free()
	)

	dialog.canceled.connect(func():
		dialog.queue_free()
	)

	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func _do_save_as_asset(export_data: Dictionary, use_global_folder: bool) -> void:
	## Actually export the files as a .godotpackage
	var files: Array = export_data.get("files", [])
	var missing: Array = export_data.get("missing", [])
	var main_files: Array = export_data.get("main_files", [])
	var global_folder: String = export_data.get("global_folder", "")

	# Get thumbnail settings
	var thumb_options: Array = export_data.get("thumb_options", [])
	var thumb_sources: Array = export_data.get("thumb_sources", [])
	var get_selected_angle = export_data.get("get_selected_angle", null)
	var get_selected_source = export_data.get("get_selected_source", null)

	var selected_angle = 0
	if get_selected_angle is Callable:
		selected_angle = get_selected_angle.call()

	var selected_source_idx = 0
	if get_selected_source is Callable:
		selected_source_idx = get_selected_source.call()

	var cam_dir = Vector3(1, 0.6, 1).normalized()
	var zoom_factor = 1.0
	if selected_angle < thumb_options.size():
		cam_dir = thumb_options[selected_angle].get("dir", cam_dir)
		zoom_factor = thumb_options[selected_angle].get("zoom", 1.0)

	var thumb_source: Dictionary = {}
	if selected_source_idx < thumb_sources.size():
		thumb_source = thumb_sources[selected_source_idx]

	# Filter out missing files
	var valid_files: Array[String] = []
	for f in files:
		if f not in missing:
			valid_files.append(f)

	if valid_files.is_empty():
		return

	# Determine package name from main file
	var package_name = main_files[0].get_file().get_basename() if main_files.size() > 0 else "asset"

	if use_global_folder and not global_folder.is_empty():
		# Export directly to global folder - check if package already exists
		var output_path = global_folder.path_join(package_name + ".godotpackage")
		if FileAccess.file_exists(output_path):
			_show_asset_replace_confirmation(valid_files, main_files, global_folder, package_name, thumb_source, cam_dir, zoom_factor)
		else:
			_create_asset_package(valid_files, main_files, global_folder, package_name, thumb_source, cam_dir, zoom_factor)
	else:
		# Open file dialog to choose location
		var file_dialog = FileDialog.new()
		file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		file_dialog.filters = ["*.godotpackage ; Godot Package"]
		file_dialog.current_file = package_name + ".godotpackage"
		file_dialog.title = "Save Asset Package"

		file_dialog.file_selected.connect(func(path: String):
			_create_asset_package(valid_files, main_files, path.get_base_dir(), path.get_file().get_basename(), thumb_source, cam_dir, zoom_factor)
			file_dialog.queue_free()
		)

		file_dialog.canceled.connect(func():
			file_dialog.queue_free()
		)

		EditorInterface.get_base_control().add_child(file_dialog)
		file_dialog.popup_centered(Vector2i(600, 400))


func _show_asset_replace_confirmation(
	files: Array[String],
	main_files: Array,
	output_dir: String,
	package_name: String,
	thumb_source: Dictionary,
	cam_dir: Vector3,
	zoom_factor: float
) -> void:
	## Show confirmation dialog when a package with the same name already exists
	var confirm = ConfirmationDialog.new()
	confirm.title = "Package Already Exists"
	confirm.dialog_text = "A package named '%s' already exists in the global folder.\n\nDo you want to replace it?" % package_name
	confirm.ok_button_text = "Replace"
	confirm.cancel_button_text = "Cancel"

	confirm.confirmed.connect(func():
		confirm.queue_free()
		_create_asset_package(files, main_files, output_dir, package_name, thumb_source, cam_dir, zoom_factor)
	)

	confirm.canceled.connect(func():
		confirm.queue_free()
	)

	EditorInterface.get_base_control().add_child(confirm)
	confirm.popup_centered()


func _create_asset_package(
	files: Array[String],
	main_files: Array,
	output_dir: String,
	package_name: String,
	thumb_source: Dictionary = {},
	cam_dir: Vector3 = Vector3(1, 0.6, 1).normalized(),
	zoom_factor: float = 1.0
) -> void:
	## Create the .godotpackage file
	## Uses coroutine for async thumbnail generation
	await _create_asset_package_async(files, main_files, output_dir, package_name, thumb_source, cam_dir, zoom_factor)


func _create_asset_package_async(
	files: Array[String],
	main_files: Array,
	output_dir: String,
	package_name: String,
	thumb_source: Dictionary = {},
	cam_dir: Vector3 = Vector3(1, 0.6, 1).normalized(),
	zoom_factor: float = 1.0
) -> void:
	## Create the .godotpackage file (async for thumbnail generation)
	var output_path = output_dir.path_join(package_name + ".godotpackage")

	# Create ZIP
	var zip = ZIPPacker.new()
	var err = zip.open(output_path)
	if err != OK:
		push_error("AssetPlus: Failed to create package at %s" % output_path)
		return

	# Find the common root folder of all files (to avoid empty parent folders)
	var common_root = _find_common_root_folder(files)

	# Use res:// structure to preserve paths for dependencies
	# This ensures that when extracted, scenes can find their dependencies
	var pack_root = package_name + "/"

	# Get OS username as default author
	var default_author = OS.get_environment("USERNAME")  # Windows
	if default_author.is_empty():
		default_author = OS.get_environment("USER")  # Linux/macOS

	var manifest = {
		"name": package_name,
		"version": "1.0.0",
		"author": default_author,
		"description": "Asset exported with dependencies",
		"type": "asset",
		"pack_root": pack_root,
		"common_root": common_root,  # The common root that was stripped
		"preserve_structure": true,  # Flag to indicate res:// structure is preserved
		"files": [],
		"main_files": []
	}

	# Store main_files with their paths relative to common_root
	for mf in main_files:
		var rel = mf
		if mf.begins_with("res://"):
			rel = mf.substr(6)  # Remove "res://"
		# Strip common_root prefix
		if not common_root.is_empty() and rel.begins_with(common_root):
			rel = rel.substr(common_root.length())
		manifest["main_files"].append(rel)

	# Try to capture a thumbnail
	var icon_data: PackedByteArray = []

	# First look for explicit icon files
	icon_data = _find_thumbnail_in_files(files)

	# If no icon found, use the selected thumbnail source
	if icon_data.is_empty() and not thumb_source.is_empty():
		var source_path = thumb_source.get("path", "")
		var source_type = thumb_source.get("type", "")
		match source_type:
			"scene":
				icon_data = await _get_scene_preview_async(source_path, cam_dir, zoom_factor)
			"model3d":
				icon_data = await _get_model3d_preview_async(source_path, cam_dir, zoom_factor)
			"material":
				icon_data = await _get_material_preview_async(source_path)
			"image":
				icon_data = await _get_image_preview_async(source_path, 256)

	# Fallback: try to find any previewable asset in files
	if icon_data.is_empty():
		for file_path in files:
			var ext = file_path.get_extension().to_lower()
			if ext in ["tscn", "scn"]:
				icon_data = await _get_scene_preview_async(file_path, cam_dir, zoom_factor)
				if not icon_data.is_empty():
					break
			elif ext in ["glb", "gltf", "obj", "fbx"]:
				icon_data = await _get_model3d_preview_async(file_path, cam_dir, zoom_factor)
				if not icon_data.is_empty():
					break
			elif ext in ["png", "jpg", "jpeg", "webp", "svg"]:
				icon_data = await _get_image_preview_async(file_path, 256)
				if not icon_data.is_empty():
					break

	# Add files - preserve res:// structure for dependency resolution
	# but strip the common_root to avoid empty parent folders
	for file_path in files:
		if not FileAccess.file_exists(file_path):
			continue

		var file = FileAccess.open(file_path, FileAccess.READ)
		if not file:
			continue

		var content = file.get_buffer(file.get_length())
		file.close()

		# Use res:// path structure (without the res:// prefix)
		var rel_path = file_path
		if file_path.begins_with("res://"):
			rel_path = file_path.substr(6)  # Remove "res://"

		# Strip common_root prefix to avoid empty parent folders
		if not common_root.is_empty() and rel_path.begins_with(common_root):
			rel_path = rel_path.substr(common_root.length())

		# Store in ZIP under package_name folder
		var zip_path = pack_root + rel_path
		zip.start_file(zip_path)
		zip.write_file(content)
		zip.close_file()

		manifest["files"].append(rel_path)

	# Add icon if captured
	if not icon_data.is_empty():
		zip.start_file("icon.png")
		zip.write_file(icon_data)
		zip.close_file()

	# Add manifest
	var manifest_json = JSON.stringify(manifest, "\t")
	zip.start_file("manifest.json")
	zip.write_file(manifest_json.to_utf8_buffer())
	zip.close_file()

	zip.close()

	SettingsDialog.debug_print("AssetPlus: Created asset package at %s with %d files" % [output_path, files.size()])

	# Show success message
	var success_dialog = AcceptDialog.new()
	success_dialog.title = "Export Complete"
	success_dialog.dialog_text = "Asset package created successfully!\n\n%s\n\n%d files included" % [output_path, files.size()]
	success_dialog.confirmed.connect(func(): success_dialog.queue_free())
	EditorInterface.get_base_control().add_child(success_dialog)
	success_dialog.popup_centered()


# Store pending thumbnail requests
var _pending_thumbnail_path: String = ""
var _pending_thumbnail_data: PackedByteArray = PackedByteArray()
var _thumbnail_ready: bool = false


func _generate_thumbnail_previews_for_source(source: Dictionary, thumb_options: Array, thumb_buttons: Array[Button]) -> void:
	## Generate thumbnail previews for each angle option (async)
	## Supports scenes, 3D models (multiple angles), materials and images (single preview)
	var source_path = source.get("path", "")
	var source_type = source.get("type", "scene")

	if source_type in ["material", "image"]:
		# For materials and images, generate one preview and show it on all buttons
		var png_data: PackedByteArray
		if source_type == "material":
			png_data = await _get_material_preview_fast(source_path)
		else:
			png_data = await _get_image_preview_async(source_path, 128)

		for i in range(thumb_buttons.size()):
			if not is_instance_valid(thumb_buttons[i]):
				return
			if not png_data.is_empty():
				var img = Image.new()
				if img.load_png_from_buffer(png_data) == OK:
					var tex = ImageTexture.create_from_image(img)
					thumb_buttons[i].icon = tex
					thumb_buttons[i].text = ""
					thumb_buttons[i].expand_icon = true
			else:
				thumb_buttons[i].text = source_type.substr(0, 3).capitalize()
	else:
		# For scenes and 3D models, generate preview for each angle
		for i in range(thumb_options.size()):
			if not is_instance_valid(thumb_buttons[i]):
				return
			var opt = thumb_options[i]
			var cam_dir: Vector3 = opt.get("dir", Vector3(1, 0.6, 1).normalized())
			var zoom: float = opt.get("zoom", 1.0)

			var png_data: PackedByteArray
			if source_type == "model3d":
				png_data = await _get_model3d_preview_fast(source_path, cam_dir, zoom)
			else:
				png_data = await _get_scene_preview_fast(source_path, cam_dir, zoom)

			if not is_instance_valid(thumb_buttons[i]):
				return
			if not png_data.is_empty():
				var img = Image.new()
				if img.load_png_from_buffer(png_data) == OK:
					var tex = ImageTexture.create_from_image(img)
					thumb_buttons[i].icon = tex
					thumb_buttons[i].text = ""
					thumb_buttons[i].expand_icon = true
			else:
				thumb_buttons[i].text = opt["name"].substr(0, 3)


func _is_material_resource(file_path: String) -> bool:
	## Check if a .tres/.res file is a material
	if not FileAccess.file_exists(file_path):
		return false
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return false
	# Read first few lines to check resource type
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

	# Create viewport
	var viewport = SubViewport.new()
	viewport.size = Vector2i(size, size)
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

	# Smaller viewport for faster rendering
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

	# Faster: only 2 frames instead of 5
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	var image = viewport.get_texture().get_image()
	viewport.queue_free()

	if image == null or image.is_empty():
		return PackedByteArray()

	# Already small, just resize to 64x64 for button
	image.resize(64, 64, Image.INTERPOLATE_BILINEAR)
	return image.save_png_to_buffer()


func _get_scene_preview_async(scene_path: String, cam_dir: Vector3 = Vector3(1, 0.6, 1).normalized(), zoom_factor: float = 1.0) -> PackedByteArray:
	## Render a scene preview using SubViewport for high quality
	## Uses same camera positioning as Godot's EditorMeshPreviewPlugin
	## cam_dir: Direction from which the camera looks at the object
	## zoom_factor: Multiplier for camera distance (lower = closer)
	## Returns PNG data or empty array

	if not ResourceLoader.exists(scene_path):
		return PackedByteArray()

	var packed_scene = load(scene_path) as PackedScene
	if packed_scene == null:
		return PackedByteArray()

	# Create SubViewport for rendering
	var viewport = SubViewport.new()
	viewport.size = Vector2i(512, 512)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.own_world_3d = true  # Isolate 3D rendering

	EditorInterface.get_base_control().add_child(viewport)

	# Instantiate scene
	var instance = packed_scene.instantiate()
	if instance == null:
		viewport.queue_free()
		return PackedByteArray()

	viewport.add_child(instance)

	# Detect if 3D or 2D
	var is_3d = instance is Node3D or _has_3d_content(instance)

	if is_3d:
		# Combine all MeshInstance3D AABBs to get the full scene bounds
		var mesh_info = _get_largest_mesh_aabb(instance)
		var aabb = mesh_info["aabb"]
		var center = aabb.get_center()

		# Still empty? Use defaults
		if aabb.size.length() < 0.001:
			var mesh_node = _find_first_mesh(instance)
			if mesh_node:
				center = mesh_node.global_position
				aabb = AABB(center - Vector3.ONE, Vector3.ONE * 2)
			else:
				center = Vector3.ZERO
				aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))

		# Camera framing formula: distance = (size * margin) / sin(FOV / 2)
		var fov = 50.0
		var margin = 1.2  # 20% padding
		var max_extent = aabb.get_longest_axis_size()
		var dist = (max_extent * margin) / sin(deg_to_rad(fov / 2.0))
		dist = max(dist, 1.0)  # Minimum distance
		dist *= zoom_factor  # Apply zoom factor

		# Position camera based on cam_dir parameter
		var cam_pos = center + cam_dir * dist

		# Create camera and add to tree BEFORE calling look_at
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
	else:
		# Setup 2D camera
		var cam = Camera2D.new()
		cam.enabled = true
		viewport.add_child(cam)

		var rect = _calculate_2d_bounds(instance)
		if rect.size.length() > 0:
			cam.position = rect.get_center()
			var max_dim = max(rect.size.x, rect.size.y)
			if max_dim > 0:
				cam.zoom = Vector2.ONE * (400.0 / max_dim)

	# Force multiple render updates to ensure scene is fully loaded
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	# Wait several frames for everything to be ready
	for i in range(5):
		await RenderingServer.frame_post_draw

	# Now capture
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	var image = viewport.get_texture().get_image()
	viewport.queue_free()

	if image == null or image.is_empty():
		return PackedByteArray()

	# Resize to final icon size
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
	## Find the first MeshInstance3D or VisualInstance3D in the tree
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
	## Combine all MeshInstance3D AABBs, excluding flat objects (floors/walls)
	## If only flat objects exist, include them
	var result = {"aabb": AABB(), "count": 0, "name": "combined"}
	var flat_result = {"aabb": AABB(), "count": 0, "name": "flat"}

	_collect_mesh_aabbs(node, result, flat_result)

	# If no non-flat meshes found, use flat ones
	if result["count"] == 0 and flat_result["count"] > 0:
		return flat_result

	return result


func _collect_mesh_aabbs(node: Node, result: Dictionary, flat_result: Dictionary) -> void:
	# Only consider actual MeshInstance3D, not lights or other VisualInstance3D
	if node is MeshInstance3D:
		var local_aabb = node.get_aabb()

		# Skip if AABB is empty/invalid
		if local_aabb.size.length() < 0.0001:
			return

		# Check if flat (one dimension is < 10% of the largest)
		var min_dim = min(local_aabb.size.x, min(local_aabb.size.y, local_aabb.size.z))
		var max_dim = max(local_aabb.size.x, max(local_aabb.size.y, local_aabb.size.z))
		var is_flat = max_dim > 0 and min_dim / max_dim < 0.1

		# Transform to global space
		var xform = node.global_transform
		var corners: Array[Vector3] = []
		for i in range(8):
			var corner = local_aabb.get_endpoint(i)
			corners.append(xform * corner)

		var global_aabb = AABB(corners[0], Vector3.ZERO)
		for c in corners:
			global_aabb = global_aabb.expand(c)

		# Add to appropriate result
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


func _find_thumbnail_in_files(files: Array[String]) -> PackedByteArray:
	## Search through the file list to find a suitable thumbnail
	## Only uses explicitly named icon files - doesn't grab random textures

	# Only look for specifically named icons - don't grab random textures
	var priority_names = ["icon.png", "thumbnail.png", "preview.png", "cover.png", "logo.png", "icon.svg"]
	for file_path in files:
		var file_name = file_path.get_file().to_lower()
		if file_name in priority_names:
			var data = _read_and_convert_image(file_path)
			if data.size() > 0:
				return data

	# Also check for icon in addon folders (plugin icon)
	for file_path in files:
		if file_path.ends_with("/icon.png") or file_path.ends_with("/icon.svg"):
			var data = _read_and_convert_image(file_path)
			if data.size() > 0:
				return data

	return PackedByteArray()


func _read_and_convert_image(image_path: String) -> PackedByteArray:
	## Read an image file and return PNG data
	## Handles PNG directly, converts SVG to PNG
	var ext = image_path.get_extension().to_lower()

	if ext == "png":
		var file = FileAccess.open(image_path, FileAccess.READ)
		if file:
			var data = file.get_buffer(file.get_length())
			file.close()
			return data

	elif ext == "svg":
		# Load SVG and convert to PNG
		var img = Image.new()
		var err = img.load(image_path)
		if err == OK:
			# Resize to reasonable icon size
			if img.get_width() > 256 or img.get_height() > 256:
				img.resize(256, 256, Image.INTERPOLATE_LANCZOS)
			return img.save_png_to_buffer()

	elif ext in ["jpg", "jpeg", "webp"]:
		# Load and convert to PNG
		var img = Image.new()
		var err = img.load(image_path)
		if err == OK:
			if img.get_width() > 256 or img.get_height() > 256:
				img.resize(256, 256, Image.INTERPOLATE_LANCZOS)
			return img.save_png_to_buffer()

	return PackedByteArray()


func _find_common_base(paths: Array[String]) -> String:
	## Find the common base directory for a set of paths
	if paths.is_empty():
		return "res://"

	# Start with first path's directory
	var common = paths[0].get_base_dir()

	for path in paths:
		var dir = path.get_base_dir()
		# Go up until we find a common ancestor
		while not dir.begins_with(common + "/") and dir != common and common != "res://" and common != "res:":
			common = common.get_base_dir()
			if common == "res://":
				break

	# Ensure trailing slash for consistency
	if not common.ends_with("/"):
		common += "/"

	return common


func _find_common_root_folder(files: Array[String]) -> String:
	## Find the common root folder that can be stripped from all file paths
	## Returns the path prefix to strip (without res://, with trailing slash)
	## Example: if all files are under "res://Packages/MyPack/Folder/", returns "Packages/MyPack/Folder/"
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
	# Split first path into components
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
	## Generate a high-quality preview for a 3D model file (GLB, GLTF, OBJ, FBX)
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

	# Render (more frames for high quality)
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
