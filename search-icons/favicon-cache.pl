#!/usr/bin/perl
#
# favicon-cache.pl - pull icons Firefox has already downloaded out of its
# favicon cache.
#
# Sometimes you cannot just fetch a site's favicon with curl. grep.app, for
# one, sits behind a Vercel JS challenge that answers every plain request with
# a 429 HTML page. But if you have visited the site in Firefox, the icon is
# already on disk in <profile>/favicons.sqlite, so it can be recovered locally.
#
# There is no sqlite3 dependency here. Rather than parse the B-tree, this
# scans the raw database pages (and the -wal, which holds recent writes not yet
# checkpointed) for an icon URL matching your pattern, then takes the image
# blob stored next to it in the same record. That is a heuristic, not a real
# query, so always check the result with imginfo.pl before using it.
#
# Usage:
#   perl favicon-cache.pl PATTERN [--out DIR] [--profile NAME|PATH]
#
# Example:
#   perl favicon-cache.pl grep.app --out ./icons
#
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use File::Basename qw(basename);

my %opt = (out => '.');
GetOptions(\%opt, 'out=s', 'all', 'profile=s', 'profiles-ini=s', 'help') or usage(2);
usage(0) if $opt{help};
my $pattern = shift @ARGV;
usage(2) unless defined $pattern && length $pattern;

my $IS_WIN = ($^O =~ /^(?:MSWin32|msys|cygwin)$/);
my $profile = find_profile();
print "  * Profile: $profile\n";

my @sources = grep { -e $_ } ("$profile/favicons.sqlite", "$profile/favicons.sqlite-wal");
die "No favicons.sqlite in that profile.\n" unless @sources;

mkdir $opt{out} unless -d $opt{out};
die "Cannot write to $opt{out}\n" unless -d $opt{out};

my $qp = quotemeta $pattern;
my (%seen, $found);

for my $src (@sources) {
    open my $fh, '<:raw', $src or do { warn "$src: $!\n"; next };
    my $blob = do { local $/; <$fh> };
    close $fh;
    next unless defined $blob;
    printf "  * Scanning %s (%.1f MB)\n", basename($src), length($blob) / 1048576;

    # Icon URLs are stored as plain text in the record; the image bytes follow
    # in the same row. A few KB of lookahead covers the intervening columns.
    while ($blob =~ /(https?:\/\/[^\x00-\x1f"<>]{0,120}$qp[^\x00-\x1f"<>]{0,120})/gi) {
        my ($url, $at) = ($1, pos $blob);

        # The cache also stores page URLs alongside icon records, and the blob
        # sitting next to one of those is usually some other page's icon. Keep
        # only URLs that actually look like an image unless --all is given.
        next unless $opt{all} || $url =~ /(?:icon|\.png|\.ico|\.svg|\.gif|\.jpe?g)/i;

        my $window = substr($blob, $at, 8192);

        my $img;
        if ($window =~ /(\x89PNG\r\n\x1a\n.*?IEND\xaeB`\x82)/s) {
            $img = $1;
        }
        elsif ($window =~ /\x00\x00\x01\x00[\x01-\x08]\x00/s) {
            $img = substr($window, $-[0], 65536);
        }
        next unless defined $img && length($img) > 64;

        my $key = length($img) . ':' . $url;
        next if $seen{$key}++;

        # Name the file from the URL path only. Anything after "?" is a cache
        # buster, and the raw scan can trail a few record bytes onto the end of
        # the match, so dropping the query removes that noise too.
        (my $slug = $url) =~ s/^https?:\/\///;
        $slug =~ s/\?.*$//;
        $slug =~ s/\.(?:png|ico|svg|gif|jpe?g)$//i;
        $slug =~ s/[^A-Za-z0-9._-]+/_/g;
        $slug = substr($slug, 0, 60);
        my $ext  = substr($img, 0, 8) eq "\x89PNG\r\n\x1a\n" ? 'png' : 'ico';
        my $path = "$opt{out}/$slug.$ext";
        my $dup  = 1;
        $path = "$opt{out}/$slug." . ++$dup . ".$ext" while -e $path;

        open my $o, '>:raw', $path or die "$path: $!\n";
        print $o $img;
        close $o;
        $found++;
        printf "    %-58s %6d bytes -> %s\n", substr($url, 0, 58), length($img), $path;
    }
}

if ($found) {
    print "\nRecovered $found icon(s). Check them with:\n";
    print "  perl imginfo.pl $opt{out}/*\n";
    print "An ICO can be made viewable with ico2png.pl.\n";
}
else {
    print "\nNothing matched '$pattern'.\n";
    print "Visit the site in Firefox first so the icon gets cached, or widen the pattern.\n";
}

sub find_profile {
    my $ini = $opt{'profiles-ini'} // default_profiles_ini();
    die "Could not locate profiles.ini (use --profiles-ini).\n" unless $ini && -e $ini;
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
    die "Multiple profiles found, pick one with --profile.\n";
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

sub usage {
    my ($code) = @_;
    print <<'USAGE';
favicon-cache.pl - pull icons out of Firefox's favicon cache.

  perl favicon-cache.pl PATTERN [--out DIR] [--profile NAME|PATH]

    PATTERN           Substring to match against cached icon URLs, for example
                      grep.app or web_maps_icon
    --out DIR         Where to write what it finds (default: current directory)
    --all             Also match page URLs, not just ones that look like an
                      image. Noisier, and the blob next to a page URL is often
                      some other page's icon
    --profile NAME|PATH   Pick a profile
    --profiles-ini PATH   Override the profiles.ini location
    --help            This help

For sites that block scripted requests but that you have already visited in
Firefox. The match is a raw scan of the database pages rather than a real
query, so verify the output with imginfo.pl.
USAGE
    exit $code;
}
