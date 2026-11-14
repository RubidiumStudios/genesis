#!/usr/bin/env perl
# Proves T495's pipeline half: a pipeline is built and propagated with no
# director to reach (D165).
#
# A kit's blueprint says which files the merge will read, which is static,
# so it needs no cloud config and no director unless the kit declares that
# it does.  pipeline-apply, propagate and pipeline-status run the blueprint
# only to learn a kit's files, so all three finish for environments whose
# director nobody has deployed yet, which is how a pipeline gets built
# before its first director exists.
#
# The environments here name a director that has no record anywhere, and the
# bosh on the path writes down every call it is given and fails it.  The
# rows read two things off each run: that it finished, and that the bosh was
# never called.
#
# The kit is one that declares a cloud config for its blueprint, which is the
# harder case: the three commands run the blueprint without fetching what it
# declares, because they want the kit's file list and not a manifest.
#
# The last row is what keeps the others honest.  In the same repository, a
# command that does build a manifest is refused and names the director, so
# the director really is out of reach and the first rows pass for the reason
# they give.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{NOCOLOR} = 1;

# lab, then qa following it, on a kit with a blueprint, both naming a
# director nothing has ever deployed, with a bosh that records its calls.
sub directorless {
	my $h = make_harness(envs => ['lab', 'qa'], chained => 1,
		provider => 'manual', github => 1, kit => 'omega-v2.7.0');

	for my $env (qw/lab qa/) {
		put_file($h->a."/$env.yml",
			slurp($h->a."/$env.yml") =~ s/^genesis:\n/genesis:\n  bosh_env: ghost-director\n/mr);
	}
	run({dir => $h->a}, 'git', 'add', '-A');
	run({dir => $h->a}, 'git', 'commit', '-qm', 'name a director that does not exist');
	push_from($h, 'a', $h->control);

	my $log  = "$h->{tmp}/bosh-calls.log";
	my $bosh = "$h->{tmp}/recording-bosh";
	put_file($bosh, 0755, "#!/bin/sh\necho \"\$*\" >> '$log'\nexit 1\n");
	return ($h, $bosh, sub { -f $log ? [grep {length} split /\n/, slurp($log)] : [] });
}

subtest 'apply, propagate and status finish, and never call bosh' => sub {
	# Nine rows, and one for each of the three runs' own restoration
	# assertions.
	plan tests => 12;

	my ($h, $bosh, $bosh_calls) = directorless();
	local $ENV{GENESIS_BOSH_COMMAND} = $bosh;

	like(slurp($h->a.'/dev/kit.yml'), qr/^required_configs:\n\s+cloud:\n\s+- blueprint$/m,
		'the kit declares a cloud config for its blueprint');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'pipeline-apply finishes') or diag("what it said:\n$out$err");
	like($out.$err, qr/recorded lab with/, 'having run the blueprint for each environment');
	is_deeply($bosh_calls->(), [], 'and bosh was never called');

	($out, $err, $exit) = run_genesis($h, 'propagate');
	is($exit, 0, 'propagate finishes') or diag("what it said:\n$out$err");
	like($out.$err, qr/lab: propagated/, 'having delivered to the first environment');
	is_deeply($bosh_calls->(), [], 'and bosh was never called');

	($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	is($exit, 0, 'pipeline-status finishes') or diag("what it said:\n$out$err");
	is_deeply($bosh_calls->(), [], 'and bosh was never called');
};

subtest 'a command that builds a manifest is refused, and names the director' => sub {
	# Three rows, and one for the run's own restoration assertion.
	plan tests => 4;

	my ($h, $bosh, $bosh_calls) = directorless();
	local $ENV{GENESIS_BOSH_COMMAND} = $bosh;

	my ($out, $err, $exit) = run_genesis($h, 'lab', 'manifest');
	isnt($exit, 0, 'genesis lab manifest does not finish') or diag("what it said:\n$out$err");
	like(unfolded($out, $err), qr/Could not find BOSH director ghost-director/,
		'and says it could not find the director the environment names')
		or diag("what it said:\n$out$err");
	is_deeply($bosh_calls->(), [], 'without a bosh call, there being no director to call');
};

done_testing;
