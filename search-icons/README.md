# Firefox search engine icons

Changes the icon on a search engine you added from a site's OpenSearch descriptor (Mycroft Project and the like), which Firefox gives you no UI for. Also stops Firefox silently replacing that icon later. Plain Perl, no modules outside core, nothing to install.

Unrelated to the titlebar and toolbar tweaks in the parent directory; it just lives in the same repo because it is the same browser and the same Perl toolbox.

## Why this is needed

Firefox keeps OpenSearch engines in `<profile>/search.json.mozlz4`, with each engine's icon inline as a base64 data URI under `_iconMapObj`, keyed by pixel size. Nothing in `about:preferences#search` or `about:config` exposes it, so editing that file is the only way.

The file is Mozilla's mozlz4 container: the magic `mozLz40\0`, a little-endian uint32 of the uncompressed size, then a raw LZ4 block with no frame header. `Compress::LZ4` is not in core Perl and is usually not installed, so `mozlz4.pl` implements both directions itself.

## Use it

Close Firefox first. It holds the engine list in memory and rewrites `search.json.mozlz4` on shutdown, so anything you write while it is running gets discarded.

List what you have, and see which engines Firefox can still overwrite:

    perl search-engine-icon.pl --list

Set an icon and stop that engine auto-updating, in one go:

    perl search-engine-icon.pl --engine "Google Maps" --icon maps.png --no-update

Check the plan without touching anything:

    perl search-engine-icon.pl --engine "grep.app" --icon g.png --dry-run

Every write is backed up first as `search.json.mozlz4.bak-<timestamp>` in the profile. To undo, copy that back with Firefox closed.

## Getting the icon in the first place

Read the site's own `<link rel="icon">` rather than assuming `/favicon.ico`, because the declared icon is often somewhere else entirely. Google Shopping's is on `gstatic.com`, and Google Maps points at `web_maps_icon_32dp.ico`.

Check what you actually downloaded with `imginfo.pl`, since plenty of sites serve a PNG under a `.ico` name. Both `developer.mozilla.org/favicon.ico` and Google's `web_maps_icon_32dp.ico` are PNGs. Firefox keys these icons by pixel size, so the real dimensions are what matter.

If the site blocks scripted requests, pull the icon out of Firefox's own cache with `favicon-cache.pl`. grep.app sits behind a Vercel JS challenge that answers curl with a 429 HTML page, but the icon was already in `favicons.sqlite` from having visited the site.

To look at an ICO, convert it with `ico2png.pl`.

## Auto-update, and why `--no-update` exists

An OpenSearch engine carries a `rel="self"` URL pointing back at the descriptor it was installed from. Once `_updateURL` is null, that rel is the only thing Firefox can refresh the engine from, so removing it ends auto-update and your icon stays put. `--no-update` removes the rel and clears `_updateURL`, and refuses to proceed if that would leave the engine with no search URL.

This matters for Mycroft engines in particular, because the descriptors on mycroftproject.com still serve whatever artwork they shipped with, which for grep.app and Google Maps is several redesigns out of date.

Engines with no `rel="self"` never auto-updated to begin with. MDN Web Docs is one, which is also the proof that an engine without it is a perfectly normal shape rather than something these scripts invented.

## What cannot be changed here

Firefox's built-in engines (Google, Bing, DuckDuckGo, Wikipedia, Amazon and so on) carry `_isConfigEngine` and take their icons from Firefox's remote search configuration, not from this file. `--list` marks them `built-in` and `--engine` refuses them.

## Files

- `search-engine-icon.pl`: the tool. Lists engines, replaces icons, disables auto-update. Finds the profile from `profiles.ini`, refuses to run while Firefox is open, backs up before writing, and verifies the container round-trips and still parses as JSON before replacing the live file.
- `mozlz4.pl`: standalone mozlz4 decompress and compress, for poking at `search.json.mozlz4` or any other `.mozlz4` / `.jsonlz4` file by hand.
- `imginfo.pl`: reports the real format and pixel size of an image, sniffing the bytes rather than trusting the extension.
- `ico2png.pl`: extracts the largest image from an ICO and writes it as a PNG so you can actually see it.
- `favicon-cache.pl`: recovers icons Firefox already downloaded, by scanning `favicons.sqlite` for a URL matching a pattern and taking the image blob next to it. No sqlite3 dependency, but it is a heuristic scan rather than a real query, so check the output.

## Notes

`search-engine-icon.pl` compresses by emitting a valid all-literal LZ4 block instead of doing a real encode. The file comes out roughly twice the size Firefox would write, which costs nothing in practice because Firefox re-compresses properly on its next save. Do not be alarmed if the file shrinks by half after the next clean shutdown.

Because Firefox rewrites the file on every shutdown, any edit has to be based on the current file. Do not decompress a copy, sit on it across a browser session, and write it back.

The `profiles.ini` parsing is duplicated from `install.pl` rather than shared. Two copies of forty lines was judged the smaller problem than refactoring a working installer for a script that is otherwise unrelated to it.
