// Goes in Firefox's install dir under: defaults/pref/autoconfig.js
// Tells Firefox to run firefox.cfg at startup with full privileges.
pref("general.config.filename", "firefox.cfg");
pref("general.config.obscure_value", 0);      // read firefox.cfg as plain text (no byte-shift)
pref("general.config.sandbox_enabled", false); // required so firefox.cfg gets chrome privileges
