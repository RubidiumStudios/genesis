#!/usr/bin/env perl
# Proves T433: the one-line reason the walk gives for an error is the error's
# first paragraph, whole, joined to one line, with no [FATAL] label, even
# where bail has wrapped it.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use Genesis;
use Genesis::CI::Walk;

$ENV{NOCOLOR} = 1;
# Narrow, so bail wraps the first sentence across lines.
$ENV{GENESIS_OUTPUT_COLUMNS} = 60;

my $sentence = 'lmelt-vsphere-canwest-1-mgmt declares the kit vault/2.0.1, '.
	'which the commit 0a0f983f96 does not carry.';

eval {
	bail("%s\n\nA deployment branch carries the kit it deploys, so the ".
		"propagation set cannot be read at a commit that holds none.",
		$sentence);
};
my $err = $@;
like($err, qr/\n.*\n/s, 'bail wrapped the error across lines');

is(Genesis::CI::Walk::_load_error($err), $sentence,
	'the reason is the first paragraph, whole, on one line, with no label');

is(Genesis::CI::Walk::_load_error("a short reason\n"), 'a short reason',
	'a one-line error is its own reason');
is(Genesis::CI::Walk::_load_error(undef), 'unknown reason',
	'and no error at all is an unknown reason');

done_testing;
