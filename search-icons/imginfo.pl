#!/usr/bin/perl
#
# imginfo.pl - report the real format and pixel size of image files.
#
# Useful when collecting favicons, because sites routinely serve a PNG under a
# .ico name (developer.mozilla.org/favicon.ico and Google's
# web_maps_icon_32dp.ico are both PNGs). Firefox keys search engine icons by
# pixel size, so the actual dimensions matter more than the file name.
#
# Usage:
#   perl imginfo.pl FILE [FILE ...]
#
use strict;
use warnings;
use File::Basename qw(basename);

@ARGV or die "usage: perl imginfo.pl FILE [FILE ...]\n";

for my $file (@ARGV) {
    open my $fh, '<:raw', $file or do {
        printf "%-24s cannot open: %s\n", basename($file), $!;
        next;
    };
    my $b = do { local $/; <$fh> };
    close $fh;
    $b = '' unless defined $b;

    printf "%-24s %7d bytes  %s\n", basename($file), length($b), describe($b);
}

sub describe {
    my ($b) = @_;
    return 'empty file' unless length $b;

    if (substr($b, 0, 8) eq "\x89PNG\r\n\x1a\n") {
        my ($w, $h) = unpack('NN', substr($b, 16, 8));
        return "PNG ${w}x${h}";
    }
    if (substr($b, 0, 4) eq "\x00\x00\x01\x00") {
        my $n = unpack('v', substr($b, 4, 2));
        my @entries;
        for my $i (0 .. $n - 1) {
            my $o = 6 + $i * 16;
            last if $o + 16 > length $b;
            my $w   = ord(substr($b, $o,     1)) || 256;
            my $h   = ord(substr($b, $o + 1, 1)) || 256;
            my $bpp = unpack('v', substr($b, $o + 6,  2));
            my $off = unpack('V', substr($b, $o + 12, 4));
            my $sub = substr($b, $off, 8) eq "\x89PNG\r\n\x1a\n" ? 'png' : 'bmp';
            push @entries, "${w}x${h}\@${bpp}bpp/$sub";
        }
        return "ICO[$n]: " . join(' ', @entries);
    }
    if (substr($b, 0, 6) eq 'GIF87a' || substr($b, 0, 6) eq 'GIF89a') {
        my ($w, $h) = unpack('vv', substr($b, 6, 4));
        return "GIF ${w}x${h}";
    }
    if (substr($b, 0, 2) eq "\xFF\xD8") {
        return 'JPEG';
    }
    if (substr($b, 0, 4) eq 'RIFF' && substr($b, 8, 4) eq 'WEBP') {
        return 'WEBP';
    }
    if ($b =~ /^\s*(?:<\?xml|<svg)/i) {
        my ($vb) = $b =~ /viewBox\s*=\s*["']([^"']+)["']/i;
        return 'SVG' . (defined $vb ? " viewBox=$vb" : '');
    }
    return 'unknown, first bytes ' . unpack('H*', substr($b, 0, 8));
}
