# .godotpackage Format

The `.godotpackage` format is a portable way to share Godot assets and addons.

## Structure

A `.godotpackage` file is a ZIP archive containing:

```
package.godotpackage
├── manifest.json    # Package metadata
├── icon.png         # Optional 256x256 icon
└── files/           # Package contents
    └── ...
```

## manifest.json

The manifest contains all package metadata:

```json
{
  "name": "My Addon",
  "version": "1.0.0",
  "author": "Your Name",
  "description": "What this package does",
  "license": "MIT",
  "godot_version": "4.3",
  "created_at": "2024-01-15T10:30:00Z",
  "files_checksum": "sha256:abc123...",
  "input_actions": {},
  "autoloads": {}
}
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| name | string | Package display name |
| version | string | Semantic version |
| author | string | Creator's name |
| description | string | Package description |
| license | string | License type |
| godot_version | string | Minimum Godot version |
| created_at | string | ISO 8601 timestamp |
| files_checksum | string | SHA256 hash of files |
| input_actions | object | Input action mappings (optional) |
| autoloads | object | Autoload definitions (optional) |

## Icon

The package icon should be:

- Format: PNG
- Size: 256x256 pixels
- Named: `icon.png`

If no icon is provided, a default icon is used.

## Files Directory

The `files/` directory contains all package contents, preserving the original folder structure.

## Input Actions

If the package includes input actions, they're stored in the manifest:

```json
{
  "input_actions": {
    "my_action": {
      "deadzone": 0.5,
      "events": [
        { "type": "key", "keycode": 32 }
      ]
    }
  }
}
```

## Autoloads

Autoload definitions are stored as:

```json
{
  "autoloads": {
    "GameManager": "res://addons/my_addon/game_manager.gd"
  }
}
```

## Creating Packages

Use AssetPlus to create packages:

1. Right-click a folder in FileSystem
2. Select **Export as .godotpackage**
3. Fill in metadata
4. Choose an icon (optional)
5. Export

## Editing Packages

You can edit package metadata after creation:

1. Open the **Global** tab
2. Click on a package to open details
3. Click **Edit Info**

### Editable Fields

| Field | Description |
|-------|-------------|
| Name | Display name of the package |
| Author | Creator's name |
| Version | Package version |
| Category | Package type (Plugin, Asset, Template) |
| License | License type |
| Description | What the package does |
| Icon | Package icon (128x128, PNG/JPG) |

Changes are saved directly to the `.godotpackage` file.

## Installing Packages

1. Open the **Global** tab
2. Select a package
3. Click **Install**

The package contents are extracted to your project, and input actions/autoloads are configured automatically.

## Extracting Packages

To extract a package to a folder (without installing):

1. Click on a package in the Global tab
2. Click **Extract to Folder**
3. Choose destination

## Checksum Verification

When installing, AssetPlus verifies the `files_checksum` to ensure package integrity. If verification fails, installation is aborted.
