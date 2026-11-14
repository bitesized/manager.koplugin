# Plugin manager

A KOReader plugin that links your plugins to GitHub repositories and installs or updates them from their releases.

## Installation

Download `manager.koplugin-<version>.zip` from [Releases](https://github.com/bitesized/manager.koplugin/releases) and unzip it into KOReader's `plugins` folder. The zip already contains a correctly named `manager.koplugin/` directory. Then restart KOReader.

To keep the manager itself up to date, tap **Plugin manager** in its own list and link it to `bitesized/manager.koplugin`.

## Usage

Open **Tools → Plugin manager**.

- **Check for updates**: checks every linked plugin and offers to update the ones that are behind.
- **Install plugin from GitHub…**: enter a GitHub username and a repository name, for example `bitesized` and `annasarchive.koplugin`. If no repository has exactly that name, the name with `.koplugin` added is tried as well. You can also paste `owner/repo` or a github.com link. The plugin is installed next to this one and linked to that repository.
- **Link plugins from a GitHub account…**: links every unlinked plugin to `<account>/<plugin>.koplugin`, where such a repository exists.
- **GitHub token**: optional. Private repositories need one. A token also raises GitHub's limit of 60 requests an hour.

Tap a plugin in the list for more options:

- check for or install its update;
- pick another release;
- read the release notes;
- turn on pre-releases;
- choose which file from a release to download;
- change the repository it is linked to, or unlink it.

KOReader asks to restart after every install or update. The new version loads when it restarts.

## Releases

A release can attach a `.zip` that contains the `name.koplugin` directory, or just the plugin's files. If a release has no `.zip`, GitHub's source archive of the tag is used. When a release has several `.zip` files, the one with the plugin's name in it is used. A plugin's **Release file** pattern overrides that choice.

Settings are stored in `settings/pluginmanager.lua`.
