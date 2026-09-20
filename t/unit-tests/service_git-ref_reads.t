#!/usr/bin/env perl
# What a ref read answers where git cannot resolve the ref.  The deployment
# manager records what sha('HEAD') hands back in the audit trail it writes
# after every deploy, so a read that folds git's own complaint into its answer
# writes that sentence into the slot a commit belongs in.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a ref git cannot resolve answers nothing at all' => sub {
	plan tests => 4;

	my $h   = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');

	is($git->sha('no-such-branch'), undef,
		'a name the repository does not carry answers undef');
	is($git->sha('no-such-branch', short => 1), undef,
		'and the abbreviated read answers undef as well');

	like($git->sha('HEAD'), qr/^[0-9a-f]{40}$/,
		'while a ref that does resolve still answers its own sha');
	like($git->sha('HEAD', short => 1), qr/^[0-9a-f]{4,40}$/,
		'and the abbreviated read still answers the short one');
};

done_testing;
