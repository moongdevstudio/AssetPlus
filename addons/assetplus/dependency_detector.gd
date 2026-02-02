@tool
class_name DependencyDetector
extends RefCounted

## Utility class to detect file dependencies in Godot projects
## Parses .tscn, .tres, .gd files to find referenced resources

const MAX_DEPTH = 10  # Maximum recursion depth to prevent infinite loops


static func get_all_dependencies(file_path: String, include_self: bool = true, include_import_files: bool = false) -> Array[String]:
	## Get all dependencies for a file, recursively
	## Returns array of absolute res:// paths
	## If include_import_files is true, also includes .import files for textures/assets
	var visited: Dictionary = {}
	var result: Array[String] = []

	if include_self and FileAccess.file_exists(file_path):
		result.append(file_path)
		visited[file_path] = true

	_collect_dependencies_recursive(file_path, visited, result, 0)

	# Optionally include .import files
	if include_import_files:
		var import_files: Array[String] = []
		for dep in result:
			var import_path = dep + ".import"
			if FileAccess.file_exists(import_path) and import_path not in result:
				import_files.append(import_path)
		result.append_array(import_files)

	return result


static func get_direct_dependencies(file_path: String) -> Array[String]:
	## Get only direct (first-level) dependencies for a file
	## Returns array of absolute res:// paths
	var ext = file_path.get_extension().to_lower()

	match ext:
		"tscn", "scn":
			return _get_scene_dependencies(file_path)
		"tres", "res":
			return _get_resource_dependencies(file_path)
		"gd":
			return _get_script_dependencies(file_path)
		_:
			return []


static func _collect_dependencies_recursive(
	file_path: String,
	visited: Dictionary,
	result: Array[String],
	depth: int
) -> void:
	if depth > MAX_DEPTH:
		return

	var deps = get_direct_dependencies(file_path)

	for dep in deps:
		if visited.has(dep):
			continue

		visited[dep] = true

		# Only add if file exists
		if FileAccess.file_exists(dep):
			result.append(dep)
			# Recursively get dependencies of this dependency
			_collect_dependencies_recursive(dep, visited, result, depth + 1)


static func _get_scene_dependencies(file_path: String) -> Array[String]:
	## Parse .tscn file and extract all ext_resource paths
	var dependencies: Array[String] = []

	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return dependencies

	var content = file.get_as_text()
	file.close()

	# Pattern: [ext_resource type="..." path="res://..." ...]
	var regex = RegEx.new()
	regex.compile('\\[ext_resource[^\\]]*path\\s*=\\s*"([^"]+)"')

	var matches = regex.search_all(content)
	for match in matches:
		var path = match.get_string(1)
		if path.begins_with("res://"):
			dependencies.append(path)

	# Also check for load() calls in embedded scripts
	var load_regex = RegEx.new()
	load_regex.compile('(?:load|preload)\\s*\\(\\s*["\']([^"\']+)["\']')

	matches = load_regex.search_all(content)
	for match in matches:
		var path = match.get_string(1)
		var resolved = _resolve_path(path, file_path)
		if not resolved.is_empty() and resolved not in dependencies:
			dependencies.append(resolved)

	return dependencies


static func _get_resource_dependencies(file_path: String) -> Array[String]:
	## Parse .tres/.res file and extract all ext_resource paths
	var dependencies: Array[String] = []

	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return dependencies

	var content = file.get_as_text()
	file.close()

	# Same pattern as scenes for text resources
	var regex = RegEx.new()
	regex.compile('\\[ext_resource[^\\]]*path\\s*=\\s*"([^"]+)"')

	var matches = regex.search_all(content)
	for match in matches:
		var path = match.get_string(1)
		if path.begins_with("res://"):
			dependencies.append(path)

	# Also check for path= in resource properties (e.g., Texture2D references)
	var path_regex = RegEx.new()
	path_regex.compile('path\\s*=\\s*"(res://[^"]+)"')

	matches = path_regex.search_all(content)
	for match in matches:
		var path = match.get_string(1)
		if path not in dependencies:
			dependencies.append(path)

	return dependencies


static func _get_script_dependencies(file_path: String) -> Array[String]:
	## Parse .gd script and extract preload()/load() paths and class_name extends
	var dependencies: Array[String] = []

	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return dependencies

	var content = file.get_as_text()
	file.close()

	# Pattern: preload("res://...") or preload('res://...')
	var preload_regex = RegEx.new()
	preload_regex.compile('preload\\s*\\(\\s*["\']([^"\']+)["\']')

	var matches = preload_regex.search_all(content)
	for match in matches:
		var path = match.get_string(1)
		var resolved = _resolve_path(path, file_path)
		if not resolved.is_empty():
			dependencies.append(resolved)

	# Pattern: load("res://...")
	var load_regex = RegEx.new()
	load_regex.compile('load\\s*\\(\\s*["\']([^"\']+)["\']')

	matches = load_regex.search_all(content)
	for match in matches:
		var path = match.get_string(1)
		var resolved = _resolve_path(path, file_path)
		if not resolved.is_empty() and resolved not in dependencies:
			dependencies.append(resolved)

	# Pattern: const X = preload("...") - already covered above

	# Pattern: extends "res://path/to/script.gd"
	var extends_regex = RegEx.new()
	extends_regex.compile('extends\\s+["\']([^"\']+)["\']')

	matches = extends_regex.search_all(content)
	for match in matches:
		var path = match.get_string(1)
		var resolved = _resolve_path(path, file_path)
		if not resolved.is_empty() and resolved not in dependencies:
			dependencies.append(resolved)

	return dependencies


static func _resolve_path(path: String, context_file: String) -> String:
	## Resolve a path (absolute or relative) to an absolute res:// path
	if path.is_empty():
		return ""

	# Already absolute
	if path.begins_with("res://"):
		return path

	# Skip user:// paths and other schemes
	if "://" in path:
		return ""

	# Relative path - resolve from context file's directory
	var context_dir = context_file.get_base_dir()
	var resolved = context_dir.path_join(path).simplify_path()

	# Ensure it starts with res://
	if not resolved.begins_with("res://"):
		if resolved.begins_with("/"):
			resolved = "res:/" + resolved
		else:
			resolved = "res://" + resolved

	return resolved


static func get_dependencies_info(file_path: String) -> Dictionary:
	## Get detailed dependency information
	## Returns {
	##   "file": String,
	##   "direct_deps": Array[String],
	##   "all_deps": Array[String],
	##   "missing_deps": Array[String],
	##   "dep_tree": Dictionary  # file -> its direct deps
	## }
	var info: Dictionary = {
		"file": file_path,
		"direct_deps": [],
		"all_deps": [],
		"missing_deps": [],
		"dep_tree": {}
	}

	info["direct_deps"] = get_direct_dependencies(file_path)

	var visited: Dictionary = {}
	var all_deps: Array[String] = []
	visited[file_path] = true

	_collect_dependencies_with_tree(file_path, visited, all_deps, info["dep_tree"], 0)

	info["all_deps"] = all_deps

	# Check for missing files
	for dep in all_deps:
		if not FileAccess.file_exists(dep):
			info["missing_deps"].append(dep)

	return info


static func _collect_dependencies_with_tree(
	file_path: String,
	visited: Dictionary,
	result: Array[String],
	tree: Dictionary,
	depth: int
) -> void:
	if depth > MAX_DEPTH:
		return

	var deps = get_direct_dependencies(file_path)
	tree[file_path] = deps

	for dep in deps:
		if visited.has(dep):
			continue

		visited[dep] = true
		result.append(dep)

		if FileAccess.file_exists(dep):
			_collect_dependencies_with_tree(dep, visited, result, tree, depth + 1)


static func categorize_files(files: Array) -> Dictionary:
	## Categorize files by type for display
	## Returns {category_name: Array[String]}
	var categories: Dictionary = {}

	for file_path in files:
		var ext = file_path.get_extension().to_lower() if file_path is String else ""
		var category = _get_category_for_extension(ext)

		if not categories.has(category):
			categories[category] = []
		categories[category].append(file_path)

	return categories


static func _get_category_for_extension(ext: String) -> String:
	match ext:
		"gd":
			return "Scripts"
		"tscn", "scn":
			return "Scenes"
		"tres", "res":
			return "Resources"
		"gdshader", "shader":
			return "Shaders"
		"png", "jpg", "jpeg", "webp", "svg", "bmp", "tga":
			return "Textures"
		"glb", "gltf", "obj", "fbx", "dae", "blend":
			return "3D Models"
		"wav", "ogg", "mp3":
			return "Audio"
		"ttf", "otf", "woff", "woff2":
			return "Fonts"
		"json", "cfg", "ini", "txt", "md":
			return "Config/Text"
		"import":
			return "Import Files"
		_:
			return "Other"
