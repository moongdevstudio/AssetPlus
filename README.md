# AssetPlus

[![Godot 4.3+](https://img.shields.io/badge/Godot-4.3%2B-blue?logo=godot-engine&logoColor=white)](https://godotengine.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/moongdevstudio/AssetPlus)](https://github.com/moongdevstudio/AssetPlus/releases)

A unified asset browser for Godot 4.x that brings together multiple asset sources into one powerful interface.

## Features

| Feature | Description |
|---------|-------------|
| **Multi-Source Browser** | Search Godot AssetLib, Godot Store Beta & Godot Shaders in one place |
| **One-Click Install** | Install any asset directly into your project |
| **Installed Tracking** | See all addons in your project with source matching |
| **Global Library** | Build a personal collection of reusable assets as `.godotpackage` files |
| **Favorites Sync** | Save favorites, synced across all projects |
| **Auto-Update** | Get notified of new versions automatically |

### Browse Multiple Sources
- **Godot AssetLib** - Official Godot Asset Library
- **Godot Store Beta** - New Godot store (store-beta.godotengine.org)
- **Godot Shaders** - Community shaders from godotshaders.com (browse only, redirects to site)

### Global Asset Library
Build your personal asset collection:
- Export any folder or addon as a `.godotpackage` file stored locally
- Store packages in a central **Global Folder**
- Install your packages into any project
- Right-click export from FileSystem dock

### Auto-Update
AssetPlus checks for updates at startup and notifies you when a new version is available. Install updates with one click, or disable auto-update in Settings.

## Installation

1. Download the [latest release](https://github.com/moongdevstudio/AssetPlus/releases)
2. Copy `addons/assetplus` to your project's `addons` folder
3. Enable in **Project Settings > Plugins > AssetPlus**
4. Access from the top toolbar (next to 2D, 3D, Script)

## Quick Start

1. **Browse** - Search assets in the Store tab
2. **Install** - Click any asset, then Install
3. **Export** - Right-click a folder > "Export as .godotpackage"
4. **Settings** - Configure your Global Folder for personal asset library

## .godotpackage Format

A portable package format for sharing Godot assets:
```
package.godotpackage
├── manifest.json    # Metadata (name, version, author, etc.)
├── icon.png         # Optional icon
└── files/           # Package contents
```

## Requirements

- Godot 4.3+
- Editor plugin only (not included in exports)

## License

MIT License - See [LICENSE](LICENSE)

## Links

- [Releases](https://github.com/moongdevstudio/AssetPlus/releases)
- [Report Issues](https://github.com/moongdevstudio/AssetPlus/issues)

---
Developed by MoongDevStudio
