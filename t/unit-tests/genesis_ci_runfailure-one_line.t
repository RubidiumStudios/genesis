#!/usr/bin/env perl
# The one line a failure's reason comes back as, and the width a caller may
# ask it to fit.  A reason printed inside a table has a column to sit in and
# a long one wraps the table apart, so the caller that has a width says so
# and every caller printing a line of its own gets the sentence whole.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use Genesis::CI::RunFailure qw/one_line/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Longer than any width a row here asks for, and one sentence, so that what
# a trim takes off is the tail of a reason rather than a second line the
# reader would have lost anyway.
my $LONG = 'the environment file names a kit this repository does not hold, '
         . 'and nothing under .genesis/kits answers to that name either';

subtest 'a reason is cut at the width, with the cut marked' => sub {
	plan tests => 3;

	my $cut = one_line($LONG, width => 80);

	isnt($cut, $LONG, 'a reason longer than the width does not come back whole');
	is(length($cut), 83, 'it is the width and the three characters that mark the cut');
	is($cut, substr($LONG, 0, 80) . '...', 'and the cut is where the width falls');
};

subtest 'a caller that names no width is given the sentence whole' => sub {
	plan tests => 2;

	is(one_line($LONG), $LONG, 'the reason comes back untrimmed');
	is(one_line($LONG, width => 400), $LONG,
		'and a width nothing reaches leaves it alone too');
};

done_testing;
