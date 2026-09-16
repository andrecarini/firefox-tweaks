#!/usr/bin/perl
#
# search-engine-icon.pl - inspect and re-icon Firefox's OpenSearch engines.
#
# Firefox has no UI for changing a search engine's icon. Engines added from a
# site's OpenSearch descriptor (Mycroft Project and similar) keep their icon
# inline in <profile>/search.json.mozlz4, as a base64 data URI in the engine's
# _iconMapObj, keyed by pixel size. This script edits that file.
#
# It can also drop an engine's rel="self" OpenSearch URL. That URL is the only
# thing Firefox can refresh an OpenSearch engine from once _updateURL is null,
# so removing it stops a customized icon being silently replaced by whatever
# the original descriptor still serves. Engines installed from a site that no
# longer maintains the descriptor are the usual reason to want this.
#
# Firefox must be closed. It holds the engine list in memory and rewrites
# search.json.mozlz4 on shutdown, so edits made while it runs are discarded.
#
# Usage:
#   perl search-engine-icon.pl --list
#   perl search-engine-icon.pl --engine "Google Maps" --icon maps.png
#   perl search-engine-icon.pl --engine "grep.app" --icon g.png --no-update
#   perl search-engine-icon.pl --engine "Wayback Machine" --no-update
#
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use File::Basename qw(basename);
use MIME::Base64 qw(encode_base64 decode_base64);
use POSIX qw(strftime);
use JSON::PP;

my $IS_WIN = ($^O =~ /^(?:MSWin32|msys|cygwin)$/);

my %opt;
GetOptions(\%opt,
    'list', 'engine=s', 'icon=s', 'no-update',
    'profile=s', 'profiles-ini=s', 'dry-run', 'yes', 'help',
) or usage(2);
usage(0) if $opt{help};
usage(2) unless $opt{list} || $opt{engine};

die "--engine needs --icon, --no-update, or both.\n"
    if $opt{engine} && !$opt{icon} && !$opt{'no-update'};

my $profile = find_profile();
my $store   = "$profile/search.json.mozlz4";
info("Profile  : $profile");
die "No search.json.mozlz4 in that profile.\n" unless -e $store;

my $json = read_store($store);
my $data = JSON::PP->new->decode($json);
my $engines = $data->{engines} || [];
die "No engines in search.json.mozlz4.\n" unless @$engines;

if ($opt{list}) { list_engines($engines); exit 0 }

# ---- locate the engine -----------------------------------------------------
my @hit = grep { lc($_->{_name} // '') eq lc($opt{engine}) } @$engines;
@hit    = grep { index(lc($_->{_name} // ''), lc($opt{engine})) >= 0 } @$engines unless @hit;
die "No engine matching '$opt{engine}'. Use --list to see them.\n" unless @hit;
die "'$opt{engine}' is ambiguous: " . join(', ', map { $_->{_name} } @hit) . "\n" if @hit > 1;
my $engine = $hit[0];
my $name   = $engine->{_name};

die "'$name' is a built-in engine. Its icon comes from Firefox's remote search\n"
  . "configuration, not from this file, so it cannot be changed here.\n"
    if $engine->{_isConfigEngine};

# ---- build the plan --------------------------------------------------------
my @plan;

if ($opt{icon}) {
    die "No such file: $opt{icon}\n" unless -e $opt{icon};
    my $img = slurp($opt{icon});
    my ($mime, $w, $h) = image_info($img);
    die "$opt{icon}: not a PNG or ICO. Firefox keys these icons by pixel size,\n"
      . "so use a raster image.\n" unless $mime;

    my $uri = "data:$mime;base64," . encode_base64($img, '');
    my $map = $engine->{_iconMapObj} ||= {};

    # Replace every size the engine already advertises, so no stale artwork is
    # left behind at a key we did not touch, then make sure the image's true
    # size is present as a key too.
    my @keys = sort { $a <=> $b } keys %$map;
    for my $k (@keys) {
        my ($om, $ow, $oh) = image_info(decode_base64(($map->{$k} =~ /base64,(.*)$/s)[0] // ''));
        push @plan, sprintf("icon[%s] %s -> %s %dx%d (%d bytes)",
            $k, ($om ? "$om ${ow}x${oh}" : 'unknown'), $mime, $w, $h, length $img);
        $map->{$k} = $uri;
    }
    unless (exists $map->{$w}) {
        push @plan, sprintf("icon[%d] added, %s %dx%d (%d bytes)", $w, $mime, $w, $h, length $img);
        $map->{$w} = $uri;
    }
}

if ($opt{'no-update'}) {
    my $urls = $engine->{_urls} || [];
    my @self = grep { is_self($_) } @$urls;
    if (!@self && !defined $engine->{_updateURL}) {
        push @plan, "auto-update: already disabled, nothing to remove";
    }
    else {
        push @plan, "auto-update: remove rel=self $_->{template}" for @self;
        push @plan, "auto-update: clear _updateURL $engine->{_updateURL}"
            if defined $engine->{_updateURL};
        $engine->{_urls} = [ grep { !is_self($_) } @$urls ];
        $engine->{_updateURL} = undef;
        my $left = scalar @{ $engine->{_urls} };
        die "Refusing to continue: that would leave '$name' with no search URL.\n" unless $left;
        push @plan, "auto-update: $left search URL(s) kept";
    }
}

print "\nPlan for '$name':\n";
info($_) for @plan;

if ($opt{'dry-run'}) { print "\nDry run, nothing written.\n"; exit 0 }

# ---- write -----------------------------------------------------------------
my $running = firefox_running();
if (!defined $running) {
    print "\nCould not tell whether Firefox is running. Make sure it is fully closed.\n";
}
elsif ($running) {
    die "\nFirefox is running. Close it completely first: it rewrites\n"
      . "search.json.mozlz4 on shutdown and would discard this edit.\n";
}

unless ($opt{yes}) {
    print "\nWrite these changes to the profile? [y/N]: ";
    my $a = <STDIN>;
    die "Aborted.\n" unless defined $a && $a =~ /^\s*y/i;
}

my $backup = "$store.bak-" . strftime('%Y%m%d-%H%M%S', localtime);
spew($backup, slurp($store));
info("Backed up: $backup");

write_store($store, JSON::PP->new->encode($data));
info("Wrote    : $store");
print "\nStart Firefox and check the engine. To undo, with Firefox closed:\n";
print "  copy the backup above back over search.json.mozlz4\n";

# ===========================================================================
#  Engine listing
# ===========================================================================
sub list_engines {
    my ($list) = @_;
    printf "\n%-22s %-6s %-22s %s\n", 'ENGINE', 'ICONS', 'ICON DETAIL', 'AUTO-UPDATE';
    for my $e (@$list) {
        my $map  = $e->{_iconMapObj} || {};
        my @keys = sort { $a <=> $b } keys %$map;
        my @self = grep { is_self($_) } @{ $e->{_urls} || [] };
        my $upd  = $e->{_isConfigEngine} ? 'built-in'
                 : (@self || defined $e->{_updateURL}) ? 'LIVE' : 'disabled';

        my $detail = '-';
        if (@keys) {
            my @bits;
            for my $k (@keys) {
                my ($m, $w, $h) = image_info(decode_base64(($map->{$k} =~ /base64,(.*)$/s)[0] // ''));
                push @bits, sprintf("%s=%s", $k, $m ? "${w}x${h}" : '?');
            }
            $detail = join(' ', @bits);
        }
        printf "%-22s %-6s %-22s %s\n", ($e->{_name} // '?'), scalar(@keys), $detail, $upd;
    }
    print "\nBuilt-in engines cannot be re-iconed here. LIVE means Firefox can still\n"
        . "refresh that engine from its OpenSearch descriptor and overwrite a custom icon.\n";
}

# ===========================================================================
#  Store I/O
# ===========================================================================
sub read_store {
    my ($path) = @_;
    my $raw = slurp($path);
    die "$path: not a mozlz4 file.\n"
        unless length($raw) >= 12 && substr($raw, 0, 8) eq "mozLz40\0";
    my $src = substr($raw, 12);
    my $len = length $src;
    my ($sp, $dst) = (0, '');
    while ($sp < $len) {
        my $token = ord substr($src, $sp++, 1);
        my $ll = $token >> 4;
        if ($ll == 15) { my $b; do { $b = ord substr($src, $sp++, 1); $ll += $b } while ($b == 255) }
        $dst .= substr($src, $sp, $ll);
        $sp  += $ll;
        last if $sp >= $len;
        my $offset = unpack('v', substr($src, $sp, 2));
        $sp += 2;
        die "corrupt block: zero match offset\n" if $offset == 0;
        my $ml = $token & 0x0F;
        if ($ml == 15) { my $b; do { $b = ord substr($src, $sp++, 1); $ml += $b } while ($b == 255) }
        $ml += 4;
        my $start = length($dst) - $offset;
        die "corrupt block: bad match offset\n" if $start < 0;
        $dst .= substr($dst, $start++, 1) for 1 .. $ml;
    }
    return $dst;
}

# All-literal LZ4 block. See mozlz4.pl for why that is enough.
sub write_store {
    my ($path, $payload) = @_;
    my $n    = length $payload;
    my $body = '';
    if ($n < 15) { $body .= chr($n << 4) }
    else {
        $body .= chr(0xF0);
        my $rest = $n - 15;
        while ($rest >= 255) { $body .= chr(255); $rest -= 255 }
        $body .= chr($rest);
    }
    $body .= $payload;
    my $out = "mozLz40\0" . pack('V', $n) . $body;

    # Prove the container reads back before replacing the live file.
    spew("$path.tmp", $out);
    my $check = eval { read_store("$path.tmp") };
    unlink "$path.tmp";
    die "Refusing to write: the container did not round-trip.\n"
        unless defined $check && $check eq $payload;
    eval { JSON::PP->new->decode($check); 1 }
        or die "Refusing to write: the result is not valid JSON.\n";

    spew($path, $out);
}

# ===========================================================================
#  Helpers
# ===========================================================================
sub is_self {
    my ($u) = @_;
    return 0 unless ref $u eq 'HASH';
    return scalar grep { $_ eq 'self' } @{ $u->{rels} || [] };
}

# Returns (mime, width, height), or an empty list if it is neither PNG nor ICO.
# Note that several sites serve a PNG under a .ico name, so sniff the bytes.
sub image_info {
    my ($d) = @_;
    return () unless defined $d && length $d > 8;
    if (substr($d, 0, 8) eq "\x89PNG\r\n\x1a\n") {
        my ($w, $h) = unpack('NN', substr($d, 16, 8));
        return ('image/png', $w, $h);
    }
    if (substr($d, 0, 4) eq "\x00\x00\x01\x00") {
        my $n = unpack('v', substr($d, 4, 2));
        my ($bw, $bh) = (0, 0);
        for my $i (0 .. $n - 1) {
            my $o = 6 + $i * 16;
            last if $o + 2 > length $d;
            my $w = ord(substr($d, $o,     1)) || 256;
            my $h = ord(substr($d, $o + 1, 1)) || 256;
            ($bw, $bh) = ($w, $h) if $w > $bw;
        }
        return ('image/x-icon', $bw, $bh);
    }
    return ();
}

# undef means "could not determine".
sub firefox_running {
    if ($IS_WIN) {
        my $out = `tasklist /FI "IMAGENAME eq firefox.exe" /NH 2>&1`;
        return undef if $? != 0 || !defined $out;
        return $out =~ /firefox\.exe/i ? 1 : 0;
    }
    my $out = `pgrep -x firefox 2>/dev/null`;
    return 1 if defined $out && $out =~ /\d/;
    return 0 if $? == 256;   # pgrep exits 1 when nothing matched
    return undef;
}

sub find_profile {
    my $ini = $opt{'profiles-ini'} // default_profiles_ini();
    die "Could not locate profiles.ini (use --profiles-ini).\n" unless $ini && -e $ini;
    info("profiles.ini: $ini");
    (my $dir = $ini) =~ s{/[^/]+$}{};

    my (@sections, $cur);
    open my $fh, '<', $ini or die "$ini: $!\n";
    while (my $line = <$fh>) {
        $line =~ s/\r?\n$//;
        if    ($line =~ /^\s*\[(.+?)\]\s*$/)                    { push @sections, ($cur = { name => $1, kv => {} }) }
        elsif ($cur && $line =~ /^\s*([^=]+?)\s*=\s*(.*?)\s*$/) { $cur->{kv}{$1} = $2 }
    }
    close $fh;

    my %install_default;
    for my $s (@sections) {
        $install_default{ $s->{kv}{Default} } = 1
            if $s->{name} =~ /^Install/i && $s->{kv}{Default};
    }
    my @profiles;
    for my $s (@sections) {
        next unless $s->{name} =~ /^Profile/i && $s->{kv}{Path};
        my $rel   = $s->{kv}{Path};
        my $isrel = !defined($s->{kv}{IsRelative}) || $s->{kv}{IsRelative} eq '1';
        push @profiles, {
            name     => $s->{kv}{Name} // basename($rel),
            path     => $isrel ? "$dir/$rel" : $rel,
            idefault => $install_default{$rel} ? 1 : 0,
            pdefault => ($s->{kv}{Default} && $s->{kv}{Default} eq '1') ? 1 : 0,
        };
    }
    die "No profiles found in profiles.ini.\n" unless @profiles;

    if (defined $opt{profile}) {
        for my $p (@profiles) {
            return $p->{path} if lc($p->{name}) eq lc($opt{profile}) || $p->{path} eq $opt{profile};
        }
        die "Profile '$opt{profile}' not found.\n";
    }
    my @def = grep { $_->{idefault} } @profiles;
    @def    = grep { $_->{pdefault} } @profiles unless @def;
    return $def[0]{path}      if @def == 1;
    return $profiles[0]{path} if @profiles == 1;

    print "Multiple profiles found:\n";
    printf "  [%d] %s%s\n", $_ + 1, $profiles[$_]{name},
        (($profiles[$_]{idefault} || $profiles[$_]{pdefault}) ? '  (default)' : '')
        for 0 .. $#profiles;
    print "Choose a profile [1-" . scalar(@profiles) . "]: ";
    my $n = <STDIN>;
    $n = defined $n ? $n : '';
    $n =~ s/^\s+|\s+$//g;
    die "Invalid choice.\n" unless $n =~ /^\d+$/ && $n >= 1 && $n <= @profiles;
    return $profiles[$n - 1]{path};
}

sub default_profiles_ini {
    if ($IS_WIN) {
        my $appdata = $ENV{APPDATA} or return '';
        $appdata =~ s{[\\]}{/}g;
        return "$appdata/Mozilla/Firefox/profiles.ini";
    }
    for my $c ("$ENV{HOME}/.mozilla/firefox/profiles.ini",
               "$ENV{HOME}/snap/firefox/common/.mozilla/firefox/profiles.ini",
               "$ENV{HOME}/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini") {
        return $c if -f $c;
    }
    return '';
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!\n";
    local $/;
    my $d = <$fh>;
    close $fh;
    return defined $d ? $d : '';
}

sub spew {
    my ($path, $data) = @_;
    open my $fh, '>:raw', $path or die "$path: $!\n";
    print $fh $data;
    close $fh or die "$path: $!\n";
}

sub info { print "  * $_[0]\n" }

sub usage {
    my ($code) = @_;
    print <<'USAGE';
search-engine-icon.pl - inspect and re-icon Firefox's OpenSearch engines.

  perl search-engine-icon.pl --list
  perl search-engine-icon.pl --engine NAME --icon FILE [--no-update]
  perl search-engine-icon.pl --engine NAME --no-update

    --list            Show every engine, its icon sizes, and whether Firefox
                      can still auto-update it
    --engine NAME     Engine to change (exact name, else unique substring)
    --icon FILE       PNG or ICO to embed, replacing every size the engine
                      advertises and adding a key for the image's own size
    --no-update       Remove the rel=self OpenSearch URL and clear _updateURL,
                      so Firefox stops refreshing the engine over your icon
    --profile NAME|PATH   Pick a profile
    --profiles-ini PATH   Override the profiles.ini location
    --dry-run         Show the plan, change nothing
    --yes             Do not prompt
    --help            This help

Firefox must be closed. It rewrites search.json.mozlz4 on shutdown, so an edit
made while it is running is discarded. Every write is backed up first as
search.json.mozlz4.bak-<timestamp>.
USAGE
    exit $code;
}
