#!/usr/bin/perl
#
# ico2png.pl - convert an ICO to PNG so it can actually be looked at.
#
# Windows ICO files are awkward to view and most tooling will not render them
# inline. This takes the largest image in an ICO and writes it as a PNG. If
# that image is already a PNG (common in modern icons) it is copied straight
# out; if it is a 32bpp BMP it is converted.
#
# Only 32bpp BMP entries are converted. Older palette or 24bpp icons are
# reported rather than guessed at, since search engine icons are effectively
# always 32bpp or embedded PNG.
#
# Usage:
#   perl ico2png.pl IN.ico OUT.png
#
use strict;
use warnings;
use Compress::Zlib qw(compress crc32);

my ($in, $out) = @ARGV;
die "usage: perl ico2png.pl IN.ico OUT.png\n" unless defined $in && defined $out;

open my $fh, '<:raw', $in or die "$in: $!\n";
my $b = do { local $/; <$fh> };
close $fh;
die "$in: empty file\n" unless defined $b && length $b;

die "$in: not an ICO (expected a 00 00 01 00 header)\n"
    unless substr($b, 0, 4) eq "\x00\x00\x01\x00";

my $count = unpack('v', substr($b, 4, 2));
die "$in: contains no images\n" unless $count;

# Pick the largest entry. Width 0 in the directory means 256.
my ($best_w, $best) = (-1, undef);
for my $i (0 .. $count - 1) {
    my $o = 6 + $i * 16;
    die "$in: truncated icon directory\n" if $o + 16 > length $b;
    my $w   = ord(substr($b, $o, 1)) || 256;
    my $sz  = unpack('V', substr($b, $o + 8,  4));
    my $off = unpack('V', substr($b, $o + 12, 4));
    if ($w > $best_w) { ($best_w, $best) = ($w, [$sz, $off]) }
}
my ($size, $offset) = @$best;
die "$in: image data lies outside the file\n" if $offset + $size > length $b;
my $blob = substr($b, $offset, $size);

if (substr($blob, 0, 8) eq "\x89PNG\r\n\x1a\n") {
    write_file($out, $blob);
    printf "copied embedded PNG (%d bytes) -> %s\n", length($blob), $out;
    exit 0;
}

my ($hdr_size, $bm_w, $bm_h, undef, $bpp) = unpack('Vllvv', substr($blob, 0, 16));
die "$in: only 32bpp BMP entries are converted, this one is ${bpp}bpp\n" unless $bpp == 32;

# An icon's BMP header doubles the height to cover the AND mask, which a
# 32bpp icon does not need because it carries a real alpha channel.
my $w = $bm_w;
my $h = int($bm_h / 2);
die "$in: nonsensical dimensions ${w}x${h}\n" if $w <= 0 || $h <= 0;

my $px = substr($blob, $hdr_size);   # no palette at 32bpp
die "$in: pixel data is short\n" if length($px) < $w * $h * 4;

my $raw = '';
for my $y (reverse 0 .. $h - 1) {    # BMP rows run bottom to top
    $raw .= "\x00";                  # PNG per-scanline filter: none
    my $row = substr($px, $y * $w * 4, $w * 4);
    for my $x (0 .. $w - 1) {
        my ($blue, $green, $red, $alpha) = unpack('C4', substr($row, $x * 4, 4));
        $raw .= pack('C4', $red, $green, $blue, $alpha);
    }
}

my $png = "\x89PNG\r\n\x1a\n"
        . chunk('IHDR', pack('NNCCCCC', $w, $h, 8, 6, 0, 0, 0))   # 8-bit RGBA
        . chunk('IDAT', compress($raw))
        . chunk('IEND', '');
write_file($out, $png);
printf "converted %dx%d 32bpp ICO -> PNG (%d bytes) -> %s\n", $w, $h, length($png), $out;

sub chunk {
    my ($type, $data) = @_;
    return pack('N', length $data) . $type . $data . pack('N', crc32($type . $data));
}

sub write_file {
    my ($path, $data) = @_;
    open my $o, '>:raw', $path or die "$path: $!\n";
    print $o $data;
    close $o or die "$path: $!\n";
}
