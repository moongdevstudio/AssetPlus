<p align="center">
  <img src="screens/banner.png" alt="AssetPlus">
</p>

<p align="center">
  <a href="https://godotengine.org/"><img src="https://img.shields.io/badge/Godot-4.3%2B-blue?logo=godot-engine&logoColor=white" alt="Godot 4.3+"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT"></a>
  <a href="https://github.com/moongdevstudio/AssetPlus/releases"><img src="https://img.shields.io/github/v/release/moongdevstudio/AssetPlus" alt="GitHub release"></a>
  <a href="https://moongdevstudio.github.io/AssetPlus/"><img src="https://img.shields.io/badge/docs-online-blue" alt="Documentation"></a>
</p>

<p align="center">A unified asset browser for Godot 4.x that brings together multiple asset sources into one powerful interface.</p>

<p align="center">
  <img src="screens/newstoreallpage.png" alt="AssetPlus Home" width="700">
</p>
<p align="center"><a href="https://www.youtube.com/watch?v=ioUR2K8xtNE">▶️ Watch the demo video on YouTube</a></p>

## Features

| Feature | Description |
|---------|-------------|
| **Home Page** | Modern landing page with latest & most liked assets by category from all stores |
| **Multi-Source Browser** | Search Godot AssetLib, Godot Store Beta & Godot Shaders in one place |
| **Likes System** | Like assets and discover what's popular - synced to cloud across all users |
| **One-Click Install** | Install addons, templates, or full demo projects with selective import |
| **GDExtension Support** | Safe installation/uninstallation of addons with native libraries |
| **Image Gallery** | Full-screen image viewer for asset screenshots |
| **Installed Tracking** | See all addons in your project with source matching |
| **Addon Updates** | Get notified when updates are available for your installed addons |
| **Global Library** | Build a personal collection of reusable assets as `.godotpackage` files |
| **Favorites Sync** | Save favorites, synced across all projects |
| **Auto-Update** | AssetPlus updates itself automatically |

### Home Page
The new Home page displays curated content from all stores in a modern carousel layout:
- Latest assets by category
- Most liked assets (sort by "Most Liked")
- Quick access to each store's categories

### Browse Multiple Sources
- **Godot AssetLib** - Official Godot Asset Library
- **Godot Store Beta** - New Godot store (store-beta.godotengine.org)
- **Godot Shaders** - Community shaders from godotshaders.com with direct download support

### Likes System
Like your favorite assets and see what's popular in the community:
- Likes are synced to a cloud server shared by all AssetPlus users
- Sort by "Most Liked" to discover popular assets
- Your liked assets are remembered across projects

### Global Asset Library
Build your personal asset collection:
- Export any folder or addon as a `.godotpackage` file stored locally
- Store packages in a central **Global Folder**
- Install your packages into any project
- Right-click export from FileSystem dock

### Smart Installation
Similar to Unity's package import, you get full control when installing templates or demo projects:
- Choose which files/folders to import with a file tree view
- Filter by file type (Scripts, Scenes, Images, etc.)
- Optionally import input actions and autoloads
- Preview what will be added to your project

<img src="screens/installfiletreescreenshot.png" width="500">

### Addon Updates
Keep your installed addons up to date:
- Automatic update detection for addons from AssetLib and Godot Store Beta
- Update badges on cards and in detail view
- One-click update installation

### Auto-Update
AssetPlus checks for its own updates at startup and notifies you when a new version is available. Install updates with one click, or disable auto-update in Settings.

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

- [Documentation](https://moongdevstudio.github.io/AssetPlus/)
- [Releases](https://github.com/moongdevstudio/AssetPlus/releases)
- [Report Issues](https://github.com/moongdevstudio/AssetPlus/issues)

---
Developed by MoongDevStudio
