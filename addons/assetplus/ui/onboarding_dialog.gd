@tool
extends AcceptDialog

## Onboarding dialog - explains how to use AssetPlus

const SettingsDialog = preload("res://addons/assetplus/ui/settings_dialog.gd")

# Page indices for direct navigation
enum Page {
	WELCOME = 0,
	STORE = 1,
	INSTALLED = 2,
	FAVORITES = 3,
	GLOBAL_FOLDER = 4,
	IMPORT_EXPORT = 5,
	READY = 6
}

const PAGES = [
	{
		"title": "Welcome to AssetPlus",
		"icon": "AssetLib",
		"tab_preview": false,
		"toolbar_preview": true,
		"content": """[center][font_size=16]Your unified asset browser for Godot[/font_size][/center]

AssetPlus lets you discover, install, and manage assets from multiple sources in one place.

[center][color=#aaaaaa]You can access AssetPlus anytime from the top toolbar:[/color][/center]

[center][color=#666666](next to 2D, 3D, Script, AssetLib)[/color][/center]

[center][color=#ffaa44][b]Beta Notice[/b][/color][/center]
[center][color=#888888]This plugin is in beta. Issues may occur.[/color][/center]
[center][color=#888888]Please use version control (Git) or backups.[/color][/center]

[color=#666666]Use next and previous to navigate.[/color]""",
		"highlight": "",
		"requires_action": false
	},
	{
		"title": "Store",
		"icon": "AssetLib",
		"tab_preview": true,
		"tab_text": "Store",
		"content": """The [b]Store[/b] tab lets you browse and search assets from multiple sources:

• [b]Godot AssetLib[/b] - Official Godot repository
• [b]Godot Store Beta[/b] - New Godot store
• [b]Godot Shaders[/b] - Community shaders
• [b]All Sources[/b] - Search everywhere at once

[b]Features:[/b]
• Filter by category (2D, 3D, Tools, etc.)
• Sort by date, name, or rating
• Click any card to see details and install""",
		"highlight": "tab_store",
		"requires_action": false
	},
	{
		"title": "Installed",
		"icon": "PackedScene",
		"tab_preview": true,
		"tab_text": "Installed",
		"content": """The [b]Installed[/b] tab shows all assets in your current project.

[b]Features:[/b]
• Enable/disable plugins with one click
• View asset details and source info
• Uninstall assets cleanly
• Open asset folder in file explorer
• Filter by category or source

[b]Linkup[/b] automatically matches your existing addons with their store entries, so you can track updates!""",
		"highlight": "tab_installed",
		"requires_action": false
	},
	{
		"title": "Favorites",
		"icon": "Heart",
		"tab_preview": true,
		"tab_text": "Favorites",
		"content": """The [b]Favorites[/b] tab stores your favorite assets.

[center][color=#ff6666][font_size=18]♥ Favorites are shared across ALL your projects! ♥[/font_size][/color][/center]

This means you can:
• Save assets you want to use later
• Build a personal library of go-to tools
• Access favorites from any Godot project

Click the [color=#ff6666]♥[/color] icon on any asset card to add it to favorites.""",
		"highlight": "tab_favorites",
		"requires_action": false
	},
	{
		"title": "Global Folder",
		"icon": "Folder",
		"tab_preview": true,
		"tab_text": "Global Folder",
		"content": """The [b]Global Folder[/b] tab accesses your personal .godotpackage library.

[center][color=#ffaa00][font_size=16]Store packages once, use in any project![/font_size][/color][/center]

[b]Features:[/b]
• Export addons as .godotpackage files
• Install packages to any project with one click
• Extract packages to custom locations
• Build your personal asset collection

[center][color=#888888]Set up your Global Folder below to get started.[/color][/center]""",
		"highlight": "tab_global_folder",
		"requires_action": true
	},
	{
		"title": "Import & Export",
		"icon": "Load",
		"tab_preview": false,
		"content": """[b]Import...[/b] button lets you add assets from:
• ZIP files
• .godotpackage files
• Local folders
• GitHub URLs (paste any repo link!)

[b]Export...[/b] button creates .godotpackage files:
• From your entire project
• From a specific folder
• Right-click in FileSystem dock for quick export

Exports include metadata, input actions and autoloads!""",
		"highlight": "import_export",
		"requires_action": false
	},
	{
		"title": "You're Ready!",
		"icon": "StatusSuccess",
		"tab_preview": false,
		"show_credits": true,
		"content": """[center][font_size=18][color=#88ff88]That's it! You're ready to use AssetPlus.[/color][/font_size][/center]

[b]Quick tips:[/b]
• Use search to find assets quickly
• Filter by category to narrow results
• Set up Global Folder for cross-project sharing
• Check Settings to customize behavior

[center][color=#888888]Click the [b]?[/b] button anytime to reopen this guide.[/color][/center]

[center][color=#666666]Please report any issues on the GitHub page of the project.[/color][/center]""",
		"highlight": "",
		"requires_action": false
	}
]

var _current_page: int = 0
var _title_label: Label
var _icon_rect: TextureRect
var _content_label: RichTextLabel
var _page_indicator: HBoxContainer
var _prev_btn: Button
var _next_btn: Button
var _page_dots: Array[Button] = []
var _highlight_panel: Panel
var _tab_preview_container: HBoxContainer

# Action buttons for Global Folder page
var _action_container: VBoxContainer
var _setup_btn: Button
var _skip_btn: Button
var _global_folder_label: Label
var _global_folder_set: bool = false

# Credits container for last page
var _credits_container: VBoxContainer

# First launch mode - hides Close button
var _is_first_launch: bool = false


func _init() -> void:
	title = "Welcome to AssetPlus"
	size = Vector2i(580, 560)
	ok_button_text = "Close"


## Set first launch mode - hides the Close button to encourage reading
func set_first_launch_mode(enabled: bool) -> void:
	_is_first_launch = enabled
	if enabled:
		get_ok_button().visible = false


func _ready() -> void:
	# Check if global folder is already configured
	var settings = SettingsDialog.get_settings()
	_global_folder_set = not settings.get("global_asset_folder", "").is_empty()

	_build_ui()
	_update_page()


## Open the dialog at a specific page based on current tab
func open_at_tab(tab_index: int) -> void:
	match tab_index:
		0:  # Tab.STORE
			_current_page = Page.STORE
		1:  # Tab.INSTALLED
			_current_page = Page.INSTALLED
		2:  # Tab.FAVORITES
			_current_page = Page.FAVORITES
		3:  # Tab.GLOBAL_FOLDER
			_current_page = Page.GLOBAL_FOLDER
		_:
			_current_page = Page.WELCOME

	if is_inside_tree():
		_update_page()


func _build_ui() -> void:
	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 12)
	add_child(main_vbox)

	# Header with icon and title
	var header_hbox = HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 15)
	main_vbox.add_child(header_hbox)

	_icon_rect = TextureRect.new()
	_icon_rect.custom_minimum_size = Vector2(48, 48)
	_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	header_hbox.add_child(_icon_rect)

	var title_vbox = VBoxContainer.new()
	header_hbox.add_child(title_vbox)

	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 24)
	title_vbox.add_child(_title_label)

	var page_label = Label.new()
	page_label.name = "PageLabel"
	page_label.add_theme_font_size_override("font_size", 12)
	page_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	title_vbox.add_child(page_label)

	# Spacer to push documentation button to the right
	var header_spacer = Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(header_spacer)

	# Online Documentation button (top right)
	var docs_btn = Button.new()
	docs_btn.text = "Online Documentation"
	docs_btn.tooltip_text = "Open online documentation in browser"
	docs_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var editor_theme = EditorInterface.get_editor_theme()
	if editor_theme:
		docs_btn.icon = editor_theme.get_icon("ExternalLink", "EditorIcons")
	docs_btn.pressed.connect(func(): OS.shell_open("https://moongdevstudio.github.io/AssetPlus/"))
	header_hbox.add_child(docs_btn)

	# Tab preview container (shows how the tab button looks)
	_tab_preview_container = HBoxContainer.new()
	_tab_preview_container.add_theme_constant_override("separation", 10)
	_tab_preview_container.alignment = BoxContainer.ALIGNMENT_CENTER
	_tab_preview_container.visible = false
	main_vbox.add_child(_tab_preview_container)

	# Separator
	main_vbox.add_child(HSeparator.new())

	# Content
	_content_label = RichTextLabel.new()
	_content_label.bbcode_enabled = true
	_content_label.fit_content = false
	_content_label.scroll_active = true
	_content_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_label.add_theme_font_size_override("normal_font_size", 14)
	_content_label.add_theme_font_size_override("bold_font_size", 14)
	main_vbox.add_child(_content_label)

	# Action container (for Global Folder page)
	_action_container = VBoxContainer.new()
	_action_container.add_theme_constant_override("separation", 10)
	_action_container.visible = false
	main_vbox.add_child(_action_container)

	# Global folder status label
	_global_folder_label = Label.new()
	_global_folder_label.add_theme_color_override("font_color", Color(0.5, 0.8, 0.5))
	_global_folder_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_action_container.add_child(_global_folder_label)

	# Action buttons
	var btn_hbox = HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 15)
	btn_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_action_container.add_child(btn_hbox)

	_setup_btn = Button.new()
	_setup_btn.text = "Choose Global Folder..."
	_setup_btn.custom_minimum_size.x = 180
	_setup_btn.pressed.connect(_on_setup_global_folder)
	btn_hbox.add_child(_setup_btn)

	_skip_btn = Button.new()
	_skip_btn.text = "Skip (I'll set it up later)"
	_skip_btn.custom_minimum_size.x = 180
	_skip_btn.pressed.connect(_on_skip_global_folder)
	btn_hbox.add_child(_skip_btn)

	# Credits container (for last page)
	_credits_container = VBoxContainer.new()
	_credits_container.add_theme_constant_override("separation", 12)
	_credits_container.visible = false
	main_vbox.add_child(_credits_container)

	# "Made with love" label
	var made_with_hbox = HBoxContainer.new()
	made_with_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	made_with_hbox.add_theme_constant_override("separation", 6)
	_credits_container.add_child(made_with_hbox)

	var made_label = Label.new()
	made_label.text = "Made with"
	made_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	made_with_hbox.add_child(made_label)

	var heart_label = Label.new()
	heart_label.text = "♥"
	heart_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.5))
	heart_label.add_theme_font_size_override("font_size", 18)
	made_with_hbox.add_child(heart_label)

	var by_label = Label.new()
	by_label.text = "by"
	by_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	made_with_hbox.add_child(by_label)

	# Credits buttons
	var credits_hbox = HBoxContainer.new()
	credits_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	credits_hbox.add_theme_constant_override("separation", 30)
	_credits_container.add_child(credits_hbox)

	var theme = EditorInterface.get_editor_theme()

	# GitHub button
	var github_btn = Button.new()
	github_btn.text = "MoongDevStudio"
	github_btn.tooltip_text = "Visit GitHub"
	if theme:
		github_btn.icon = theme.get_icon("GitHub", "EditorIcons") if theme.has_icon("GitHub", "EditorIcons") else theme.get_icon("ExternalLink", "EditorIcons")
	github_btn.pressed.connect(func(): OS.shell_open("https://github.com/moongdevstudio"))
	credits_hbox.add_child(github_btn)

	# YouTube button
	var youtube_btn = Button.new()
	youtube_btn.text = "YouTube"
	youtube_btn.tooltip_text = "Visit YouTube Channel"
	if theme:
		youtube_btn.icon = theme.get_icon("VideoStreamPlayer", "EditorIcons") if theme.has_icon("VideoStreamPlayer", "EditorIcons") else theme.get_icon("Play", "EditorIcons")
	youtube_btn.pressed.connect(func(): OS.shell_open("https://www.youtube.com/@onokoreal"))
	credits_hbox.add_child(youtube_btn)

	main_vbox.add_child(HSeparator.new())

	# Navigation bar
	var nav_hbox = HBoxContainer.new()
	nav_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(nav_hbox)

	_prev_btn = Button.new()
	_prev_btn.text = "< Previous"
	_prev_btn.custom_minimum_size.x = 100
	_prev_btn.pressed.connect(_on_prev_pressed)
	nav_hbox.add_child(_prev_btn)

	# Spacer
	var spacer1 = Control.new()
	spacer1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav_hbox.add_child(spacer1)

	# Page indicator dots
	_page_indicator = HBoxContainer.new()
	_page_indicator.add_theme_constant_override("separation", 8)
	nav_hbox.add_child(_page_indicator)

	for i in range(PAGES.size()):
		var dot = Button.new()
		dot.custom_minimum_size = Vector2(14, 14)
		dot.flat = true
		var page_idx = i
		dot.pressed.connect(func(): _go_to_page(page_idx))
		dot.tooltip_text = PAGES[i]["title"]
		_page_indicator.add_child(dot)
		_page_dots.append(dot)

	# Spacer
	var spacer2 = Control.new()
	spacer2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav_hbox.add_child(spacer2)

	_next_btn = Button.new()
	_next_btn.text = "Next >"
	_next_btn.custom_minimum_size.x = 100
	_next_btn.pressed.connect(_on_next_pressed)
	nav_hbox.add_child(_next_btn)


func _create_toolbar_preview() -> Control:
	# Create a preview that looks like the AssetPlus button in the top toolbar
	var container = PanelContainer.new()

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.15, 0.18)
	style.set_border_width_all(1)
	style.border_color = Color(0.3, 0.3, 0.35)
	style.set_corner_radius_all(3)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	container.add_theme_stylebox_override("panel", style)

	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	container.add_child(hbox)

	var icon = TextureRect.new()
	icon.custom_minimum_size = Vector2(16, 16)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var theme = EditorInterface.get_editor_theme()
	if theme:
		icon.texture = theme.get_icon("AssetLib", "EditorIcons")
	hbox.add_child(icon)

	var label = Label.new()
	label.text = "AssetPlus"
	label.add_theme_font_size_override("font_size", 13)
	hbox.add_child(label)

	return container


func _create_tab_preview(icon_name: String, tab_text: String) -> Control:
	# Create a preview that looks like the actual tab button
	var container = PanelContainer.new()

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.25, 0.35)
	style.set_border_width_all(1)
	style.border_color = Color(0.4, 0.5, 0.7)
	style.set_corner_radius_all(4)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	container.add_theme_stylebox_override("panel", style)

	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	container.add_child(hbox)

	var icon = TextureRect.new()
	icon.custom_minimum_size = Vector2(20, 20)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var theme = EditorInterface.get_editor_theme()
	if theme:
		icon.texture = theme.get_icon(icon_name, "EditorIcons")
	hbox.add_child(icon)

	var label = Label.new()
	label.text = tab_text
	label.add_theme_font_size_override("font_size", 14)
	hbox.add_child(label)

	return container


func _update_page() -> void:
	var page = PAGES[_current_page]

	# Update title
	_title_label.text = page["title"]

	# Update page number
	var page_label = get_node_or_null("VBoxContainer/HBoxContainer/VBoxContainer/PageLabel")
	if page_label == null:
		# Try to find it in the first VBox's first HBox
		for child in get_children():
			if child is VBoxContainer:
				for sub in child.get_children():
					if sub is HBoxContainer:
						for subsub in sub.get_children():
							if subsub is VBoxContainer:
								for label in subsub.get_children():
									if label is Label and label.name == "PageLabel":
										page_label = label
										break
	if page_label:
		page_label.text = "Page %d of %d" % [_current_page + 1, PAGES.size()]

	# Update icon - use AssetPlus icon for welcome page
	if _current_page == Page.WELCOME:
		_icon_rect.texture = load("res://addons/assetplus/icon.png")
	else:
		var theme = EditorInterface.get_editor_theme()
		if theme:
			_icon_rect.texture = theme.get_icon(page["icon"], "EditorIcons")

	# Update tab/toolbar preview
	var show_tab_preview = page.get("tab_preview", false)
	var show_toolbar_preview = page.get("toolbar_preview", false)
	_tab_preview_container.visible = show_tab_preview or show_toolbar_preview
	# Clear old preview
	for child in _tab_preview_container.get_children():
		child.queue_free()
	# Add new preview if needed
	if show_toolbar_preview:
		var preview = _create_toolbar_preview()
		_tab_preview_container.add_child(preview)
	elif show_tab_preview:
		var tab_text = page.get("tab_text", "")
		var preview = _create_tab_preview(page["icon"], tab_text)
		_tab_preview_container.add_child(preview)

	# Update content
	var content = page["content"]
	_content_label.text = content

	# Show/hide action container
	var requires_action = page.get("requires_action", false)
	_action_container.visible = requires_action

	# Update action buttons state
	if requires_action:
		_update_global_folder_ui()

	# Show/hide credits container
	var show_credits = page.get("show_credits", false)
	_credits_container.visible = show_credits

	# Update navigation buttons
	_prev_btn.disabled = _current_page == 0
	_next_btn.text = "Get Started!" if _current_page == PAGES.size() - 1 else "Next >"

	# Disable Next if action required and not completed
	if requires_action and not _global_folder_set:
		_next_btn.disabled = true
	else:
		_next_btn.disabled = false

	# Update page dots
	for i in range(_page_dots.size()):
		var dot = _page_dots[i]
		var is_current = i == _current_page

		var style = StyleBoxFlat.new()
		style.set_corner_radius_all(7)

		if is_current:
			style.bg_color = Color(0.4, 0.6, 1.0)
			style.set_border_width_all(2)
			style.border_color = Color(0.6, 0.8, 1.0)
		else:
			style.bg_color = Color(0.3, 0.3, 0.35)

		dot.add_theme_stylebox_override("normal", style)
		dot.add_theme_stylebox_override("hover", style)
		dot.add_theme_stylebox_override("pressed", style)


func _update_global_folder_ui() -> void:
	var settings = SettingsDialog.get_settings()
	var global_folder = settings.get("global_asset_folder", "")

	if not global_folder.is_empty():
		_global_folder_set = true
		_global_folder_label.text = "✓ Global Folder: %s" % global_folder
		_global_folder_label.add_theme_color_override("font_color", Color(0.5, 0.9, 0.5))
		_setup_btn.text = "Change Global Folder..."
		_skip_btn.visible = false
		_next_btn.disabled = false
	else:
		_global_folder_set = false
		_global_folder_label.text = "No global folder configured yet"
		_global_folder_label.add_theme_color_override("font_color", Color(0.9, 0.7, 0.4))
		_setup_btn.text = "Choose Global Folder..."
		_skip_btn.visible = true
		_next_btn.disabled = true


func _on_setup_global_folder() -> void:
	var dialog = FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.title = "Select Global Asset Folder"

	var settings = SettingsDialog.get_settings()
	var current_folder = settings.get("global_asset_folder", "")
	if not current_folder.is_empty():
		dialog.current_dir = current_folder

	dialog.dir_selected.connect(func(dir: String):
		dialog.queue_free()
		_save_global_folder(dir)
	)

	dialog.canceled.connect(func():
		dialog.queue_free()
	)

	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered(Vector2i(600, 400))


func _save_global_folder(folder_path: String) -> void:
	# Load current settings
	var settings = SettingsDialog.get_settings()
	settings["global_asset_folder"] = folder_path

	# Save settings
	var file = FileAccess.open("user://asset_store_settings.cfg", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(settings, "\t"))
		file.close()
		SettingsDialog.debug_print("Global folder set to: %s" % folder_path)

	# Update UI
	_global_folder_set = true
	_update_global_folder_ui()
	_update_page()


func _on_skip_global_folder() -> void:
	_global_folder_set = true  # Mark as "handled" even though not set
	_on_next_pressed()  # Go to next page


func _on_prev_pressed() -> void:
	if _current_page > 0:
		_current_page -= 1
		_update_page()


func _on_next_pressed() -> void:
	if _current_page < PAGES.size() - 1:
		_current_page += 1
		_update_page()
	else:
		# Last page - close dialog
		hide()


func _go_to_page(page: int) -> void:
	if page >= 0 and page < PAGES.size():
		_current_page = page
		_update_page()
