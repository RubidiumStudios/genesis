#!/usr/bin/env perl
# Proves T136: the propagate command takes no argument, declares --dry-run,
# -y, and --force and nothing else, and refuses --all.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the run takes no environment argument' => sub {
	# Three rows, and one more for the restoration the run asserts for
	# itself, which run_genesis makes unless a row turns it off.
	plan tests => 4;

	my $h = make_harness(envs => ['lab', 'qa']);
	fixture_applied($h, control => $h->git('a')->sha($h->control));

	# The record names the commit rather than the branch, because nothing
	# resolves a name written here and every staleness read behind it would
	# be answered from a string git never gave.
	my ($out, $err, $exit) = run_genesis($h, 'propagate', 'qa');
	is($exit, 2, 'an environment argument is a usage error');
	like($err, qr/propagate/, 'the usage error names the command');

	# Both streams, because the walk announces itself through info and
	# everything Genesis says about itself goes to standard error.
	unlike("$out$err", qr/Propagating from/, 'nothing was walked');
};

subtest 'the option table holds three options and no more' => sub {
	# Seven rows, and one more for the run's own restoration assertion.
	plan tests => 8;

	my $h = make_harness(envs => ['qa']);
	fixture_applied($h, control => $h->git('a')->sha($h->control));

	# The help screen is written to standard error, where everything
	# Genesis says about itself goes, so the listing comes back in the
	# second value rather than the first.
	my (undef, $help) = run_genesis($h, 'help', 'propagate');
	like($help, qr/--dry-run/, '--dry-run is declared');
	like($help, qr/(?:^|\s)-y\b|--yes/, '-y is declared');
	like($help, qr/--force/, '--force is declared');
	unlike($help, qr/--commit/, '--commit is gone');
	unlike($help, qr/--no-push/, '--no-push is gone');
	unlike($help, qr/--no-fetch/, '--no-fetch is gone');
	unlike($help, qr/--all/, '--all was never declared');
};

subtest 'an undeclared option is a usage error' => sub {
	# Two rows, and one more for each of the two runs' own restoration
	# assertions.
	plan tests => 4;

	my $h = make_harness(envs => ['qa']);
	fixture_applied($h, control => $h->git('a')->sha($h->control));

	my (undef, undef, $all_exit) = run_genesis($h, 'propagate', '--all');
	is($all_exit, 2, '--all is refused at exit 2');

	my (undef, undef, $commit_exit) =
		run_genesis($h, 'propagate', '--commit', 'deadbeef');
	is($commit_exit, 2, '--commit is refused at exit 2');
};

done_testing;
