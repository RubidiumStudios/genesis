#!/usr/bin/env perl
# Proves T247: a secrets command that rotates against the branch tip while the
# certified commit is older warns that the version it served is not the
# certified one and names the risk of a redeploy.
#
# What the rows catch: an implementation that warned on every run, which the
# --as-deployed row catches by asking for silence where the run served exactly
# what the environment is certified at; one that never warned, which the two
# message rows catch; and one that warned by comparing the deployed commit
# against the certified commit, which D87 keeps apart and which would warn on
# every environment ever deployed, including the --as-deployed run.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'rotating against the tip says which version it served' => sub {
	plan tests => 7;

	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');

	my $control = commit_on_control($h,
		files   => {'ops/base.yml' => "---\nversion: one\n"},
		message => 'the certified content',
		push    => 1,
	);
	init_branch($h, 'qa');
	my $deployed = deliver($h, 'qa', control => $control);
	certify($h, 'qa', commit => $deployed, control_commit => $control);

	my $later = commit_on_control($h,
		files   => {'ops/base.yml' => "---\nversion: two\n"},
		message => 'the coming version',
		push    => 1,
	);
	deliver($h, 'qa', control => $later);
	refresh($h, 'a');

	# Every delivery above is published from the teammate's copy, so the
	# operator's own clone still holds the deployment branch where the apply
	# cut it, at a root commit that carries no marker at all.  The builder's
	# catch-up brings it up to the delivery, which is what a pull would have
	# done, and without it the tip this row is about is a commit that was
	# never delivered anything.  The kit is the one the harness installed,
	# so the builder is told to leave it alone, and it runs before the row
	# stands anywhere.
	fixture_bosh($h, kit => 0);
	stand_on($h, $h->control);

	# The spaces in the phrase are read as any run of whitespace, because
	# Genesis wraps its warnings at the terminal width and the two commits it
	# names are forty characters each, so where the break falls depends on
	# the shas the fixture happened to write.  The row is about the words the
	# command says and not about where the renderer wrapped them.
	my ($out, $err, $exit) = run_genesis($h, 'qa', 'rotate-secrets', '-y');
	is($exit, 0, 'the rotation succeeded');
	like($out.$err, qr/not\s+the\s+certified/i,
		'the command says the version it served is not the certified one');
	like($out.$err, qr/redeploy/i, 'the warning names what a redeploy would do');

	# The as-deployed run serves the certified version, so it says nothing.
	my ($clean_out, $clean_err, $clean_exit) =
		run_genesis($h, 'qa', 'rotate-secrets', '--as-deployed', '-y');
	is($clean_exit, 0, 'the as-deployed rotation succeeded');
	unlike($clean_out.$clean_err, qr/not\s+the\s+certified/i,
		'serving the running version raises nothing');
};

done_testing;
