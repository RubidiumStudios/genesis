#!/usr/bin/env perl
# Proves T228, the sweep of the retired routing sense of "entry point" from
# the files this step touches.
#
# T210 and T238 belong in this file and are not in it yet.  Both run a deploy
# to its end, and no deploy in this suite reaches its end: the harness has no
# BOSH double, so `with_bosh` refuses at the director, and the deploy switches
# to a branch named for the environment alone while every branch the harness
# builds is named <env>/<type>, which git will not let stand beside it.  The
# second is this step's own to fix and a later task fixes it.  The first is a
# harness gap, and it is named in the report of the task that wrote this file.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the retired routing sense of entry point is gone' => sub {
	plan tests => 1;

	# The paths are read under the checkout root and reported relative to
	# it, because a row that ran before this one may have left the process
	# standing somewhere else and the name a reader needs is the short one.
	my @files = qw(
		lib/Genesis/Commands/Env.pm
		lib/Genesis/Commands/Env.pod
		lib/Genesis/Env.pm
		lib/Genesis/Env.pod
	);
	my @hits;
	for my $file (@files) {
		my @lines = split(/\n/, slurp("$helper::TOPDIR/$file"));
		for my $i (0 .. $#lines) {
			push @hits, sprintf('%s:%d', $file, $i + 1)
				if $lines[$i] =~ /entry[- ]point/i;
		}
	}
	is_deeply(\@hits, [], 'no file this step touches carries the retired term');
};

done_testing;
