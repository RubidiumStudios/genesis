#!/usr/bin/env perl
# Proves T522's last part: every warning the pipeline commands print goes
# out as a paragraph, through the one sub that asks for that (D186).  A
# warning written straight to the logger would sit hard against the report's
# lines again, so the source is what is read.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

my $file = 'lib/Genesis/Commands/Pipelines.pm';
open my $fh, '<', $file or die "Could not read $file: $!";
my @lines = <$fh>;
close $fh;

my ($from) = grep {$lines[$_] =~ /^sub _caution\b/} 0..$#lines;
ok(defined $from, 'the module has a sub that prints a warning as a paragraph')
	or BAIL_OUT('nothing to read the other rows against');
my ($to) = grep {$_ > $from && $lines[$_] =~ /^}/} 0..$#lines;

like(join('', @lines[$from..$to]), qr/warning\(\s*\{[^}]*paragraph\s*=>\s*1/,
	'which asks the logger for one');

my @direct = map {sprintf('%d: %s', $_ + 1, $lines[$_] =~ s/^\s+|\s+$//gr)}
	grep {($_ < $from || $_ > $to) && $lines[$_] =~ /(?<![\w>:])warning\(/ && $lines[$_] !~ /^\s*#/}
	0..$#lines;
is_deeply(\@direct, [], 'and no other line of the module calls warning itself');

done_testing;
