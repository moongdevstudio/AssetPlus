@tool
extends PanelContainer

## Main panel for AssetPlus - aggregates multiple asset sources

const AssetCard = preload("res://addons/assetplus/ui/asset_card.gd")
const AssetDetailDialog = preload("res://addons/assetplus/ui/asset_detail_dialog.gd")
const InstallDialog = preload("res://addons/assetplus/ui/install_dialog.gd")
const SettingsDialog = preload("res://addons/assetplus/ui/settings_dialog.gd")
const ExportDialog = preload("res://addons/assetplus/ui/export_dialog.gd")
const OnboardingDialog = preload("res://addons/assetplus/ui/onboarding_dialog.gd")
const UpdateChecker = preload("res://addons/assetplus/ui/update_checker.gd")
const UpdateDialog = preload("res://addons/assetplus/ui/update_dialog.gd")

# Sources
const SOURCE_ALL = "All Sources"
const SOURCE_GODOT = "Godot AssetLib"
const SOURCE_GODOT_BETA = "Godot Store Beta"
const SOURCE_SHADERS = "Godot Shaders"
const SOURCE_LOCAL = "Local"
const SOURCE_GITHUB = "GitHub"
const SOURCE_GLOBAL_FOLDER = "GlobalFolder"

const GODOT_API = "https://godotengine.org/asset-library/api"
const GODOT_BETA_API = "https://store-beta.godotengine.org/api"
const GODOT_SHADERS_URL = "https://godotshaders.com"
const GODOT_BETA_DEFAULT_IMAGE = "https://store-beta.godotengine.org/static/images/share-image.webp"

const INSTALLED_REGISTRY_PATH = "user://asset_store_installed.cfg"
const LINKUP_CACHE_PATH = "user://asset_store_linkup.cfg"
const DEFAULT_ICON_PATH = "res://addons/assetplus/defaultgodot.png"
const ITEMS_PER_PAGE = 24
const GLOBAL_FAVORITES_FOLDER = "GodotAssetPlus"
const GLOBAL_FAVORITES_FILE = "favorites.cfg"
const GLOBAL_CONFIG_FILE = "config.cfg"

# AssetPlus self-identification (to filter from stores and show specially in Installed)
const ASSETPLUS_NAMES = ["assetplus", "asset plus", "asset-plus", "asset_plus"]
const ASSETPLUS_ASSET_ID = ""  # Fill this when published to AssetLib

var _default_icon: Texture2D = null

enum Tab { STORE, INSTALLED, FAVORITES, GLOBAL_FOLDER }

var editor_plugin: EditorPlugin = null
var _current_tab: Tab = Tab.STORE


func set_editor_plugin(plugin: EditorPlugin) -> void:
	editor_plugin = plugin

# UI Elements
@onready var _search_edit: LineEdit = $VBox/TopBar/SearchEdit
@onready var _search_btn: Button = $VBox/TopBar/SearchBtn
@onready var _sort_filter: OptionButton = $VBox/TopBar/SortFilter
@onready var _category_filter: OptionButton = $VBox/TopBar/CategoryFilter
@onready var _source_filter: OptionButton = $VBox/TopBar/SourceFilter
@onready var _assets_grid: HFlowContainer = $VBox/Scroll/Grid
@onready var _assets_scroll: ScrollContainer = $VBox/Scroll
@onready var _loading_label: Label = $LoadingLabel
@onready var _page_numbers: HBoxContainer = $VBox/TabsBar/PageBar/PageNumbers
@onready var _prev_btn: Button = $VBox/TabsBar/PageBar/PrevBtn
@onready var _next_btn: Button = $VBox/TabsBar/PageBar/NextBtn
@onready var _first_btn: Button = $VBox/TabsBar/PageBar/FirstBtn
@onready var _last_btn: Button = $VBox/TabsBar/PageBar/LastBtn
@onready var _page_bar: HBoxContainer = $VBox/TabsBar/PageBar
@onready var _tab_store: Button = $VBox/TabsBar/TabStore
@onready var _tab_installed: Button = $VBox/TabsBar/TabInstalled
@onready var _tab_favorites: Button = $VBox/TabsBar/TabFavorites
@onready var _tab_global_folder: Button = $VBox/TabsBar/TabGlobalFolder
@onready var _import_btn: Button = $VBox/TabsBar/ImportBtn
@onready var _export_btn: Button = $VBox/TabsBar/ExportBtn
@onready var _settings_btn: Button = $VBox/TabsBar/SettingsBtn
@onready var _filter_cat_label: Label = $VBox/TopBar/FilterCatLabel
@onready var _filter_category: OptionButton = $VBox/TopBar/FilterCategory
@onready var _filter_source_label: Label = $VBox/TopBar/FilterSourceLabel
@onready var _filter_source: OptionButton = $VBox/TopBar/FilterSource
@onready var _help_btn: Button = $VBox/TopBar/HelpBtn

var _refresh_linkup_btn: Button
var _open_global_folder_btn: Button
var _import_dialog: FileDialog
var _import_popup: PopupMenu
var _export_popup: PopupMenu
var _github_dialog: ConfirmationDialog
var _github_url_edit: LineEdit
var _github_http: HTTPRequest
var _github_progress_dialog: AcceptDialog
var _github_progress_label: Label

var _page_buttons: Array[Button] = []

# Card sizing
const CARD_MIN_WIDTH = 300
const CARD_MAX_WIDTH = 500
const CARD_HEIGHT = 120
const CARD_SPACING = 8

# State
var _current_source: String = SOURCE_GODOT
var _current_page: int = 0
var _total_pages: int = 1
var _search_query: String = ""
var _assets: Array[Dictionary] = []
var _favorites: Array[Dictionary] = []
var _installed_registry: Dictionary = {}  # asset_id -> {path: String, info: Dictionary}
var _http_requests: Array[HTTPRequest] = []
var _pending_request_count: int = 0
var _icon_cache: Dictionary = {}
var _cards: Array = []
var _linkup_cache: Dictionary = {}  # folder_name -> {matched: bool, asset_id: String, source: String, info: Dictionary}
var _linkup_pending: Dictionary = {}  # folder_name -> true (for ongoing searches)
var _session_installed_paths: Array[String] = []  # Paths installed during this session (may crash if deleted)
var _update_checker: RefCounted  # Keep reference to prevent garbage collection

# Update checking for installed addons
var _update_cache: Dictionary = {}  # asset_id -> {latest_version: String, godot_version: String, versions: Array, checked_at: int}
var _update_check_pending: Dictionary = {}  # asset_id -> true (for ongoing checks)
var _ignored_updates: Dictionary = {}  # asset_id -> version (ignored version string)
const UPDATE_CACHE_PATH = "user://asset_store_updates.cfg"
const UPDATE_CACHE_TTL = 3600  # Cache updates for 1 hour (in seconds)

# Filters for Installed/Favorites tabs
var _filter_selected_category: String = "All"
var _filter_selected_source: String = "All"
var _available_categories: Array[String] = []
var _available_sources: Array[String] = []


func _ready() -> void:
	SettingsDialog.debug_print("main_panel._ready() called")
	_load_default_icon()
	_load_favorites()
	_load_installed_registry()
	_load_linkup_cache()
	_load_update_cache()
	var recovered = _recover_pending_installation()  # Recover installations interrupted by script reload
	SettingsDialog.debug_print("Recovery result: %s" % str(recovered))
	_setup_ui()
	# If we recovered an installation/update, show Installed tab; otherwise show Store
	if recovered:
		SettingsDialog.debug_print("Switching to Installed tab after recovery")
		call_deferred("_switch_tab", Tab.INSTALLED)
	else:
		call_deferred("_search_assets")
	# Start linkup scan in background when AssetPlus opens
	call_deferred("_start_linkup_scan")
	# Check if this is first launch
	call_deferred("_check_first_launch")
	# Check for updates (after a short delay to not slow down startup)
	get_tree().create_timer(2.0).timeout.connect(_check_for_updates)
	# Connect to filesystem changes to detect when plugins are moved/deleted
	var fs = EditorInterface.get_resource_filesystem()
	if fs:
		fs.filesystem_changed.connect(_on_filesystem_changed)


func _load_default_icon() -> void:
	if FileAccess.file_exists(DEFAULT_ICON_PATH):
		var img = Image.load_from_file(ProjectSettings.globalize_path(DEFAULT_ICON_PATH))
		if img:
			_default_icon = ImageTexture.create_from_image(img)
	# Fallback to editor icon if custom icon not found
	if _default_icon == null:
		_default_icon = EditorInterface.get_editor_theme().get_icon("Godot", "EditorIcons")


func _setup_ui() -> void:
	# Setup button icons
	var theme = EditorInterface.get_editor_theme()
	if theme:
		_search_btn.icon = theme.get_icon("Search", "EditorIcons")
		_import_btn.icon = theme.get_icon("Load", "EditorIcons")
		_export_btn.icon = theme.get_icon("Save", "EditorIcons")
		_settings_btn.icon = theme.get_icon("Tools", "EditorIcons")
		_tab_store.icon = theme.get_icon("AssetLib", "EditorIcons")
		_tab_installed.icon = theme.get_icon("PackedScene", "EditorIcons")
		_tab_favorites.icon = theme.get_icon("Heart", "EditorIcons")
		_tab_global_folder.icon = theme.get_icon("Folder", "EditorIcons")

	# Connect signals
	_search_edit.text_submitted.connect(_on_search_submitted)
	_search_btn.pressed.connect(func(): _on_search_submitted(_search_edit.text))

	# Setup sort filter
	_sort_filter.clear()
	_sort_filter.add_item("Recently Updated")
	_sort_filter.add_item("Name")
	_sort_filter.add_item("Rating")
	_sort_filter.item_selected.connect(_on_filter_changed)

	# Setup category filter (will be updated by _update_filters_for_source)
	_category_filter.clear()
	_category_filter.add_item("All")
	_category_filter.add_item("2D Tools")
	_category_filter.add_item("3D Tools")
	_category_filter.add_item("Shaders")
	_category_filter.add_item("Materials")
	_category_filter.add_item("Tools")
	_category_filter.add_item("Scripts")
	_category_filter.add_item("Misc")
	_category_filter.add_item("Templates")
	_category_filter.add_item("Projects")
	_category_filter.add_item("Demos")
	_category_filter.item_selected.connect(_on_filter_changed)

	# Setup source filter
	_source_filter.clear()
	_source_filter.add_item(SOURCE_GODOT)
	_source_filter.add_item(SOURCE_GODOT_BETA)
	_source_filter.add_item(SOURCE_SHADERS)
	_source_filter.add_item(SOURCE_ALL)
	_source_filter.item_selected.connect(_on_source_changed)

	# Setup tabs
	_tab_store.pressed.connect(func(): _switch_tab(Tab.STORE))
	_tab_installed.pressed.connect(func(): _switch_tab(Tab.INSTALLED))
	_tab_favorites.pressed.connect(func(): _switch_tab(Tab.FAVORITES))
	_tab_global_folder.pressed.connect(func(): _switch_tab(Tab.GLOBAL_FOLDER))

	# Open Global Folder button (only visible in Global Folder tab)
	_open_global_folder_btn = Button.new()
	_open_global_folder_btn.text = "Open Folder"
	_open_global_folder_btn.tooltip_text = "Open global asset folder in file explorer"
	if theme:
		_open_global_folder_btn.icon = theme.get_icon("Folder", "EditorIcons")
	_open_global_folder_btn.pressed.connect(_on_open_global_folder_pressed)
	_open_global_folder_btn.visible = false
	$VBox/TabsBar.add_child(_open_global_folder_btn)
	# Move it after TabGlobalFolder (index 4)
	$VBox/TabsBar.move_child(_open_global_folder_btn, 5)

	# Refresh Linkup button (only visible in Installed tab, next to Global Folder button)
	_refresh_linkup_btn = Button.new()
	_refresh_linkup_btn.text = "↻ Linkup"
	_refresh_linkup_btn.tooltip_text = "Clear linkup cache and re-scan for store matches"
	_refresh_linkup_btn.flat = true
	_refresh_linkup_btn.add_theme_color_override("font_color", Color(0.6, 0.75, 0.9))
	_refresh_linkup_btn.add_theme_color_override("font_hover_color", Color(0.8, 0.9, 1.0))
	_refresh_linkup_btn.pressed.connect(_on_refresh_linkup_pressed)
	_refresh_linkup_btn.visible = false
	$VBox/TabsBar.add_child(_refresh_linkup_btn)
	# Move it after Open Global Folder button (index 6)
	$VBox/TabsBar.move_child(_refresh_linkup_btn, 6)

	_update_tab_buttons()

	# Setup pagination
	_first_btn.pressed.connect(func(): _go_to_page(0))
	_prev_btn.pressed.connect(_on_prev_page)
	_next_btn.pressed.connect(_on_next_page)
	_last_btn.pressed.connect(func(): _go_to_page(_total_pages - 1))

	# Create page number buttons
	for i in range(10):
		var btn = Button.new()
		btn.text = str(i + 1)
		btn.custom_minimum_size = Vector2(32, 0)
		btn.visible = false
		var page_idx = i
		btn.pressed.connect(func(): _go_to_page(page_idx))
		_page_numbers.add_child(btn)
		_page_buttons.append(btn)

	# Connect resize signal to update card sizes
	_assets_scroll.resized.connect(_update_card_sizes)

	# Setup Import button with popup menu
	_import_btn.pressed.connect(_on_import_pressed)
	_import_btn.tooltip_text = "Import asset from ZIP, folder, or GitHub"

	# Create import popup menu
	_import_popup = PopupMenu.new()
	_import_popup.add_item("From .ZIP file", 0)
	_import_popup.add_item("From .godotpackage file", 3)
	_import_popup.add_item("From Folder", 1)
	_import_popup.add_item("From Your Godot Projects", 4)
	_import_popup.add_separator()
	_import_popup.add_item("From GitHub", 2)
	_import_popup.id_pressed.connect(_on_import_menu_selected)
	add_child(_import_popup)

	# Setup Export button with popup menu
	_export_btn.pressed.connect(_on_export_pressed)
	_export_btn.tooltip_text = "Export project or folder as .zip or .godotpackage"

	# Create export popup menu
	_export_popup = PopupMenu.new()
	_export_popup.add_item("From This Project", 0)
	_export_popup.add_item("From Folder", 1)
	_export_popup.id_pressed.connect(_on_export_menu_selected)
	add_child(_export_popup)

	# Setup Settings button
	_settings_btn.pressed.connect(_on_settings_pressed)
	_settings_btn.tooltip_text = "Open Asset Store settings"

	# Setup Help button (bottom right corner)
	_setup_help_button()

	# Setup filter bar for Installed/Favorites tabs
	_setup_filter_bar()


func _setup_filter_bar() -> void:
	# Connect filter signals
	_filter_category.item_selected.connect(_on_local_filter_changed)
	_filter_source.item_selected.connect(_on_local_filter_changed)

	# Initial population (will be updated when switching tabs)
	_update_filter_options()


func _setup_help_button() -> void:
	_help_btn.pressed.connect(_show_onboarding)

	# Style as a floating button
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.4, 0.6, 0.9)
	style.set_corner_radius_all(15)
	_help_btn.add_theme_stylebox_override("normal", style)

	var hover_style = StyleBoxFlat.new()
	hover_style.bg_color = Color(0.3, 0.5, 0.7, 0.95)
	hover_style.set_corner_radius_all(15)
	_help_btn.add_theme_stylebox_override("hover", hover_style)

	_help_btn.add_theme_color_override("font_color", Color.WHITE)
	_help_btn.add_theme_font_size_override("font_size", 16)


func _show_onboarding(is_first_launch: bool = false) -> void:
	var dialog = OnboardingDialog.new()
	EditorInterface.get_base_control().add_child(dialog)
	# Hide close button on first launch to encourage reading the guide
	if is_first_launch:
		dialog.set_first_launch_mode(true)
	else:
		# Open at the page corresponding to current tab
		dialog.open_at_tab(_current_tab)
	dialog.popup_centered()


func _check_first_launch() -> void:
	if not _has_seen_onboarding():
		call_deferred("_show_onboarding", true)
		_mark_onboarding_seen()


func _check_for_updates() -> void:
	# Check if user has disabled auto-update
	var settings = SettingsDialog.get_settings()
	if settings.get("auto_update_disabled", false):
		SettingsDialog.debug_print("Auto-update check disabled by user")
		return

	_update_checker = UpdateChecker.new()
	_update_checker.update_available.connect(_on_update_available)
	_update_checker.check_for_updates(self)


func _on_update_available(current_version: String, new_version: String, browse_url: String, download_url: String, release_notes: String = "") -> void:
	# Show update dialog
	var dialog = UpdateDialog.new()
	dialog.setup(current_version, new_version, browse_url, download_url, release_notes)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.confirmed.connect(func(): dialog.queue_free())
	dialog.canceled.connect(func(): dialog.queue_free())
	dialog.popup_centered()


func _get_global_config_path() -> String:
	var config_dir = OS.get_config_dir()
	var app_dir = config_dir.path_join(GLOBAL_FAVORITES_FOLDER)

	if not DirAccess.dir_exists_absolute(app_dir):
		DirAccess.make_dir_recursive_absolute(app_dir)

	return app_dir.path_join(GLOBAL_CONFIG_FILE)


func _has_seen_onboarding() -> bool:
	var config_path = _get_global_config_path()
	if not FileAccess.file_exists(config_path):
		return false

	var file = FileAccess.open(config_path, FileAccess.READ)
	if file == null:
		return false

	var json = JSON.new()
	if json.parse(file.get_as_text()) == OK:
		var data = json.data
		if data is Dictionary:
			return data.get("onboarding_seen", false)

	file.close()
	return false


func _mark_onboarding_seen() -> void:
	var config_path = _get_global_config_path()

	# Load existing config or create new
	var config: Dictionary = {}
	if FileAccess.file_exists(config_path):
		var file = FileAccess.open(config_path, FileAccess.READ)
		if file:
			var json = JSON.new()
			if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
				config = json.data
			file.close()

	config["onboarding_seen"] = true

	var file = FileAccess.open(config_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(config, "\t"))
		file.close()


func _update_filter_options() -> void:
	# Collect all unique categories and sources from installed and favorites
	var categories_set: Dictionary = {}
	var sources_set: Dictionary = {}

	# From installed
	for asset_id in _installed_registry:
		var entry = _installed_registry[asset_id]
		var info = entry.get("info", {})
		var cat = info.get("category", "")
		var source = info.get("source", "")
		if cat.is_empty():
			cat = "Unknown"
		if source.is_empty():
			source = "Unknown"
		categories_set[cat] = true
		sources_set[source] = true

	# From favorites
	for fav in _favorites:
		var cat = fav.get("category", "")
		var source = fav.get("source", "")
		if cat.is_empty():
			cat = "Unknown"
		if source.is_empty():
			source = "Unknown"
		categories_set[cat] = true
		sources_set[source] = true

	# From global folder packages (scan for categories and original sources)
	var settings = SettingsDialog.get_settings()
	var global_folder = settings.get("global_asset_folder", "")
	if not global_folder.is_empty() and DirAccess.dir_exists_absolute(global_folder):
		var dir = DirAccess.open(global_folder)
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			while file_name != "":
				if not dir.current_is_dir() and file_name.get_extension().to_lower() == "godotpackage":
					var full_path = global_folder.path_join(file_name)
					var manifest = _read_godotpackage_manifest(full_path)
					if not manifest.is_empty():
						var cat = manifest.get("category", manifest.get("type", ""))
						var source = manifest.get("original_source", "")
						if cat.is_empty():
							cat = "Unknown"
						if source.is_empty():
							source = "Unknown"
						categories_set[cat] = true
						sources_set[source] = true
				file_name = dir.get_next()
			dir.list_dir_end()

	# Build sorted arrays
	_available_categories = ["All"]
	var cat_keys = categories_set.keys()
	cat_keys.sort()
	for cat in cat_keys:
		_available_categories.append(cat)

	_available_sources = ["All"]
	# Add known sources in order, then unknown
	var known_sources = [SOURCE_GODOT, SOURCE_GODOT_BETA, SOURCE_LOCAL, SOURCE_GITHUB, SOURCE_GLOBAL_FOLDER]
	for src in known_sources:
		if sources_set.has(src):
			_available_sources.append(src)
			sources_set.erase(src)
	# Add remaining unknown sources
	var remaining_sources = sources_set.keys()
	remaining_sources.sort()
	for src in remaining_sources:
		_available_sources.append(src)

	# Update dropdown options
	_filter_category.clear()
	for cat in _available_categories:
		_filter_category.add_item(cat)

	_filter_source.clear()
	for src in _available_sources:
		_filter_source.add_item(src)

	# Restore selection if still valid
	var cat_idx = _available_categories.find(_filter_selected_category)
	if cat_idx >= 0:
		_filter_category.select(cat_idx)
	else:
		_filter_category.select(0)
		_filter_selected_category = "All"

	var src_idx = _available_sources.find(_filter_selected_source)
	if src_idx >= 0:
		_filter_source.select(src_idx)
	else:
		_filter_source.select(0)
		_filter_selected_source = "All"


func _on_local_filter_changed(_index: int) -> void:
	_filter_selected_category = _filter_category.get_item_text(_filter_category.selected)
	_filter_selected_source = _filter_source.get_item_text(_filter_source.selected)

	# Refresh current tab
	if _current_tab == Tab.INSTALLED:
		_show_installed()
	elif _current_tab == Tab.FAVORITES:
		_show_favorites()
	elif _current_tab == Tab.GLOBAL_FOLDER:
		_show_global_folder()


func _on_import_pressed() -> void:
	# Show popup menu below the import button
	var btn_rect = _import_btn.get_global_rect()
	_import_popup.position = Vector2i(int(btn_rect.position.x), int(btn_rect.position.y + btn_rect.size.y))
	_import_popup.popup()


func _on_export_pressed() -> void:
	# Show export popup menu
	var btn_rect = _export_btn.get_global_rect()
	_export_popup.position = Vector2i(int(btn_rect.position.x), int(btn_rect.position.y + btn_rect.size.y))
	_export_popup.popup()


func _on_export_menu_selected(id: int) -> void:
	match id:
		0:  # From Project
			_show_export_from_project()
		1:  # From Folder
			_show_export_from_folder()


func _show_export_from_project() -> void:
	# Check if global folder is configured and ask first
	var settings = SettingsDialog.get_settings()
	var global_folder = settings.get("global_asset_folder", "")

	if not global_folder.is_empty():
		_ask_export_to_global_folder(func(to_global: bool):
			if to_global:
				_do_export_project_to_global(global_folder)
			else:
				_do_export_project_normal()
		)
	else:
		_do_export_project_normal()


func _do_export_project_normal() -> void:
	var dialog = ExportDialog.new()
	dialog.setup_from_project()
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func _do_export_project_to_global(global_folder: String) -> void:
	var dialog = ExportDialog.new()
	dialog.setup_from_project_for_global_folder(global_folder)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func _show_export_from_folder() -> void:
	# Show folder selection dialog first
	var folder_dialog = FileDialog.new()
	folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	folder_dialog.access = FileDialog.ACCESS_RESOURCES
	folder_dialog.title = "Select Folder to Export"
	folder_dialog.current_dir = "res://"
	folder_dialog.min_size = Vector2i(600, 400)

	folder_dialog.dir_selected.connect(func(dir_path: String):
		folder_dialog.queue_free()
		_show_export_dialog(dir_path)
	)

	folder_dialog.canceled.connect(func():
		folder_dialog.queue_free()
	)

	EditorInterface.get_base_control().add_child(folder_dialog)
	folder_dialog.popup_centered()


func _show_export_dialog(folder_path: String) -> void:
	# Check if global folder is configured and ask first
	var settings = SettingsDialog.get_settings()
	var global_folder = settings.get("global_asset_folder", "")

	if not global_folder.is_empty():
		_ask_export_to_global_folder(func(to_global: bool):
			if to_global:
				var dialog = ExportDialog.new()
				dialog.setup_for_global_folder(folder_path, global_folder)
				EditorInterface.get_base_control().add_child(dialog)
				dialog.popup_centered()
			else:
				var dialog = ExportDialog.new()
				dialog.setup(folder_path)
				EditorInterface.get_base_control().add_child(dialog)
				dialog.popup_centered()
		)
	else:
		var dialog = ExportDialog.new()
		dialog.setup(folder_path)
		EditorInterface.get_base_control().add_child(dialog)
		dialog.popup_centered()


func _ask_export_to_global_folder(callback: Callable) -> void:
	var settings = SettingsDialog.get_settings()
	var global_folder = settings.get("global_asset_folder", "")

	var confirm = ConfirmationDialog.new()
	confirm.title = "Export to Global Folder?"
	confirm.dialog_text = "Do you want to export directly to your Global Folder?\n\n%s\n\n(This will create a .godotpackage file)" % global_folder
	confirm.ok_button_text = "Yes, to Global Folder"
	confirm.cancel_button_text = "No, choose location"

	confirm.confirmed.connect(func():
		confirm.queue_free()
		callback.call(true)
	)

	confirm.canceled.connect(func():
		confirm.queue_free()
		callback.call(false)
	)

	EditorInterface.get_base_control().add_child(confirm)
	confirm.popup_centered()


func _prompt_add_to_global_folder(export_path: String) -> void:
	## Prompt user to add exported file to global asset folder
	const SettingsDialog = preload("res://addons/assetplus/ui/settings_dialog.gd")
	var settings = SettingsDialog.get_settings()
	var global_folder = settings.get("global_asset_folder", "")

	if global_folder.is_empty():
		# No global folder set - ask if they want to set one
		var setup_dialog = ConfirmationDialog.new()
		setup_dialog.title = "Global Asset Folder"
		setup_dialog.dialog_text = "Would you like to set up a global asset folder?\n\nThis allows you to store assets in a shared location\nand import them across multiple projects."
		setup_dialog.ok_button_text = "Set Up"
		setup_dialog.get_cancel_button().text = "Not Now"

		setup_dialog.confirmed.connect(func():
			setup_dialog.queue_free()
			_show_global_folder_setup(export_path)
		)
		setup_dialog.canceled.connect(func():
			setup_dialog.queue_free()
		)

		EditorInterface.get_base_control().add_child(setup_dialog)
		setup_dialog.popup_centered()
	else:
		# Global folder exists - ask if they want to add the export there
		var add_dialog = ConfirmationDialog.new()
		add_dialog.title = "Add to Global Assets"
		var file_name = export_path.get_file()
		add_dialog.dialog_text = "Add '%s' to your global asset folder?\n\n%s" % [file_name, global_folder]
		add_dialog.ok_button_text = "Yes"
		add_dialog.get_cancel_button().text = "No"

		add_dialog.confirmed.connect(func():
			add_dialog.queue_free()
			_copy_to_global_folder(export_path, global_folder)
		)
		add_dialog.canceled.connect(func():
			add_dialog.queue_free()
		)

		EditorInterface.get_base_control().add_child(add_dialog)
		add_dialog.popup_centered()


func _show_global_folder_setup(export_path: String) -> void:
	## Show dialog to select global asset folder
	var folder_dialog = FileDialog.new()
	folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
	folder_dialog.title = "Select Global Asset Folder"
	folder_dialog.min_size = Vector2i(600, 400)

	folder_dialog.dir_selected.connect(func(dir_path: String):
		folder_dialog.queue_free()
		# Save to settings
		_save_global_folder_setting(dir_path)
		# Copy the export to the new folder
		_copy_to_global_folder(export_path, dir_path)
	)

	folder_dialog.canceled.connect(func():
		folder_dialog.queue_free()
	)

	EditorInterface.get_base_control().add_child(folder_dialog)
	folder_dialog.popup_centered()


func _save_global_folder_setting(folder_path: String) -> void:
	## Save global asset folder to settings
	const SettingsDialog = preload("res://addons/assetplus/ui/settings_dialog.gd")
	var settings = SettingsDialog.get_settings()
	settings["global_asset_folder"] = folder_path

	var file = FileAccess.open("user://asset_store_settings.cfg", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(settings, "\t"))
		file.close()
		SettingsDialog.debug_print(" Global asset folder set to: %s" % folder_path)


func _validate_global_folder(folder_path: String) -> Dictionary:
	## Validate that a global folder is usable
	## Returns {valid: bool, error: String}
	if folder_path.is_empty():
		return {"valid": false, "error": "Global folder path is empty"}

	# Check if directory exists
	if not DirAccess.dir_exists_absolute(folder_path):
		# Try to create it
		var err = DirAccess.make_dir_recursive_absolute(folder_path)
		if err != OK:
			return {"valid": false, "error": "Directory does not exist and cannot be created: %s" % error_string(err)}

	# Check if we can write to it by creating a temp file
	var test_file_path = folder_path.path_join(".assetplus_write_test")
	var test_file = FileAccess.open(test_file_path, FileAccess.WRITE)
	if test_file == null:
		return {"valid": false, "error": "Cannot write to directory (permission denied or read-only)"}
	test_file.store_string("test")
	test_file.close()

	# Clean up test file
	DirAccess.remove_absolute(test_file_path)

	return {"valid": true, "error": ""}


func _copy_to_global_folder(source_path: String, global_folder: String) -> void:
	## Copy exported file to global asset folder
	# Validate global folder first
	var validation = _validate_global_folder(global_folder)
	if not validation["valid"]:
		_show_message("Global folder error: %s" % validation["error"])
		return

	var file_name = source_path.get_file()
	var dest_path = global_folder.path_join(file_name)

	# Read source file
	var src_file = FileAccess.open(source_path, FileAccess.READ)
	if src_file == null:
		_show_message("Failed to read exported file: %s" % error_string(FileAccess.get_open_error()))
		return

	var content = src_file.get_buffer(src_file.get_length())
	src_file.close()

	# Write to destination
	var dst_file = FileAccess.open(dest_path, FileAccess.WRITE)
	if dst_file == null:
		_show_message("Failed to write to global folder: %s\nError: %s" % [dest_path, error_string(FileAccess.get_open_error())])
		return

	dst_file.store_buffer(content)
	dst_file.close()

	_show_message("Added to global assets: %s" % file_name)
	SettingsDialog.debug_print(" Copied export to global folder: %s" % dest_path)


func _on_settings_pressed() -> void:
	_show_settings_panel()


func _read_godotpackage_manifest(file_path: String) -> Dictionary:
	## Read manifest.json from a .godotpackage file (ZIP format)
	var reader = ZIPReader.new()
	var err = reader.open(file_path)
	if err != OK:
		return {}

	var manifest: Dictionary = {}
	if reader.file_exists("manifest.json"):
		var data = reader.read_file("manifest.json")
		var json = JSON.new()
		if json.parse(data.get_string_from_utf8()) == OK and json.data is Dictionary:
			manifest = json.data

	reader.close()
	return manifest


func _extract_icon_from_godotpackage(file_path: String) -> Texture2D:
	## Extract icon.png from a .godotpackage file if it exists
	var reader = ZIPReader.new()
	var err = reader.open(file_path)
	if err != OK:
		return null

	var icon_tex: Texture2D = null
	if reader.file_exists("icon.png"):
		var data = reader.read_file("icon.png")
		if data.size() > 0:
			var img = Image.new()
			if img.load_png_from_buffer(data) == OK:
				icon_tex = ImageTexture.create_from_image(img)

	reader.close()
	return icon_tex


func _show_settings_panel() -> void:
	const SettingsDialog = preload("res://addons/assetplus/ui/settings_dialog.gd")
	var dialog = SettingsDialog.new()

	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func _on_import_menu_selected(id: int) -> void:
	match id:
		0:  # From .ZIP file
			_show_import_zip_dialog()
		1:  # From Folder
			_show_import_folder_dialog()
		2:  # From GitHub
			_show_github_import_dialog()
		3:  # From .godotpackage file
			_show_import_godotpackage_dialog()
		4:  # From Your Godot Projects
			_show_import_from_godot_projects()


func _show_import_zip_dialog() -> void:
	if not _import_dialog:
		_import_dialog = FileDialog.new()
		_import_dialog.file_selected.connect(_on_import_file_selected)
		_import_dialog.dir_selected.connect(_on_import_dir_selected)
		add_child(_import_dialog)

	_import_dialog.title = "Import from ZIP"
	_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_import_dialog.clear_filters()
	_import_dialog.add_filter("*.zip", "ZIP Archives")
	_import_dialog.min_size = Vector2i(600, 400)
	_import_dialog.popup_centered()


func _show_import_folder_dialog() -> void:
	if not _import_dialog:
		_import_dialog = FileDialog.new()
		_import_dialog.file_selected.connect(_on_import_file_selected)
		_import_dialog.dir_selected.connect(_on_import_dir_selected)
		add_child(_import_dialog)

	_import_dialog.title = "Import from Folder"
	_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_import_dialog.clear_filters()
	_import_dialog.min_size = Vector2i(600, 400)
	_import_dialog.popup_centered()


func _show_import_godotpackage_dialog() -> void:
	var godotpackage_dialog = FileDialog.new()
	godotpackage_dialog.title = "Import GodotPackage"
	godotpackage_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	godotpackage_dialog.access = FileDialog.ACCESS_FILESYSTEM
	godotpackage_dialog.clear_filters()
	godotpackage_dialog.add_filter("*.godotpackage", "GodotPackage Files")
	godotpackage_dialog.min_size = Vector2i(600, 400)
	godotpackage_dialog.file_selected.connect(_on_godotpackage_file_selected.bind(godotpackage_dialog))
	godotpackage_dialog.canceled.connect(func(): godotpackage_dialog.queue_free())
	add_child(godotpackage_dialog)
	godotpackage_dialog.popup_centered()


func _on_godotpackage_file_selected(path: String, dialog: FileDialog) -> void:
	dialog.queue_free()

	# Use InstallDialog for godotpackage import (same as ZIP/GitHub)
	var install_dialog = InstallDialog.new()
	EditorInterface.get_base_control().add_child(install_dialog)
	install_dialog.setup_from_local_godotpackage(path)
	install_dialog.installation_complete.connect(func(success, paths: Array, tracked_uids: Array):
		if success and paths.size() > 0:
			# Track paths installed this session (for crash warning on delete)
			for p in paths:
				if p not in _session_installed_paths:
					_session_installed_paths.append(p)

			# Read manifest to get asset info
			var manifest = _read_godotpackage_manifest_quick(path)
			var pkg_name = manifest.get("name", path.get_file().get_basename())
			var asset_id = "godotpackage_%s_%d" % [pkg_name.to_lower().replace(" ", "_"), Time.get_unix_time_from_system()]

			var info = {
				"asset_id": asset_id,
				"title": pkg_name,
				"author": manifest.get("author", "Unknown"),
				"version": manifest.get("version", ""),
				"description": manifest.get("description", ""),
				"source": "GodotPackage"
			}
			_register_installed_addon(asset_id, paths, info, tracked_uids)
			_update_card_installed_status(asset_id, true)
			_switch_tab(Tab.INSTALLED)
			# Safe scan filesystem
			_queue_safe_scan()
	)
	install_dialog.popup_centered()


func _show_import_from_godot_projects() -> void:
	## Show a dialog with list of Godot projects from recent projects list
	# Get the list of recent projects from EditorSettings
	var projects = _get_godot_recent_projects()

	if projects.is_empty():
		var error_dialog = AcceptDialog.new()
		error_dialog.title = "No Projects Found"
		error_dialog.dialog_text = "No Godot projects found in your recent projects list.\n\nPlease open some projects in Godot first, or use 'From Folder' to manually select a project directory."
		error_dialog.confirmed.connect(func(): error_dialog.queue_free())
		error_dialog.canceled.connect(func(): error_dialog.queue_free())
		EditorInterface.get_base_control().add_child(error_dialog)
		error_dialog.popup_centered()
		return

	# Reverse the order - oldest first, newest last
	projects.reverse()

	# Create a dialog to show the list of projects
	var project_dialog = AcceptDialog.new()
	project_dialog.title = "Select Godot Project"
	project_dialog.min_size = Vector2i(700, 500)

	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 8)

	# Add header label
	var header = Label.new()
	header.text = "Choose a project to import from:"
	header.add_theme_font_size_override("font_size", 14)
	main_vbox.add_child(header)

	var scroll = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(650, 380)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var project_list = VBoxContainer.new()
	project_list.add_theme_constant_override("separation", 4)

	# Get default project icon from editor theme
	var default_icon = EditorInterface.get_editor_theme().get_icon("DefaultProjectIcon", "EditorIcons")
	if not default_icon:
		default_icon = EditorInterface.get_editor_theme().get_icon("Godot", "EditorIcons")

	# Add a styled panel for each project
	for project in projects:
		var panel = PanelContainer.new()
		panel.custom_minimum_size = Vector2(0, 80)
		panel.size_flags_horizontal = Control.SIZE_FILL

		# Add hover effect with StyleBoxFlat
		var hover_style = StyleBoxFlat.new()
		hover_style.bg_color = Color(0.3, 0.5, 0.7, 0.1)
		hover_style.border_color = Color(0.4, 0.6, 0.8, 0.3)
		hover_style.set_border_width_all(1)
		hover_style.corner_radius_top_left = 4
		hover_style.corner_radius_top_right = 4
		hover_style.corner_radius_bottom_left = 4
		hover_style.corner_radius_bottom_right = 4

		var normal_style = StyleBoxFlat.new()
		normal_style.bg_color = Color(0, 0, 0, 0.1)
		normal_style.border_color = Color(0.3, 0.3, 0.3, 0.2)
		normal_style.set_border_width_all(1)
		normal_style.corner_radius_top_left = 4
		normal_style.corner_radius_top_right = 4
		normal_style.corner_radius_bottom_left = 4
		normal_style.corner_radius_bottom_right = 4

		panel.add_theme_stylebox_override("panel", normal_style)

		var hbox = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 12)

		# Load project icon
		var icon_texture: Texture2D = null
		var icon_path_png = project.path.path_join("icon.png")
		var icon_path_svg = project.path.path_join("icon.svg")

		if FileAccess.file_exists(icon_path_png):
			var img = Image.load_from_file(icon_path_png)
			if img:
				icon_texture = ImageTexture.create_from_image(img)
		elif FileAccess.file_exists(icon_path_svg):
			var img = Image.load_from_file(icon_path_svg)
			if img:
				icon_texture = ImageTexture.create_from_image(img)

		if not icon_texture:
			icon_texture = default_icon

		# Icon
		var icon = TextureRect.new()
		icon.texture = icon_texture
		icon.custom_minimum_size = Vector2(64, 64)
		icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		hbox.add_child(icon)

		# Project info VBox
		var info_vbox = VBoxContainer.new()
		info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info_vbox.add_theme_constant_override("separation", 4)

		# Project name (bold, larger)
		var name_label = Label.new()
		name_label.text = project.name
		name_label.add_theme_font_size_override("font_size", 16)
		name_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
		info_vbox.add_child(name_label)

		# Project path (smaller, dimmed)
		var path_label = Label.new()
		path_label.text = project.path
		path_label.add_theme_font_size_override("font_size", 11)
		path_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 0.7))
		path_label.clip_text = true
		path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		info_vbox.add_child(path_label)

		# Godot version (if available)
		if project.has("godot_version") and not project.godot_version.is_empty():
			var version_label = Label.new()
			version_label.text = "Godot " + project.godot_version
			version_label.add_theme_font_size_override("font_size", 11)
			version_label.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0, 0.8))
			info_vbox.add_child(version_label)

		hbox.add_child(info_vbox)

		panel.add_child(hbox)

		# Make the whole panel clickable
		var button = Button.new()
		button.flat = true
		button.custom_minimum_size = Vector2(0, 80)
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

		# Store project path for the lambda
		var proj_path = project.path
		button.pressed.connect(func():
			project_dialog.hide()
			project_dialog.queue_free()
			_on_godot_project_selected(proj_path)
		)

		button.mouse_entered.connect(func():
			panel.add_theme_stylebox_override("panel", hover_style)
		)

		button.mouse_exited.connect(func():
			panel.add_theme_stylebox_override("panel", normal_style)
		)

		# Use MarginContainer to overlay button on panel
		var margin = MarginContainer.new()
		margin.add_child(panel)
		margin.add_child(button)

		project_list.add_child(margin)

	scroll.add_child(project_list)
	main_vbox.add_child(scroll)

	project_dialog.add_child(main_vbox)
	project_dialog.get_ok_button().visible = false
	project_dialog.canceled.connect(func(): project_dialog.queue_free())

	EditorInterface.get_base_control().add_child(project_dialog)
	project_dialog.popup_centered()


func _get_godot_recent_projects() -> Array:
	## Get list of recent Godot projects from projects.cfg
	var projects: Array = []

	# Get the Godot config directory - works on Windows, Linux, and macOS
	# Windows: %APPDATA%/Godot
	# Linux: ~/.config/godot or ~/.local/share/godot
	# macOS: ~/Library/Application Support/Godot
	var config_path = OS.get_config_dir().path_join("Godot")

	var projects_file = config_path.path_join("projects.cfg")

	if not FileAccess.file_exists(projects_file):
		return projects

	var file = FileAccess.open(projects_file, FileAccess.READ)
	if not file:
		return projects

	var content = file.get_as_text()
	file.close()

	# Parse the CFG file
	# Format: [C:/path/to/project]
	#         favorite=false
	var lines = content.split("\n")

	for line in lines:
		line = line.strip_edges()

		if line.is_empty() or line.begins_with(";"):
			continue

		# Project path in brackets: [C:/path/to/project]
		if line.begins_with("[") and line.ends_with("]"):
			var project_path = line.substr(1, line.length() - 2)

			# Extract project name from path (last folder)
			var project_name = project_path.get_file()
			if project_name.is_empty():
				# Handle paths ending with / or \
				project_name = project_path.rstrip("/\\").get_file()

			# Try to read Godot version from project.godot
			var godot_version = _get_project_godot_version(project_path)

			projects.append({
				"path": project_path,
				"name": project_name,
				"godot_version": godot_version
			})

	return projects


func _get_project_godot_version(project_path: String) -> String:
	## Extract Godot version from a project's project.godot file
	var project_godot = project_path.path_join("project.godot")

	if not FileAccess.file_exists(project_godot):
		return ""

	var file = FileAccess.open(project_godot, FileAccess.READ)
	if not file:
		return ""

	var content = file.get_as_text()
	file.close()

	# Look for config/features line which contains version like: PackedStringArray("4.6", "Forward Plus")
	var lines = content.split("\n")
	for line in lines:
		line = line.strip_edges()
		if line.begins_with("config/features="):
			# Extract version from PackedStringArray("4.6", ...)
			var start = line.find('"')
			if start >= 0:
				var end = line.find('"', start + 1)
				if end > start:
					var version = line.substr(start + 1, end - start - 1)
					# Check if it looks like a version number (e.g., "4.6")
					if version.contains(".") and version.length() <= 5:
						return version

	return ""


func _on_godot_project_selected(project_path: String) -> void:
	## Called when user selects a Godot project from the list
	# Show loading indicator
	var loading_dialog = AcceptDialog.new()
	loading_dialog.title = "Loading Project..."
	loading_dialog.dialog_text = "Scanning project files, please wait..."
	loading_dialog.get_ok_button().visible = false
	EditorInterface.get_base_control().add_child(loading_dialog)
	loading_dialog.popup_centered(Vector2i(300, 100))

	# Wait one frame to show the loading dialog
	await get_tree().process_frame

	# Open the import dialog with this project folder
	var install_dialog = InstallDialog.new()
	EditorInterface.get_base_control().add_child(install_dialog)
	install_dialog.setup_from_local_folder(project_path)
	install_dialog.installation_complete.connect(func(success, paths: Array, tracked_uids: Array):
		if success and paths.size() > 0:
			# Track paths installed this session
			for p in paths:
				if p not in _session_installed_paths:
					_session_installed_paths.append(p)
			_switch_tab(Tab.INSTALLED)
			# Safe scan filesystem
			_queue_safe_scan()
		install_dialog.queue_free()
	)

	# Close loading dialog and show install dialog
	loading_dialog.queue_free()
	install_dialog.popup_centered()


func _read_godotpackage_manifest_quick(package_path: String) -> Dictionary:
	## Quick read of manifest.json from godotpackage file
	var reader = ZIPReader.new()
	var err = reader.open(package_path)
	if err != OK:
		return {}

	if not reader.file_exists("manifest.json"):
		reader.close()
		return {}

	var manifest_data = reader.read_file("manifest.json")
	reader.close()

	var json = JSON.new()
	err = json.parse(manifest_data.get_string_from_utf8())
	if err != OK:
		return {}

	return json.data if json.data is Dictionary else {}


func _show_github_import_dialog() -> void:
	if not _github_dialog:
		_github_dialog = ConfirmationDialog.new()
		_github_dialog.title = "Import from GitHub"
		_github_dialog.ok_button_text = "Import"

		var vbox = VBoxContainer.new()
		vbox.add_theme_constant_override("separation", 10)
		_github_dialog.add_child(vbox)

		var label = Label.new()
		label.text = "Enter GitHub repository URL:"
		vbox.add_child(label)

		_github_url_edit = LineEdit.new()
		_github_url_edit.placeholder_text = "https://github.com/owner/repo"
		_github_url_edit.custom_minimum_size.x = 400
		vbox.add_child(_github_url_edit)

		var hint = Label.new()
		hint.text = "Example: https://github.com/godot-addons/godot-behavior-tree-plugin"
		hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		hint.add_theme_font_size_override("font_size", 11)
		vbox.add_child(hint)

		_github_dialog.confirmed.connect(_on_github_import_confirmed)
		add_child(_github_dialog)

	_github_url_edit.text = ""
	_github_dialog.popup_centered()


func _on_github_import_confirmed() -> void:
	var url = _github_url_edit.text.strip_edges()
	if url.is_empty():
		return

	# Parse GitHub URL to extract owner and repo
	var parsed = _parse_github_url(url)
	if parsed.is_empty():
		push_error("AssetPlus: Invalid GitHub URL: %s" % url)
		return

	var owner = parsed["owner"]
	var repo = parsed["repo"]

	SettingsDialog.debug_print(" Importing from GitHub: %s/%s" % [owner, repo])

	# First, get repo info from GitHub API to find default branch
	_fetch_github_repo_info(owner, repo, url)


func _parse_github_url(url: String) -> Dictionary:
	## Parse a GitHub URL and extract owner and repo
	## Supports: https://github.com/owner/repo, github.com/owner/repo, owner/repo

	# Remove trailing slashes and .git extension
	url = url.strip_edges().rstrip("/")
	if url.ends_with(".git"):
		url = url.substr(0, url.length() - 4)

	# Try to extract owner/repo from various formats
	var regex = RegEx.new()
	regex.compile("(?:https?://)?(?:www\\.)?github\\.com/([^/]+)/([^/]+)")
	var match = regex.search(url)

	if match:
		return {"owner": match.get_string(1), "repo": match.get_string(2)}

	# Try simple owner/repo format
	var parts = url.split("/")
	if parts.size() == 2:
		return {"owner": parts[0], "repo": parts[1]}

	return {}


func _fetch_github_repo_info(owner: String, repo: String, original_url: String) -> void:
	## Fetch repository info from GitHub API to get default branch

	if _github_http:
		_github_http.cancel_request()
		_github_http.queue_free()

	_github_http = HTTPRequest.new()
	_github_http.use_threads = true
	add_child(_github_http)

	var api_url = "https://api.github.com/repos/%s/%s" % [owner, repo]

	_github_http.request_completed.connect(
		func(result: int, code: int, headers: PackedStringArray, body: PackedByteArray):
			_on_github_repo_info_received(result, code, headers, body, owner, repo, original_url)
	)

	var err = _github_http.request(api_url, ["User-Agent: GodotAssetPlus"])
	if err != OK:
		push_error("AssetPlus: Failed to request GitHub API: %s" % error_string(err))


func _on_github_repo_info_received(result: int, code: int, headers: PackedStringArray, body: PackedByteArray, owner: String, repo: String, original_url: String) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_error("AssetPlus: GitHub API request failed (code %d)" % code)
		if _github_http:
			_github_http.queue_free()
			_github_http = null
		return

	var json = JSON.new()
	var parse_err = json.parse(body.get_string_from_utf8())
	if parse_err != OK:
		push_error("AssetPlus: Failed to parse GitHub API response")
		if _github_http:
			_github_http.queue_free()
			_github_http = null
		return

	var data = json.data
	var default_branch = data.get("default_branch", "main")
	var description = data.get("description", "")
	var repo_name = data.get("name", repo)
	var repo_full_name = data.get("full_name", "%s/%s" % [owner, repo])
	var stars = data.get("stargazers_count", 0)
	var license_info = data.get("license", {})
	var license_name = license_info.get("spdx_id", "Unknown") if license_info else "Unknown"

	# Download the ZIP of the default branch
	var download_url = "https://github.com/%s/%s/archive/refs/heads/%s.zip" % [owner, repo, default_branch]

	SettingsDialog.debug_print(" Downloading %s (branch: %s)" % [repo_full_name, default_branch])

	# Store repo info for later
	var repo_info = {
		"title": repo_name,
		"author": owner,
		"source": SOURCE_GITHUB,
		"license": license_name,
		"description": description,
		"url": original_url,
		"stars": stars,
		"asset_id": "github_%s_%s" % [owner, repo]
	}

	_download_github_repo(download_url, repo_info, default_branch)


func _download_github_repo(download_url: String, repo_info: Dictionary, branch: String) -> void:
	## Download the GitHub repository ZIP

	if _github_http:
		_github_http.cancel_request()
		_github_http.queue_free()

	# Show progress dialog
	_show_github_progress_dialog(repo_info.get("title", "GitHub Repository"))

	_github_http = HTTPRequest.new()
	_github_http.use_threads = true

	# Download to temp file
	var temp_path = "user://github_temp_%d.zip" % Time.get_unix_time_from_system()
	_github_http.download_file = ProjectSettings.globalize_path(temp_path)
	add_child(_github_http)

	_github_http.request_completed.connect(
		func(result: int, code: int, headers: PackedStringArray, body: PackedByteArray):
			_on_github_download_complete(result, code, temp_path, repo_info, branch)
	)

	var err = _github_http.request(download_url, ["User-Agent: GodotAssetPlus"])
	if err != OK:
		_hide_github_progress_dialog()
		push_error("AssetPlus: Failed to download GitHub repo: %s" % error_string(err))


func _show_github_progress_dialog(repo_name: String) -> void:
	if _github_progress_dialog:
		_github_progress_dialog.queue_free()

	_github_progress_dialog = AcceptDialog.new()
	_github_progress_dialog.title = "Downloading from GitHub"
	_github_progress_dialog.dialog_hide_on_ok = false
	_github_progress_dialog.get_ok_button().visible = false

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 15)
	_github_progress_dialog.add_child(vbox)

	_github_progress_label = Label.new()
	_github_progress_label.text = "Downloading %s..." % repo_name
	_github_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_github_progress_label)

	var progress_bar = ProgressBar.new()
	progress_bar.custom_minimum_size.x = 300
	progress_bar.max_value = 100
	progress_bar.value = 0
	progress_bar.name = "ProgressBar"
	# Indeterminate style - just animate
	vbox.add_child(progress_bar)

	# Animate progress bar
	var tween = create_tween()
	tween.set_loops()
	tween.tween_property(progress_bar, "value", 100, 1.5)
	tween.tween_property(progress_bar, "value", 0, 0.0)

	EditorInterface.get_base_control().add_child(_github_progress_dialog)
	_github_progress_dialog.popup_centered()


func _hide_github_progress_dialog() -> void:
	if _github_progress_dialog and is_instance_valid(_github_progress_dialog):
		_github_progress_dialog.queue_free()
		_github_progress_dialog = null
		_github_progress_label = null


func _on_github_download_complete(result: int, code: int, temp_path: String, repo_info: Dictionary, branch: String) -> void:
	if _github_http:
		_github_http.queue_free()
		_github_http = null

	# Hide progress dialog
	_hide_github_progress_dialog()

	# Handle redirect
	if code == 302 or code == 301:
		push_warning("AssetPlus: GitHub download redirected, please try again")
		return

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_error("AssetPlus: GitHub download failed (code %d)" % code)
		# Cleanup temp file
		if FileAccess.file_exists(temp_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
		return

	SettingsDialog.debug_print(" GitHub download complete, opening install dialog...")

	# Open InstallDialog with the downloaded ZIP
	var global_path = ProjectSettings.globalize_path(temp_path)
	var asset_id = repo_info.get("asset_id", "github_%d" % Time.get_unix_time_from_system())

	var install_dialog = InstallDialog.new()
	EditorInterface.get_base_control().add_child(install_dialog)
	install_dialog.setup_from_local_zip(global_path, repo_info)
	install_dialog.installation_complete.connect(func(success, paths: Array, tracked_uids: Array):
		# Cleanup the temp file
		if FileAccess.file_exists(temp_path):
			DirAccess.remove_absolute(global_path)

		if success and paths.size() > 0:
			# Track paths installed this session
			for p in paths:
				if p not in _session_installed_paths:
					_session_installed_paths.append(p)
			_register_installed_addon(asset_id, paths, repo_info, tracked_uids)
			# Update the detail dialog if open
			if _current_detail_dialog and is_instance_valid(_current_detail_dialog):
				_current_detail_dialog.set_installed(true, paths)
			# Update card badge
			_update_card_installed_status(asset_id, true)
			_switch_tab(Tab.INSTALLED)
			# Safe scan filesystem
			_queue_safe_scan()
	)
	install_dialog.popup_centered()


func _on_import_file_selected(path: String) -> void:
	if path.ends_with(".zip"):
		_import_local_zip_file(path)


func _on_import_dir_selected(path: String) -> void:
	_import_local_folder(path)


func _import_local_zip_file(zip_path: String) -> void:
	## Open InstallDialog for a local ZIP file
	var zip_name = zip_path.get_file().get_basename()
	var asset_id = "local_%d" % Time.get_unix_time_from_system()

	var info = {
		"title": zip_name,
		"author": "Local Import",
		"source": SOURCE_LOCAL,
		"license": "Unknown",
		"asset_id": asset_id
	}

	var install_dialog = InstallDialog.new()
	EditorInterface.get_base_control().add_child(install_dialog)
	install_dialog.setup_from_local_zip(zip_path, info)
	install_dialog.installation_complete.connect(func(success, paths: Array, tracked_uids: Array):
		if success and paths.size() > 0:
			# Track paths installed this session
			for p in paths:
				if p not in _session_installed_paths:
					_session_installed_paths.append(p)
			_register_installed_addon(asset_id, paths, info, tracked_uids)
			_update_card_installed_status(asset_id, true)
			_switch_tab(Tab.INSTALLED)
			# Safe scan filesystem
			_queue_safe_scan()
	)
	install_dialog.popup_centered()


func _import_local_folder(folder_path: String) -> void:
	## Open InstallDialog for a local folder
	var folder_name = folder_path.get_file()
	if folder_name.is_empty():
		folder_name = folder_path.rstrip("/\\").get_file()

	var asset_id = "local_%d" % Time.get_unix_time_from_system()

	var info = {
		"title": folder_name,
		"author": "Local Import",
		"source": SOURCE_LOCAL,
		"license": "Unknown",
		"asset_id": asset_id
	}

	var install_dialog = InstallDialog.new()
	EditorInterface.get_base_control().add_child(install_dialog)
	install_dialog.setup_from_local_folder(folder_path, info)
	install_dialog.installation_complete.connect(func(success, paths: Array, tracked_uids: Array):
		if success and paths.size() > 0:
			# Track paths installed this session
			for p in paths:
				if p not in _session_installed_paths:
					_session_installed_paths.append(p)
			_register_installed_addon(asset_id, paths, info, tracked_uids)
			_update_card_installed_status(asset_id, true)
			_switch_tab(Tab.INSTALLED)
			# Safe scan filesystem
			_queue_safe_scan()
	)
	install_dialog.popup_centered()


func _copy_dir_recursive(from_path: String, to_path: String) -> void:
	var from_dir = DirAccess.open(from_path)
	if not from_dir:
		return

	DirAccess.make_dir_recursive_absolute(to_path)

	from_dir.list_dir_begin()
	var file_name = from_dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var from_file = from_path.path_join(file_name)
			var to_file = to_path.path_join(file_name)
			if from_dir.current_is_dir():
				_copy_dir_recursive(from_file, to_file)
			else:
				from_dir.copy(from_file, to_file)
		file_name = from_dir.get_next()
	from_dir.list_dir_end()


func _on_search_submitted(query: String) -> void:
	_search_query = query.strip_edges()
	_current_page = 0
	_search_assets()


func _on_source_changed(index: int) -> void:
	_current_source = _source_filter.get_item_text(index)
	_current_page = 0
	_update_filters_for_source()
	_search_assets()


func _switch_tab(tab: Tab) -> void:
	_current_tab = tab
	_current_page = 0
	_update_tab_buttons()

	# Clear search when switching tabs
	_search_edit.text = ""
	_search_query = ""

	# Check if we have pending filesystem changes when switching to a relevant tab
	if _needs_filesystem_refresh and tab in [Tab.INSTALLED, Tab.FAVORITES, Tab.GLOBAL_FOLDER]:
		_needs_filesystem_refresh = false
		SettingsDialog.debug_print_verbose("Processing deferred filesystem changes on tab switch")
		_cleanup_installed_registry()

	_refresh_content()


func _update_tab_buttons() -> void:
	_tab_store.button_pressed = _current_tab == Tab.STORE
	_tab_installed.button_pressed = _current_tab == Tab.INSTALLED
	_tab_favorites.button_pressed = _current_tab == Tab.FAVORITES
	_tab_global_folder.button_pressed = _current_tab == Tab.GLOBAL_FOLDER

	# Style selected/unselected tabs
	_style_tab_button(_tab_store, _current_tab == Tab.STORE)
	_style_tab_button(_tab_installed, _current_tab == Tab.INSTALLED)
	_style_tab_button(_tab_favorites, _current_tab == Tab.FAVORITES)
	_style_tab_button(_tab_global_folder, _current_tab == Tab.GLOBAL_FOLDER)

	# Show/hide store filters and pagination based on tab
	var show_store_filters = _current_tab == Tab.STORE
	_sort_filter.visible = show_store_filters
	_category_filter.visible = show_store_filters
	_source_filter.visible = show_store_filters
	# Also hide labels
	var top_bar = $VBox/TopBar
	top_bar.get_node("SortLabel").visible = show_store_filters
	top_bar.get_node("CatLabel").visible = show_store_filters
	top_bar.get_node("SiteLabel").visible = show_store_filters

	# Only show pagination for Store tab
	_page_bar.visible = _current_tab == Tab.STORE

	# Show/hide local filters for Installed/Favorites/Global Folder tabs (in TopBar)
	var show_local_filters = _current_tab in [Tab.INSTALLED, Tab.FAVORITES, Tab.GLOBAL_FOLDER]
	_filter_cat_label.visible = show_local_filters
	_filter_category.visible = show_local_filters
	_filter_source_label.visible = show_local_filters
	_filter_source.visible = show_local_filters
	if show_local_filters:
		_update_filter_options()

	# Show refresh linkup button only in Installed tab
	if _refresh_linkup_btn:
		_refresh_linkup_btn.visible = _current_tab == Tab.INSTALLED

	# Show open folder button only in Global Folder tab
	if _open_global_folder_btn:
		_open_global_folder_btn.visible = _current_tab == Tab.GLOBAL_FOLDER


func _style_tab_button(btn: Button, is_selected: bool) -> void:
	if is_selected:
		# Selected tab: bright color with underline effect
		btn.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
		btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
		btn.add_theme_color_override("font_pressed_color", Color(0.9, 0.9, 0.95))

		var style = StyleBoxFlat.new()
		style.bg_color = Color(0.3, 0.4, 0.55)
		style.set_corner_radius_all(4)
		style.border_width_bottom = 2
		style.border_color = Color(0.5, 0.7, 1.0)
		btn.add_theme_stylebox_override("normal", style)
		btn.add_theme_stylebox_override("hover", style)
		btn.add_theme_stylebox_override("pressed", style)
	else:
		# Unselected tab: dimmed
		btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
		btn.add_theme_color_override("font_hover_color", Color(0.7, 0.7, 0.75))
		btn.add_theme_color_override("font_pressed_color", Color(0.6, 0.6, 0.65))

		var style = StyleBoxFlat.new()
		style.bg_color = Color(0.18, 0.18, 0.2)
		style.set_corner_radius_all(4)
		btn.add_theme_stylebox_override("normal", style)

		var hover_style = StyleBoxFlat.new()
		hover_style.bg_color = Color(0.22, 0.22, 0.25)
		hover_style.set_corner_radius_all(4)
		btn.add_theme_stylebox_override("hover", hover_style)
		btn.add_theme_stylebox_override("pressed", hover_style)


func _refresh_content() -> void:
	match _current_tab:
		Tab.STORE:
			_search_assets()
		Tab.INSTALLED:
			_show_installed()
		Tab.FAVORITES:
			_show_favorites()
		Tab.GLOBAL_FOLDER:
			_show_global_folder()


func _update_filters_for_source() -> void:
	# Update category filter based on source
	_category_filter.clear()

	if _current_source == SOURCE_SHADERS:
		# Shader-specific categories
		_category_filter.add_item("All")
		_category_filter.add_item("2D (Canvas Item)")
		_category_filter.add_item("3D (Spatial)")
		_category_filter.add_item("Sky")
		_category_filter.add_item("Particles")
		_category_filter.add_item("Fog")

		# Update sort filter for shaders
		_sort_filter.clear()
		_sort_filter.add_item("Newest")
		_sort_filter.add_item("Most Liked")
		_sort_filter.add_item("Alphabetical")
	elif _current_source == SOURCE_GODOT_BETA:
		# Beta Store categories (real ones from the site)
		_category_filter.add_item("All")
		_category_filter.add_item("2D")
		_category_filter.add_item("3D")
		_category_filter.add_item("Tool")
		_category_filter.add_item("Audio")
		_category_filter.add_item("Template")
		_category_filter.add_item("Materials")
		_category_filter.add_item("VFX")

		# Sort options matching Beta Store API
		_sort_filter.clear()
		_sort_filter.add_item("Recently Updated")
		_sort_filter.add_item("Relevance")
		_sort_filter.add_item("Top Rated")
	else:
		# AssetLib categories (including Templates, Projects, Demos)
		# Category IDs: 1=2D Tools, 2=3D Tools, 3=Shaders, 4=Materials, 5=Tools, 6=Scripts, 7=Misc, 8=Templates, 9=Projects, 10=Demos
		_category_filter.add_item("All")
		_category_filter.add_item("2D Tools")
		_category_filter.add_item("3D Tools")
		_category_filter.add_item("Shaders")
		_category_filter.add_item("Materials")
		_category_filter.add_item("Tools")
		_category_filter.add_item("Scripts")
		_category_filter.add_item("Misc")
		_category_filter.add_item("Templates")
		_category_filter.add_item("Projects")
		_category_filter.add_item("Demos")

		# Default sort options
		_sort_filter.clear()
		_sort_filter.add_item("Recently Updated")
		_sort_filter.add_item("Name")
		_sort_filter.add_item("Rating")


func _on_filter_changed(_index: int) -> void:
	_current_page = 0
	_search_assets()


func _on_prev_page() -> void:
	if _current_page > 0:
		_current_page -= 1
		_search_assets()


func _on_next_page() -> void:
	if _current_page < _total_pages - 1:
		_current_page += 1
		_search_assets()


func _go_to_page(page: int) -> void:
	if page >= 0 and page < _total_pages:
		_current_page = page
		_search_assets()


func _search_assets() -> void:
	# Clear current assets
	for child in _assets_grid.get_children():
		child.queue_free()
	_cards.clear()

	_assets.clear()
	_loading_label.text = "Loading..."
	_loading_label.visible = true
	_total_pages = 1

	# Cancel pending requests
	for req in _http_requests:
		if is_instance_valid(req):
			req.cancel_request()
			req.queue_free()
	_http_requests.clear()
	_pending_request_count = 0

	# Fetch from sources based on filter
	if _current_source == SOURCE_ALL or _current_source == SOURCE_GODOT:
		_pending_request_count += 1
		_fetch_godot_assets()

	if _current_source == SOURCE_ALL or _current_source == SOURCE_GODOT_BETA:
		_pending_request_count += 1
		_fetch_godot_beta_assets()

	if _current_source == SOURCE_ALL or _current_source == SOURCE_SHADERS:
		_pending_request_count += 1
		_fetch_godot_shaders()


func _check_no_results() -> void:
	# Called when a request completes - check if all done with no results
	_pending_request_count -= 1
	if _pending_request_count <= 0 and _assets.is_empty():
		_loading_label.text = "No results for this search"
		_loading_label.visible = true


func _show_favorites() -> void:
	# Clear current assets
	for child in _assets_grid.get_children():
		child.queue_free()
	_cards.clear()
	_assets.clear()

	_loading_label.text = "Loading..."
	_loading_label.visible = false

	var filtered = _favorites.duplicate()

	# Filter by search
	if not _search_query.is_empty():
		filtered = filtered.filter(func(a):
			return _search_query.to_lower() in a.get("title", "").to_lower()
		)

	# Filter by category
	if _filter_selected_category != "All":
		filtered = filtered.filter(func(a):
			var cat = a.get("category", "Unknown")
			if cat.is_empty():
				cat = "Unknown"
			return cat == _filter_selected_category
		)

	# Filter by source
	if _filter_selected_source != "All":
		filtered = filtered.filter(func(a):
			var src = a.get("source", "Unknown")
			if src.is_empty():
				src = "Unknown"
			return src == _filter_selected_source
		)

	for info in filtered:
		_assets.append(info)
		_create_asset_card(info)

	# Show empty state messages
	if _assets.is_empty():
		if _favorites.is_empty():
			# No favorites at all
			var info_label = Label.new()
			info_label.text = "You don't have any favorites yet.\n\nClick the ♥ icon on any asset from the Store,\nInstalled, or Global Folder tabs to add it here."
			info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			info_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			_assets_grid.add_child(info_label)
		elif not _search_query.is_empty() or _filter_selected_category != "All" or _filter_selected_source != "All":
			# Has favorites but filters don't match
			_loading_label.text = "No favorites match the current filters"
			_loading_label.visible = true


func _on_open_global_folder_pressed() -> void:
	var settings = SettingsDialog.get_settings()
	var global_folder = settings.get("global_asset_folder", "")

	if global_folder.is_empty():
		# Show message to configure
		var dialog = AcceptDialog.new()
		dialog.title = "Global Folder Not Configured"
		dialog.dialog_text = "Please configure your Global Asset Folder in Settings first."
		dialog.confirmed.connect(func(): dialog.queue_free())
		dialog.canceled.connect(func(): dialog.queue_free())
		EditorInterface.get_base_control().add_child(dialog)
		dialog.popup_centered()
		return

	if not DirAccess.dir_exists_absolute(global_folder):
		# Create it
		DirAccess.make_dir_recursive_absolute(global_folder)

	OS.shell_open(global_folder)


func _show_global_folder() -> void:
	# Clear current assets
	for child in _assets_grid.get_children():
		child.queue_free()
	_cards.clear()
	_assets.clear()

	_loading_label.text = "Loading..."
	_loading_label.visible = false

	# Get global folder path from settings
	var settings = SettingsDialog.get_settings()
	var global_folder = settings.get("global_asset_folder", "")

	if global_folder.is_empty():
		# Show message to configure global folder
		var info_label = Label.new()
		info_label.text = "No global folder configured.\nGo to Settings to set your Global Asset Folder."
		info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_assets_grid.add_child(info_label)
		return

	# Check if folder exists
	if not DirAccess.dir_exists_absolute(global_folder):
		var info_label = Label.new()
		info_label.text = "Global folder not found:\n%s" % global_folder
		info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info_label.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))
		_assets_grid.add_child(info_label)
		return

	# Scan for .godotpackage files in root folder only
	var dir = DirAccess.open(global_folder)
	if dir == null:
		var info_label = Label.new()
		info_label.text = "Cannot access global folder:\n%s" % global_folder
		info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info_label.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))
		_assets_grid.add_child(info_label)
		return

	var packages: Array[Dictionary] = []

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.get_extension().to_lower() == "godotpackage":
			var full_path = global_folder.path_join(file_name)
			var manifest = _read_godotpackage_manifest(full_path)
			if not manifest.is_empty():
				# Build info dictionary for the card
				var info: Dictionary = {
					"asset_id": "global_" + file_name.get_basename(),
					"title": manifest.get("name", file_name.get_basename()),
					"author": manifest.get("author", "Unknown"),
					"description": manifest.get("description", ""),
					"version": manifest.get("version", ""),
					"category": manifest.get("category", manifest.get("type", "Asset")),
					"license": manifest.get("license", ""),
					"source": SOURCE_GLOBAL_FOLDER,
					"godotpackage_path": full_path,
					"original_source": manifest.get("original_source", ""),
					"original_browse_url": manifest.get("original_browse_url", ""),
					"original_url": manifest.get("original_url", ""),
					"icon_url": manifest.get("icon_url", ""),
					"original_asset_id": manifest.get("original_asset_id", "")
				}

				# Try to extract embedded icon from the .godotpackage
				var embedded_icon = _extract_icon_from_godotpackage(full_path)
				if embedded_icon:
					info["_embedded_icon"] = embedded_icon

				packages.append(info)
		file_name = dir.get_next()
	dir.list_dir_end()

	if packages.is_empty():
		var info_label = Label.new()
		info_label.text = "No packages in your Global Folder yet.\n\nRight-click any folder in the FileSystem dock\nand select 'Export as .godotpackage' to add assets here."
		info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_assets_grid.add_child(info_label)
		return

	# Sort by name
	packages.sort_custom(func(a, b): return a.get("title", "").to_lower() < b.get("title", "").to_lower())

	# Filter by search
	if not _search_query.is_empty():
		packages = packages.filter(func(a):
			return _search_query.to_lower() in a.get("title", "").to_lower()
		)

	# Filter by category
	if _filter_selected_category != "All":
		packages = packages.filter(func(a):
			var cat = a.get("category", "Unknown")
			if cat.is_empty():
				cat = "Unknown"
			return cat == _filter_selected_category
		)

	# Filter by source (original source)
	if _filter_selected_source != "All":
		packages = packages.filter(func(a):
			var src = a.get("original_source", "Unknown")
			if src.is_empty():
				src = "Unknown"
			return src == _filter_selected_source
		)

	# Create cards for each package
	for info in packages:
		_assets.append(info)
		_create_global_folder_card(info)

	# Show "No results" if filtering returned no matches (but packages existed before filtering)
	if _assets.is_empty() and (not _search_query.is_empty() or _filter_selected_category != "All" or _filter_selected_source != "All"):
		_loading_label.text = "No packages match the current filters"
		_loading_label.visible = true


func _create_global_folder_card(info: Dictionary) -> void:
	var is_fav = _is_favorite(info)
	var card_width = _calculate_card_width()

	# Check if this package is already installed
	var asset_id = info.get("asset_id", "")
	var is_installed = _installed_registry.has(asset_id)

	SettingsDialog.debug_print_verbose("Global Folder card - asset_id='%s', is_installed=%s" % [asset_id, is_installed])

	var card = AssetCard.new()
	card.custom_minimum_size = Vector2(card_width, CARD_HEIGHT)
	card.setup(info, is_fav, is_installed)
	card.clicked.connect(_on_global_folder_card_clicked)
	card.favorite_clicked.connect(_on_favorite_clicked)
	_assets_grid.add_child(card)
	_cards.append(card)

	# Load icon: prioritize embedded icon, then URL, then default
	var embedded_icon = info.get("_embedded_icon", null)
	if embedded_icon is Texture2D:
		card.set_icon(embedded_icon)
		# Also cache it for the detail dialog
		var icon_url = info.get("icon_url", "")
		if not icon_url.is_empty():
			_icon_cache[icon_url] = embedded_icon
	else:
		var icon_url = info.get("icon_url", "")
		if not icon_url.is_empty():
			_load_icon(card, icon_url)
		elif _default_icon:
			card.set_icon(_default_icon)


func _on_global_folder_card_clicked(info: Dictionary) -> void:
	# Show detail dialog like other tabs
	var dialog = AssetDetailDialog.new()
	EditorInterface.get_base_control().add_child(dialog)
	_current_detail_dialog = dialog

	var is_fav = _is_favorite(info)
	# Check if this package is already installed
	var asset_id = info.get("asset_id", "")
	var is_installed = _installed_registry.has(asset_id)

	# Add installed paths to info for the "Open in Explorer" button
	var display_info = info.duplicate()
	if is_installed:
		var paths = _get_installed_addon_paths(asset_id)
		display_info["installed_paths"] = paths

	# Get icon: prioritize embedded icon, then cache, then default
	var icon_tex: Texture2D = info.get("_embedded_icon", null)
	if not icon_tex:
		icon_tex = _icon_cache.get(info.get("icon_url", ""), _default_icon)
	dialog.setup(display_info, is_fav, is_installed, icon_tex)

	# Pass tracked files if installed (with resolved paths)
	if is_installed:
		var tracked_files = _get_resolved_tracked_files(asset_id)
		dialog.set_tracked_files(tracked_files)

	dialog.install_requested.connect(_on_global_folder_install_requested)
	dialog.favorite_toggled.connect(_on_dialog_favorite_toggled)
	dialog.remove_from_global_folder_requested.connect(_on_remove_from_global_folder)
	dialog.metadata_edited.connect(_on_global_folder_metadata_edited)
	dialog.uninstall_requested.connect(_on_uninstall_requested)
	dialog.extract_package_requested.connect(_on_extract_package_requested)
	dialog.popup_centered()


func _on_global_folder_install_requested(info: Dictionary) -> void:
	# Wait a frame for the previous dialog to fully close
	await get_tree().process_frame
	# Open install dialog for the godotpackage
	var godotpackage_path = info.get("godotpackage_path", "")
	if godotpackage_path.is_empty():
		return

	# Use the global_ prefix for asset_id so it's linked to the Global Folder source
	var global_asset_id = "global_" + godotpackage_path.get_file().get_basename()

	var install_dialog = InstallDialog.new()
	EditorInterface.get_base_control().add_child(install_dialog)
	# Pass the global asset_id so the installation is tracked under the same ID
	install_dialog.setup_from_local_godotpackage(godotpackage_path, {"asset_id": global_asset_id})

	install_dialog.installation_complete.connect(func(success: bool, paths: Array, tracked_uids: Array):
		SettingsDialog.debug_print_verbose("Global Folder installation_complete - success=%s, paths=%s" % [success, str(paths)])

		if success and not paths.is_empty():
			# Track paths installed this session
			for p in paths:
				if p not in _session_installed_paths:
					_session_installed_paths.append(p)
			# Register in installed registry using the global_ asset_id
			var manifest = _read_godotpackage_manifest(godotpackage_path)

			SettingsDialog.debug_print_verbose("Registering global folder install - asset_id='%s'" % global_asset_id)

			var reg_info: Dictionary = {
				"asset_id": global_asset_id,
				"title": manifest.get("name", godotpackage_path.get_file().get_basename()),
				"author": manifest.get("author", "Unknown"),
				"description": manifest.get("description", ""),
				"category": manifest.get("type", "Asset"),
				"version": manifest.get("version", ""),
				"source": SOURCE_GLOBAL_FOLDER,
				"original_source": manifest.get("original_source", ""),
				"original_browse_url": manifest.get("original_browse_url", ""),
				"original_url": manifest.get("original_url", ""),
				"godotpackage_path": godotpackage_path  # Store path to extract icon later
			}

			_register_installed_addon(global_asset_id, paths, reg_info, tracked_uids)
			# Update the detail dialog if open
			if _current_detail_dialog and is_instance_valid(_current_detail_dialog):
				_current_detail_dialog.set_installed(true, paths)
			# Update card badge
			_update_card_installed_status(global_asset_id, true)
			_show_global_folder()  # Refresh
			# Safe scan filesystem
			_queue_safe_scan()
	)

	install_dialog.popup_centered()


func _on_remove_from_global_folder(info: Dictionary) -> void:
	# Wait a frame for the previous dialog to fully close
	await get_tree().process_frame
	var godotpackage_path = info.get("godotpackage_path", "")
	if godotpackage_path.is_empty():
		return

	# Confirm deletion
	var confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.title = "Remove from Global Folder"
	confirm_dialog.dialog_text = "Remove '%s' from your global asset folder?\n\nThis will delete the .godotpackage file." % info.get("title", "Unknown")
	confirm_dialog.ok_button_text = "Remove"

	confirm_dialog.confirmed.connect(func():
		confirm_dialog.queue_free()
		# Delete the file
		var err = DirAccess.remove_absolute(godotpackage_path)
		if err == OK:
			SettingsDialog.debug_print(" Removed %s from global folder" % godotpackage_path.get_file())
			_show_global_folder()  # Refresh
		else:
			push_error("AssetPlus: Failed to remove %s (error %d)" % [godotpackage_path, err])
	)

	confirm_dialog.canceled.connect(func():
		confirm_dialog.queue_free()
	)

	EditorInterface.get_base_control().add_child(confirm_dialog)
	confirm_dialog.popup_centered()


func _on_global_folder_metadata_edited(info: Dictionary, new_metadata: Dictionary) -> void:
	var godotpackage_path = info.get("godotpackage_path", "")
	if godotpackage_path.is_empty():
		push_error("AssetPlus: No package path for metadata edit")
		return

	# Read existing package contents
	var reader = ZIPReader.new()
	var err = reader.open(godotpackage_path)
	if err != OK:
		push_error("AssetPlus: Failed to open package for editing: %s" % godotpackage_path)
		return

	# Read existing manifest
	var manifest: Dictionary = {}
	var files_data: Dictionary = {}  # path -> PackedByteArray

	for file_path in reader.get_files():
		var data = reader.read_file(file_path)
		if file_path == "manifest.json":
			var json = JSON.new()
			if json.parse(data.get_string_from_utf8()) == OK:
				manifest = json.data
		elif file_path != "icon.png":  # Don't keep old icon if we're updating it
			files_data[file_path] = data
		else:
			# Keep old icon unless we're changing it
			if not new_metadata.get("_remove_icon", false) and new_metadata.get("_new_icon_data", PackedByteArray()).size() == 0:
				files_data[file_path] = data

	reader.close()

	# Update manifest with new values (except source)
	if new_metadata.has("name"):
		manifest["name"] = new_metadata["name"]
	if new_metadata.has("author"):
		manifest["author"] = new_metadata["author"]
	if new_metadata.has("version"):
		manifest["version"] = new_metadata["version"]
	if new_metadata.has("category"):
		manifest["category"] = new_metadata["category"]
	if new_metadata.has("license"):
		manifest["license"] = new_metadata["license"]
	if new_metadata.has("description"):
		manifest["description"] = new_metadata["description"]

	# Handle icon changes
	var new_icon_data: PackedByteArray = new_metadata.get("_new_icon_data", PackedByteArray())
	var remove_icon: bool = new_metadata.get("_remove_icon", false)

	if remove_icon:
		manifest["has_icon"] = false
		# icon.png already excluded from files_data above
	elif new_icon_data.size() > 0:
		manifest["has_icon"] = true
		# New icon will be added below

	# Write updated package
	var writer = ZIPPacker.new()
	err = writer.open(godotpackage_path)
	if err != OK:
		push_error("AssetPlus: Failed to write package: %s" % godotpackage_path)
		return

	# Write updated manifest
	writer.start_file("manifest.json")
	writer.write_file(JSON.stringify(manifest, "\t").to_utf8_buffer())
	writer.close_file()

	# Write new icon if provided
	if new_icon_data.size() > 0:
		writer.start_file("icon.png")
		writer.write_file(new_icon_data)
		writer.close_file()

	# Write all other files
	for file_path in files_data:
		writer.start_file(file_path)
		writer.write_file(files_data[file_path])
		writer.close_file()

	writer.close()

	SettingsDialog.debug_print(" Updated metadata for %s" % godotpackage_path.get_file())

	# Refresh the view
	_show_global_folder()


func _on_extract_package_requested(info: Dictionary, target_folder: String) -> void:
	var godotpackage_path = info.get("godotpackage_path", "")
	if godotpackage_path.is_empty():
		push_error("AssetPlus: No package path for extraction")
		return

	# Get package name for subfolder
	var package_name = godotpackage_path.get_file().get_basename()

	# Read manifest to get proper name if available
	var reader = ZIPReader.new()
	var err = reader.open(godotpackage_path)
	if err != OK:
		push_error("AssetPlus: Failed to open package for extraction: %s" % godotpackage_path)
		return

	# Try to get name from manifest
	for file_path in reader.get_files():
		if file_path == "manifest.json":
			var data = reader.read_file(file_path)
			var json = JSON.new()
			if json.parse(data.get_string_from_utf8()) == OK:
				var manifest = json.data
				if manifest.has("name") and not manifest["name"].is_empty():
					# Sanitize name for folder
					package_name = manifest["name"].replace(" ", "_").replace("/", "_").replace("\\", "_")
			break

	# Create target subfolder
	var extract_folder = target_folder.path_join(package_name)
	err = DirAccess.make_dir_recursive_absolute(extract_folder)
	if err != OK:
		push_error("AssetPlus: Failed to create extraction folder: %s" % extract_folder)
		reader.close()
		return

	# Extract all files except manifest.json
	var extracted_count = 0
	for file_path in reader.get_files():
		if file_path == "manifest.json":
			continue  # Skip manifest

		var data = reader.read_file(file_path)
		var target_path = extract_folder.path_join(file_path)

		# Create subdirectories if needed
		var dir_path = target_path.get_base_dir()
		DirAccess.make_dir_recursive_absolute(dir_path)

		# Write file
		var file = FileAccess.open(target_path, FileAccess.WRITE)
		if file:
			file.store_buffer(data)
			file.close()
			extracted_count += 1
		else:
			push_error("AssetPlus: Failed to write: %s" % target_path)

	reader.close()

	SettingsDialog.debug_print(" Extracted %d files to %s" % [extracted_count, extract_folder])

	# Show success message
	var success_dialog = AcceptDialog.new()
	success_dialog.title = "Extraction Complete"
	success_dialog.dialog_text = "Extracted %d files to:\n%s" % [extracted_count, extract_folder]
	success_dialog.confirmed.connect(func(): success_dialog.queue_free())
	success_dialog.canceled.connect(func(): success_dialog.queue_free())
	EditorInterface.get_base_control().add_child(success_dialog)
	success_dialog.popup_centered()


func _on_add_to_global_folder_from_installed(info: Dictionary) -> void:
	# Wait a frame for the previous dialog to fully close
	await get_tree().process_frame
	# Get the installed path(s)
	var paths: Array = info.get("installed_paths", [])
	if paths.is_empty():
		var single_path = info.get("installed_path", "")
		if not single_path.is_empty():
			paths = [single_path]

	if paths.is_empty():
		push_error("AssetPlus: No installed path found for asset")
		return

	# Use the first path (usually the main addon folder) - keep as res:// path for ExportDialog
	var folder_path: String = paths[0]

	# Confirm with user
	var confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.title = "Add to Global Folder"
	confirm_dialog.dialog_text = "This will create a local copy of '%s' in your global asset folder.\n\nYou'll be able to select which files to include." % info.get("title", "Unknown")
	confirm_dialog.ok_button_text = "Continue"

	confirm_dialog.confirmed.connect(func():
		confirm_dialog.queue_free()
		# Open export dialog for this folder
		_show_export_for_global_folder(folder_path, info)
	)

	confirm_dialog.canceled.connect(func():
		confirm_dialog.queue_free()
	)

	EditorInterface.get_base_control().add_child(confirm_dialog)
	confirm_dialog.popup_centered()


func _show_export_for_global_folder(folder_path: String, info: Dictionary) -> void:
	# Check if global folder is configured
	var settings = SettingsDialog.get_settings()
	var global_folder = settings.get("global_asset_folder", "")

	if global_folder.is_empty():
		# Prompt to configure global folder first
		_show_global_folder_setup_then_export(folder_path, info)
		return

	# Open export dialog configured for global folder (locked to .godotpackage, auto-export)
	var dialog = ExportDialog.new()
	EditorInterface.get_base_control().add_child(dialog)

	# Pass the cached icon texture if available
	var export_info = info.duplicate()
	var icon_url = info.get("icon_url", "")
	if not icon_url.is_empty() and _icon_cache.has(icon_url):
		export_info["_icon_texture"] = _icon_cache[icon_url]

	dialog.setup_for_global_folder(folder_path, global_folder, export_info)

	dialog.export_completed.connect(func(success: bool, output_path: String):
		if success:
			SettingsDialog.debug_print(" Added to global folder: %s" % output_path)
			# Refresh global folder view if we're on that tab
			if _current_tab == Tab.GLOBAL_FOLDER:
				_show_global_folder()
	)

	dialog.popup_centered()


func _show_global_folder_setup_then_export(folder_path: String, info: Dictionary) -> void:
	var setup_dialog = ConfirmationDialog.new()
	setup_dialog.title = "Global Folder Not Set"
	setup_dialog.dialog_text = "You haven't configured a Global Asset Folder yet.\n\nWould you like to set one up now?"
	setup_dialog.ok_button_text = "Set Up"

	setup_dialog.confirmed.connect(func():
		setup_dialog.queue_free()
		# Show folder selection dialog
		var folder_dialog = FileDialog.new()
		folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
		folder_dialog.title = "Select Global Asset Folder"
		folder_dialog.min_size = Vector2i(600, 400)

		folder_dialog.dir_selected.connect(func(dir_path: String):
			folder_dialog.queue_free()
			# Save to settings
			_save_global_folder_setting(dir_path)
			# Now open export dialog
			_show_export_for_global_folder(folder_path, info)
		)

		folder_dialog.canceled.connect(func():
			folder_dialog.queue_free()
		)

		EditorInterface.get_base_control().add_child(folder_dialog)
		folder_dialog.popup_centered()
	)

	setup_dialog.canceled.connect(func():
		setup_dialog.queue_free()
	)

	EditorInterface.get_base_control().add_child(setup_dialog)
	setup_dialog.popup_centered()


func _show_installed() -> void:
	# Clear current assets
	for child in _assets_grid.get_children():
		child.queue_free()
	_cards.clear()
	_assets.clear()

	_loading_label.text = "Loading..."
	_loading_label.visible = false

	# Try to recover any pending installations (in case callback was lost)
	_recover_pending_installation()

	# Collect UIDs for assets that don't have them (after script reload recovery)
	_collect_missing_uids()

	# Clean up registry first to remove non-existent entries
	_cleanup_installed_registry()

	# Check for updates in background
	call_deferred("_check_addon_updates")

	# Show AssetPlus first (always, with special treatment)
	_create_assetplus_card()

	# Collect all paths from registry to avoid duplicates with scanned addons
	var registry_paths: Array[String] = []
	for asset_id in _installed_registry:
		var paths = _get_installed_addon_paths(asset_id)
		for path in paths:
			if not path.is_empty():
				registry_paths.append(path)

	# Show installed addons from registry (these have full info)
	for asset_id in _installed_registry:
		var entry = _installed_registry[asset_id]
		var paths: Array = []
		var stored_info: Dictionary = {}

		# Handle new format {paths, info}, old format {path, info} and legacy format (just string path)
		if entry is Dictionary:
			if entry.has("paths") and entry["paths"] is Array:
				paths = entry["paths"]
			elif entry.has("path"):
				paths = [entry["path"]]
			stored_info = entry.get("info", {})
		elif entry is String:
			paths = [entry]

		# Filter out non-existent paths
		paths = paths.filter(func(p): return DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(p)))
		if paths.is_empty():
			continue

		# Use stored info if available, otherwise create basic info
		var info: Dictionary = {}
		if not stored_info.is_empty():
			info = stored_info.duplicate()
		else:
			# Fallback: try to extract name from first path
			var folder_name = paths[0].get_file()
			if folder_name.is_empty():
				folder_name = paths[0].trim_suffix("/").get_file()

			info = {
				"asset_id": asset_id,
				"title": folder_name.replace("-", " ").replace("_", " ").capitalize(),
				"author": "Unknown",
				"source": "Installed",
				"license": "Unknown",
				"browse_url": ""
			}

		# Add ALL installed paths (for multi-folder assets)
		info["installed_path"] = paths[0]  # Primary path for backward compatibility
		info["installed_paths"] = paths     # All paths for grouped display

		# Determine the best version to use
		# We compare stored_version (from store at install time) and local_version (from plugin.cfg)
		# Use the HIGHER version to handle cases where:
		# - Author forgot to update plugin.cfg (stored > local)
		# - User manually updated the plugin (local > stored)
		var stored_version = stored_info.get("version", "")
		var local_version = _get_local_version(paths[0])
		var final_version = ""

		if not stored_version.is_empty() and not local_version.is_empty():
			# Compare versions - use the higher one
			if _compare_versions(stored_version, local_version) > 0:
				final_version = stored_version
			else:
				final_version = local_version
		elif not local_version.is_empty():
			final_version = local_version
		elif not stored_version.is_empty():
			final_version = stored_version

		if not final_version.is_empty():
			info["version"] = final_version

		SettingsDialog.debug_print_verbose("Installed asset '%s': stored_version=%s, local_version=%s, final_version=%s" % [
			info.get("title", "?"),
			stored_version if not stored_version.is_empty() else "none",
			local_version if not local_version.is_empty() else "none",
			final_version if not final_version.is_empty() else "none"
		])

		# Filter by search
		if not _search_query.is_empty():
			if not _search_query.to_lower() in info.get("title", "").to_lower():
				continue

		# Filter by category
		if _filter_selected_category != "All":
			var asset_cat = info.get("category", "Unknown")
			if asset_cat.is_empty():
				asset_cat = "Unknown"
			if asset_cat != _filter_selected_category:
				continue

		# Filter by source
		if _filter_selected_source != "All":
			var asset_source = info.get("source", "Unknown")
			if asset_source.is_empty():
				asset_source = "Unknown"
			if asset_source != _filter_selected_source:
				continue

		_assets.append(info)
		_create_installed_card(info)

	# Now scan res://addons/ for plugins not in our registry (native/manual installs)
	_scan_native_addons(registry_paths)


func _scan_native_addons(exclude_paths: Array[String]) -> void:
	SettingsDialog.debug_print(" Scanning native addons in res://addons/...")
	var addons_path = "res://addons/"
	var dir = DirAccess.open(addons_path)
	if not dir:
		SettingsDialog.debug_print(" Could not open addons directory")
		return

	dir.list_dir_begin()
	var folder_name = dir.get_next()

	while folder_name != "":
		if dir.current_is_dir() and not folder_name.begins_with("."):
			var addon_path = addons_path + folder_name

			# Skip if already in registry (avoid duplicates)
			var skip = false
			for excluded in exclude_paths:
				if excluded == addon_path or excluded.trim_suffix("/") == addon_path:
					skip = true
					break

			# Also skip ourselves (assetplus plugin)
			if folder_name == "assetplus":
				skip = true

			if not skip:
				# Check if it's a valid plugin (has plugin.cfg)
				var plugin_cfg_path = addon_path + "/plugin.cfg"
				var is_plugin = FileAccess.file_exists(plugin_cfg_path)

				# Try to read plugin.cfg for name and author
				var plugin_name = folder_name.replace("-", " ").replace("_", " ").capitalize()
				var plugin_author = "Unknown"
				var plugin_description = ""

				if is_plugin:
					var cfg = ConfigFile.new()
					if cfg.load(plugin_cfg_path) == OK:
						plugin_name = cfg.get_value("plugin", "name", plugin_name)
						plugin_author = cfg.get_value("plugin", "author", plugin_author)
						plugin_description = cfg.get_value("plugin", "description", "")

				# Check if we already have a linkup for this plugin
				var info: Dictionary = {}
				SettingsDialog.debug_print(" Found local addon '%s' at %s" % [plugin_name, addon_path])
				if _linkup_cache.has(folder_name) and _linkup_cache[folder_name].get("matched", false):
					# Use linked store info
					SettingsDialog.debug_print(" Using cached linkup for '%s'" % plugin_name)
					info = _linkup_cache[folder_name].get("info", {}).duplicate()
					info["installed_path"] = addon_path
				else:
					# No linkup yet - show as Local and try to find a match
					info = {
						"asset_id": "local-" + folder_name,
						"title": plugin_name,
						"author": plugin_author,
						"source": "Local",
						"license": "Unknown",
						"browse_url": "",
						"description": plugin_description,
						"installed_path": addon_path
					}
					# Try to find a linkup (async - will update registry if found)
					_try_linkup_plugin(folder_name, plugin_name, plugin_author, addon_path)

				# Filter by search
				if not _search_query.is_empty():
					if not _search_query.to_lower() in info.get("title", "").to_lower():
						folder_name = dir.get_next()
						continue

				# Filter by category
				if _filter_selected_category != "All":
					var asset_cat = info.get("category", "Unknown")
					if asset_cat.is_empty():
						asset_cat = "Unknown"
					if asset_cat != _filter_selected_category:
						folder_name = dir.get_next()
						continue

				# Filter by source
				if _filter_selected_source != "All":
					var asset_source = info.get("source", "Unknown")
					if asset_source.is_empty():
						asset_source = "Unknown"
					if asset_source != _filter_selected_source:
						folder_name = dir.get_next()
						continue

				_assets.append(info)
				_create_asset_card(info)

		folder_name = dir.get_next()

	dir.list_dir_end()

	# Show empty state messages
	if _assets.is_empty():
		if _search_query.is_empty() and _filter_selected_category == "All" and _filter_selected_source == "All":
			# No addons installed at all
			var info_label = Label.new()
			info_label.text = "No addons installed in this project.\n\nInstall assets from the Store, Favorites, or Global Folder tabs."
			info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			info_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			_assets_grid.add_child(info_label)
		else:
			# Has addons but filters don't match
			_loading_label.text = "No installed assets match the current filters"
			_loading_label.visible = true


func _fetch_godot_assets() -> void:
	var http = HTTPRequest.new()
	add_child(http)
	_http_requests.append(http)

	# Use high version number to get all Godot 4.x assets (future-proof)
	var engine_version = Engine.get_version_info()
	var godot_ver = "%d.9" % engine_version.get("major", 4)  # e.g., "4.9" for Godot 4.x

	# Build URL with version filter - required for API to return Godot 4+ assets
	var url = "%s/asset?godot_version=%s&max_results=%d" % [GODOT_API, godot_ver, ITEMS_PER_PAGE]
	if not _search_query.is_empty():
		url += "&filter=%s" % _search_query.uri_encode()
	url += "&page=%d" % _current_page

	var category_idx = _category_filter.selected
	if category_idx > 0:
		url += "&category=%d" % category_idx
		# Categories 8 (Templates), 9 (Projects), 10 (Demos) require type=any to work
		# Otherwise the API returns 0 results for these categories
		if category_idx in [8, 9, 10]:
			url += "&type=any"

	# Sort
	var sort_idx = _sort_filter.selected
	match sort_idx:
		0: url += "&sort=updated"
		1: url += "&sort=name"
		2: url += "&sort=rating"

	SettingsDialog.debug_print(" Fetching AssetLib URL: %s" % url)

	http.request_completed.connect(func(result, code, headers, body):
		_http_requests.erase(http)
		http.queue_free()
		_on_godot_response(result, code, body)
	)
	http.request(url)


func _on_godot_response(result: int, code: int, body: PackedByteArray) -> void:
	# Don't add cards if we've switched away from Store tab
	if _current_tab != Tab.STORE:
		_check_no_results()
		return

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		SettingsDialog.debug_print(" AssetLib request failed - code %d" % code)
		_check_no_results()
		return

	var response_text = body.get_string_from_utf8()

	# Debug: save response to file
	var log_file = FileAccess.open("user://assetlib_search_response.json", FileAccess.WRITE)
	if log_file:
		log_file.store_string(response_text)
		log_file.close()
		SettingsDialog.debug_print(" AssetLib response saved to user://assetlib_search_response.json")

	var json = JSON.new()
	if json.parse(response_text) != OK:
		SettingsDialog.debug_print(" Failed to parse JSON response")
		return

	var data = json.data
	_total_pages = max(_total_pages, data.get("pages", 1))

	var results = data.get("result", [])
	for asset in results:
		var info = {
			"source": SOURCE_GODOT,
			"asset_id": str(asset.get("asset_id", "")),
			"title": asset.get("title", "Unknown"),
			"author": asset.get("author", "Unknown"),
			"category": asset.get("category", ""),
			"version": asset.get("version_string", ""),
			"description": asset.get("description", ""),
			"icon_url": asset.get("icon_url", ""),
			"cost": asset.get("cost", "Free"),
			"license": asset.get("license", "MIT"),
			"support_level": asset.get("support_level", ""),
			"browse_url": "https://godotengine.org/asset-library/asset/" + str(asset.get("asset_id", ""))
		}
		# Skip AssetPlus itself from store results
		if _is_assetplus(info):
			continue
		_assets.append(info)
		_create_asset_card(info)

	_loading_label.visible = false
	_update_pagination()
	_check_no_results()


var _beta_last_query: String = ""
var _beta_last_category: int = -1
var _beta_last_sort: int = -1
var _beta_total_count: int = 0

func _fetch_godot_beta_assets() -> void:
	var category_idx = _category_filter.selected
	var sort_idx = _sort_filter.selected

	# Check if query/category/sort changed - if so, reset pagination
	var params_changed = _beta_last_query != _search_query or _beta_last_category != category_idx or _beta_last_sort != sort_idx

	if params_changed:
		_beta_total_count = 0
		_current_page = 0
		_beta_last_query = _search_query
		_beta_last_category = category_idx
		_beta_last_sort = sort_idx

	# Fetch the current page from API
	_fetch_beta_api_page()


func _fetch_beta_api_page() -> void:
	var category_idx = _beta_last_category
	var sort_idx = _beta_last_sort

	var http = HTTPRequest.new()
	add_child(http)
	_http_requests.append(http)

	# Map category index to API tag slug
	var category_map = {
		0: "",           # All - no filter
		1: "2d",         # 2D
		2: "3d",         # 3D
		3: "tool",       # Tool
		4: "audio",      # Audio
		5: "template",   # Template
		6: "materials",  # Materials
		7: "vfx"         # VFX
	}

	var tag = category_map.get(category_idx, "")

	var sort_param = "updated_desc"
	match sort_idx:
		0: sort_param = "updated_desc"
		1: sort_param = "relevance"
		2: sort_param = "reviews_desc"

	# Build query with tag filter
	var query = _search_query if not _search_query.is_empty() else "*"
	if not tag.is_empty():
		query = "#%s %s" % [tag, query] if query != "*" else "#%s" % tag

	# Use page parameter (1-indexed in API)
	var url = "https://store-beta.godotengine.org/api/v1/search/query/?query=%s&sort=%s&batch_size=%d&page=%d" % [query.uri_encode(), sort_param, ITEMS_PER_PAGE, _current_page + 1]

	SettingsDialog.debug_print("Fetching Beta Store API: %s" % url)

	http.request_completed.connect(func(result, code, headers, body):
		_http_requests.erase(http)
		http.queue_free()
		_on_godot_beta_api_response(result, code, body)
	)
	http.request(url)


func _on_godot_beta_api_response(result: int, code: int, body: PackedByteArray) -> void:
	# Don't process if we've switched away from Store tab
	if _current_tab != Tab.STORE:
		_check_no_results()
		return

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		SettingsDialog.debug_print("Godot Store Beta API: HTTP error %d" % code)
		_check_no_results()
		return

	var json_str = body.get_string_from_utf8()
	var json = JSON.new()
	if json.parse(json_str) != OK:
		SettingsDialog.debug_print("Godot Store Beta API: JSON parse error")
		_check_no_results()
		return

	var data = json.data
	if not data is Dictionary:
		SettingsDialog.debug_print("Godot Store Beta API: unexpected response format")
		_check_no_results()
		return

	# Get total count for pagination
	_beta_total_count = int(data.get("count", "0"))

	# Calculate total pages from server count
	_total_pages = max(1, ceili(float(_beta_total_count) / ITEMS_PER_PAGE))

	var assets_array: Array = data.get("hits", [])

	# Map tag slugs to display categories
	var tag_to_category = {
		"3d": "3D",
		"2d": "2D",
		"tool": "Tools",
		"audio": "Audio",
		"template": "Templates",
		"materials": "Materials",
		"vfx": "VFX"
	}

	# Clear current page assets and rebuild
	_assets.clear()
	_cards.clear()
	for child in _assets_grid.get_children():
		child.queue_free()

	for hit in assets_array:
		# Data is in hit.asset, not directly in hit
		var asset = hit.get("asset", {})
		if asset.is_empty():
			continue

		var publisher_info = asset.get("publisher", {})
		var publisher_slug = publisher_info.get("slug", "unknown")
		var asset_slug = asset.get("slug", "")
		var key = "%s/%s" % [publisher_slug, asset_slug]

		# Extract categories from tags
		var tags = asset.get("tags", [])
		var categories: Array[String] = []
		for tag in tags:
			var tag_slug = tag.get("slug", "") if tag is Dictionary else str(tag)
			if tag_to_category.has(tag_slug):
				var cat_display = tag_to_category[tag_slug]
				if cat_display not in categories:
					categories.append(cat_display)

		var category_str = ", ".join(categories) if categories.size() > 0 else "Tools"

		# Handle thumbnail URL - prefix with domain if relative
		var thumbnail = asset.get("thumbnail", "")
		if thumbnail.begins_with("/"):
			thumbnail = "https://store-beta.godotengine.org" + thumbnail
		elif thumbnail.is_empty():
			thumbnail = GODOT_BETA_DEFAULT_IMAGE

		var info = {
			"source": SOURCE_GODOT_BETA,
			"asset_id": key,
			"title": asset.get("name", asset_slug.replace("-", " ").capitalize()),
			"author": publisher_info.get("name", publisher_slug.replace("-", " ").capitalize()),
			"category": category_str,
			"version": "",
			"description": asset.get("description", ""),
			"icon_url": thumbnail,
			"license": asset.get("license_type", "MIT"),
			"cost": "Free" if asset.get("price_cent", 0) == 0 else "$%.2f" % (asset.get("price_cent", 0) / 100.0),
			"browse_url": asset.get("store_url", "https://store-beta.godotengine.org/asset/%s/%s/" % [publisher_slug, asset_slug]),
			"reviews_score": asset.get("reviews_score", 0)
		}
		# Skip AssetPlus itself from store results
		if _is_assetplus(info):
			continue
		_assets.append(info)
		_create_asset_card(info)

	SettingsDialog.debug_print("Beta Store API: page %d/%d, showing %d assets (total: %d)" % [_current_page + 1, _total_pages, assets_array.size(), _beta_total_count])

	_loading_label.visible = false
	_update_pagination()
	_check_no_results()


# Cache for godotshaders pagination
var _shaders_all_assets: Array[Dictionary] = []
var _shaders_last_query: String = ""
var _shaders_last_category: int = -1
var _shaders_last_sort: int = -1

func _fetch_godot_shaders() -> void:
	var category_idx = _category_filter.selected
	var sort_idx = _sort_filter.selected

	# Check cache - must match query, category, and sort
	if _shaders_all_assets.size() > 0 and _shaders_last_query == _search_query and _shaders_last_category == category_idx and _shaders_last_sort == sort_idx:
		_display_shaders_page()
		_loading_label.visible = false
		_check_no_results()
		return

	_shaders_last_query = _search_query
	_shaders_last_category = category_idx
	_shaders_last_sort = sort_idx

	var http = HTTPRequest.new()
	add_child(http)
	_http_requests.append(http)

	# Build URL with JSON API
	var url = "https://godotshaders.com/wp-json/gds/v1/shaders?per_page=%d&page=%d" % [ITEMS_PER_PAGE, _current_page + 1]

	# Add shader type filter based on category
	# 0=All, 1=Canvas Item, 2=Spatial, 3=Sky, 4=Particles, 5=Fog
	var shader_type_map = {
		1: "canvas_item",
		2: "spatial",
		3: "sky",
		4: "particles",
		5: "fog"
	}
	if shader_type_map.has(category_idx):
		url += "&shader_type=%s" % shader_type_map[category_idx]

	# Add sort parameter
	# 0=Newest, 1=Most Liked, 2=Alphabetical
	if not _search_query.is_empty():
		# With search, use relevance by default
		url += "&q=%s&orderby=relevance&order=DESC" % _search_query.uri_encode()
	else:
		match sort_idx:
			0:  # Newest
				url += "&orderby=date&order=DESC"
			1:  # Most Liked
				url += "&orderby=likes&order=DESC"
			2:  # Alphabetical
				url += "&orderby=title&order=ASC"
			_:
				url += "&orderby=date&order=DESC"

	http.request_completed.connect(func(result, code, headers, body):
		_http_requests.erase(http)
		http.queue_free()
		_on_godot_shaders_response(result, code, body)
	)
	http.request(url)


func _on_godot_shaders_response(result: int, code: int, body: PackedByteArray) -> void:
	# Don't add cards if we've switched away from Store tab
	if _current_tab != Tab.STORE:
		_check_no_results()
		return

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		SettingsDialog.debug_print("Godot Shaders: HTTP error %d" % code)
		_check_no_results()
		return

	var response_text = body.get_string_from_utf8()

	_shaders_all_assets.clear()

	# Parse JSON API response
	var json = JSON.new()
	if json.parse(response_text) != OK:
		SettingsDialog.debug_print("Godot Shaders: Failed to parse JSON response")
		_check_no_results()
		return

	var data = json.data
	if not data is Dictionary or not data.has("html"):
		SettingsDialog.debug_print("Godot Shaders: Invalid JSON response format")
		_check_no_results()
		return

	var html: String = data.get("html", "")

	# Parse shader cards from the HTML
	# Each card has classes like: gds-shader-card__link, gds-shader-card__title, etc.

	# Extract individual shader cards (articles)
	var card_regex = RegEx.new()
	card_regex.compile('<article[^>]*class="[^"]*gds-shader-card[^"]*"[^>]*>([\\s\\S]*?)</article>')
	var cards = card_regex.search_all(html)

	SettingsDialog.debug_print("Godot Shaders JSON API: found %d shader cards" % cards.size())

	for card_match in cards:
		var card_html = card_match.get_string(0)

		# Extract link/slug from gds-shader-card__link
		var slug = ""
		var link = ""
		var link_regex = RegEx.new()
		link_regex.compile('href="https://godotshaders\\.com/shader/([a-z0-9-]+)/?"')
		var link_match = link_regex.search(card_html)
		if link_match:
			slug = link_match.get_string(1)
			link = "https://godotshaders.com/shader/%s/" % slug

		if slug.is_empty():
			continue

		# Extract title from gds-shader-card__title
		var title = slug.replace("-", " ").capitalize()
		var title_regex = RegEx.new()
		title_regex.compile('class="[^"]*gds-shader-card__title[^"]*"[^>]*>([^<]+)<')
		var title_match = title_regex.search(card_html)
		if title_match:
			title = title_match.get_string(1).strip_edges()

		# Extract author from gds-shader-card__author
		var author = "Unknown"
		var author_regex = RegEx.new()
		author_regex.compile('class="[^"]*gds-shader-card__author[^"]*"[^>]*>([^<]+)<')
		var author_match = author_regex.search(card_html)
		if author_match:
			author = author_match.get_string(1).strip_edges()

		# Extract image from gds-shader-card__cover background-image:url(...)
		var icon_url = ""
		var img_regex = RegEx.new()
		img_regex.compile('class="[^"]*gds-shader-card__cover[^"]*"[^>]*style="[^"]*background-image:\\s*url\\(([^)]+)\\)')
		var img_match = img_regex.search(card_html)
		if img_match:
			icon_url = img_match.get_string(1).strip_edges()
			# Remove quotes if present
			icon_url = icon_url.trim_prefix("'").trim_suffix("'")
			icon_url = icon_url.trim_prefix('"').trim_suffix('"')

		# Extract shader type from gds-shader-card__type--canvas_item or gds-shader-card__type--spatial
		var category = "Shaders"
		var type_regex = RegEx.new()
		type_regex.compile('gds-shader-card__type--([a-z_]+)')
		var type_match = type_regex.search(card_html)
		if type_match:
			var shader_type = type_match.get_string(1)
			match shader_type:
				"canvas_item":
					category = "2D Shader"
				"spatial":
					category = "3D Shader"
				"particles":
					category = "Particles"
				"sky":
					category = "Sky"
				"fog":
					category = "Fog"
				_:
					category = shader_type.replace("_", " ").capitalize()

		_shaders_all_assets.append({
			"source": SOURCE_SHADERS,
			"asset_id": "shader-" + slug,
			"title": title,
			"author": author,
			"category": category,
			"version": "",
			"description": "",
			"icon_url": icon_url,
			"license": "MIT",
			"cost": "Free",
			"browse_url": link
		})

	SettingsDialog.debug_print(" Parsed %d shaders from JSON API" % _shaders_all_assets.size())

	_display_shaders_page()
	_loading_label.visible = false
	_check_no_results()


func _display_shaders_page() -> void:
	# Don't add cards if we've switched away from Store tab
	if _current_tab != Tab.STORE:
		return

	_total_pages = max(_total_pages, ceili(float(_shaders_all_assets.size()) / ITEMS_PER_PAGE))

	var start_idx = _current_page * ITEMS_PER_PAGE
	var end_idx = min(start_idx + ITEMS_PER_PAGE, _shaders_all_assets.size())

	for i in range(start_idx, end_idx):
		var info = _shaders_all_assets[i]
		_assets.append(info)
		_create_asset_card(info)

	_update_pagination()


func _calculate_card_width() -> float:
	# Get available width from scroll container (minus scrollbar width ~12px)
	var available_width = _assets_scroll.size.x - 12

	if available_width <= 0:
		return CARD_MIN_WIDTH

	# Calculate how many columns fit
	var num_columns = max(1, int(available_width / (CARD_MIN_WIDTH + CARD_SPACING)))

	# Calculate card width to fill the space evenly
	var card_width = (available_width - (num_columns - 1) * CARD_SPACING) / num_columns

	# Clamp to reasonable bounds
	return clampf(card_width, CARD_MIN_WIDTH, CARD_MAX_WIDTH)


func _update_card_sizes() -> void:
	var card_width = _calculate_card_width()

	for card in _cards:
		if is_instance_valid(card):
			card.custom_minimum_size = Vector2(card_width, CARD_HEIGHT)


func _create_asset_card(info: Dictionary) -> void:
	var is_fav = _is_favorite(info)
	var is_inst = _is_addon_installed(info.get("asset_id", ""))

	var card = AssetCard.new()
	var card_width = _calculate_card_width()
	card.custom_minimum_size = Vector2(card_width, CARD_HEIGHT)
	card.setup(info, is_fav, is_inst)
	card.clicked.connect(_on_asset_clicked)
	card.favorite_clicked.connect(_on_favorite_clicked)
	_assets_grid.add_child(card)
	_cards.append(card)

	# Load icon (with fallback to default)
	var icon_url = info.get("icon_url", "")
	if not icon_url.is_empty():
		_load_icon(card, icon_url)
	elif _default_icon:
		card.set_icon(_default_icon)


func _create_assetplus_card() -> void:
	## Create a special card for AssetPlus itself (always shown first in Installed)
	var addon_path = "res://addons/assetplus"
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(addon_path)):
		return

	# Read version from plugin.cfg
	var version = "1.0.0"
	var cfg = ConfigFile.new()
	if cfg.load(addon_path + "/plugin.cfg") == OK:
		version = cfg.get_value("plugin", "version", version)

	var info = {
		"asset_id": "assetplus-self",
		"title": "AssetPlus",
		"author": "MoongDevStudio",
		"source": "This Plugin",
		"version": version,
		"category": "Tools",
		"license": "MIT",
		"description": "The asset browser you're currently using!",
		"browse_url": "https://github.com/moongdevstudio/AssetPlus",
		"installed_path": addon_path,
		"is_assetplus": true  # Special flag
	}

	# Check search filter
	if not _search_query.is_empty():
		if not _search_query.to_lower() in info.get("title", "").to_lower():
			return

	# Check category filter
	if _filter_selected_category != "All":
		if info.get("category", "") != _filter_selected_category:
			return

	# Check source filter - "This Plugin" should match only when All or specific
	if _filter_selected_source != "All" and _filter_selected_source != "This Plugin":
		return

	var card_width = _calculate_card_width()
	var card = AssetCard.new()
	card.custom_minimum_size = Vector2(card_width, CARD_HEIGHT)

	# Setup card without favorites (pass false for is_favorite, true for is_installed)
	card.setup(info, false, true)

	# Hide favorite button for AssetPlus
	card.set_favorite_visible(false)

	card.clicked.connect(_on_asset_clicked)
	# Don't connect favorite_clicked since we hide the button
	_assets_grid.add_child(card)
	_cards.append(card)

	# Plugin toggle (AssetPlus is always a plugin)
	var is_enabled = _is_plugin_enabled(addon_path)
	card.set_plugin_visible(true)
	card.set_plugin_enabled(is_enabled)
	card.plugin_toggled.connect(func(_card_info, enabled):
		_set_plugin_enabled(addon_path, enabled)
	)

	# Load icon from addon folder
	var icon_path = addon_path + "/icon.png"
	if FileAccess.file_exists(icon_path):
		var icon_texture = load(icon_path)
		if icon_texture:
			card.set_icon(icon_texture)
	elif _default_icon:
		card.set_icon(_default_icon)

	_assets.append(info)


func _create_installed_card(info: Dictionary) -> void:
	# For assets with multiple folders, create a grouped display
	var paths: Array = info.get("installed_paths", [])
	if paths.is_empty():
		var single_path = info.get("installed_path", "")
		if not single_path.is_empty():
			paths = [single_path]

	var is_fav = _is_favorite(info)
	var card_width = _calculate_card_width()

	if paths.size() <= 1:
		# Single folder - create card with built-in enable/disable toggle
		var single_path = paths[0] if paths.size() > 0 else info.get("installed_path", "")
		var has_plugin = _has_plugin_cfg(single_path) if not single_path.is_empty() else false

		var card = AssetCard.new()
		card.custom_minimum_size = Vector2(card_width, CARD_HEIGHT)
		card.setup(info, is_fav, true)
		card.clicked.connect(_on_asset_clicked)
		card.favorite_clicked.connect(_on_favorite_clicked)
		_assets_grid.add_child(card)
		_cards.append(card)

		# Check for update available
		var asset_id = info.get("asset_id", "")
		var installed_version = info.get("version", "")
		if _has_update_available(asset_id, installed_version):
			var update_info = _get_update_info(asset_id)
			card.set_update_available(true, update_info.get("latest_version", ""))

		# Setup plugin toggle if it's a plugin
		if has_plugin:
			var is_enabled = _is_plugin_enabled(single_path)
			card.set_plugin_visible(true)
			card.set_plugin_enabled(is_enabled)
			var path_for_toggle = single_path
			card.plugin_toggled.connect(func(_card_info, enabled):
				_set_plugin_enabled(path_for_toggle, enabled)
			)

		# Load icon (with fallback to default)
		# For GlobalFolder items, extract icon from the godotpackage file
		var godotpackage_path = info.get("godotpackage_path", "")
		if not godotpackage_path.is_empty() and FileAccess.file_exists(godotpackage_path):
			var icon_texture = _extract_icon_from_godotpackage(godotpackage_path)
			if icon_texture:
				card.set_icon(icon_texture)
			elif _default_icon:
				card.set_icon(_default_icon)
		else:
			var icon_url = info.get("icon_url", "")
			if not icon_url.is_empty():
				_load_icon(card, icon_url)
			elif _default_icon:
				card.set_icon(_default_icon)
		return

	# Multiple folders - card with small expand indicator at bottom right
	var card = AssetCard.new()
	card.custom_minimum_size = Vector2(card_width, CARD_HEIGHT)

	# Modify title to show folder count
	var display_info = info.duplicate()
	display_info["title"] = "%s (%d)" % [info.get("title", "Unknown"), paths.size()]
	card.setup(display_info, is_fav, true)
	# Use lambda to pass original info (not display_info with modified title)
	card.clicked.connect(func(_card_info): _on_asset_clicked(info))
	card.favorite_clicked.connect(_on_favorite_clicked)
	_assets_grid.add_child(card)
	_cards.append(card)

	# Check for update available
	var asset_id = info.get("asset_id", "")
	var installed_version = info.get("version", "")
	if _has_update_available(asset_id, installed_version):
		var update_info = _get_update_info(asset_id)
		card.set_update_available(true, update_info.get("latest_version", ""))

	# Load icon (with fallback to default)
	# For GlobalFolder items, extract icon from the godotpackage file
	var godotpackage_path = info.get("godotpackage_path", "")
	if not godotpackage_path.is_empty() and FileAccess.file_exists(godotpackage_path):
		var icon_texture = _extract_icon_from_godotpackage(godotpackage_path)
		if icon_texture:
			card.set_icon(icon_texture)
		elif _default_icon:
			card.set_icon(_default_icon)
	else:
		var icon_url = info.get("icon_url", "")
		if not icon_url.is_empty():
			_load_icon(card, icon_url)
		elif _default_icon:
			card.set_icon(_default_icon)

	# Check if any folder has a plugin and count enabled
	var plugin_paths: Array = []
	for p in paths:
		if _has_plugin_cfg(p):
			plugin_paths.append(p)

	# Store sub-toggle buttons for syncing
	var sub_toggle_btns: Array[Button] = []

	# Add global ON/OFF toggle if there are plugins
	if plugin_paths.size() > 0:
		var any_enabled = false
		for p in plugin_paths:
			if _is_plugin_enabled(p):
				any_enabled = true
				break

		card.set_plugin_visible(true)
		card.set_plugin_enabled(any_enabled)
		card.plugin_toggled.connect(func(_card_info, enabled):
			# Toggle all plugins at once
			for p in plugin_paths:
				_set_plugin_enabled(p, enabled)
			# Update all sub-toggle buttons to match (without triggering their signals)
			for btn in sub_toggle_btns:
				if is_instance_valid(btn):
					btn.set_pressed_no_signal(enabled)
					btn.text = "ON" if enabled else "OFF"
					_style_toggle_btn(btn, enabled)
		)

	# Create small expand indicator at bottom right of card
	var expand_btn = Button.new()
	expand_btn.text = "%d ▼" % paths.size()
	expand_btn.flat = true
	expand_btn.custom_minimum_size = Vector2(32, 18)
	expand_btn.add_theme_font_size_override("font_size", 10)
	expand_btn.add_theme_color_override("font_color", Color(0.5, 0.7, 0.9))
	expand_btn.tooltip_text = "Show %d addon folders" % paths.size()
	expand_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	card.add_child(expand_btn)

	# Position at bottom right using anchors (moved up a bit)
	expand_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	expand_btn.offset_left = -44
	expand_btn.offset_top = -28
	expand_btn.offset_right = -8
	expand_btn.offset_bottom = -10

	# Create overlay panel (top level so it floats above everything)
	var overlay = PanelContainer.new()
	overlay.set_as_top_level(true)
	overlay.visible = false

	var overlay_style = StyleBoxFlat.new()
	overlay_style.bg_color = Color(0.15, 0.15, 0.18, 0.98)
	overlay_style.set_corner_radius_all(6)
	overlay_style.set_border_width_all(1)
	overlay_style.border_color = Color(0.3, 0.3, 0.35)
	overlay_style.set_content_margin_all(8)
	overlay.add_theme_stylebox_override("panel", overlay_style)

	var sub_container = VBoxContainer.new()
	sub_container.add_theme_constant_override("separation", 4)
	overlay.add_child(sub_container)

	# Create sub-items for each folder
	for folder_path in paths:
		var folder_name = folder_path.get_file()
		if folder_name.is_empty():
			folder_name = folder_path.trim_suffix("/").get_file()

		var sub_item = HBoxContainer.new()
		sub_item.add_theme_constant_override("separation", 8)

		# Folder icon and name
		var folder_label = Label.new()
		folder_label.text = "📁 %s" % folder_name
		folder_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		folder_label.add_theme_font_size_override("font_size", 12)
		folder_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		sub_item.add_child(folder_label)

		# Enable/disable toggle if it's a plugin
		var has_plugin = _has_plugin_cfg(folder_path)
		if has_plugin:
			var toggle_btn = Button.new()
			var is_enabled = _is_plugin_enabled(folder_path)
			toggle_btn.toggle_mode = true
			toggle_btn.button_pressed = is_enabled
			toggle_btn.text = "ON" if is_enabled else "OFF"
			toggle_btn.custom_minimum_size = Vector2(38, 20)
			toggle_btn.add_theme_font_size_override("font_size", 10)
			_style_toggle_btn(toggle_btn, is_enabled)
			toggle_btn.tooltip_text = "Enable/Disable this plugin"
			var path_for_toggle = folder_path
			toggle_btn.toggled.connect(func(pressed):
				_set_plugin_enabled(path_for_toggle, pressed)
				toggle_btn.text = "ON" if pressed else "OFF"
				_style_toggle_btn(toggle_btn, pressed)
				# Update main card toggle to reflect overall state
				var all_on = true
				var any_on = false
				for btn in sub_toggle_btns:
					if is_instance_valid(btn):
						if btn.button_pressed:
							any_on = true
						else:
							all_on = false
				card.set_plugin_enabled(any_on)
			)
			sub_toggle_btns.append(toggle_btn)
			sub_item.add_child(toggle_btn)

		# Individual delete button
		var del_btn = Button.new()
		del_btn.text = "×"
		del_btn.flat = true
		del_btn.custom_minimum_size = Vector2(24, 24)
		del_btn.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))
		del_btn.tooltip_text = "Delete only this folder"
		var path_to_delete = folder_path
		var del_asset_id = info.get("asset_id", "")
		del_btn.pressed.connect(func():
			overlay.visible = false
			expand_btn.text = "%d ▼" % paths.size()
			_uninstall_single_folder(del_asset_id, path_to_delete, info.get("title", "addon"))
		)
		sub_item.add_child(del_btn)

		sub_container.add_child(sub_item)

	card.add_child(overlay)

	# Expand button toggle
	expand_btn.pressed.connect(func():
		overlay.visible = not overlay.visible
		if overlay.visible:
			expand_btn.text = "%d ▲" % paths.size()
			# Position overlay below the card
			var card_global = card.get_global_rect()
			overlay.global_position = Vector2(card_global.position.x + 8, card_global.position.y + card_global.size.y + 2)
			overlay.custom_minimum_size.x = card_width - 16
		else:
			expand_btn.text = "%d ▼" % paths.size()
	)


func _style_toggle_btn(btn: Button, enabled: bool) -> void:
	var style = StyleBoxFlat.new()
	style.set_corner_radius_all(10)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 2
	style.content_margin_bottom = 2

	if enabled:
		style.bg_color = Color(0.25, 0.55, 0.25)
		btn.add_theme_color_override("font_color", Color(0.85, 1.0, 0.85))
		btn.add_theme_color_override("font_pressed_color", Color(0.85, 1.0, 0.85))
	else:
		style.bg_color = Color(0.45, 0.25, 0.25)
		btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.85))
		btn.add_theme_color_override("font_pressed_color", Color(1.0, 0.85, 0.85))

	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("hover", style)
	btn.add_theme_stylebox_override("pressed", style)
	btn.add_theme_stylebox_override("focus", style)


func _uninstall_single_folder(asset_id: String, folder_path: String, title: String) -> void:
	# Get tracked UIDs for this folder only
	var all_uids = _get_installed_addon_uids(asset_id)
	var folder_uids = all_uids.filter(func(uid_entry):
		var path: String = uid_entry.get("path", "")
		return path.begins_with(folder_path + "/") or path == folder_path
	)
	var use_safe_mode = folder_uids.size() > 0

	# Check if this was installed during current session (may cause crash)
	var installed_this_session = false
	for session_path in _session_installed_paths:
		if folder_path.begins_with(session_path) or session_path.begins_with(folder_path):
			installed_this_session = true
			break

	var confirm = ConfirmationDialog.new()
	confirm.title = "Delete Folder"

	var warning_text = ""
	if installed_this_session:
		warning_text = "\n\n⚠️ WARNING: This was installed during the current session.\nGodot may crash. Restart Godot first for safe deletion."

	if use_safe_mode:
		confirm.dialog_text = "Delete tracked files from '%s'?\n\n%s\n\n(%d tracked files, your additions will be kept)%s" % [title, folder_path, folder_uids.size(), warning_text]
	else:
		confirm.dialog_text = "Delete this folder from '%s'?\n\n%s\n\n(Warning: All files will be deleted)%s" % [title, folder_path, warning_text]
	confirm.ok_button_text = "Delete"

	var uids_to_delete = folder_uids.duplicate()
	var safe_mode = use_safe_mode
	var path_to_delete = folder_path

	confirm.confirmed.connect(func():
		# IMPORTANT: Disable plugin BEFORE deleting files to prevent crash
		_disable_plugins_before_uninstall([path_to_delete])

		# Remove autoloads that reference scripts in the folder being deleted
		_remove_autoloads_in_paths([path_to_delete])

		if safe_mode:
			_delete_tracked_files_only(uids_to_delete, [path_to_delete])
		else:
			_do_uninstall(path_to_delete)

		# Update registry
		var paths = _get_installed_addon_paths(asset_id)
		paths = paths.filter(func(p): return p != path_to_delete)

		# Also update UIDs list to remove deleted ones
		var remaining_uids = all_uids.filter(func(uid_entry):
			var path: String = uid_entry.get("path", "")
			return not (path.begins_with(path_to_delete + "/") or path == path_to_delete)
		)

		if paths.is_empty():
			_unregister_installed_addon(asset_id)
			_clear_installed_paths_from_favorite(asset_id)  # Clear cached paths from favorites
		else:
			var info = _get_installed_addon_info(asset_id)
			_register_installed_addon(asset_id, paths, info, remaining_uids)
		_show_installed()
	)

	EditorInterface.get_base_control().add_child(confirm)
	confirm.popup_centered()


func _update_card_installed_status(asset_id: String, is_installed: bool) -> void:
	# Update ALL cards with matching asset_id (could be in multiple places)
	for card in _cards:
		if is_instance_valid(card) and card.get_info().get("asset_id", "") == asset_id:
			card.set_installed(is_installed)
			# Don't break - update all matching cards


func _load_icon(card: Control, url: String) -> void:
	if _icon_cache.has(url):
		card.set_icon(_icon_cache[url])
		return

	var http = HTTPRequest.new()
	add_child(http)

	http.request_completed.connect(func(result, code, headers, body):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200 and body.size() > 8:
			var img = Image.new()
			var success = false

			# Detect format using magic bytes (avoids error spam from trying wrong formats)
			var magic = body.slice(0, 8)
			var is_png = magic[0] == 0x89 and magic[1] == 0x50 and magic[2] == 0x4E and magic[3] == 0x47
			var is_jpg = magic[0] == 0xFF and magic[1] == 0xD8 and magic[2] == 0xFF
			var is_webp = magic[0] == 0x52 and magic[1] == 0x49 and magic[2] == 0x46 and magic[3] == 0x46 and body.size() > 12 and body[8] == 0x57 and body[9] == 0x45 and body[10] == 0x42 and body[11] == 0x50
			var is_gif = magic[0] == 0x47 and magic[1] == 0x49 and magic[2] == 0x46

			if is_png:
				success = img.load_png_from_buffer(body) == OK
			elif is_jpg:
				success = img.load_jpg_from_buffer(body) == OK
			elif is_webp:
				success = img.load_webp_from_buffer(body) == OK
			elif is_gif:
				# Handle GIF separately below
				pass
			else:
				# Unknown format - try based on URL extension as fallback
				var url_lower = url.to_lower()
				if url_lower.ends_with(".jpg") or url_lower.ends_with(".jpeg"):
					success = img.load_jpg_from_buffer(body) == OK
				elif url_lower.ends_with(".webp"):
					success = img.load_webp_from_buffer(body) == OK
				elif url_lower.ends_with(".png"):
					success = img.load_png_from_buffer(body) == OK

			if success:
				var tex = ImageTexture.create_from_image(img)
				_icon_cache[url] = tex
				if is_instance_valid(card):
					card.set_icon(tex)
			elif is_gif:
				# Try GIF decoder for first frame
				var gif_img = _decode_gif_first_frame(body)
				if gif_img:
					var tex = ImageTexture.create_from_image(gif_img)
					_icon_cache[url] = tex
					if is_instance_valid(card):
						card.set_icon(tex)
				elif is_instance_valid(card) and _default_icon:
					card.set_icon(_default_icon)
			else:
				# Unknown/unsupported format - use default icon
				if is_instance_valid(card) and _default_icon:
					card.set_icon(_default_icon)
		else:
			# Download failed - use default icon
			if is_instance_valid(card) and _default_icon:
				card.set_icon(_default_icon)
	)
	http.request(url)


## Decode the first frame of a GIF image
func _decode_gif_first_frame(data: PackedByteArray) -> Image:
	# Check minimum size and GIF header
	if data.size() < 13:
		return null

	var header = data.slice(0, 6).get_string_from_ascii()
	if header != "GIF89a" and header != "GIF87a":
		return null

	# Read Logical Screen Descriptor
	var width = data.decode_u16(6)
	var height = data.decode_u16(8)
	var packed = data[10]
	var has_gct = (packed & 0x80) != 0
	var gct_size = 1 << ((packed & 0x07) + 1)
	var bg_color_index = data[11]

	var pos = 13

	# Read Global Color Table
	var gct: PackedByteArray = PackedByteArray()
	if has_gct:
		if pos + gct_size * 3 > data.size():
			return null
		gct = data.slice(pos, pos + gct_size * 3)
		pos += gct_size * 3

	# Track transparent color index
	var transparent_index = -1

	# Find first Image Descriptor (0x2C)
	while pos < data.size():
		var block_type = data[pos]
		pos += 1

		if block_type == 0x2C:  # Image Descriptor
			if pos + 9 > data.size():
				return null

			var img_left = data.decode_u16(pos)
			var img_top = data.decode_u16(pos + 2)
			var img_width = data.decode_u16(pos + 4)
			var img_height = data.decode_u16(pos + 6)
			var img_packed = data[pos + 8]
			pos += 9

			var has_lct = (img_packed & 0x80) != 0
			var interlaced = (img_packed & 0x40) != 0
			var lct_size_bits = img_packed & 0x07
			var lct_size = 1 << (lct_size_bits + 1)

			var color_table = gct
			if has_lct:
				if pos + lct_size * 3 > data.size():
					return null
				color_table = data.slice(pos, pos + lct_size * 3)
				pos += lct_size * 3

			if pos >= data.size():
				return null

			# LZW minimum code size
			var lzw_min_code_size = data[pos]
			pos += 1

			# Collect all data sub-blocks
			var compressed: PackedByteArray = PackedByteArray()
			while pos < data.size():
				var block_size = data[pos]
				pos += 1
				if block_size == 0:
					break
				if pos + block_size > data.size():
					break
				compressed.append_array(data.slice(pos, pos + block_size))
				pos += block_size

			# Decompress LZW
			var pixels = _decompress_gif_lzw(compressed, lzw_min_code_size, img_width * img_height)
			if pixels.size() < img_width * img_height:
				return null

			# Create image
			var img = Image.create(img_width, img_height, false, Image.FORMAT_RGBA8)

			for y in range(img_height):
				var actual_y = y
				if interlaced:
					actual_y = _get_interlaced_row(y, img_height)

				for x in range(img_width):
					var idx = y * img_width + x
					var color_idx = pixels[idx]

					if color_idx == transparent_index:
						img.set_pixel(x, actual_y, Color(0, 0, 0, 0))
					elif color_idx * 3 + 2 < color_table.size():
						var r = color_table[color_idx * 3]
						var g = color_table[color_idx * 3 + 1]
						var b = color_table[color_idx * 3 + 2]
						img.set_pixel(x, actual_y, Color8(r, g, b, 255))

			return img

		elif block_type == 0x21:  # Extension
			if pos >= data.size():
				return null

			var ext_type = data[pos]
			pos += 1

			# Graphics Control Extension - may contain transparency info
			if ext_type == 0xF9 and pos + 4 <= data.size():
				var block_size = data[pos]
				if block_size >= 4:
					var gce_packed = data[pos + 1]
					var has_transparent = (gce_packed & 0x01) != 0
					if has_transparent:
						transparent_index = data[pos + 4]
				pos += block_size + 1
				if pos < data.size() and data[pos] == 0:
					pos += 1
			else:
				# Skip other extension blocks
				while pos < data.size():
					var block_size = data[pos]
					pos += 1
					if block_size == 0:
						break
					pos += block_size

		elif block_type == 0x3B:  # Trailer
			break
		else:
			# Unknown block, try to skip
			break

	return null


func _get_interlaced_row(pass_row: int, height: int) -> int:
	# GIF interlacing: Pass 1 (rows 0, 8, 16...), Pass 2 (4, 12, 20...), Pass 3 (2, 6, 10...), Pass 4 (1, 3, 5...)
	var pass1_rows = (height + 7) / 8
	var pass2_rows = (height + 3) / 8
	var pass3_rows = (height + 1) / 4
	var pass4_rows = height / 2

	if pass_row < pass1_rows:
		return pass_row * 8
	elif pass_row < pass1_rows + pass2_rows:
		return (pass_row - pass1_rows) * 8 + 4
	elif pass_row < pass1_rows + pass2_rows + pass3_rows:
		return (pass_row - pass1_rows - pass2_rows) * 4 + 2
	else:
		return (pass_row - pass1_rows - pass2_rows - pass3_rows) * 2 + 1


func _decompress_gif_lzw(data: PackedByteArray, min_code_size: int, pixel_count: int) -> PackedByteArray:
	var clear_code = 1 << min_code_size
	var end_code = clear_code + 1
	var code_size = min_code_size + 1
	var next_code = end_code + 1
	var max_code = 1 << code_size

	# Initialize code table with single-character strings
	var code_table: Array[PackedByteArray] = []
	for i in range(clear_code):
		code_table.append(PackedByteArray([i]))
	code_table.append(PackedByteArray())  # Clear code placeholder
	code_table.append(PackedByteArray())  # End code placeholder

	var output: PackedByteArray = PackedByteArray()
	var bit_pos = 0
	var prev_code = -1

	while output.size() < pixel_count:
		# Read next code
		var byte_pos = bit_pos >> 3
		if byte_pos + 2 >= data.size():
			break

		# Read up to 24 bits to handle codes up to 12 bits
		var bits = data[byte_pos]
		if byte_pos + 1 < data.size():
			bits |= data[byte_pos + 1] << 8
		if byte_pos + 2 < data.size():
			bits |= data[byte_pos + 2] << 16

		var bit_offset = bit_pos & 7
		var code = (bits >> bit_offset) & ((1 << code_size) - 1)
		bit_pos += code_size

		if code == clear_code:
			# Reset
			code_size = min_code_size + 1
			next_code = end_code + 1
			max_code = 1 << code_size
			code_table.resize(end_code + 1)
			prev_code = -1
			continue

		if code == end_code:
			break

		var entry: PackedByteArray

		if code < code_table.size():
			entry = code_table[code]
		elif code == next_code and prev_code >= 0 and prev_code < code_table.size():
			entry = code_table[prev_code].duplicate()
			entry.append(code_table[prev_code][0])
		else:
			# Invalid code
			break

		output.append_array(entry)

		# Add new entry to table
		if prev_code >= 0 and prev_code < code_table.size() and next_code < 4096:
			var new_entry = code_table[prev_code].duplicate()
			new_entry.append(entry[0])
			code_table.append(new_entry)
			next_code += 1

			# Increase code size if needed
			if next_code >= max_code and code_size < 12:
				code_size += 1
				max_code = 1 << code_size

		prev_code = code

	return output


func _show_message(text: String) -> void:
	var dialog = AcceptDialog.new()
	dialog.title = "Asset Store"
	dialog.dialog_text = text
	dialog.confirmed.connect(func(): dialog.queue_free())
	dialog.canceled.connect(func(): dialog.queue_free())
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()
	SettingsDialog.debug_print(" %s" % text)


var _current_detail_dialog: AcceptDialog = null

func _on_asset_clicked(info: Dictionary) -> void:
	var dialog = AssetDetailDialog.new()
	EditorInterface.get_base_control().add_child(dialog)
	_current_detail_dialog = dialog

	var is_fav = _is_favorite(info)
	# Check if installed: either in registry OR has installed_path (local/scanned plugin)
	var asset_id = info.get("asset_id", "")
	var is_installed = _is_addon_installed(asset_id)
	if not is_installed and info.has("installed_path"):
		var path = info.get("installed_path", "")
		is_installed = not path.is_empty() and DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path))

	# Add installed paths to info for the "Open in Explorer" button
	var display_info = info.duplicate()
	var registry_paths: Array = []
	if is_installed:
		registry_paths = _get_installed_addon_paths(asset_id)
		if registry_paths.size() > 0:
			display_info["installed_paths"] = registry_paths
		elif info.has("installed_path"):
			display_info["installed_paths"] = [info.get("installed_path")]

	# Get installed version from registry (not from info, which may be stale for favorites)
	# This must be done BEFORE dialog.setup() so the correct version is displayed
	var installed_version = ""
	if is_installed and _installed_registry.has(asset_id):
		var entry = _installed_registry[asset_id]
		var stored_info = entry.get("info", {}) if entry is Dictionary else {}
		var stored_version = stored_info.get("version", "")
		var paths = entry.get("paths", []) if entry is Dictionary else []
		var local_version = _get_local_version(paths[0]) if paths.size() > 0 else ""

		# Use the higher version (same logic as _show_installed)
		if not stored_version.is_empty() and not local_version.is_empty():
			if _compare_versions(stored_version, local_version) > 0:
				installed_version = stored_version
			else:
				installed_version = local_version
		elif not local_version.is_empty():
			installed_version = local_version
		elif not stored_version.is_empty():
			installed_version = stored_version

	# Fallback to info version if not in registry
	if installed_version.is_empty():
		installed_version = info.get("version", "")

	# Update display_info with the correct installed version for Favorites/GlobalFolder items
	if is_installed and not installed_version.is_empty():
		display_info["version"] = installed_version

	# Get icon - for GlobalFolder items installed, use the godotpackage icon
	var icon_tex: Texture2D = null
	var godotpackage_path = info.get("godotpackage_path", "")
	if not godotpackage_path.is_empty() and FileAccess.file_exists(godotpackage_path):
		icon_tex = _extract_icon_from_godotpackage(godotpackage_path)
	if icon_tex == null:
		icon_tex = _icon_cache.get(info.get("icon_url", ""), _default_icon)

	dialog.setup(display_info, is_fav, is_installed, icon_tex)

	# Pass tracked files if installed (with resolved paths)
	if is_installed and _installed_registry.has(asset_id):
		var tracked_files = _get_resolved_tracked_files(asset_id)
		dialog.set_tracked_files(tracked_files)

	dialog.install_requested.connect(_on_install_requested)
	dialog.uninstall_requested.connect(_on_uninstall_requested)
	dialog.favorite_toggled.connect(_on_dialog_favorite_toggled)
	dialog.add_to_global_folder_requested.connect(_on_add_to_global_folder_from_installed)
	dialog.update_requested.connect(_on_update_requested.bind(dialog))

	var has_update = is_installed and _has_update_available(asset_id, installed_version)
	if has_update:
		var update_info = _get_update_info(asset_id)
		var latest_version = update_info.get("latest_version", "")
		# Always show update button in dialog
		dialog.set_update_available(true, latest_version)

	dialog.popup_centered()

	# Show update popup only if not ignored
	if has_update:
		var update_info = _get_update_info(asset_id)
		var latest_version = update_info.get("latest_version", "")
		if not _is_update_ignored(asset_id, latest_version):
			call_deferred("_show_update_prompt", display_info, dialog)


func _on_favorite_clicked(info: Dictionary) -> void:
	_toggle_favorite(info)


func _on_dialog_favorite_toggled(info: Dictionary, is_fav: bool) -> void:
	if is_fav:
		_add_favorite(info)
	else:
		_remove_favorite(info)

	# Update card if visible
	for card in _cards:
		if is_instance_valid(card) and card.get_info().get("asset_id", "") == info.get("asset_id", ""):
			card.set_favorite(is_fav)
			break


func _on_install_requested(info: Dictionary) -> void:
	var source = info.get("source", "")

	# Handle GitHub reinstall
	if source == SOURCE_GITHUB:
		var github_url = info.get("url", "")
		if github_url.is_empty():
			push_error("AssetPlus: No GitHub URL stored for reinstall")
			return

		# Parse the URL and start GitHub download flow
		var parsed = _parse_github_url(github_url)
		if parsed.is_empty():
			push_error("AssetPlus: Invalid GitHub URL: %s" % github_url)
			return

		var owner = parsed["owner"]
		var repo = parsed["repo"]
		SettingsDialog.debug_print(" Reinstalling from GitHub: %s/%s" % [owner, repo])
		_fetch_github_repo_info(owner, repo, github_url)
		return

	# Handle GlobalFolder items (from Favorites or other tabs)
	if source == SOURCE_GLOBAL_FOLDER:
		_on_global_folder_install_requested(info)
		return

	var download_url = info.get("download_url", "")
	if download_url.is_empty():
		# Fallback to browser
		var url = info.get("browse_url", "")
		if not url.is_empty():
			OS.shell_open(url)
		return

	# Open install dialog
	var install_dialog = InstallDialog.new()
	EditorInterface.get_base_control().add_child(install_dialog)
	install_dialog.setup(info)
	var asset_id = info.get("asset_id", "")
	install_dialog.installation_complete.connect(func(success, paths: Array, tracked_uids: Array):
		SettingsDialog.debug_print("installation_complete callback received: success=%s, paths=%s" % [success, str(paths)])
		if success:
			# Track paths installed this session
			for p in paths:
				if p not in _session_installed_paths:
					_session_installed_paths.append(p)
			# Register the installed addon with its actual paths, UIDs, and full asset info
			if paths.size() > 0:
				# Generate asset_id if missing
				var reg_asset_id = asset_id
				if reg_asset_id.is_empty():
					reg_asset_id = "installed_%d" % Time.get_unix_time_from_system()
				SettingsDialog.debug_print("Registering addon: %s with paths %s" % [reg_asset_id, str(paths)])
				_register_installed_addon(reg_asset_id, paths, info, tracked_uids)
				# Update card badge
				_update_card_installed_status(reg_asset_id, true)
				# Clear update cache for this asset (so it doesn't show "Update Available" after updating)
				if _update_cache.has(reg_asset_id):
					_update_cache.erase(reg_asset_id)
					_save_update_cache()
				# Delete pending file since callback worked
				var pending_path = "user://assetplus_pending_install.cfg"
				if FileAccess.file_exists(pending_path):
					DirAccess.remove_absolute(ProjectSettings.globalize_path(pending_path))
					SettingsDialog.debug_print("Deleted pending installation file (callback worked)")
			if _current_detail_dialog and is_instance_valid(_current_detail_dialog):
				_current_detail_dialog.set_installed(true, paths)
			# Refresh installed tab to update version and remove update badge (with delay to ensure filesystem is updated)
			if _current_tab == Tab.INSTALLED:
				await get_tree().create_timer(0.5).timeout
				_show_installed()
	)
	install_dialog.popup_centered()


func _on_update_requested(info: Dictionary, detail_dialog: AcceptDialog = null) -> void:
	## Handle update request from detail dialog's Update button
	var asset_id = info.get("asset_id", "")
	var update_info = _get_update_info(asset_id)
	if update_info.is_empty():
		return

	var latest_version = update_info.get("latest_version", "")
	var download_url = update_info.get("download_url", "")

	# Clear any ignored update for this asset
	_clear_ignored_update(asset_id)

	# Close detail dialog if provided
	if is_instance_valid(detail_dialog):
		detail_dialog.hide()

	# Start the update process
	_perform_addon_update(info, latest_version, download_url)


func _on_uninstall_requested(info: Dictionary) -> void:
	var asset_id = info.get("asset_id", "")

	# Check if we have tracked UIDs for safe uninstall
	var tracked_uids = _get_installed_addon_uids(asset_id)
	var use_safe_uninstall = tracked_uids.size() > 0

	# ALWAYS get paths from registry first - they are the most up-to-date (after move detection)
	var addon_paths: Array = _get_installed_addon_paths(asset_id)

	# Fallback to info paths only if registry has nothing
	if addon_paths.is_empty():
		var multi_paths = info.get("installed_paths", [])
		if multi_paths.size() > 0:
			addon_paths = multi_paths
		else:
			var single_path = info.get("installed_path", "")
			if not single_path.is_empty():
				addon_paths = [single_path]

	# Last resort: guess from asset_id
	if addon_paths.is_empty():
		var slug = asset_id
		if "/" in slug:
			slug = slug.split("/")[1]
		slug = slug.replace(" ", "-").replace("_", "-").to_lower()
		addon_paths = ["res://addons/%s" % slug]

	# Build confirmation dialog
	var confirm = ConfirmationDialog.new()
	confirm.title = "Uninstall Addon"

	if use_safe_uninstall:
		# Safe mode: only tracked files will be deleted
		# Collect root folders from tracked files
		var root_folders: Dictionary = {}
		for uid_entry in tracked_uids:
			var file_path: String = uid_entry.get("path", "")
			if not file_path.is_empty():
				# Extract root folder (res://addons/name or res://folder)
				var parts = file_path.replace("res://", "").split("/")
				if parts.size() >= 2:
					root_folders["res://" + parts[0] + "/" + parts[1]] = true
				elif parts.size() >= 1:
					root_folders["res://" + parts[0]] = true
		var folders_list = root_folders.keys()
		folders_list.sort()
		var folders_text = "\n".join(folders_list) if folders_list.size() > 0 else "(unknown)"
		confirm.dialog_text = "Are you sure you want to uninstall '%s'?\n\nAffected folders:\n%s\n\nThis will delete %d tracked files.\nAny files you added to these folders will be kept." % [info.get("title", "addon"), folders_text, tracked_uids.size()]
	else:
		# Legacy mode: delete entire folder(s)
		var paths_text = "\n".join(addon_paths)
		# Check if paths are folders or files
		var folder_count = 0
		var file_count = 0
		for path in addon_paths:
			if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)):
				folder_count += 1
			else:
				file_count += 1

		var items_description = ""
		if folder_count > 0 and file_count > 0:
			items_description = "%d folder(s) and %d file(s)" % [folder_count, file_count]
		elif folder_count > 0:
			items_description = "%d folder(s)" % folder_count
		else:
			items_description = "%d file(s)" % file_count

		if addon_paths.size() > 1:
			confirm.dialog_text = "Are you sure you want to uninstall '%s'?\n\nThis will delete %s:\n%s\n\n(Warning: All content will be deleted)" % [info.get("title", "addon"), items_description, paths_text]
		else:
			confirm.dialog_text = "Are you sure you want to uninstall '%s'?\n\nThis will delete:\n%s\n\n(Warning: All content will be deleted)" % [info.get("title", "addon"), paths_text]
	confirm.ok_button_text = "Uninstall"

	# Get resolved tracked files for show files button (with current paths)
	var resolved_files = _get_resolved_tracked_files(asset_id)

	# Add "Show Files" button if we have tracked files
	if resolved_files.size() > 0:
		var show_files_btn = confirm.add_button("Show Files", false, "show_files")
		show_files_btn.pressed.connect(func():
			_show_uninstall_files_popup(info.get("title", "addon"), resolved_files)
		)

	var paths_to_delete = addon_paths.duplicate()
	var uids_to_delete = tracked_uids.duplicate()
	var safe_mode = use_safe_uninstall
	var addon_title = info.get("title", "addon")

	confirm.confirmed.connect(func():
		# IMPORTANT: Disable plugins BEFORE deleting files to prevent crash
		_disable_plugins_before_uninstall(paths_to_delete)

		# Remove autoloads that reference scripts in the folders being deleted
		_remove_autoloads_in_paths(paths_to_delete)

		if safe_mode:
			# Safe uninstall: delete only tracked files, then clean up empty folders
			SettingsDialog.debug_print(" Safe uninstalling '%s' (%d tracked files)..." % [addon_title, uids_to_delete.size()])
			var deleted = _delete_tracked_files_only(uids_to_delete, paths_to_delete)
			SettingsDialog.debug_print(" Deleted %d files" % deleted)
		else:
			# Legacy: delete entire folders
			SettingsDialog.debug_print(" Uninstalling %d folders..." % paths_to_delete.size())
			for addon_path in paths_to_delete:
				SettingsDialog.debug_print(" Deleting %s" % addon_path)
				_delete_addon_folder(addon_path)

		# Unregister BEFORE scan
		_unregister_installed_addon(asset_id)
		_clear_installed_paths_from_favorite(asset_id)  # Clear cached paths from favorites
		if _current_detail_dialog and is_instance_valid(_current_detail_dialog):
			_current_detail_dialog.set_installed(false)
		_update_card_installed_status(asset_id, false)
		# Refresh current tab to reflect uninstall status
		if _current_tab == Tab.INSTALLED:
			_show_installed()
		elif _current_tab == Tab.FAVORITES:
			_show_favorites()

		# Safe scan: wait frames + timer before scanning (avoids crash during import)
		_queue_safe_scan()
		SettingsDialog.debug_print(" Uninstall complete")
	)

	EditorInterface.get_base_control().add_child(confirm)
	confirm.popup_centered()


func _show_uninstall_files_popup(addon_title: String, files: Array) -> void:
	## Show a popup with all files that will be deleted during uninstall
	var popup = AcceptDialog.new()
	popup.title = "Files to Delete - %s" % addon_title
	popup.size = Vector2i(700, 500)
	popup.ok_button_text = "Close"

	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 10)
	popup.add_child(main_vbox)

	# Header with count
	var header = Label.new()
	header.text = "%d files will be deleted:" % files.size()
	header.add_theme_font_size_override("font_size", 14)
	main_vbox.add_child(header)

	# Organize files by type
	var files_by_type: Dictionary = {}
	for file_entry in files:
		var path: String = file_entry.get("path", "")
		if path.is_empty():
			continue
		var ext = path.get_extension().to_lower()
		var type_name = _get_file_type_name_for_uninstall(ext)
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
		"Textures": 3,
		"3D Models": 4,
		"Audio": 5,
		"Fonts": 6,
		"Text/Config": 7,
		"Scripts (Shell)": 8,
		"Import Files": 98,
		"Other": 99
	}
	var type_names = files_by_type.keys()
	type_names.sort_custom(func(a, b):
		var pa = type_priority.get(a, 50)
		var pb = type_priority.get(b, 50)
		return pa < pb
	)

	var theme = EditorInterface.get_editor_theme()

	for type_name in type_names:
		var files_array: Array = files_by_type[type_name]

		# Type header
		var type_header = HBoxContainer.new()
		type_header.add_theme_constant_override("separation", 8)
		scroll_vbox.add_child(type_header)

		var type_icon = TextureRect.new()
		type_icon.custom_minimum_size = Vector2(16, 16)
		type_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		type_icon.texture = _get_icon_for_file_type(type_name, theme)
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
				exists_indicator.tooltip_text = "File exists - will be deleted"
			else:
				exists_indicator.text = "✗"
				exists_indicator.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
				exists_indicator.tooltip_text = "File NOT found (already deleted?)"
			exists_indicator.custom_minimum_size.x = 16
			file_hbox.add_child(exists_indicator)

			# Path label
			var path_label = Label.new()
			path_label.text = path
			path_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
			path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			file_hbox.add_child(path_label)

	EditorInterface.get_base_control().add_child(popup)
	popup.popup_centered()


func _get_file_type_name_for_uninstall(ext: String) -> String:
	## Get display name for file extension
	match ext:
		"gd": return "Scripts"
		"tscn", "scn": return "Scenes"
		"tres", "res": return "Resources"
		"png", "jpg", "jpeg", "webp", "svg", "bmp": return "Textures"
		"glb", "gltf", "obj", "fbx", "dae": return "3D Models"
		"wav", "ogg", "mp3": return "Audio"
		"ttf", "otf", "woff": return "Fonts"
		"md", "txt", "json", "cfg", "ini": return "Text/Config"
		"import": return "Import Files"
		"sh", "bat", "ps1": return "Scripts (Shell)"
		_: return "Other"


func _get_icon_for_file_type(type_name: String, theme: Theme) -> Texture2D:
	## Get icon for file type category
	match type_name:
		"Scripts": return theme.get_icon("Script", "EditorIcons")
		"Scenes": return theme.get_icon("PackedScene", "EditorIcons")
		"Resources": return theme.get_icon("ResourcePreloader", "EditorIcons")
		"Textures": return theme.get_icon("ImageTexture", "EditorIcons")
		"3D Models": return theme.get_icon("Mesh", "EditorIcons")
		"Audio": return theme.get_icon("AudioStream", "EditorIcons")
		"Fonts": return theme.get_icon("Font", "EditorIcons")
		"Text/Config": return theme.get_icon("TextFile", "EditorIcons")
		"Import Files": return theme.get_icon("Load", "EditorIcons")
		"Scripts (Shell)": return theme.get_icon("Terminal", "EditorIcons")
		_: return theme.get_icon("File", "EditorIcons")


func _delete_addon_folder(addon_path: String) -> void:
	var global_path = ProjectSettings.globalize_path(addon_path)

	if not DirAccess.dir_exists_absolute(global_path):
		SettingsDialog.debug_print(" Path does not exist: %s" % global_path)
		return

	# Recursively delete directory
	_delete_directory(global_path)
	SettingsDialog.debug_print(" Deleted %s" % global_path)


func _force_delete_addon(addon_paths: Array, asset_id: String, addon_title: String) -> void:
	## Force delete with safe scan pattern (deferred + wait frames + timer)
	SettingsDialog.debug_print(" FORCE DELETE - '%s'" % addon_title)

	# Move to trash
	for addon_path in addon_paths:
		var global_path = ProjectSettings.globalize_path(addon_path)
		SettingsDialog.debug_print(" Moving to trash: %s" % global_path)
		var err = OS.move_to_trash(global_path)
		if err != OK:
			SettingsDialog.debug_print(" move_to_trash failed (error %d)" % err)
		else:
			SettingsDialog.debug_print(" Moved to trash OK")

	# Unregister from our tracking BEFORE scan
	_unregister_installed_addon(asset_id)

	# Update UI state BEFORE scan
	if _current_detail_dialog and is_instance_valid(_current_detail_dialog):
		_current_detail_dialog.set_installed(false)
	_update_card_installed_status(asset_id, false)
	if _current_tab == Tab.INSTALLED:
		_show_installed()

	# Safe scan: wait 2 frames + 200ms timer before scanning (avoids crash during import)
	SettingsDialog.debug_print(" Waiting before safe scan...")
	_queue_safe_scan()

	SettingsDialog.debug_print(" Force delete complete")


var _scan_queued := false

func _queue_safe_scan() -> void:
	## Queue a safe filesystem scan (deferred + wait frames + timer)
	if _scan_queued:
		return
	_scan_queued = true
	call_deferred("_do_safe_scan")


func _do_safe_scan() -> void:
	## Perform scan after waiting for editor to "breathe"
	# Wait 2 process frames
	await get_tree().process_frame
	await get_tree().process_frame

	# Extra safety: wait 200ms
	await get_tree().create_timer(0.2).timeout

	SettingsDialog.debug_print(" Performing safe filesystem scan...")
	EditorInterface.get_resource_filesystem().scan()

	_scan_queued = false
	SettingsDialog.debug_print(" Safe scan complete")


func _do_uninstall(addon_path: String) -> void:
	_delete_addon_folder(addon_path)
	# Safe rescan filesystem
	_queue_safe_scan()


func _remove_autoloads_in_paths(paths: Array) -> void:
	## Remove autoloads whose scripts are inside the given paths
	## This is called during uninstall to clean up autoloads

	var autoloads_removed := 0
	var autoloads_to_remove: Array[String] = []

	# First, collect all autoloads that need to be removed
	for setting in ProjectSettings.get_property_list():
		var name: String = setting.name
		if name.begins_with("autoload/"):
			var autoload_name = name.substr(9)  # Remove "autoload/"
			var autoload_value: String = ProjectSettings.get_setting(name)

			# Extract script path (remove * prefix if present)
			var script_path = autoload_value
			if script_path.begins_with("*"):
				script_path = script_path.substr(1)

			# Check if this script is inside any of the paths being deleted
			for addon_path in paths:
				var normalized_path = addon_path
				if not normalized_path.ends_with("/"):
					normalized_path += "/"

				if script_path.begins_with(normalized_path) or script_path == addon_path:
					autoloads_to_remove.append(autoload_name)
					SettingsDialog.debug_print(" Autoload '%s' (%s) is in deleted path, will remove" % [autoload_name, script_path])
					break

	# Now remove them
	for autoload_name in autoloads_to_remove:
		var setting_name = "autoload/" + autoload_name
		if ProjectSettings.has_setting(setting_name):
			ProjectSettings.set_setting(setting_name, null)  # Setting to null removes it
			autoloads_removed += 1
			SettingsDialog.debug_print(" Removed autoload '%s'" % autoload_name)

	# Save if we removed any
	if autoloads_removed > 0:
		ProjectSettings.save()
		SettingsDialog.debug_print(" Removed %d autoloads and saved project settings" % autoloads_removed)


func _delete_directory(path: String) -> void:
	var dir = DirAccess.open(path)
	if not dir:
		return

	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		var full_path = path.path_join(file_name)
		if dir.current_is_dir():
			_delete_directory(full_path)
		else:
			DirAccess.remove_absolute(full_path)
		file_name = dir.get_next()

	dir.list_dir_end()
	DirAccess.remove_absolute(path)


func _delete_tracked_files_only(tracked_files: Array, asset_root_paths: Array = []) -> int:
	# Delete only the files we originally installed (tracked via paths/UIDs)
	# Returns the number of files deleted
	var deleted_count = 0
	var folders_to_check: Dictionary = {}  # Track folders that might become empty

	for file_entry in tracked_files:
		var uid_str: String = file_entry.get("uid", "")
		var original_path: String = file_entry.get("path", "")
		var current_path = ""

		# Try to resolve current path from UID (handles moved files)
		if not uid_str.is_empty():
			var uid_id = ResourceUID.text_to_id(uid_str)
			if ResourceUID.has_id(uid_id):
				current_path = ResourceUID.get_id_path(uid_id)

		# Fallback to original path if no UID or UID not found
		if current_path.is_empty():
			current_path = original_path

		if current_path.is_empty():
			continue

		var global_path = ProjectSettings.globalize_path(current_path)

		# Delete the main file
		if FileAccess.file_exists(global_path):
			DirAccess.remove_absolute(global_path)
			deleted_count += 1
			SettingsDialog.debug_print(" Deleted tracked file: %s" % current_path)

			# Track the folder for cleanup
			var folder = global_path.get_base_dir()
			folders_to_check[folder] = true

		# Also delete associated .import and .uid files
		var import_path = global_path + ".import"
		if FileAccess.file_exists(import_path):
			DirAccess.remove_absolute(import_path)

		var uid_file_path = global_path + ".uid"
		if FileAccess.file_exists(uid_file_path):
			DirAccess.remove_absolute(uid_file_path)

	# Clean up empty folders (from deepest to shallowest), including asset root folders
	_cleanup_empty_folders(folders_to_check.keys(), asset_root_paths)

	return deleted_count


func _cleanup_empty_folders(folder_paths: Array, asset_root_paths: Array = []) -> void:
	var project_root = ProjectSettings.globalize_path("res://").replace("\\", "/").trim_suffix("/")
	var addons_path = ProjectSettings.globalize_path("res://addons").replace("\\", "/").trim_suffix("/")
	var assets_path = ProjectSettings.globalize_path("res://assets").replace("\\", "/").trim_suffix("/")
	var templates_path = ProjectSettings.globalize_path("res://templates").replace("\\", "/").trim_suffix("/")
	var packages_path = ProjectSettings.globalize_path("res://Packages").replace("\\", "/").trim_suffix("/")

	# Protected folders that should never be deleted (even if empty)
	var protected_folders = [project_root, addons_path, assets_path, templates_path, packages_path]

	# First: recursively clean empty subfolders from each root path (bottom-up)
	for root_path in asset_root_paths:
		var global_root = ProjectSettings.globalize_path(root_path).replace("\\", "/").trim_suffix("/")
		_delete_empty_folders_recursive(global_root, protected_folders)

	# Then: clean the file parent folders and walk up to parents
	var processed: Dictionary = {}
	for folder_path in folder_paths:
		var current = folder_path.replace("\\", "/").trim_suffix("/")
		while not current.is_empty():
			if processed.has(current):
				break
			processed[current] = true

			# Don't delete protected folders
			if current in protected_folders:
				break
			if not current.begins_with(project_root):
				break

			if _is_folder_empty(current):
				var err = DirAccess.remove_absolute(current)
				if err == OK:
					SettingsDialog.debug_print(" Removed empty folder: %s" % current)
				current = current.get_base_dir().replace("\\", "/").trim_suffix("/")
			else:
				break


func _delete_empty_folders_recursive(folder_path: String, protected_folders: Array) -> bool:
	## Recursively delete empty folders from bottom up. Returns true if folder was deleted.
	# Don't delete protected folders
	if folder_path in protected_folders:
		return false

	var dir = DirAccess.open(folder_path)
	if not dir:
		return false

	# First, recursively process all subdirectories
	var subdirs: Array = []
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while not file_name.is_empty():
		if file_name != "." and file_name != "..":
			var full_path = folder_path.path_join(file_name)
			if dir.current_is_dir():
				subdirs.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()

	# Recursively clean subdirectories first (bottom-up)
	for subdir in subdirs:
		_delete_empty_folders_recursive(subdir, protected_folders)

	# Now check if this folder is empty (after cleaning subdirs)
	if _is_folder_empty(folder_path):
		var err = DirAccess.remove_absolute(folder_path)
		if err == OK:
			SettingsDialog.debug_print(" Removed empty folder: %s" % folder_path)
			return true
		else:
			SettingsDialog.debug_print(" Failed to remove folder: %s (error %d)" % [folder_path, err])
	return false


func _is_folder_empty(folder_path: String) -> bool:
	var dir = DirAccess.open(folder_path)
	if not dir:
		return true  # Can't open = treat as empty/deletable

	dir.list_dir_begin()
	var file_name = dir.get_next()
	var is_empty = true

	while not file_name.is_empty():
		if file_name != "." and file_name != "..":
			is_empty = false
			break
		file_name = dir.get_next()

	dir.list_dir_end()
	return is_empty


func _update_pagination() -> void:
	_prev_btn.disabled = _current_page <= 0
	_next_btn.disabled = _current_page >= _total_pages - 1

	# Update page buttons
	var start_page = max(0, _current_page - 4)
	var end_page = min(_total_pages, start_page + 10)

	for i in range(_page_buttons.size()):
		var btn = _page_buttons[i]
		var page_num = start_page + i

		if page_num < end_page:
			btn.visible = true
			btn.text = str(page_num + 1)
			btn.disabled = page_num == _current_page

			if page_num == _current_page:
				btn.flat = false
			else:
				btn.flat = true
		else:
			btn.visible = false


# ===== FAVORITES =====

func _is_favorite(info: Dictionary) -> bool:
	var asset_id = info.get("asset_id", "")
	for fav in _favorites:
		if fav.get("asset_id", "") == asset_id:
			return true
	return false


func _toggle_favorite(info: Dictionary) -> void:
	if _is_favorite(info):
		# Show confirmation dialog before removing from favorites
		_confirm_remove_favorite(info)
	else:
		_add_favorite(info)
		# Update card
		_update_card_favorite_state(info)


func _confirm_remove_favorite(info: Dictionary) -> void:
	var title = info.get("title", "Unknown")
	var confirm = ConfirmationDialog.new()
	confirm.title = "Remove from Favorites?"
	confirm.dialog_text = "Remove \"%s\" from favorites?" % title
	confirm.ok_button_text = "Remove"
	confirm.cancel_button_text = "Cancel"

	confirm.confirmed.connect(func():
		_remove_favorite(info)
		_update_card_favorite_state(info)
		confirm.queue_free()
	)

	confirm.canceled.connect(func():
		confirm.queue_free()
	)

	EditorInterface.get_base_control().add_child(confirm)
	confirm.popup_centered()


func _update_card_favorite_state(info: Dictionary) -> void:
	# Update card favorite icon
	for card in _cards:
		if is_instance_valid(card) and card.get_info().get("asset_id", "") == info.get("asset_id", ""):
			card.set_favorite(_is_favorite(info))
			break


func _add_favorite(info: Dictionary) -> void:
	if _is_favorite(info):
		return

	# Create a copy with essential fields for global favorites
	# This ensures we can reimport the asset in another project
	var favorite_data = info.duplicate()

	# Ensure key fields are preserved for reimport
	var essential_fields = [
		"asset_id", "title", "author", "source", "category", "license",
		"url", "browse_url", "download_url", "icon_url",
		"description", "version", "godot_version",
		# GitHub specific
		"repo_owner", "repo_name", "default_branch",
		# Local/installed specific
		"installed_paths", "installed_path"
	]

	for field in essential_fields:
		if info.has(field) and not favorite_data.has(field):
			favorite_data[field] = info[field]

	# Add timestamp for when it was favorited
	favorite_data["favorited_at"] = Time.get_datetime_string_from_system(true)

	_favorites.append(favorite_data)
	_save_favorites()


func _remove_favorite(info: Dictionary) -> void:
	var asset_id = info.get("asset_id", "")
	_favorites = _favorites.filter(func(f): return f.get("asset_id", "") != asset_id)
	_save_favorites()

	# If viewing favorites tab, refresh
	if _current_tab == Tab.FAVORITES:
		_show_favorites()


func _clear_installed_paths_from_favorite(asset_id: String) -> void:
	## Clear installed_path and installed_paths from a favorite when uninstalling
	## This ensures favorites don't show as installed after uninstall
	var modified = false
	for fav in _favorites:
		if fav.get("asset_id", "") == asset_id:
			if fav.has("installed_path"):
				fav.erase("installed_path")
				modified = true
			if fav.has("installed_paths"):
				fav.erase("installed_paths")
				modified = true
			break
	if modified:
		_save_favorites()


func _get_global_favorites_path() -> String:
	## Returns the global favorites file path (shared across all projects)
	## Uses system config directory: AppData/Roaming on Windows, ~/.config on Linux, ~/Library/Application Support on macOS
	var config_dir = OS.get_config_dir()
	var app_dir = config_dir.path_join(GLOBAL_FAVORITES_FOLDER)

	# Ensure directory exists
	if not DirAccess.dir_exists_absolute(app_dir):
		DirAccess.make_dir_recursive_absolute(app_dir)

	return app_dir.path_join(GLOBAL_FAVORITES_FILE)


func _load_favorites() -> void:
	_favorites.clear()
	var config = ConfigFile.new()
	var favorites_path = _get_global_favorites_path()

	if config.load(favorites_path) == OK:
		var data = config.get_value("favorites", "list", [])
		for item in data:
			if item is Dictionary:
				_favorites.append(item)
		SettingsDialog.debug_print(" Loaded %d favorites from %s" % [_favorites.size(), favorites_path])


func _save_favorites() -> void:
	var config = ConfigFile.new()
	config.set_value("favorites", "list", _favorites)
	var favorites_path = _get_global_favorites_path()
	var err = config.save(favorites_path)
	if err != OK:
		push_error("AssetPlus: Failed to save favorites to %s: %s" % [favorites_path, error_string(err)])


# ===== PLUGIN ENABLE/DISABLE =====

func _get_plugin_cfg_path(addon_path: String) -> String:
	# Find plugin.cfg in the addon folder
	var plugin_cfg = addon_path.path_join("plugin.cfg")
	if FileAccess.file_exists(plugin_cfg):
		return plugin_cfg

	# Also check with trailing slash stripped
	var clean_path = addon_path.trim_suffix("/")
	plugin_cfg = clean_path.path_join("plugin.cfg")
	if FileAccess.file_exists(plugin_cfg):
		return plugin_cfg

	return ""


func _is_plugin_enabled(addon_path: String) -> bool:
	# Check if the plugin is enabled using EditorInterface
	if not Engine.is_editor_hint():
		return false

	# Extract plugin name from addon path
	var plugin_name = addon_path.trim_suffix("/").get_file()
	if plugin_name.is_empty():
		var plugin_cfg = _get_plugin_cfg_path(addon_path)
		if plugin_cfg.is_empty():
			return false
		var parts = plugin_cfg.split("/")
		for i in range(parts.size()):
			if parts[i] == "addons" and i + 1 < parts.size():
				plugin_name = parts[i + 1]
				break

	if plugin_name.is_empty():
		return false

	return EditorInterface.is_plugin_enabled(plugin_name)


func _set_plugin_enabled(addon_path: String, enabled: bool) -> bool:
	var plugin_cfg = _get_plugin_cfg_path(addon_path)
	if plugin_cfg.is_empty():
		SettingsDialog.debug_print(" Cannot enable/disable - no plugin.cfg found in %s" % addon_path)
		return false

	# Extract plugin name from addon path (e.g., "res://addons/my_plugin" -> "my_plugin")
	var plugin_name = addon_path.trim_suffix("/").get_file()
	if plugin_name.is_empty():
		# Try extracting from plugin.cfg path
		var parts = plugin_cfg.split("/")
		for i in range(parts.size()):
			if parts[i] == "addons" and i + 1 < parts.size():
				plugin_name = parts[i + 1]
				break

	if plugin_name.is_empty():
		SettingsDialog.debug_print(" Cannot determine plugin name from %s" % addon_path)
		return false

	# Use EditorInterface to properly enable/disable the plugin
	if Engine.is_editor_hint():
		var is_currently_enabled = EditorInterface.is_plugin_enabled(plugin_name)
		if enabled == is_currently_enabled:
			return true  # Already in desired state

		EditorInterface.set_plugin_enabled(plugin_name, enabled)
		SettingsDialog.debug_print(" %s plugin %s" % ["Enabled" if enabled else "Disabled", plugin_name])

		# Delayed check to verify the plugin state (in case Godot crashed/disabled it)
		if enabled:
			_verify_plugin_enabled_delayed(plugin_name, addon_path)

		return true

	return false


func _verify_plugin_enabled_delayed(plugin_name: String, addon_path: String) -> void:
	# Wait a short time then verify the plugin is still enabled
	await get_tree().create_timer(0.5).timeout
	if Engine.is_editor_hint() and is_inside_tree():
		var still_enabled = EditorInterface.is_plugin_enabled(plugin_name)
		if not still_enabled:
			SettingsDialog.debug_print(" Plugin %s was disabled (possibly crashed). Updating UI." % plugin_name)
			# Refresh the installed tab to reflect the actual state
			if _current_tab == Tab.INSTALLED:
				_show_installed()


func _has_plugin_cfg(addon_path: String) -> bool:
	return not _get_plugin_cfg_path(addon_path).is_empty()


func _disable_plugins_before_uninstall(addon_paths: Array) -> void:
	## Disable any enabled plugins in the given paths before deleting their files
	## This prevents Godot from crashing when trying to access deleted plugin scripts
	## Also scans subdirectories for nested plugins (e.g., templates containing addons)
	for addon_path in addon_paths:
		# First check if this path itself is a plugin
		if _has_plugin_cfg(addon_path):
			_disable_single_plugin(addon_path)

		# Then scan for any nested plugins in subdirectories
		_scan_and_disable_nested_plugins(addon_path)


func _disable_single_plugin(addon_path: String) -> void:
	## Disable a single plugin at the given path
	var plugin_name = addon_path.trim_suffix("/").get_file()
	if plugin_name.is_empty():
		return

	SettingsDialog.debug_print(" Preparing plugin for uninstall: %s" % plugin_name)

	# Always try to disable, even if we think it's not enabled (Godot state might differ)
	if Engine.is_editor_hint():
		if EditorInterface.is_plugin_enabled(plugin_name):
			SettingsDialog.debug_print(" Disabling plugin: %s" % plugin_name)
			EditorInterface.set_plugin_enabled(plugin_name, false)

		# Also remove from project.godot [editor_plugins] section to prevent reload crash
		_remove_plugin_from_project_settings(plugin_name)


func _scan_and_disable_nested_plugins(root_path: String) -> void:
	## Recursively scan a directory for nested plugins and disable them
	## This handles templates that contain addons folders
	var global_path = ProjectSettings.globalize_path(root_path)
	if not DirAccess.dir_exists_absolute(global_path):
		return

	var dir = DirAccess.open(global_path)
	if not dir:
		return

	dir.list_dir_begin()
	var item = dir.get_next()
	while item != "":
		if dir.current_is_dir() and not item.begins_with("."):
			var sub_path = root_path.path_join(item)
			# Check if this subdirectory is a plugin
			if _has_plugin_cfg(sub_path):
				_disable_single_plugin(sub_path)
			# Continue scanning deeper
			_scan_and_disable_nested_plugins(sub_path)
		item = dir.get_next()
	dir.list_dir_end()


func _remove_plugin_from_project_settings(plugin_name: String) -> void:
	## Remove plugin from project.godot [editor_plugins] to prevent crash on filesystem scan
	var enabled_plugins = ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray())
	if enabled_plugins is PackedStringArray:
		var plugin_path = "res://addons/%s/plugin.cfg" % plugin_name
		var new_plugins: PackedStringArray = []
		var found = false
		for p in enabled_plugins:
			if p != plugin_path:
				new_plugins.append(p)
			else:
				found = true
		if found:
			SettingsDialog.debug_print(" Removed plugin from project settings: %s" % plugin_name)
			ProjectSettings.set_setting("editor_plugins/enabled", new_plugins)
			ProjectSettings.save()


func _update_toggle_btn_style(btn: Button, enabled: bool) -> void:
	if enabled:
		btn.add_theme_color_override("font_color", Color(0.4, 0.85, 0.4))
		btn.add_theme_color_override("font_hover_color", Color(0.5, 0.95, 0.5))
	else:
		btn.add_theme_color_override("font_color", Color(0.6, 0.4, 0.4))
		btn.add_theme_color_override("font_hover_color", Color(0.7, 0.5, 0.5))


# ===== INSTALLED ADDONS REGISTRY =====

func _load_installed_registry() -> void:
	_installed_registry.clear()
	var config = ConfigFile.new()
	if config.load(INSTALLED_REGISTRY_PATH) == OK:
		var data = config.get_value("installed", "registry", {})
		if data is Dictionary:
			_installed_registry = data
	# Clean up registry: remove entries for addons that no longer exist
	_cleanup_installed_registry()


func _save_installed_registry() -> void:
	var config = ConfigFile.new()
	config.set_value("installed", "registry", _installed_registry)
	config.save(INSTALLED_REGISTRY_PATH)


func _cleanup_installed_registry() -> bool:
	## Remove entries for addons that no longer exist on disk
	## Uses UIDs to detect moved files and update paths automatically
	## Returns true if any changes were made to the registry
	var to_remove: Array = []
	var registry_changed = false

	SettingsDialog.debug_print_verbose("Checking %d installed assets..." % _installed_registry.size())

	for asset_id in _installed_registry:
		var entry = _installed_registry[asset_id]
		var paths = _get_installed_addon_paths(asset_id)
		var uids = entry.get("uids", []) if entry is Dictionary else []

		SettingsDialog.debug_print_verbose("  Checking '%s': paths=%s, uids_count=%d" % [asset_id, str(paths), uids.size()])

		# First check if any path still exists (could be folder or file)
		var any_path_exists = false
		for path in paths:
			var global_path = ProjectSettings.globalize_path(path)
			var dir_exists = DirAccess.dir_exists_absolute(global_path)
			var file_exists = FileAccess.file_exists(global_path)
			SettingsDialog.debug_print_verbose("    Path '%s' -> dir_exists=%s, file_exists=%s" % [path, str(dir_exists), str(file_exists)])
			if dir_exists or file_exists:
				any_path_exists = true
				break

		if any_path_exists:
			SettingsDialog.debug_print_verbose("    -> Asset exists at known paths, skipping")
			continue  # Asset still exists at known paths

		SettingsDialog.debug_print_verbose("    -> No paths exist, trying UIDs...")

		# Paths don't exist - try to resolve from UIDs
		if uids.size() > 0:
			var new_paths = _resolve_paths_from_uids(uids)
			SettingsDialog.debug_print_verbose("    -> Resolved paths from UIDs: %s" % str(new_paths))
			if new_paths.size() > 0:
				# Check if the new paths are actually different from the old ones
				var paths_changed = false
				if paths.size() != new_paths.size():
					paths_changed = true
				else:
					for new_path in new_paths:
						if new_path not in paths:
							paths_changed = true
							break

				if paths_changed:
					# Files were moved - update the registry with new paths AND tracked file paths
					SettingsDialog.debug_print("Asset '%s' was moved, updating paths" % asset_id)
					if entry is Dictionary:
						# Also update the paths in the uids array (pass old and new paths for non-UID files)
						entry["uids"] = _update_tracked_file_paths(uids, paths, new_paths)
						entry["paths"] = new_paths
						registry_changed = true
				else:
					SettingsDialog.debug_print_verbose("    -> Paths resolved to same location, no change needed")
				continue

		# Neither paths nor UIDs could resolve - mark for removal
		SettingsDialog.debug_print("Asset '%s' was deleted, removing from registry" % asset_id)
		to_remove.append(asset_id)

	for asset_id in to_remove:
		_installed_registry.erase(asset_id)
		registry_changed = true

	if registry_changed:
		_save_installed_registry()
		SettingsDialog.debug_print_verbose("Registry saved after changes")

	return registry_changed


var _filesystem_change_timer: Timer = null
var _filesystem_change_pending := false
var _is_panel_visible := false  # True when AssetPlus tab is the active main screen
var _needs_filesystem_refresh := false  # True when filesystem changed while panel was not visible

func _on_filesystem_changed() -> void:
	## Called when the editor filesystem changes (files added, removed, or moved)
	## Only processes immediately if AssetPlus tab is visible AND on a relevant sub-tab
	## Otherwise defers the refresh until the panel becomes visible

	# Check if we should process now or defer
	var should_process_now = _is_panel_visible and _current_tab in [Tab.INSTALLED, Tab.FAVORITES, Tab.GLOBAL_FOLDER]

	if not should_process_now:
		# Defer the refresh - will be processed when panel becomes visible
		_needs_filesystem_refresh = true
		return

	# Process with debouncing
	if _filesystem_change_pending:
		return

	_filesystem_change_pending = true

	# Debounce: wait a bit before processing to batch rapid changes
	if _filesystem_change_timer == null:
		_filesystem_change_timer = Timer.new()
		_filesystem_change_timer.one_shot = true
		_filesystem_change_timer.wait_time = 0.5
		_filesystem_change_timer.timeout.connect(_process_filesystem_change)
		add_child(_filesystem_change_timer)

	_filesystem_change_timer.start()


func _process_filesystem_change() -> void:
	## Process filesystem changes after debounce period
	_filesystem_change_pending = false

	# Try to recover any pending installations (may have been created before script reload)
	var recovered = _recover_pending_installation()

	# Check if any installed plugins were moved or deleted
	var registry_changed = _cleanup_installed_registry()

	# If registry changed or we recovered, refresh the current view if relevant
	if registry_changed or recovered:
		if _current_tab == Tab.INSTALLED or _current_tab == Tab.FAVORITES or _current_tab == Tab.GLOBAL_FOLDER:
			SettingsDialog.debug_print_verbose("Refreshing current tab after filesystem change")
			_refresh_content()


func set_panel_visible(is_visible: bool) -> void:
	## Called by plugin.gd when the AssetPlus main screen visibility changes
	_is_panel_visible = is_visible

	# If becoming visible and we have pending filesystem changes, process them now
	if is_visible and _needs_filesystem_refresh:
		_needs_filesystem_refresh = false
		SettingsDialog.debug_print_verbose("Processing deferred filesystem changes on tab switch")
		# Try to recover any pending installations
		var recovered = _recover_pending_installation()
		# Process immediately (no debounce since changes already happened)
		var registry_changed = _cleanup_installed_registry()
		if registry_changed or recovered:
			if _current_tab in [Tab.INSTALLED, Tab.FAVORITES, Tab.GLOBAL_FOLDER]:
				_refresh_content()


func _resolve_paths_from_uids(uids: Array) -> Array:
	## Try to resolve current paths from tracked UIDs
	## Returns array of unique folder paths where tracked files ACTUALLY exist on disk
	var folder_paths: Dictionary = {}  # Use dict as set

	for uid_entry in uids:
		if not uid_entry is Dictionary:
			continue
		var uid_str: String = uid_entry.get("uid", "")
		if uid_str.is_empty():
			continue

		# Convert UID string to ID and get current path
		var uid_id = ResourceUID.text_to_id(uid_str)
		if uid_id == ResourceUID.INVALID_ID:
			continue

		if not ResourceUID.has_id(uid_id):
			continue

		var current_path = ResourceUID.get_id_path(uid_id)
		if current_path.is_empty():
			continue

		# IMPORTANT: Verify the file actually exists on disk
		# ResourceUID can return stale paths for deleted files
		var global_path = ProjectSettings.globalize_path(current_path)
		if not FileAccess.file_exists(global_path):
			continue

		# Extract the root folder (addons/xxx or assets/xxx)
		var folder_path = _extract_asset_folder(current_path)
		if not folder_path.is_empty():
			folder_paths[folder_path] = true

	return folder_paths.keys()


func _extract_asset_folder(file_path: String) -> String:
	## Extract the asset/addon folder from a file path
	## e.g., "res://addons/my_plugin/script.gd" -> "res://addons/my_plugin"
	## e.g., "res://assets/textures/img.png" -> "res://assets/textures"
	var parts = file_path.replace("res://", "").split("/")
	if parts.size() >= 2:
		return "res://" + parts[0] + "/" + parts[1]
	return ""


func _update_tracked_file_paths(uids: Array, old_folder_paths: Array, new_folder_paths: Array) -> Array:
	## Update the file paths in tracked UIDs to their current locations
	## Uses ResourceUID to resolve the current path for files with UIDs
	## For files without UIDs, calculates new path based on folder move
	var updated_uids: Array = []

	# Build a mapping from old folder roots to new folder roots
	# old_folder_paths may be individual files/folders like ["res://Packages/foo/assets", "res://Packages/foo/README.md"]
	# new_folder_paths are root folders like ["res://assets/foo"]
	# We need to find the common root of old paths and map it to the new root
	var folder_mapping: Dictionary = {}

	# Extract root folders from old paths (find common parent)
	var old_roots: Dictionary = {}  # Use dict as set
	for old_path in old_folder_paths:
		var root = _extract_asset_folder(old_path)
		if not root.is_empty():
			old_roots[root] = true

	# Create mapping between old roots and new roots
	var old_roots_array = old_roots.keys()
	for i in range(mini(old_roots_array.size(), new_folder_paths.size())):
		folder_mapping[old_roots_array[i]] = new_folder_paths[i]
		SettingsDialog.debug_print_verbose("       Folder mapping: %s -> %s" % [old_roots_array[i], new_folder_paths[i]])

	for uid_entry in uids:
		if not uid_entry is Dictionary:
			continue

		var uid_str: String = uid_entry.get("uid", "")
		var old_path: String = uid_entry.get("path", "")

		# If no UID, try to calculate new path based on folder move
		if uid_str.is_empty():
			var new_path = _calculate_moved_path(old_path, folder_mapping)
			if new_path != old_path:
				var global_new_path = ProjectSettings.globalize_path(new_path)
				if FileAccess.file_exists(global_new_path):
					var new_entry = uid_entry.duplicate()
					new_entry["path"] = new_path
					updated_uids.append(new_entry)
					SettingsDialog.debug_print_verbose("       File moved (no UID): %s -> %s" % [old_path, new_path])
					continue
			# Keep old entry if we can't find the new path
			updated_uids.append(uid_entry)
			continue

		# Try to resolve the current path from the UID
		var uid_id = ResourceUID.text_to_id(uid_str)
		if uid_id == ResourceUID.INVALID_ID:
			# Fall back to folder-based calculation
			var new_path = _calculate_moved_path(old_path, folder_mapping)
			var new_entry = uid_entry.duplicate()
			new_entry["path"] = new_path
			updated_uids.append(new_entry)
			continue

		if not ResourceUID.has_id(uid_id):
			# Fall back to folder-based calculation
			var new_path = _calculate_moved_path(old_path, folder_mapping)
			var new_entry = uid_entry.duplicate()
			new_entry["path"] = new_path
			updated_uids.append(new_entry)
			continue

		var current_path = ResourceUID.get_id_path(uid_id)
		if current_path.is_empty():
			# Fall back to folder-based calculation
			var new_path = _calculate_moved_path(old_path, folder_mapping)
			var new_entry = uid_entry.duplicate()
			new_entry["path"] = new_path
			updated_uids.append(new_entry)
			continue

		# Verify the file actually exists at the new path
		var global_path = ProjectSettings.globalize_path(current_path)
		if not FileAccess.file_exists(global_path):
			# Fall back to folder-based calculation
			var new_path = _calculate_moved_path(old_path, folder_mapping)
			var new_entry = uid_entry.duplicate()
			new_entry["path"] = new_path
			updated_uids.append(new_entry)
			continue

		# Update the path to the new location
		var new_entry = uid_entry.duplicate()
		new_entry["path"] = current_path
		updated_uids.append(new_entry)

		if current_path != old_path:
			SettingsDialog.debug_print_verbose("       File moved: %s -> %s" % [old_path, current_path])

	return updated_uids


func _calculate_moved_path(old_file_path: String, folder_mapping: Dictionary) -> String:
	## Calculate the new path for a file based on folder move mapping
	## e.g., if "res://assets/Foo" moved to "res://gffg/Foo",
	## then "res://assets/Foo/bar.txt" becomes "res://gffg/Foo/bar.txt"
	for old_folder in folder_mapping:
		if old_file_path.begins_with(old_folder):
			var relative_path = old_file_path.substr(old_folder.length())
			return folder_mapping[old_folder] + relative_path
	return old_file_path


func _register_installed_addon(asset_id: String, paths: Variant, asset_info: Dictionary = {}, tracked_uids: Array = []) -> void:
	# Support both single path (String) and multiple paths (Array) for backward compatibility
	var paths_array: Array = []
	if paths is String:
		if paths.is_empty():
			return
		paths_array = [paths]
	elif paths is Array:
		paths_array = paths.filter(func(p): return not p.is_empty())
		if paths_array.is_empty():
			return
	else:
		return

	if asset_id.is_empty():
		return

	_installed_registry[asset_id] = {
		"paths": paths_array,
		"info": asset_info,
		"uids": tracked_uids  # Array of {path: String, uid: String}
	}
	_save_installed_registry()

	# Save version.cfg for assets without plugin.cfg (templates, etc.)
	var version = asset_info.get("version", "")
	var source = asset_info.get("source", "")
	for p in paths_array:
		_save_local_version(p, version, source)


func _collect_missing_uids() -> void:
	## Collect UIDs for installed assets that don't have them yet
	## This handles assets installed during a session where script reload
	## prevented the normal UID collection
	var registry_changed = false

	for asset_id in _installed_registry:
		var entry = _installed_registry[asset_id]
		if not entry is Dictionary:
			continue

		var uids = entry.get("uids", [])
		var paths = _get_installed_addon_paths(asset_id)

		# Skip if already has UIDs with actual values
		var has_valid_uids = false
		for uid_entry in uids:
			if uid_entry is Dictionary and not uid_entry.get("uid", "").is_empty():
				has_valid_uids = true
				break

		if has_valid_uids:
			continue

		# Collect UIDs for all files in the installed paths
		var new_uids: Array = []
		for addon_path in paths:
			var files = _scan_directory_files(addon_path)
			for file_path in files:
				var uid = _get_file_uid_safe(file_path)
				new_uids.append({"path": file_path, "uid": uid})

		if new_uids.size() > 0:
			entry["uids"] = new_uids
			registry_changed = true
			SettingsDialog.debug_print("Collected %d UIDs for %s" % [new_uids.size(), asset_id])

	if registry_changed:
		_save_installed_registry()


func _scan_directory_files(dir_path: String) -> Array:
	## Recursively scan a directory and return all file paths
	var files: Array = []
	var dir = DirAccess.open(dir_path)
	if not dir:
		return files

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path = dir_path.path_join(file_name)
			if dir.current_is_dir():
				files.append_array(_scan_directory_files(full_path))
			else:
				files.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()
	return files


func _get_file_uid_safe(file_path: String) -> String:
	## Get UID for a file, returning empty string if not available
	var uid_id = ResourceLoader.get_resource_uid(file_path)
	if uid_id != ResourceUID.INVALID_ID:
		return ResourceUID.id_to_text(uid_id)
	return ""


func _unregister_installed_addon(asset_id: String) -> void:
	if _installed_registry.has(asset_id):
		_installed_registry.erase(asset_id)
		_save_installed_registry()


func _get_installed_addon_path(asset_id: String) -> String:
	# Returns the first path (for backward compatibility)
	var paths = _get_installed_addon_paths(asset_id)
	return paths[0] if paths.size() > 0 else ""


func _get_installed_addon_paths(asset_id: String) -> Array:
	# Returns all paths for an asset
	var entry = _installed_registry.get(asset_id, {})
	if entry is Dictionary:
		# New format with "paths" array
		if entry.has("paths") and entry["paths"] is Array:
			return entry["paths"]
		# Old format with single "path"
		if entry.has("path") and entry["path"] is String and not entry["path"].is_empty():
			return [entry["path"]]
	# Very old format (just path string)
	if entry is String and not entry.is_empty():
		return [entry]
	return []


func _get_installed_addon_uids(asset_id: String) -> Array:
	# Returns all tracked UIDs for an asset
	var entry = _installed_registry.get(asset_id, {})
	if entry is Dictionary and entry.has("uids"):
		return entry.get("uids", [])
	return []


func _get_resolved_tracked_files(asset_id: String) -> Array:
	## Returns tracked files with resolved paths (using UIDs to find current location)
	## Returns array of {path: String, uid: String} with updated paths
	var uids = _get_installed_addon_uids(asset_id)
	var resolved: Array = []

	for uid_entry in uids:
		if not uid_entry is Dictionary:
			continue

		var stored_path: String = uid_entry.get("path", "")
		var uid_str: String = uid_entry.get("uid", "")
		var resolved_path: String = stored_path

		# Try to resolve actual path from UID
		if not uid_str.is_empty():
			var uid_id = ResourceUID.text_to_id(uid_str)
			if uid_id != ResourceUID.INVALID_ID and ResourceUID.has_id(uid_id):
				var current_path = ResourceUID.get_id_path(uid_id)
				if not current_path.is_empty():
					# Verify the file exists at this path
					var global_path = ProjectSettings.globalize_path(current_path)
					if FileAccess.file_exists(global_path):
						resolved_path = current_path

		resolved.append({"path": resolved_path, "uid": uid_str})

	return resolved


func _get_installed_addon_info(asset_id: String) -> Dictionary:
	var entry = _installed_registry.get(asset_id, {})
	if entry is Dictionary and entry.has("info"):
		return entry["info"]
	return {}


func _is_addon_installed(asset_id: String) -> bool:
	if not _installed_registry.has(asset_id):
		return false
	var paths = _get_installed_addon_paths(asset_id)
	if paths.is_empty():
		return false
	# Check if at least one path exists
	for path in paths:
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)):
			return true

	# Paths don't exist - try UIDs to detect moved files
	var entry = _installed_registry.get(asset_id, {})
	if entry is Dictionary:
		var uids = entry.get("uids", [])
		if uids.size() > 0:
			var resolved_paths = _resolve_paths_from_uids(uids)
			if resolved_paths.size() > 0:
				# Update the registry with new paths
				entry["paths"] = resolved_paths
				_save_installed_registry()
				return true

	return false


# ===== LINKUP SYSTEM =====
# Automatically matches local plugins with their store versions

func _load_linkup_cache() -> void:
	_linkup_cache.clear()
	var config = ConfigFile.new()
	if config.load(LINKUP_CACHE_PATH) == OK:
		var data = config.get_value("linkup", "cache", {})
		if data is Dictionary:
			_linkup_cache = data


func _save_linkup_cache() -> void:
	var config = ConfigFile.new()
	config.set_value("linkup", "cache", _linkup_cache)
	config.save(LINKUP_CACHE_PATH)


func _start_linkup_scan() -> void:
	# Scan all addons in res://addons/ and start linkup for any not in cache
	SettingsDialog.debug_print_verbose("Linkup: Starting background scan...")
	var addons_path = "res://addons/"
	var dir = DirAccess.open(addons_path)
	if not dir:
		SettingsDialog.debug_print_verbose("Linkup: Could not open addons directory")
		return

	dir.list_dir_begin()
	var folder_name = dir.get_next()

	while folder_name != "":
		if dir.current_is_dir() and not folder_name.begins_with(".") and folder_name != "assetplus":
			var addon_path = addons_path + folder_name
			var plugin_cfg_path = addon_path + "/plugin.cfg"

			# Only process valid plugins
			if FileAccess.file_exists(plugin_cfg_path):
				# Skip if already in cache or in registry with a known source
				var skip_linkup = _linkup_cache.has(folder_name)
				if not skip_linkup:
					# Check if this addon is already in registry with a store source
					for asset_id in _installed_registry:
						var entry = _installed_registry[asset_id]
						if entry is Dictionary:
							var paths = entry.get("paths", [])
							if entry.has("path"):
								paths = [entry["path"]]
							for p in paths:
								if p == addon_path or p.trim_suffix("/") == addon_path.trim_suffix("/"):
									var info = entry.get("info", {})
									var source = info.get("source", "")
									if not source.is_empty() and source != "Local":
										skip_linkup = true
										SettingsDialog.debug_print_verbose("Linkup: '%s' already in registry from %s - skipping" % [folder_name, source])
										break
							if skip_linkup:
								break
				if not skip_linkup:
					var cfg = ConfigFile.new()
					var plugin_name = folder_name.replace("-", " ").replace("_", " ").capitalize()
					var plugin_author = "Unknown"

					if cfg.load(plugin_cfg_path) == OK:
						plugin_name = cfg.get_value("plugin", "name", plugin_name)
						plugin_author = cfg.get_value("plugin", "author", plugin_author)

					# Start linkup search in background
					_try_linkup_plugin(folder_name, plugin_name, plugin_author, addon_path)

		folder_name = dir.get_next()

	dir.list_dir_end()
	SettingsDialog.debug_print_verbose("Linkup: Background scan initiated")


func _on_refresh_linkup_pressed() -> void:
	SettingsDialog.debug_print_verbose("Linkup: Manual refresh triggered - clearing cache")
	_linkup_cache.clear()
	_linkup_pending.clear()
	_save_linkup_cache()
	# Also clear installed registry for local plugins (those starting with "local-")
	var to_remove: Array = []
	for asset_id in _installed_registry:
		if not str(asset_id).begins_with("local-"):
			# Keep non-local entries but check if they were from linkup
			pass
	# Refresh the installed tab
	_show_installed()


func _try_linkup_plugin(folder_name: String, plugin_name: String, plugin_author: String, addon_path: String) -> void:
	SettingsDialog.debug_print_verbose("Linkup: Checking '%s' (folder: %s)" % [plugin_name, folder_name])

	# Skip if this addon is already in registry with a known store source (not Local)
	for asset_id in _installed_registry:
		var entry = _installed_registry[asset_id]
		if entry is Dictionary:
			var paths = entry.get("paths", [])
			if entry.has("path"):
				paths = [entry["path"]]
			for p in paths:
				if p == addon_path or p.trim_suffix("/") == addon_path.trim_suffix("/"):
					var info = entry.get("info", {})
					var source = info.get("source", "")
					if not source.is_empty() and source != "Local":
						SettingsDialog.debug_print_verbose("Linkup: '%s' already registered from %s - skipping" % [plugin_name, source])
						return

	# Skip if already in cache (matched or not)
	if _linkup_cache.has(folder_name):
		var cached = _linkup_cache[folder_name]
		if cached.get("matched", false):
			SettingsDialog.debug_print_verbose("Linkup: '%s' already linked to %s" % [plugin_name, cached.get("asset_id", "?")])
			# Already linked - register in registry if not already
			var asset_id = cached.get("asset_id", "")
			if not asset_id.is_empty() and not _installed_registry.has(asset_id):
				_register_installed_addon(asset_id, addon_path, cached.get("info", {}))
		else:
			SettingsDialog.debug_print_verbose("Linkup: '%s' cached as no-match" % plugin_name)
		return

	# Skip if search already pending
	if _linkup_pending.has(folder_name):
		SettingsDialog.debug_print_verbose("Linkup: '%s' search already pending" % plugin_name)
		return

	_linkup_pending[folder_name] = true

	# Build list of search terms to try
	var search_terms: Array[String] = [plugin_name]

	# Try without common suffixes (Plugin, Addon, etc)
	var name_no_suffix = plugin_name
	for suffix in ["Plugin", "Addon", "Extension", "Module"]:
		if name_no_suffix.ends_with(suffix):
			name_no_suffix = name_no_suffix.substr(0, name_no_suffix.length() - suffix.length()).strip_edges()
			if not name_no_suffix.is_empty() and _normalize_name(name_no_suffix) != _normalize_name(plugin_name):
				search_terms.append(name_no_suffix)
				SettingsDialog.debug_print_verbose("Linkup: Will also search without suffix: '%s'" % name_no_suffix)
			break

	# Try with spaces in CamelCase (AssetPlacer -> Asset Placer)
	# Compare raw strings, not normalized (API search is text-based)
	var spaced_name = _add_spaces_to_camelcase(plugin_name)
	if spaced_name != plugin_name and spaced_name not in search_terms:
		search_terms.append(spaced_name)
		SettingsDialog.debug_print_verbose("Linkup: Will also search with spaces: '%s'" % spaced_name)

	# Also try folder name if different from plugin name
	var folder_as_name = folder_name.replace("-", " ").replace("_", " ")
	if _normalize_name(folder_name) != _normalize_name(plugin_name) and folder_as_name not in search_terms:
		search_terms.append(folder_as_name)
		SettingsDialog.debug_print_verbose("Linkup: Will also search by folder name '%s'" % folder_as_name)

	SettingsDialog.debug_print_verbose("Linkup: Starting search for '%s'..." % plugin_name)

	# Search AssetLib first, then Beta Store if no match
	_linkup_search_assetlib(folder_name, search_terms, plugin_author, addon_path, 0)


func _linkup_search_assetlib(folder_name: String, search_terms: Array[String], plugin_author: String, addon_path: String, term_index: int) -> void:
	if term_index >= search_terms.size():
		# All terms exhausted, try Beta Store with all terms
		_linkup_search_beta(folder_name, search_terms, plugin_author, addon_path, 0)
		return

	var search_term = search_terms[term_index]
	var http = HTTPRequest.new()
	add_child(http)

	# Use high version number to get all Godot 4.x assets
	var engine_version = Engine.get_version_info()
	var godot_ver = "%d.9" % engine_version.get("major", 4)  # e.g., "4.9"

	# Search by current term
	var url = "%s/asset?godot_version=%s&max_results=10&filter=%s" % [GODOT_API, godot_ver, search_term.uri_encode()]
	SettingsDialog.debug_print_verbose("Linkup: Searching AssetLib for '%s'..." % search_term)

	http.request_completed.connect(func(result, code, headers, body):
		http.queue_free()
		_on_linkup_assetlib_response(result, code, body, folder_name, search_terms, plugin_author, addon_path, term_index)
	)
	http.request(url)


func _on_linkup_assetlib_response(result: int, code: int, body: PackedByteArray, folder_name: String, search_terms: Array[String], plugin_author: String, addon_path: String, term_index: int) -> void:
	var search_term = search_terms[term_index]
	SettingsDialog.debug_print_verbose("Linkup: AssetLib response for '%s' - code %d" % [search_term, code])

	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var json = JSON.new()
		if json.parse(body.get_string_from_utf8()) == OK:
			var data = json.data
			var results = data.get("result", [])
			SettingsDialog.debug_print_verbose("Linkup: AssetLib returned %d results for '%s'" % [results.size(), search_term])

			for asset in results:
				var title = asset.get("title", "")
				var author = asset.get("author", "")
				SettingsDialog.debug_print_verbose("Linkup: Comparing '%s' with AssetLib '%s' by %s" % [search_term, title, author])

				# Check for confident match with current search term
				if _is_confident_match(search_term, title, plugin_author, author):
					SettingsDialog.debug_print_verbose("Linkup: MATCH FOUND for '%s' -> '%s'" % [search_term, title])
					var asset_id = str(asset.get("asset_id", ""))
					var info = {
						"source": SOURCE_GODOT,
						"asset_id": asset_id,
						"title": title,
						"author": author,
						"category": asset.get("category", ""),
						"version": asset.get("version_string", ""),
						"description": asset.get("description", ""),
						"icon_url": asset.get("icon_url", ""),
						"cost": asset.get("cost", "Free"),
						"license": asset.get("license", "MIT"),
						"support_level": asset.get("support_level", ""),
						"browse_url": "https://godotengine.org/asset-library/asset/" + asset_id,
						"installed_path": addon_path
					}

					# Found match!
					_linkup_cache[folder_name] = {
						"matched": true,
						"asset_id": asset_id,
						"source": SOURCE_GODOT,
						"info": info
					}
					_save_linkup_cache()
					_register_installed_addon(asset_id, addon_path, info)
					_linkup_pending.erase(folder_name)

					SettingsDialog.debug_print_verbose("Linkup: Matched '%s' -> AssetLib '%s' by %s" % [search_term, title, author])
					# Auto-refresh Installed tab if currently viewing it
					if _current_tab == Tab.INSTALLED:
						call_deferred("_show_installed")
					return

	# No match with this term, try next term
	SettingsDialog.debug_print_verbose("Linkup: No AssetLib match for '%s'" % search_term)
	_linkup_search_assetlib(folder_name, search_terms, plugin_author, addon_path, term_index + 1)


func _linkup_search_beta(folder_name: String, search_terms: Array[String], plugin_author: String, addon_path: String, term_index: int) -> void:
	if term_index >= search_terms.size():
		# All terms exhausted, no match found
		SettingsDialog.debug_print_verbose("Linkup: No match found for folder '%s' - caching as no-match" % folder_name)
		_linkup_cache[folder_name] = {"matched": false}
		_save_linkup_cache()
		_linkup_pending.erase(folder_name)
		return

	var search_term = search_terms[term_index]
	var http = HTTPRequest.new()
	add_child(http)

	# Search Beta Store
	var url = "https://store-beta.godotengine.org/search/?query=%s&sort=relevance" % search_term.uri_encode()
	SettingsDialog.debug_print_verbose("Linkup: Searching Beta Store for '%s'..." % search_term)

	http.request_completed.connect(func(result, code, headers, body):
		http.queue_free()
		_on_linkup_beta_response(result, code, body, folder_name, search_terms, plugin_author, addon_path, term_index)
	)
	http.request(url)


func _on_linkup_beta_response(result: int, code: int, body: PackedByteArray, folder_name: String, search_terms: Array[String], plugin_author: String, addon_path: String, term_index: int) -> void:
	var search_term = search_terms[term_index]
	SettingsDialog.debug_print_verbose("Linkup: Beta Store response for '%s' - code %d" % [search_term, code])

	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var html = body.get_string_from_utf8()

		# Parse results - look for asset cards
		var card_regex = RegEx.new()
		card_regex.compile('(?s)<a[^>]*href="/asset/([a-z0-9-]+)/([a-z0-9-]+)/"[^>]*>.*?<img[^>]*src="([^"]+)"')
		var matches = card_regex.search_all(html)
		SettingsDialog.debug_print_verbose("Linkup: Beta Store returned %d results for '%s'" % [matches.size(), search_term])

		for m in matches:
			var publisher = m.get_string(1)
			var slug = m.get_string(2)
			var icon_url = m.get_string(3)

			var title = slug.replace("-", " ")
			var author = publisher.replace("-", " ")
			SettingsDialog.debug_print_verbose("Linkup: Comparing '%s' with Beta '%s' by %s" % [search_term, title, author])

			# Check for confident match
			if _is_confident_match(search_term, title, plugin_author, author):
				SettingsDialog.debug_print_verbose("Linkup: MATCH FOUND for '%s' -> Beta '%s'" % [search_term, title])
				var asset_id = "%s/%s" % [publisher, slug]
				var info = {
					"source": SOURCE_GODOT_BETA,
					"asset_id": asset_id,
					"title": title.capitalize(),
					"author": author.capitalize(),
					"category": "Tools",  # Beta Store doesn't provide category in linkup, default to Tools
					"version": "",
					"description": "",
					"icon_url": icon_url if icon_url.begins_with("http") else GODOT_BETA_DEFAULT_IMAGE,
					"license": "MIT",
					"cost": "Free",
					"browse_url": "https://store-beta.godotengine.org/asset/%s/%s/" % [publisher, slug],
					"installed_path": addon_path
				}

				# Found match!
				_linkup_cache[folder_name] = {
					"matched": true,
					"asset_id": asset_id,
					"source": SOURCE_GODOT_BETA,
					"info": info
				}
				_save_linkup_cache()
				_register_installed_addon(asset_id, addon_path, info)
				_linkup_pending.erase(folder_name)

				SettingsDialog.debug_print_verbose("Linkup: Matched '%s' -> Beta Store '%s' by %s" % [search_term, title.capitalize(), author.capitalize()])
				# Auto-refresh Installed tab if currently viewing it
				if _current_tab == Tab.INSTALLED:
					call_deferred("_show_installed")
				return

	# No match with this term, try next term
	SettingsDialog.debug_print_verbose("Linkup: No Beta Store match for '%s'" % search_term)
	_linkup_search_beta(folder_name, search_terms, plugin_author, addon_path, term_index + 1)


func _is_confident_match(local_name: String, store_name: String, local_author: String, store_author: String) -> bool:
	# Normalize names for comparison
	var norm_local = _normalize_name(local_name)
	var norm_store = _normalize_name(store_name)

	SettingsDialog.debug_print_verbose("Linkup: Match check - normalized '%s' vs '%s'" % [norm_local, norm_store])

	# Exact name match (case-insensitive, ignoring separators)
	if norm_local == norm_store:
		SettingsDialog.debug_print_verbose("Linkup: Exact match!")
		return true

	# Check if store name STARTS WITH local name (for "GD-Sync" vs "GD-Sync | Advanced Plugin")
	# Local name must be substantial (at least 4 chars) to avoid false positives
	if norm_local.length() >= 4 and norm_store.begins_with(norm_local):
		SettingsDialog.debug_print_verbose("Linkup: Store name starts with local name - match!")
		return true

	# Check if local name is contained in store name AND local name is substantial
	# This handles cases like abbreviations in the middle
	if norm_local.length() >= 5 and norm_local in norm_store:
		# Additional check: local name should be a significant portion of store name
		# to avoid matching "test" in "contestmanager"
		var ratio = float(norm_local.length()) / float(norm_store.length())
		if ratio >= 0.4:  # Local name is at least 40% of store name
			SettingsDialog.debug_print_verbose("Linkup: Local name contained in store name (ratio %.2f) - match!" % ratio)
			return true

	return false


func _normalize_name(name: String) -> String:
	# Lowercase, remove common separators, trim
	return name.to_lower().replace("-", "").replace("_", "").replace(" ", "").strip_edges()


func _add_spaces_to_camelcase(name: String) -> String:
	# Convert "AssetPlacerPlugin" to "Asset Placer Plugin"
	var result = ""
	for i in range(name.length()):
		var c = name[i]
		# Add space before uppercase letters (except at start)
		if i > 0 and c == c.to_upper() and c != c.to_lower():
			# Check if previous char was lowercase (avoid splitting "HTTPRequest" -> "H T T P Request")
			var prev = name[i - 1]
			if prev == prev.to_lower() and prev != prev.to_upper():
				result += " "
		result += c
	return result


func _is_assetplus(info: Dictionary) -> bool:
	## Check if an asset is AssetPlus itself (to filter from stores or show specially)
	var title = info.get("title", "").to_lower()
	var asset_id = str(info.get("asset_id", ""))

	# Check by asset_id if we know it
	if not ASSETPLUS_ASSET_ID.is_empty() and asset_id == ASSETPLUS_ASSET_ID:
		return true

	# Check by name
	for name_variant in ASSETPLUS_NAMES:
		if title == name_variant or _normalize_name(title) == _normalize_name(name_variant):
			return true

	return false


# ===== UPDATE CHECKING FOR INSTALLED ADDONS =====

func _load_update_cache() -> void:
	_update_cache.clear()
	_ignored_updates.clear()
	var config = ConfigFile.new()
	if config.load(UPDATE_CACHE_PATH) == OK:
		var data = config.get_value("updates", "cache", {})
		if data is Dictionary:
			_update_cache = data
		var ignored = config.get_value("updates", "ignored", {})
		if ignored is Dictionary:
			_ignored_updates = ignored


func _save_update_cache() -> void:
	var config = ConfigFile.new()
	config.set_value("updates", "cache", _update_cache)
	config.set_value("updates", "ignored", _ignored_updates)
	config.save(UPDATE_CACHE_PATH)


func _is_update_ignored(asset_id: String, version: String) -> bool:
	## Check if a specific update version is ignored for an asset
	if not _ignored_updates.has(asset_id):
		return false
	return _ignored_updates[asset_id] == version


func _ignore_update(asset_id: String, version: String) -> void:
	## Mark a specific update version as ignored for an asset
	_ignored_updates[asset_id] = version
	_save_update_cache()
	SettingsDialog.debug_print("Ignored update %s for asset %s" % [version, asset_id])


func _clear_ignored_update(asset_id: String) -> void:
	## Clear ignored update for an asset (e.g., when user manually updates)
	if _ignored_updates.has(asset_id):
		_ignored_updates.erase(asset_id)
		_save_update_cache()


func _recover_pending_installation() -> bool:
	## Recover installation that was interrupted by script reload
	## This handles the case where Godot reloads scripts after file changes,
	## canceling the signal handler before it can register the installed addon
	## Returns true if a recovery was performed (new install or update)
	var pending_path = "user://assetplus_pending_install.cfg"
	SettingsDialog.debug_print("Checking for pending installation at: %s" % pending_path)
	if not FileAccess.file_exists(pending_path):
		SettingsDialog.debug_print("No pending installation file found")
		return false

	SettingsDialog.debug_print("Found pending installation file, loading...")
	var cfg = ConfigFile.new()
	if cfg.load(pending_path) != OK:
		SettingsDialog.debug_print("Failed to load pending installation file")
		return false

	var asset_id = cfg.get_value("pending", "asset_id", "")
	var paths = cfg.get_value("pending", "paths", [])
	var info = cfg.get_value("pending", "info", {})
	var uids = cfg.get_value("pending", "uids", [])
	var timestamp = cfg.get_value("pending", "timestamp", 0)

	SettingsDialog.debug_print("Pending install: asset_id=%s, paths=%s, timestamp=%d" % [asset_id, str(paths), timestamp])

	# Only recover if the pending install is recent (within last 60 seconds)
	var current_time = int(Time.get_unix_time_from_system())
	if current_time - timestamp > 60:
		# Old pending file, just delete it
		SettingsDialog.debug_print("Pending installation too old (%d seconds), deleting" % (current_time - timestamp))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(pending_path))
		return false

	# Verify paths still exist
	var valid_paths: Array = []
	for p in paths:
		var global_p = ProjectSettings.globalize_path(p) if p.begins_with("res://") else p
		SettingsDialog.debug_print("Checking path: %s -> %s" % [p, global_p])
		if p is String and DirAccess.dir_exists_absolute(global_p):
			valid_paths.append(p)
			SettingsDialog.debug_print("  Path exists!")
		else:
			SettingsDialog.debug_print("  Path does NOT exist")

	if valid_paths.is_empty():
		# Paths don't exist, delete pending file
		SettingsDialog.debug_print("No valid paths found, deleting pending file")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(pending_path))
		return false

	# Check if this is an update (asset already registered) or new install
	var is_update = _installed_registry.has(asset_id)
	if is_update:
		SettingsDialog.debug_print("Asset already registered - this is an update, updating info...")
		# Update the existing entry with new version info
		var new_version = info.get("version", "")
		if not new_version.is_empty():
			var entry = _installed_registry[asset_id]
			if entry is Dictionary:
				var stored_info = entry.get("info", {})
				stored_info["version"] = new_version
				entry["info"] = stored_info
				entry["paths"] = valid_paths
				_installed_registry[asset_id] = entry
				_save_installed_registry()
				SettingsDialog.debug_print("Updated version to %s" % new_version)
		# Clear update cache for this asset
		if _update_cache.has(asset_id):
			_update_cache.erase(asset_id)
			_save_update_cache()
	else:
		# Register new installation
		SettingsDialog.debug_print("Recovering pending installation: %s with paths %s" % [info.get("title", asset_id), str(valid_paths)])
		_register_installed_addon(asset_id, valid_paths, info, uids)

	# Track paths for session
	for p in valid_paths:
		if p not in _session_installed_paths:
			_session_installed_paths.append(p)

	# Delete the pending file
	DirAccess.remove_absolute(ProjectSettings.globalize_path(pending_path))
	SettingsDialog.debug_print("Pending installation recovered successfully!")
	return true


func _check_addon_updates() -> void:
	## Check for updates on all installed addons with a store source
	SettingsDialog.debug_print("Checking for addon updates...")

	var current_time = int(Time.get_unix_time_from_system())

	for asset_id in _installed_registry:
		var entry = _installed_registry[asset_id]
		if not entry is Dictionary:
			continue

		var info: Dictionary = entry.get("info", {})
		var source = info.get("source", "")

		# Only check addons from stores
		if source != SOURCE_GODOT and source != SOURCE_GODOT_BETA:
			continue

		# Skip if already pending
		if _update_check_pending.has(asset_id):
			continue

		# Check cache - if recent enough, skip
		if _update_cache.has(asset_id):
			var cached = _update_cache[asset_id]
			var checked_at = cached.get("checked_at", 0)
			if current_time - checked_at < UPDATE_CACHE_TTL:
				SettingsDialog.debug_print_verbose("Update check: Using cached data for %s" % asset_id)
				continue

		# Start update check
		_update_check_pending[asset_id] = true
		if source == SOURCE_GODOT:
			_check_assetlib_update(asset_id, info)
		elif source == SOURCE_GODOT_BETA:
			_check_beta_update(asset_id, info)


func _check_assetlib_update(asset_id: String, info: Dictionary) -> void:
	## Check AssetLib for updates
	var http = HTTPRequest.new()
	add_child(http)

	var url = "https://godotengine.org/asset-library/api/asset/%s" % asset_id
	SettingsDialog.debug_print_verbose("Update check: Fetching AssetLib details for %s" % asset_id)

	http.request_completed.connect(func(result, code, headers, body):
		http.queue_free()
		_on_assetlib_update_response(result, code, body, asset_id, info)
	)
	http.request(url)


func _on_assetlib_update_response(result: int, code: int, body: PackedByteArray, asset_id: String, info: Dictionary) -> void:
	_update_check_pending.erase(asset_id)

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		SettingsDialog.debug_print_verbose("Update check: Failed to fetch AssetLib details for %s" % asset_id)
		return

	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		return

	var data = json.data
	if not data is Dictionary:
		return

	var latest_version = data.get("version_string", "")
	var godot_version = data.get("godot_version", "")
	var download_url = data.get("download_url", "")

	# Store in cache
	_update_cache[asset_id] = {
		"latest_version": latest_version,
		"godot_version": godot_version,
		"download_url": download_url,
		"checked_at": int(Time.get_unix_time_from_system())
	}
	_save_update_cache()

	# Check if update is available
	var installed_version = info.get("version", "").split(" | ")[0].strip_edges()  # Remove Godot version suffix
	if not latest_version.is_empty() and latest_version != installed_version:
		SettingsDialog.debug_print("Update available for %s: %s -> %s" % [info.get("title", asset_id), installed_version, latest_version])
		# Refresh the installed tab to show the update badge
		if _current_tab == Tab.INSTALLED:
			call_deferred("_refresh_installed_cards")


func _check_beta_update(asset_id: String, info: Dictionary) -> void:
	## Check Godot Store Beta for updates
	var browse_url = info.get("browse_url", "")
	if browse_url.is_empty():
		_update_check_pending.erase(asset_id)
		return

	var http = HTTPRequest.new()
	add_child(http)

	SettingsDialog.debug_print_verbose("Update check: Fetching Beta Store details for %s" % asset_id)

	http.request_completed.connect(func(result, code, headers, body):
		http.queue_free()
		_on_beta_update_response(result, code, body, asset_id, info)
	)
	http.request(browse_url)


func _on_beta_update_response(result: int, code: int, body: PackedByteArray, asset_id: String, info: Dictionary) -> void:
	_update_check_pending.erase(asset_id)

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		SettingsDialog.debug_print_verbose("Update check: Failed to fetch Beta Store details for %s" % asset_id)
		return

	var html = body.get_string_from_utf8()

	# Parse publisher/slug from asset_id (format: publisher/slug)
	var parts = asset_id.split("/")
	var publisher = parts[0] if parts.size() > 0 else ""
	var slug = parts[1] if parts.size() > 1 else ""

	# Parse all versions from version-dropdown
	# Format: <option data-id="702" data-version="3.0" ... data-min-display-version="4.0" data-max-display-version="4.6">
	var all_versions: Array = []
	var version_regex = RegEx.new()
	version_regex.compile('<option[^>]*data-id="([^"]*)"[^>]*data-version="([^"]+)"[^>]*data-min-display-version="([^"]*)"[^>]*data-max-display-version="([^"]*)"')
	var all_matches = version_regex.search_all(html)

	SettingsDialog.debug_print_verbose("Update check: Found %d versions for %s" % [all_matches.size(), asset_id])

	for m in all_matches:
		var download_id = m.get_string(1)
		var version = m.get_string(2)
		var min_godot = m.get_string(3)
		var max_godot = m.get_string(4)

		# Format Godot version like in detail dialog: "4.0-4.6" or "4.0+"
		var godot_display = ""
		if min_godot != "Undefined" and max_godot != "Undefined":
			godot_display = "%s-%s" % [min_godot, max_godot]
		elif min_godot != "Undefined":
			godot_display = "%s+" % min_godot
		elif max_godot != "Undefined":
			godot_display = "<=%s" % max_godot

		var version_download_url = ""
		if not download_id.is_empty() and not publisher.is_empty() and not slug.is_empty():
			version_download_url = "https://store-beta.godotengine.org/asset/%s/%s/download/%s/" % [publisher, slug, download_id]

		all_versions.append({
			"version": version,
			"godot_version": godot_display,
			"download_url": version_download_url,
			"download_id": download_id
		})
		SettingsDialog.debug_print_verbose("  Version %s (Godot %s, ID: %s)" % [version, godot_display, download_id])

	if all_versions.is_empty():
		SettingsDialog.debug_print_verbose("Update check: No versions found for %s" % asset_id)
		return

	var latest_version = all_versions[0].get("version", "")
	var godot_version = all_versions[0].get("godot_version", "")
	var download_url = all_versions[0].get("download_url", "")

	# Store in cache
	_update_cache[asset_id] = {
		"latest_version": latest_version,
		"godot_version": godot_version,
		"download_url": download_url,
		"versions": all_versions,
		"checked_at": int(Time.get_unix_time_from_system())
	}
	_save_update_cache()

	# Check if update is available
	var installed_version = info.get("version", "").split(" | ")[0].strip_edges()
	if not latest_version.is_empty() and latest_version != installed_version:
		SettingsDialog.debug_print("Update available for %s: %s -> %s" % [info.get("title", asset_id), installed_version, latest_version])
		if _current_tab == Tab.INSTALLED:
			call_deferred("_refresh_installed_cards")


func _has_update_available(asset_id: String, installed_version: String) -> bool:
	## Check if an update is available for the given asset
	if not _update_cache.has(asset_id):
		return false

	var cached = _update_cache[asset_id]
	var latest_version = cached.get("latest_version", "")

	if latest_version.is_empty():
		return false

	# Normalize versions for comparison (remove 'v' prefix, trim)
	var norm_installed = installed_version.split(" | ")[0].strip_edges()
	if norm_installed.begins_with("v"):
		norm_installed = norm_installed.substr(1)

	var norm_latest = latest_version.strip_edges()
	if norm_latest.begins_with("v"):
		norm_latest = norm_latest.substr(1)

	return norm_latest != norm_installed and not norm_latest.is_empty()


func _get_update_info(asset_id: String) -> Dictionary:
	## Get update info for an asset (if available)
	if _update_cache.has(asset_id):
		return _update_cache[asset_id]
	return {}


func _get_local_version(addon_path: String) -> String:
	## Get local installed version from plugin.cfg or version.cfg
	## Returns empty string if no version found
	## For templates, version.cfg may be in a subfolder (e.g., assets/)
	if addon_path.is_empty():
		return ""

	var base_path = addon_path.trim_suffix("/")

	# First try plugin.cfg (for plugins)
	var plugin_cfg_path = base_path + "/plugin.cfg"
	if FileAccess.file_exists(plugin_cfg_path):
		var cfg = ConfigFile.new()
		if cfg.load(plugin_cfg_path) == OK:
			var version = cfg.get_value("plugin", "version", "")
			if not version.is_empty():
				return version

	# Then try version.cfg at root (for non-plugin assets like templates)
	var version_cfg_path = base_path + "/version.cfg"
	if FileAccess.file_exists(version_cfg_path):
		var cfg = ConfigFile.new()
		if cfg.load(version_cfg_path) == OK:
			var version = cfg.get_value("assetplus", "version", "")
			if not version.is_empty():
				return version

	# For templates, version.cfg may be in a subfolder - check immediate subdirectories
	var dir = DirAccess.open(base_path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if dir.current_is_dir() and not file_name.begins_with("."):
				var sub_version_cfg = base_path + "/" + file_name + "/version.cfg"
				if FileAccess.file_exists(sub_version_cfg):
					var cfg = ConfigFile.new()
					if cfg.load(sub_version_cfg) == OK:
						var version = cfg.get_value("assetplus", "version", "")
						if not version.is_empty():
							dir.list_dir_end()
							return version
			file_name = dir.get_next()
		dir.list_dir_end()

	return ""


func _parse_godot_version_number(version_num: String) -> String:
	## Convert Godot's internal version number (e.g., "40000300000") to readable format (e.g., "4.3")
	## Format: major * 10000000000 + minor * 100000000 + patch * 1000000
	## Examples: 40000300000 = 4.3.0, 40000400000 = 4.4.0, 40000000000 = 4.0.0
	if version_num.is_empty():
		return ""

	# If it's already a readable version (contains "."), return as-is
	if "." in version_num:
		return version_num

	# If it's not a valid number, return as-is
	if not version_num.is_valid_int():
		return version_num

	var num = version_num.to_int()
	if num < 10000000000:  # Not in the expected format
		return version_num

	var major = num / 10000000000
	var remainder = num % 10000000000
	var minor = remainder / 100000000
	var patch = (remainder % 100000000) / 1000000

	if patch > 0:
		return "%d.%d.%d" % [major, minor, patch]
	else:
		return "%d.%d" % [major, minor]


func _compare_versions(version_a: String, version_b: String) -> int:
	## Compare two version strings
	## Returns: >0 if a > b, <0 if a < b, 0 if equal
	## Handles versions like "1.0.0", "0.10.1", "1.2.3-beta", etc.
	if version_a == version_b:
		return 0

	# Extract only the numeric part (before any "-" suffix like "-beta", "-DEV", etc.)
	var a_base = version_a.split("-")[0].strip_edges()
	var b_base = version_b.split("-")[0].strip_edges()

	# Split into parts
	var a_parts = a_base.split(".")
	var b_parts = b_base.split(".")

	# Compare each part
	var max_parts = maxi(a_parts.size(), b_parts.size())
	for i in range(max_parts):
		var a_val = 0
		var b_val = 0

		if i < a_parts.size() and a_parts[i].is_valid_int():
			a_val = a_parts[i].to_int()
		if i < b_parts.size() and b_parts[i].is_valid_int():
			b_val = b_parts[i].to_int()

		if a_val > b_val:
			return 1
		elif a_val < b_val:
			return -1

	# If numeric parts are equal, version without suffix is considered higher
	# e.g., "1.0.0" > "1.0.0-beta"
	var a_has_suffix = "-" in version_a
	var b_has_suffix = "-" in version_b
	if a_has_suffix and not b_has_suffix:
		return -1
	elif not a_has_suffix and b_has_suffix:
		return 1

	return 0


func _save_local_version(addon_path: String, version: String, source: String = "") -> void:
	## Save version info to version.cfg for assets without plugin.cfg
	## This allows tracking updates for templates and non-plugin assets
	if addon_path.is_empty():
		return

	# Skip if plugin.cfg exists (it already has version)
	var plugin_cfg_path = addon_path.trim_suffix("/") + "/plugin.cfg"
	if FileAccess.file_exists(plugin_cfg_path):
		return

	# Use "unknown" if version is empty (we still want to track the install)
	var save_version = version if not version.is_empty() else "unknown"

	# Create version.cfg
	var version_cfg_path = addon_path.trim_suffix("/") + "/version.cfg"
	var cfg = ConfigFile.new()
	cfg.set_value("assetplus", "version", save_version)
	cfg.set_value("assetplus", "installed_at", Time.get_unix_time_from_system())
	if not source.is_empty():
		cfg.set_value("assetplus", "source", source)

	var err = cfg.save(version_cfg_path)
	if err == OK:
		SettingsDialog.debug_print("Saved version.cfg for %s (version: %s)" % [addon_path, save_version])
	else:
		SettingsDialog.debug_print("Failed to save version.cfg for %s: %d" % [addon_path, err])


func _refresh_installed_cards() -> void:
	## Refresh cards to show update badges without full reload
	# For now, just reload the installed tab
	if _current_tab == Tab.INSTALLED:
		_show_installed()


func _show_update_prompt(info: Dictionary, detail_dialog: AcceptDialog) -> void:
	## Show an update prompt dialog when clicking on an addon with available update
	var asset_id = info.get("asset_id", "")
	var update_info = _get_update_info(asset_id)
	if update_info.is_empty():
		return

	var installed_version = info.get("version", "").split(" | ")[0].strip_edges()
	var installed_godot = ""
	if " | Godot " in info.get("version", ""):
		installed_godot = info.get("version", "").split(" | Godot ")[1].strip_edges()

	var latest_version = update_info.get("latest_version", "")
	var latest_godot = update_info.get("godot_version", "")

	# Create update prompt dialog
	var update_dialog = AcceptDialog.new()
	update_dialog.title = "Update Available"
	update_dialog.size = Vector2i(450, 280)
	update_dialog.ok_button_text = "Update"
	update_dialog.add_cancel_button("Later")

	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 12)
	update_dialog.add_child(main_vbox)

	# Title
	var title_label = Label.new()
	title_label.text = "An update is available for %s" % info.get("title", "this addon")
	title_label.add_theme_font_size_override("font_size", 15)
	main_vbox.add_child(title_label)

	# Separator
	main_vbox.add_child(HSeparator.new())

	# Version comparison grid
	var grid = GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 20)
	grid.add_theme_constant_override("v_separation", 8)
	main_vbox.add_child(grid)

	# Header row
	var empty_label = Label.new()
	empty_label.text = ""
	grid.add_child(empty_label)

	var version_header = Label.new()
	version_header.text = "Version"
	version_header.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	grid.add_child(version_header)

	var godot_header = Label.new()
	godot_header.text = "Godot"
	godot_header.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	grid.add_child(godot_header)

	# Current version row
	var current_label = Label.new()
	current_label.text = "Current:"
	grid.add_child(current_label)

	var current_version_label = Label.new()
	current_version_label.text = installed_version if not installed_version.is_empty() else "-"
	current_version_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	grid.add_child(current_version_label)

	var current_godot_label = Label.new()
	current_godot_label.text = installed_godot if not installed_godot.is_empty() else "-"
	current_godot_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	grid.add_child(current_godot_label)

	# New version row
	var new_label = Label.new()
	new_label.text = "New:"
	grid.add_child(new_label)

	var new_version_label = Label.new()
	new_version_label.text = latest_version
	new_version_label.add_theme_color_override("font_color", Color(0.5, 0.9, 0.5))
	grid.add_child(new_version_label)

	var new_godot_label = Label.new()
	new_godot_label.text = latest_godot if not latest_godot.is_empty() else "-"
	new_godot_label.add_theme_color_override("font_color", Color(0.5, 0.9, 0.5))
	grid.add_child(new_godot_label)

	# Warning if Godot version might be incompatible
	var engine_version = Engine.get_version_info()
	var current_godot_major = engine_version.get("major", 4)
	var current_godot_minor = engine_version.get("minor", 0)
	var current_godot_str = "%d.%d" % [current_godot_major, current_godot_minor]

	if not latest_godot.is_empty() and latest_godot != current_godot_str:
		main_vbox.add_child(HSeparator.new())
		var warning_label = Label.new()
		warning_label.text = "Note: This version targets Godot %s (you have %s)" % [latest_godot, current_godot_str]
		warning_label.add_theme_color_override("font_color", Color(0.95, 0.7, 0.2))
		warning_label.add_theme_font_size_override("font_size", 12)
		warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		main_vbox.add_child(warning_label)

	# Add spacer
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	main_vbox.add_child(spacer)

	# "Don't show again" checkbox
	var dont_show_check = CheckBox.new()
	dont_show_check.text = "Don't show this again for this addon"
	dont_show_check.add_theme_font_size_override("font_size", 12)
	dont_show_check.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	main_vbox.add_child(dont_show_check)

	# Handle update confirmation
	update_dialog.confirmed.connect(func():
		update_dialog.queue_free()
		# Clear ignored update when user chooses to update
		_clear_ignored_update(asset_id)
		# Close detail dialog too
		if is_instance_valid(detail_dialog):
			detail_dialog.hide()
		# Start the update process
		_perform_addon_update(info, latest_version, update_info.get("download_url", ""))
	)

	update_dialog.canceled.connect(func():
		# If "don't show again" is checked, ignore this update version
		if dont_show_check.button_pressed:
			_ignore_update(asset_id, latest_version)
		update_dialog.queue_free()
	)

	EditorInterface.get_base_control().add_child(update_dialog)
	update_dialog.popup_centered()


func _perform_addon_update(info: Dictionary, target_version: String, download_url: String) -> void:
	## Perform the addon update by downloading and installing the new version
	var asset_id = info.get("asset_id", "")
	var source = info.get("source", "")

	SettingsDialog.debug_print("Starting update for %s to version %s" % [info.get("title", asset_id), target_version])

	# If no download URL in cache, fetch it
	if download_url.is_empty():
		var update_info = _get_update_info(asset_id)
		download_url = update_info.get("download_url", "")

	if download_url.is_empty():
		_show_message("Could not find download URL for update. Please try reinstalling manually.")
		return

	# Get current installed paths from registry (in case asset was moved)
	var current_paths = _get_installed_addon_paths(asset_id)
	var update_target_path = ""
	if current_paths.size() > 0:
		# Use the exact current installation path - install_dialog will replace this folder
		update_target_path = current_paths[0]
		SettingsDialog.debug_print("Update will replace existing installation at: %s" % update_target_path)

	# Create updated info with the download URL
	var update_asset_info = info.duplicate()
	update_asset_info["download_url"] = download_url
	update_asset_info["version"] = target_version
	if not update_target_path.is_empty():
		update_asset_info["update_target_path"] = update_target_path

	# Use the existing install flow (which will overwrite the current installation)
	_on_install_requested(update_asset_info)
