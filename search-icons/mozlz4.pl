#!/usr/bin/perl
#
# mozlz4.pl - decompress and compress Mozilla's mozlz4 container.
#
# Firefox stores several profile files in this format, including
# search.json.mozlz4 (the search engine list), sessionstore-backups/*.jsonlz4
# and addonStartup.json.lz4. The container is:
#
#   bytes 0-7    magic "mozLz40\0"
#   bytes 8-11   uncompressed size, little-endian uint32
#   bytes 12-    a raw LZ4 block (no frame header, no checksum)
#
# This is a pure-Perl implementation because Compress::LZ4 is not in core and
# is often unavailable. The decompressor is a complete LZ4 block decoder. The
# compressor deliberately emits a valid all-literal ("stored") block rather
# than searching for matches: the output is a few hundred bytes larger than a
# real encoder would produce, which does not matter because Firefox rewrites
# the file properly the next time it saves.
#
# Usage:
#   perl mozlz4.pl -d IN.mozlz4 OUT.json
#   perl mozlz4.pl -c IN.json   OUT.mozlz4
#
use strict;
use warnings;

my ($mode, $in, $out) = @ARGV;
usage(2) unless defined $mode && defined $in && defined $out;

if    ($mode eq '-d' || $mode eq 'd' || $mode eq '--decompress') { do_decompress($in, $out) }
elsif ($mode eq '-c' || $mode eq 'c' || $mode eq '--compress')   { do_compress($in, $out) }
else                                                            { usage(2) }

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;
    return defined $data ? $data : '';
}

sub spew {
    my ($path, $data) = @_;
    open my $fh, '>:raw', $path or die "$path: $!\n";
    print $fh $data;
    close $fh or die "$path: $!\n";
}

# LZ4 block format: a sequence of (token, literals, offset, match) groups.
# Token high nibble = literal length, low nibble = match length - 4. A nibble
# of 15 means "read additional bytes, each 255 continuing the count".
sub do_decompress {
    my ($src_path, $dst_path) = @_;
    my $raw = slurp($src_path);

    die "$src_path: not a mozlz4 file (magic is not mozLz40)\n"
        unless length($raw) >= 12 && substr($raw, 0, 8) eq "mozLz40\0";

    my $expect = unpack('V', substr($raw, 8, 4));
    my $src    = substr($raw, 12);
    my $len    = length $src;
    my ($sp, $dst) = (0, '');

    while ($sp < $len) {
        my $token = ord substr($src, $sp++, 1);

        my $ll = $token >> 4;
        if ($ll == 15) {
            my $b;
            do { die "truncated literal length\n" if $sp >= $len;
                 $b = ord substr($src, $sp++, 1); $ll += $b } while ($b == 255);
        }
        $dst .= substr($src, $sp, $ll);
        $sp  += $ll;

        # The final sequence is literals only, with no match to follow.
        last if $sp >= $len;

        my $offset = unpack('v', substr($src, $sp, 2));
        $sp += 2;
        die "corrupt block: zero match offset\n" if $offset == 0;

        my $ml = $token & 0x0F;
        if ($ml == 15) {
            my $b;
            do { die "truncated match length\n" if $sp >= $len;
                 $b = ord substr($src, $sp++, 1); $ml += $b } while ($b == 255);
        }
        $ml += 4;   # minimum match is 4 bytes

        my $start = length($dst) - $offset;
        die "corrupt block: match offset points before start of output\n" if $start < 0;

        # Copy one byte at a time: matches are allowed to overlap the region
        # they are still producing, which is how LZ4 encodes runs.
        $dst .= substr($dst, $start++, 1) for 1 .. $ml;
    }

    warn "warning: header says $expect bytes, decoded " . length($dst) . "\n"
        if length($dst) != $expect;

    spew($dst_path, $dst);
    printf "decompressed %d bytes -> %s\n", length($dst), $dst_path;
}

sub do_compress {
    my ($src_path, $dst_path) = @_;
    my $data = slurp($src_path);
    my $n    = length $data;

    # One all-literal sequence. This satisfies the LZ4 end-of-block rules
    # trivially, since there is no match and the block is entirely literals.
    my $body = '';
    my $ll   = $n;
    if ($ll < 15) {
        $body .= chr($ll << 4);
    }
    else {
        $body .= chr(0xF0);
        my $rest = $ll - 15;
        while ($rest >= 255) { $body .= chr(255); $rest -= 255 }
        $body .= chr($rest);
    }
    $body .= $data;

    spew($dst_path, "mozLz40\0" . pack('V', $n) . $body);
    printf "compressed %d bytes -> %s (%d bytes, stored)\n",
        $n, $dst_path, length($body) + 12;
}

sub usage {
    my ($code) = @_;
    print <<'USAGE';
mozlz4.pl - decompress and compress Mozilla's mozlz4 container.

  perl mozlz4.pl -d IN.mozlz4 OUT.json     decompress
  perl mozlz4.pl -c IN.json   OUT.mozlz4   compress

Compression emits a valid all-literal LZ4 block rather than a real encode, so
the output is slightly larger than Firefox's own. Firefox reads it correctly
and re-compresses properly on its next save.
USAGE
    exit $code;
}
