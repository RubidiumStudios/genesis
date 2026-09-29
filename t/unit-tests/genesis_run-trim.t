#!perl
# run trims trailing whitespace from what it captures, which every caller
# reading one line of answer wants.  A caller reading output framed by byte
# counts, as git cat-file --batch frames it, needs every byte, so trim => 0
# hands the output back exactly.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis;

subtest 'trailing whitespace is trimmed unless trim is off' => sub {
	plan tests => 3;

	my $cmd = q{printf 'one\ntwo  \n\n'};
	is(scalar(run($cmd)), "one\ntwo", 'the default trims it');
	is(scalar(run({trim => 1}, $cmd)), "one\ntwo", 'and trim => 1 says so');
	is(scalar(run({trim => 0}, $cmd)), "one\ntwo  \n\n",
		'trim => 0 hands back every byte');
};

done_testing;
