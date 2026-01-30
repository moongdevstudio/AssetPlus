# Installed Addons

The **Installed** tab shows all addons currently in your project, helping you manage what's installed.

![Installed Addons](../images/installedscreenshot.png)

## Addon Detection

AssetPlus automatically scans your project's `addons/` folder and detects:

- Addon name (from `plugin.cfg`)
- Version
- Author
- Description

## Source Matching

AssetPlus tries to match your installed addons with their online sources. When a match is found, you can:

- See if updates are available
- View the original asset page
- Compare versions

## Update Detection

AssetPlus automatically checks for updates to your installed addons:

- **Update Badge** - Cards show an orange "Update" badge when a new version is available
- **Detail View** - The update button shows the new version number
- **One-Click Update** - Click the Update button to download and install the latest version

Updates are checked for addons installed from:

- Godot AssetLib
- Godot Store Beta
- Global Folder packages (if they have an original source)

## Addon Information

Each installed addon card shows:

- Addon name
- Current version
- Author
- Source (if matched)

Click on an addon to see more details.

## Managing Addons

Click on any addon to open its detail view with options:

- **Open in FileSystem** - Navigate to the addon folder
- **View Online** - Open the asset's page (if source matched)
- **Uninstall** - Remove the addon from your project

!!! warning "Uninstall"
    Uninstalling an addon deletes its entire folder. Make sure you don't have any modified files you want to keep.

## GDExtension Support

Addons with native libraries (GDExtensions) require special handling:

- **Installation** - GDExtension files are detected and installed normally. Godot may need a restart to load them.
- **Uninstallation** - Native libraries (.dll/.so) are locked while Godot runs. AssetPlus uses **deferred deletion**:
  1. The `.gdextension` file is emptied (prevents loading on restart)
  2. On next Godot restart, files are fully deleted

This prevents crashes when uninstalling addons with native code.

## Refreshing

The addon list refreshes automatically when:

- The plugin is enabled
- Files change in the `addons/` folder
- You install or uninstall an addon

You can also manually refresh by clicking the refresh button.

## Linkup Scan

AssetPlus performs a "linkup scan" on startup to match installed addons with online sources. This runs in the background and doesn't affect editor performance.
