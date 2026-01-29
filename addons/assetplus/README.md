# AssetPlus

A unified asset browser for Godot 4.x that brings together multiple asset sources into one powerful interface.

## Features

### Browse Multiple Sources
- **Godot AssetLib** - Official Godot Asset Library
- **Godot Store Beta** - New Godot store (store-beta.godotengine.org)
- **Godot Shaders** - Community shaders from godotshaders.com
- Search across all sources at once

### Install & Manage
- One-click installation from any source
- Track all installed addons in the **Installed** tab
- Auto-detect installed addons and match with online sources
- Uninstall addons cleanly
- Update notifications for installed assets

### Global Asset Library
Build your personal asset collection:
- Export any folder as a `.godotpackage` file
- Store packages in a central **Global Folder**
- Install your packages into any project
- Right-click export from FileSystem dock
- Edit package metadata and icons

### Favorites
- Save favorite assets with one click
- Shared across all your Godot projects

### Package Export
Export project folders with full metadata:
- Name, description, author, version, license
- Custom icon (embedded in package)
- Input actions & autoloads included
- Checksums for integrity

## Installation

1. Copy `addons/assetplus` to your project's `addons` folder
2. Enable in Project Settings > Plugins > AssetPlus
3. Access from the top toolbar (next to 2D, 3D, Script)

## Quick Start

1. **Browse**: Search assets in the Store tab
2. **Install**: Click any asset, then Install
3. **Export**: Right-click a folder > "Export as .godotpackage"
4. **Global Folder**: Set up in Settings to build your personal library

## .godotpackage Format

ZIP archive containing:
```
package.godotpackage
├── manifest.json    # Metadata
├── icon.png         # Optional icon
└── files/           # Contents
```

## Requirements

- Godot 4.3+
- Editor plugin only

## License

MIT License

## Credits

Developed by MoongDevStudio
