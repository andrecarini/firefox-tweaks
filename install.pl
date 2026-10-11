#!/usr/bin/perl
#
# install.pl — install/update the Firefox customization files.
#
#   Install-dir (needs admin/root):
#     firefox.cfg    -> <firefox install dir>/firefox.cfg
#     autoconfig.js  -> <firefox install dir>/defaults/pref/autoconfig.js
#   Profile (no admin):
#     userChrome.css  -> <profile>/chrome/userChrome.css
#     userContent.css -> <profile>/chrome/userContent.css
#   Also ensures the profile's user.js sets the prefs in @PREFS (custom
#     stylesheets enabled, scrollbar width, no scrollbar arrow buttons).
#
# Cross-platform: Windows (native or Git-for-Windows perl) and Linux.
# Finds the install dir and active profile, asks for elevation only when the
# install dir isn't writable, and backs up every file it would overwrite.
#
# Usage:
#   perl install.pl [options]
#     --source DIR        Where the source files live (default: this script's dir)
#     --install-dir DIR   Override the Firefox install directory
#     --profile NAME|PATH Override which profile to use
#     --profiles-ini PATH Override the profiles.ini location
#     --no-buttons        Skip firefox.cfg / autoconfig.js (install-dir files)
#     --no-css            Skip userChrome.css / userContent.css (profile files)
#     --dry-run           Show what would happen, change nothing
#     --yes               Don't prompt for confirmation
#     --help              This help
#
use strict;
use warnings;
use utf8;   # this source file is UTF-8 (em-dashes etc. in output strings)
use Getopt::Long qw(GetOptions);
use File::Basename qw(dirname basename);
use Cwd qw(abs_path);
use MIME::Base64 qw(encode_base64 decode_base64);
use Encode qw(encode decode);
use POSIX qw(strftime);

# Git-for-Windows perl spawns native Windows binaries below; stop MSYS2 from
# mangling ':'-containing args (drive letters).
BEGIN { $ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|msys|cygwin)$/ }

my $IS_WIN = ($^O =~ /^(MSWin32|msys|cygwin)$/) ? 1 : 0;
my $STAMP  = strftime('%Y%m%d-%H%M%S', localtime);

# Print Unicode paths (e.g. C:\Users\Andre\... with accents) without warnings.
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

# Absolute path to Windows PowerShell, so a hijacked PATH can't substitute a
# malicious `powershell` (which would otherwise be the binary UAC elevates).
my $PWSH = 'powershell';
if ($IS_WIN && ($ENV{SystemRoot} || $ENV{WINDIR})) {
    (my $sr = ($ENV{SystemRoot} // $ENV{WINDIR})) =~ s{\\}{/}g;
    $PWSH = "$sr/System32/WindowsPowerShell/v1.0/powershell.exe";
}

# THE list of prefs ensured in the profile's user.js — to add or remove one,
# edit only this table. value = the JS literal written into user_pref().
# Missing prefs are appended; a pref already set in user.js is left alone (with
# a warning if its value differs), so hand edits there are never overwritten.
my @PREFS = (
    { key => 'toolkit.legacyUserProfileCustomizations.stylesheets', value => 'true',
      why => 'enables userChrome.css / userContent.css' },
    { key => 'widget.non-native-theme.win.scrollbar.use-system-size', value => 'false',
      why => 'stop the Windows system size from overriding the size below' },
    { key => 'widget.non-native-theme.scrollbar.size.override', value => '12',
      why => 'scrollbar width in px (scrollbar-width: thin is always half of this)' },
    { key => 'ui.scrollArrowStyle', value => '0',
      why => 'no arrow buttons at the ends of scrollbars' },
    { key => 'browser.nova.enabled', value => 'false',
      why => 'keep the "Nova" theme off (pill shapes, heavy padding/radius/contrast)' },
);

my %opt;
GetOptions(\%opt,
    'source=s', 'install-dir=s', 'profile=s', 'profiles-ini=s',
    'no-buttons', 'no-css', 'dry-run', 'yes', 'help',
) or usage(2);
usage(0) if $opt{help};

my $SRC = $opt{source} // dirname(abs_path($0));
info("Platform : " . ($IS_WIN ? "Windows ($^O)" : $^O));
info("Source   : $SRC");

# ---- what gets installed, and where ----------------------------------------
# THE list of files to copy — to add or remove a file, edit only this table.
#   name = source file (looked for under --source / this script's directory)
#   dest = destination path, relative to the base for its kind
#   kind = 'install' -> Firefox program dir (needs admin) | 'profile' -> profile dir
my @MANIFEST = (
    { name => 'firefox.cfg',     dest => 'firefox.cfg',                 kind => 'install' },
    { name => 'autoconfig.js',   dest => 'defaults/pref/autoconfig.js', kind => 'install' },
    { name => 'userChrome.css',  dest => 'chrome/userChrome.css',       kind => 'profile' },
    { name => 'userContent.css', dest => 'chrome/userContent.css',      kind => 'profile' },
);
sub want_kind {
    my ($k) = @_;
    return !($k eq 'install' && $opt{'no-buttons'})
        && !($k eq 'profile' && $opt{'no-css'});
}
# Build copy operations for one kind against a base directory, from @MANIFEST.
sub build_ops {
    my ($base, $kind) = @_;
    my @ops;
    for my $m (@MANIFEST) {
        next unless $m->{kind} eq $kind && want_kind($kind);
        my $src    = $IS_WIN ? to_win_path("$SRC/$m->{name}") : "$SRC/$m->{name}";
        my $dst    = $IS_WIN ? win_join($base, split m{/}, $m->{dest}) : "$base/$m->{dest}";
        my $dstdir = $IS_WIN ? win_dirname($dst) : dirname($dst);
        push @ops, { src => $src, dst => $dst, dstdir => $dstdir };
    }
    return @ops;
}

# ---- validate source files -------------------------------------------------
my @want = grep { want_kind($_->{kind}) } @MANIFEST;
die "Nothing to do (both --no-buttons and --no-css given).\n" unless @want;
for my $m (@want) {
    -e "$SRC/$m->{name}" or die "Source file missing: $SRC/$m->{name}\n";
}

# ===========================================================================
#  Windows PowerShell bridge (all Windows filesystem/registry work goes here,
#  base64/UTF-16 encoded so Unicode paths like C:\Users\Andr\x{e9}\... survive).
# ===========================================================================
# Wrap a script body so ANY terminating error exits non-zero (so callers can
# detect failure), and silence first-run module "progress" CLIXML noise.
sub ps_wrap {
    my ($body) = @_;
    return "\$ProgressPreference='SilentlyContinue'\n"
         . "\$ErrorActionPreference='Stop'\n"
         . "try {\n$body\n} catch { [Console]::Error.WriteLine(\$_.ToString()); exit 1 }\n"
         . "exit 0\n";
}
sub ps_run {                       # run a PowerShell script; returns (stdout, exit_code)
    my ($script) = @_;
    my $b64 = encode_base64(encode('UTF-16LE', ps_wrap($script)), '');
    my $out = scalar qx{"$PWSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $b64};
    return ($out, $? >> 8);
}
sub ps_capture {                   # run a script that sets $Result, return it (unicode)
    my ($script) = @_;
    my $wrapped = $script . "\n"
        . 'if ($null -eq $Result) { [Console]::Out.Write("") } '
        . 'else { [Console]::Out.Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Result))) }';
    my ($b64) = ps_run($wrapped);   # take stdout; capture failures surface as ''
    $b64 = '' unless defined $b64;
    $b64 =~ s/\s+//g;
    return length($b64) ? decode('UTF-8', decode_base64($b64)) : '';
}
sub ps_sq { my ($s) = @_; $s =~ s/'/''/g; return "'$s'"; }   # PS single-quote

# ---- path helpers ----------------------------------------------------------
sub win_join {                     # join parts into a Windows path
    my $s = join('\\', @_);
    $s =~ s{/}{\\}g;
    $s =~ s{(?<=.)\\{2,}}{\\}g;
    return $s;
}
sub to_win_path {                  # perl/source path -> Windows path (for source files)
    my ($p) = @_;
    return $p if $^O eq 'MSWin32';
    # Already a Windows path (e.g. from --source): just normalize separators.
    if ($p =~ m{^[A-Za-z]:[\\/]}) { (my $w = $p) =~ s{/}{\\}g; return $w; }
    # cygwin/msys drive path: /c/... or /cygdrive/c/...  ->  C:\...
    # Done in-process so we don't depend on cygpath being on PATH (it isn't when
    # perl is launched from PowerShell rather than Git-Bash).
    if ($p =~ m{^/(?:cygdrive/)?([A-Za-z])/(.*)$}) {
        my ($drive, $rest) = (uc $1, $2);
        $rest =~ s{/}{\\}g;
        return "$drive:\\$rest";
    }
    # Anything exotic (UNC, /tmp, custom mounts): try cygpath, else fail loudly.
    my $w = qx{cygpath -w "$p" 2>/dev/null}; chomp $w;
    return $w if $w =~ m{^(?:[A-Za-z]:\\|\\\\)};
    die "Could not convert source path to a Windows path: $p\n"
      . "Re-run with --source pointing at the files, e.g. --source 'C:\\Development\\Firefox'.\n";
}
sub path_join {                    # platform-native join of dir + relative
    my ($dir, $rel) = @_;
    my $sep = $IS_WIN ? "\\" : "/";
    $rel =~ s{[\\/]+}{$sep}ge;
    $rel =~ s{^\Q$sep\E+}{};
    $dir =~ s{[\\/]+$}{};
    return "$dir$sep$rel";
}

# ===========================================================================
#  Discovery: Firefox install directory
# ===========================================================================
sub valid_install_dir {
    my ($dir) = @_;
    return 0 unless defined $dir && length $dir;
    return 0 if $dir =~ m{^[A-Za-z]:[\\/]?$};   # bare drive root: C:, C:\, C:/
    return 0 if !$IS_WIN && $dir =~ m{^/*$};     # empty or filesystem root on POSIX
    # Must actually BE a Firefox install (contains the Firefox binary) before we
    # ever write into it — especially since we may do so elevated.
    return $IS_WIN ? path_exists(win_join($dir, 'firefox.exe'))
                   : (-e "$dir/firefox" || -e "$dir/firefox-bin");
}
sub find_install_dir {
    my $explicit = defined $opt{'install-dir'} && length $opt{'install-dir'};
    my $dir = trim($opt{'install-dir'}
        // ($IS_WIN ? win_find_install_dir() : linux_find_install_dir()));
    # Only fall back to an interactive prompt when AUTO-detection failed. An
    # explicit-but-wrong --install-dir reports that path; --yes never prompts.
    if (!valid_install_dir($dir) && !$explicit && !$opt{yes}) {
        $dir = trim(ask("Enter the Firefox install directory (must contain the Firefox binary)"));
    }
    # Fail closed: never proceed (or elevate) into an unvalidated target, even with --yes.
    valid_install_dir($dir) or die
        "Refusing to continue: '$dir' is not a valid Firefox install directory.\n"
      . "It must be an existing, non-root directory containing the Firefox binary.\n"
      . "Pass a correct path with --install-dir.\n";
    return $dir;
}
sub win_find_install_dir {
    my $ps = <<'PS';
$p = $null
foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe',
                 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe')) {
  try { if (Test-Path $k) { $v = (Get-ItemProperty -Path $k).'(default)'; if ($v) { $p = $v; break } } } catch {}
}
if (-not $p) {
  foreach ($c in @("$env:ProgramFiles\Mozilla Firefox\firefox.exe",
                   "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe",
                   "$env:LOCALAPPDATA\Mozilla Firefox\firefox.exe")) {
    if (Test-Path -LiteralPath $c) { $p = $c; break }
  }
}
if ($p) { $Result = Split-Path -Parent $p }
PS
    return ps_capture($ps);
}
sub linux_find_install_dir {
    my $bin = trim(qx{command -v firefox 2>/dev/null})
           || trim(qx{command -v firefox-esr 2>/dev/null});
    my $real = $bin ? trim(qx{readlink -f "$bin" 2>/dev/null}) : '';
    if (($bin && $bin =~ m{/snap/}) || ($real && $real =~ m{/snap/})) {
        warn "!! Firefox appears to be a Snap package. AutoConfig files cannot be\n"
           . "!! placed inside the read-only snap, so the buttons won't work there.\n";
    }
    my @cands;
    push @cands, dirname($real) if $real;
    push @cands, qw(/usr/lib/firefox /usr/lib64/firefox /usr/lib/firefox-esr
                    /opt/firefox /usr/local/firefox);
    for my $d (@cands) {
        next unless $d && -d $d;
        return $d if -d "$d/defaults/pref" || -e "$d/firefox";
    }
    return $real ? dirname($real) : '';
}

# ===========================================================================
#  Discovery: active profile
# ===========================================================================
sub find_profile {
    my $ini = $opt{'profiles-ini'} // ($IS_WIN ? win_profiles_ini() : linux_profiles_ini());
    die "Could not locate profiles.ini (use --profiles-ini).\n" unless $ini && path_exists($ini);
    my $dir = $IS_WIN ? win_dirname($ini) : dirname($ini);
    info("profiles.ini: $ini");

    my @profiles = parse_profiles_ini(read_text($ini), $dir);
    die "No profiles found in profiles.ini.\n" unless @profiles;

    if (defined $opt{profile}) {
        for my $p (@profiles) {
            return $p->{path} if lc($p->{name}) eq lc($opt{profile})
                              || $p->{path} eq $opt{profile};
        }
        die "Profile '$opt{profile}' not found.\n";
    }
    my @def = grep { $_->{idefault} } @profiles;              # prefer per-install default
    @def    = grep { $_->{pdefault} } @profiles unless @def;  # fall back to legacy Default=1
    return $def[0]{path}      if @def == 1;
    return $profiles[0]{path} if @profiles == 1;

    print "Multiple profiles found:\n";
    for my $i (0 .. $#profiles) {
        printf "  [%d] %s%s\n", $i + 1, $profiles[$i]{name},
            (($profiles[$i]{idefault} || $profiles[$i]{pdefault}) ? "  (default)" : "");
    }
    my $n = ask("Choose a profile [1-" . scalar(@profiles) . "]");
    die "Invalid choice.\n" unless $n && $n =~ /^\d+$/ && $n >= 1 && $n <= @profiles;
    return $profiles[$n - 1]{path};
}
sub win_profiles_ini {
    my $appdata = ps_capture('$Result = [Environment]::GetFolderPath("ApplicationData")');
    return '' unless $appdata;
    return win_join($appdata, 'Mozilla', 'Firefox', 'profiles.ini');
}
sub linux_profiles_ini {
    for my $c ("$ENV{HOME}/.mozilla/firefox/profiles.ini",
               "$ENV{HOME}/snap/firefox/common/.mozilla/firefox/profiles.ini",
               "$ENV{HOME}/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini") {
        return $c if -f $c;
    }
    return '';
}
sub parse_profiles_ini {
    my ($content, $ini_dir) = @_;
    my (@sections, $cur);
    for my $line (split /\r?\n/, $content) {
        if ($line =~ /^\s*\[(.+?)\]\s*$/)          { push @sections, ($cur = { name => $1, kv => {} }) }
        elsif ($cur && $line =~ /^\s*([^=]+?)\s*=\s*(.*?)\s*$/) { $cur->{kv}{$1} = $2 }
    }
    my %default_rel;
    for my $s (@sections) {
        $default_rel{ $s->{kv}{Default} } = 1
            if $s->{name} =~ /^Install/i && $s->{kv}{Default};
    }
    my @profiles;
    for my $s (@sections) {
        next unless $s->{name} =~ /^Profile/i && $s->{kv}{Path};
        my $rel   = $s->{kv}{Path};
        my $isrel = !defined($s->{kv}{IsRelative}) || $s->{kv}{IsRelative} eq '1';
        push @profiles, {
            name     => $s->{kv}{Name} // basename($rel),
            path     => $isrel ? path_join($ini_dir, $rel) : $rel,
            idefault => $default_rel{$rel} ? 1 : 0,                              # per-install default (modern)
            pdefault => ($s->{kv}{Default} && $s->{kv}{Default} eq '1') ? 1 : 0, # legacy Default=1
        };
    }
    return @profiles;
}

# ===========================================================================
#  Cross-platform primitives
# ===========================================================================
sub path_exists {
    my ($p) = @_;
    return $IS_WIN
        ? (ps_capture("\$Result = if (Test-Path -LiteralPath " . ps_sq($p) . ") {'1'} else {'0'}") eq '1')
        : (-e $p);
}
sub read_text {
    my ($p) = @_;
    if ($IS_WIN) {
        my $q = ps_sq($p);
        return ps_capture("\$Result = if (Test-Path -LiteralPath $q) { Get-Content -LiteralPath $q -Raw } else { '' }");
    }
    open my $fh, '<:raw', $p or return '';
    local $/; my $c = <$fh>; close $fh;
    return decode('UTF-8', $c);
}
sub win_dirname { my ($p) = @_; (my $d = $p) =~ s{[\\/][^\\/]+[\\/]*$}{}; return $d }
sub dir_writable_win {
    my ($d) = @_;
    my $q = ps_sq($d);
    return ps_capture(
        "\$Result = try { \$t = Join-Path $q ('.w_'+[IO.Path]::GetRandomFileName());"
      . " [IO.File]::WriteAllText(\$t,'x'); Remove-Item -LiteralPath \$t -Force; '1' } catch { '0' }"
    ) eq '1';
}

# ===========================================================================
#  Execute a batch of file operations (backup existing + copy), optionally
#  elevated. @ops = ({src,dst,dstdir}, ...)
# ===========================================================================
sub run_batch {
    my ($ops, $need_elevate) = @_;
    return unless @$ops;
    if ($opt{'dry-run'}) {
        print "    (dry-run" . ($need_elevate ? ", would elevate" : "") . ")\n";
        return;
    }
    $IS_WIN ? run_batch_win($ops, $need_elevate) : run_batch_linux($ops, $need_elevate);
}
sub run_batch_win {
    my ($ops, $elevate) = @_;
    my $s = '';   # ps_wrap() adds ErrorActionPreference=Stop + failure->exit 1
    for my $o (@$ops) {
        my ($src, $dst, $dir) = (ps_sq($o->{src}), ps_sq($o->{dst}), ps_sq($o->{dstdir}));
        $s .= "if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }\n";
        $s .= "if (Test-Path -LiteralPath $dst) {\n";
        $s .= "  \$bak = $dst + '.bak-$STAMP'\n";
        $s .= "  if (Test-Path -LiteralPath \$bak) { throw ('backup already exists: ' + \$bak) }\n";
        $s .= "  Copy-Item -LiteralPath $dst -Destination \$bak\n";   # no -Force: never clobber a backup
        $s .= "}\n";
        $s .= "Copy-Item -LiteralPath $src -Destination $dst -Force\n";
    }
    if (!$elevate) {
        my (undef, $rc) = ps_run($s);
        die "Install-dir file copy failed (see the error above).\n" if $rc;
        return;
    }
    # Elevate: relaunch a self-checking encoded PowerShell as admin (UAC) and wait.
    # A declined UAC prompt makes Start-Process throw -> ps_wrap exits 1 -> we die.
    my $inner = encode_base64(encode('UTF-16LE', ps_wrap($s)), '');
    my $outer =
        "\$p = Start-Process -FilePath (Join-Path \$PSHOME 'powershell.exe') -Verb RunAs -PassThru -Wait"
      . " -ArgumentList \@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand','$inner')\n"
      . "if (\$null -eq \$p) { throw 'could not start the elevated process' }\n"
      . "if (\$p.ExitCode -ne 0) { throw ('elevated install exited ' + \$p.ExitCode) }\n";
    my (undef, $rc) = ps_run($outer);
    die "Elevated install failed or was cancelled at the UAC prompt "
      . "(the install directory was NOT changed).\n" if $rc;
}
sub run_batch_linux {
    my ($ops, $elevate) = @_;
    my $sh = "set -e\n";
    for my $o (@$ops) {
        my ($src, $dst, $dir) = (shq($o->{src}), shq($o->{dst}), shq($o->{dstdir}));
        $sh .= "mkdir -p $dir\n";
        $sh .= "if [ -e $dst ]; then\n";
        $sh .= "  if [ -e $dst.bak-$STAMP ]; then echo \"backup already exists: $dst.bak-$STAMP\" >&2; exit 1; fi\n";
        $sh .= "  cp -p -- $dst $dst.bak-$STAMP\n";
        $sh .= "fi\n";
        $sh .= "cp -- $src $dst\n";
    }
    my @cmd = $elevate ? ('sudo', 'bash', '-c', $sh) : ('bash', '-c', $sh);
    system(@cmd) == 0 or die "File operations failed (exit $?).\n";
}
sub shq { my ($s) = @_; $s =~ s/'/'\\''/g; return "'$s'" }

# ===========================================================================
#  Ensure the profile's user.js sets every pref in @PREFS
# ===========================================================================
sub ensure_prefs {
    my ($profile) = @_;
    my $uj = $IS_WIN ? win_join($profile, 'user.js') : "$profile/user.js";
    my $existing = read_text($uj);
    my @missing;
    for my $p (@PREFS) {
        # Only a live (uncommented) user_pref line counts as already set.
        if ($existing =~ /^\s*user_pref\(\s*["']\Q$p->{key}\E["']\s*,\s*(.*?)\s*\)\s*;/m) {
            my $cur = $1;
            if ($cur eq $p->{value}) {
                info("user.js already sets $p->{key} = $p->{value}.");
            } else {
                info("user.js sets $p->{key} = $cur (this setup uses $p->{value}) — leaving it alone.");
            }
            next;
        }
        push @missing, $p;
    }
    return unless @missing;
    if ($opt{'dry-run'}) {
        print "    (dry-run) would add '$_->{key} = $_->{value}' to user.js\n" for @missing;
        return;
    }
    my $add = "\n// added by install.pl on $STAMP\n"
            . join('', map { qq{user_pref("$_->{key}", $_->{value}); // $_->{why}\n} } @missing);
    if ($IS_WIN) {
        my $q = ps_sq($uj);
        # Pass the text as base64 and write with explicit UTF-8 (no BOM) so we
        # can't ANSI-mangle/BOM-corrupt an existing UTF-8 user.js.
        my $addb64 = encode_base64(encode('UTF-8', $add), '');
        my (undef, $rc) = ps_run(
            "if (Test-Path -LiteralPath $q) {\n"
          . "  \$bak = $q + '.bak-$STAMP'\n"
          . "  if (Test-Path -LiteralPath \$bak) { throw ('backup already exists: ' + \$bak) }\n"
          . "  Copy-Item -LiteralPath $q -Destination \$bak\n"
          . "}\n"
          . "\$txt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$addb64'))\n"
          . "[IO.File]::AppendAllText($q, \$txt, (New-Object System.Text.UTF8Encoding -ArgumentList \$false))\n"
        );
        die "Failed to update user.js.\n" if $rc;
    } else {
        if (-e $uj) {
            my $bak = "$uj.bak-$STAMP";
            die "backup already exists: $bak\n" if -e $bak;
            system('cp', '-p', '--', $uj, $bak) == 0 or die "backup of user.js failed\n";
        }
        open my $fh, '>>:raw', $uj or die "Cannot write $uj: $!\n";
        print $fh encode('UTF-8', $add); close $fh;
    }
    info("Added to user.js: " . join(', ', map { $_->{key} } @missing)
       . " (backup kept if it existed).");
}

# ===========================================================================
#  Main
# ===========================================================================
my (@install_ops, @profile_ops);
my ($INSTALL, $PROFILE, $need_elevate);

unless ($opt{'no-buttons'}) {
    $INSTALL = find_install_dir();
    info("Install  : $INSTALL");
    @install_ops = build_ops($INSTALL, 'install');
    $need_elevate = $IS_WIN ? !dir_writable_win($INSTALL) : !(-w $INSTALL);
}
unless ($opt{'no-css'}) {
    $PROFILE = find_profile();
    info("Profile  : $PROFILE");
    path_exists($PROFILE) or die
        "Refusing to continue: profile directory does not exist: $PROFILE\n"
      . "(listed in profiles.ini). Pass --profile to choose another.\n";
    @profile_ops = build_ops($PROFILE, 'profile');
}

# ---- plan + confirm --------------------------------------------------------
print "\nPlanned actions:\n";
print "  Install-dir files" . ($need_elevate ? "  (needs admin/root)" : "") . ":\n"
    . join('', map { "    $_->{src}\n      -> $_->{dst}\n" } @install_ops) if @install_ops;
print "  Profile files:\n"
    . join('', map { "    $_->{src}\n      -> $_->{dst}\n" } @profile_ops) if @profile_ops;
print "  Ensure these prefs in the profile's user.js:\n"
    . join('', map { "    $_->{key} = $_->{value}\n" } @PREFS) if @profile_ops;
print "  Existing files are backed up as <file>.bak-$STAMP\n\n";

unless ($opt{'dry-run'} || $opt{yes}) {
    my $a = ask("Proceed? [y/N]");
    die "Aborted.\n" unless defined($a) && $a =~ /^y/i;
}

# ---- execute ---------------------------------------------------------------
if (@profile_ops) {
    info("Installing profile files...");
    run_batch(\@profile_ops, 0);
    ensure_prefs($PROFILE);
}
if (@install_ops) {
    info("Installing install-dir files" . ($need_elevate ? " (you'll be asked to elevate)..." : "..."));
    run_batch(\@install_ops, $need_elevate);
}

print "\n" . ($opt{'dry-run'} ? "Dry run complete — nothing changed.\n"
                              : "Done. Restart Firefox for the changes to take effect.\n");

# ===========================================================================
#  Small utilities
# ===========================================================================
sub info { print "  * $_[0]\n" }
sub trim { my ($s) = @_; return '' unless defined $s; $s =~ s/^\s+|\s+$//g; return $s }
sub ask {
    my ($prompt) = @_;
    print "$prompt: ";
    my $a = <STDIN>;
    return defined $a ? trim($a) : '';
}
sub usage {
    my ($code) = @_;
    print <<'USAGE';
install.pl — install/update Firefox customization files.

  perl install.pl [--source DIR] [--install-dir DIR] [--profile NAME|PATH]
                  [--profiles-ini PATH] [--no-buttons] [--no-css]
                  [--dry-run] [--yes] [--help]

Run with --dry-run first to see the detected paths and planned actions.
USAGE
    exit $code;
}
