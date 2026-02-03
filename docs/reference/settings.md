# Settings

Access settings by clicking the **gear icon** in AssetPlus.

## Export Settings

### Default Export Path

Set a default folder for exporting `.godotpackage` files. Leave empty to always choose manually.

### Global Asset Folder

Path to your personal asset library. Packages saved here appear in the **Global** tab across all projects.

!!! tip
    Use a cloud-synced folder (Dropbox, OneDrive, etc.) to backup your packages automatically.

## Debug Settings

### Debug Output

Control debug messages in the Output panel:

| Level | Description |
|-------|-------------|
| Off | No debug messages |
| Minimal | Important messages only |
| Full | All debug information |

## Available Stores

Enable or disable asset sources:

- **Godot Asset Library** - Official Godot repository
- **Godot Store Beta** - New Godot store
- **Godot Shaders** - Community shaders with direct download

Disabled stores won't appear in the source dropdown.

## About

### Version

Shows the current AssetPlus version.

### Check for Updates

Manually check if a newer version is available.

### Check for updates at startup

When enabled, AssetPlus checks for updates when the editor opens.

## Config Location

Settings are shared between all projects and stored in:

| OS | Path |
|----|------|
| Windows | `%APPDATA%/GodotAssetPlus/settings.cfg` |
| Linux | `~/.config/GodotAssetPlus/settings.cfg` |
| macOS | `~/Library/Application Support/GodotAssetPlus/settings.cfg` |

Click **Open Config Folder** to access this location directly.
