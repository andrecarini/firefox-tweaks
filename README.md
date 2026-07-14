# Firefox merged-titlebar and toolbar tweaks

Collapses Firefox's tab bar into the titlebar so it and the nav-bar share one row, and adds two toolbar buttons: a Performance button that opens about:performance (Task Manager), and a Layout menu with per-window toggles for the tab bar and the sidebar header. It also blanks the New Tab / about:home page. It's plain CSS plus one small AutoConfig script, installed by a Perl script.

Known to work on Firefox 152, Windows and Linux. The merged row assumes Firefox's separate title bar is off.

## What it does

- Merges the tab strip into the titlebar row to reclaim vertical space, keeping the window min/max/close buttons and a drag strip on the right.
- Performance button opens about:performance. If a Task Manager tab (about:performance or about:processes) is already open in that window, it selects it instead of opening a second one.
- Layout menu with checkbox toggles that show or hide the tab bar and the sidebar header, per window. New windows start with both hidden.
- Blanks about:home and about:newtab (hides the whole home app and its scrollbars).

## Install

Clone, then run `perl install.pl` (Perl ships with Git for Windows).

The installer detects your Firefox install directory and active profile, prints a plan, asks you to confirm, and backs up any file it would overwrite (as `<file>.bak-<timestamp>`). Profile files install without elevation; it only asks for admin/root for the program-directory files, and only when that directory isn't writable. It also sets `toolkit.legacyUserProfileCustomizations.stylesheets = true` in the profile's user.js. Fully restart Firefox afterward.

Useful flags: `--dry-run` (show the plan, change nothing), `--no-css` (skip the profile CSS), `--no-buttons` (skip the AutoConfig files), `--profile NAME|PATH` (pick a profile), `--yes` (don't prompt), `--help`. Also `--source`, `--install-dir`, and `--profiles-ini` to override auto-detected paths.

## Files

- `firefox.cfg`: the AutoConfig script that adds the Performance and Layout buttons. Installs to the Firefox program dir.
- `autoconfig.js`: points Firefox at firefox.cfg. Installs to `defaults/pref/` in the program dir.
- `userChrome.css`: merges the titlebar and gates the tab-bar / sidebar-header hiding on the Layout toggles. Installs to the profile's `chrome/`.
- `userContent.css`: blanks about:home / about:newtab. Installs to the profile's `chrome/`.
- `install.pl`: the installer.

## Security

`firefox.cfg` runs with full browser privileges, because `autoconfig.js` sets `general.config.sandbox_enabled = false`. That's what lets it add the buttons, but it also means the file can do anything Firefox can. Read it before installing, and only run AutoConfig code you trust.

## License

MIT.
