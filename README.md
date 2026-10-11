# Firefox merged-titlebar and toolbar tweaks

Collapses Firefox's tab bar into the titlebar so it and the nav-bar share one row, and adds two toolbar buttons: a Performance button that opens about:performance (Task Manager), and a Layout menu with per-window toggles for the tab bar, the sidebar header and the search dropdown styling. It also blanks the New Tab / about:home page. It's plain CSS plus one small AutoConfig script, installed by a Perl script.

Known to work on Firefox 152, Windows and Linux. The merged row assumes Firefox's separate title bar is off.

## What it does

- Merges the tab strip into the titlebar row to reclaim vertical space, keeping the window min/max/close buttons and a drag strip on the right.
- Performance button opens about:performance. If a Task Manager tab (about:performance or about:processes) is already open in that window, it selects it instead of opening a second one.
- Layout menu with per-window checkbox toggles: show the tab bar, show the sidebar header, and switch the search dropdown back to Firefox's default look. New windows start with all three unchecked (tab bar and header hidden, dropdown restyled).
- Flattens the sidebar: no padding around the panel, no rounded corner, no visible splitter gap.
- Restyles the search box's suggestions dropdown: square rows, tighter spacing, thin scrollbar.
- Slims every scrollbar to 12px (thin ones to 6px) and removes the arrow buttons at both ends, via prefs in the profile's user.js.
- Blanks about:home and about:newtab (hides the whole home app and its scrollbars).

## Install

Clone, then run `perl install.pl` (Perl ships with Git for Windows).

The installer detects your Firefox install directory and active profile, prints a plan, asks you to confirm, and backs up any file it would overwrite (as `<file>.bak-<timestamp>`). Profile files install without elevation; it only asks for admin/root for the program-directory files, and only when that directory isn't writable. It also adds its prefs to the profile's user.js: `toolkit.legacyUserProfileCustomizations.stylesheets = true` plus the scrollbar prefs (`widget.non-native-theme.win.scrollbar.use-system-size = false`, `widget.non-native-theme.scrollbar.size.override = 12`, `ui.scrollArrowStyle = 0`) and `browser.nova.enabled = false`. A pref already set in user.js is left as is. Since user.js is reapplied at every startup, change these values in user.js rather than about:config. Fully restart Firefox afterward.

Useful flags: `--dry-run` (show the plan, change nothing), `--no-css` (skip the profile CSS), `--no-buttons` (skip the AutoConfig files), `--profile NAME|PATH` (pick a profile), `--yes` (don't prompt), `--help`. Also `--source`, `--install-dir`, and `--profiles-ini` to override auto-detected paths.

## Files

- `firefox.cfg`: the AutoConfig script that adds the Performance and Layout buttons. Installs to the Firefox program dir.
- `autoconfig.js`: points Firefox at firefox.cfg. Installs to `defaults/pref/` in the program dir.
- `userChrome.css`: merges the titlebar, gates the tab-bar / sidebar-header hiding on the Layout toggles, and holds the sidebar and search-dropdown styling. Installs to the profile's `chrome/`.
- `userContent.css`: blanks about:home / about:newtab. Installs to the profile's `chrome/`.
- `install.pl`: the installer.

## Security

`firefox.cfg` runs with full browser privileges, because `autoconfig.js` sets `general.config.sandbox_enabled = false`. That's what lets it add the buttons, but it also means the file can do anything Firefox can. Read it before installing, and only run AutoConfig code you trust.

## Also in this repo

`search-icons/` is a separate, self-contained set of Perl scripts for changing the icon on a search engine added from an OpenSearch descriptor, which Firefox has no UI for, and for stopping Firefox refreshing that icon back to the original later. It shares nothing with the files above beyond being Firefox and being Perl. See `search-icons/README.md`.

## License

MIT.
