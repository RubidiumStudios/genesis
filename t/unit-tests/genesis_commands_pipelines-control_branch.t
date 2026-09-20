#!perl
#
# The control branch is a name the repository chooses, not a constant.
# It is declared at pipeline.source_control.control_branch and read back
# through Genesis::Top::control_branch, so a repository that calls its
# control branch anything other than the schema default must still be
# understood by the commands that work from it.
#
# Every row here runs against a repository whose control branch is named
# `trunk`, which is deliberately not the default, so a reader that fell
# back to the constant answers `control` and is caught.
#
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;

provide_rc();

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

use_ok 'Genesis::Commands::Pipelines';

# No vault: every row here is answered before a command reaches one.
my $h = make_harness(envs => ['qa'], control => 'trunk', vault => 0);

# Somewhere that is neither the configured control branch nor the
# constant, so a refusal has to name one of the two and cannot name both.
Harness::Propagation::run(
	{dir => $h->a, onfailure => 'Failed to cut the off-branch'},
	'git', 'checkout', '-q', '-b', 'elsewhere');

subtest 'propagate switches to the configured name and comes back' => sub {
	# D65 took the off-control refusal away, so what this row used to read
	# out of a refusal it now reads out of the switch.  A run started on
	# `elsewhere` stands itself on trunk, and a reader that fell back to the
	# schema default would look for a branch called `control`, find it
	# neither here nor on the remote, and say so by name.
	plan tests => 3;

	my $w = snapshot_w($h);
	my (undef, $err) = $h->run_genesis({restore => 0}, 'propagate');

	unlike $err, qr/must be run from/,
		'standing off the control branch is a refusal no longer';
	unlike $err, qr/control branch control/,
		'the switch read the branch the repository declared, not the default';
	assert_w_restored($w, 'the operator is back on the branch they ran from');
};

subtest 'pipeline-status resolves the configured branch head' => sub {
	plan tests => 2;

	# A repository of its own, because the read model reads the applied
	# record and every environment's certified commit, and the harness above
	# has no vault for either.  Its control branch is named the same way, so
	# the row still catches a reader that fell back to the constant.
	my $hv = make_harness(envs => ['qa'], control => 'trunk',
		kit => 'omega-v2.7.0');
	init_branch($hv, 'qa');
	refresh($hv, 'a');

	# There is no branch called `control` in this repository, so the header
	# says outright which of the two the reader took.
	my ($out) = $hv->run_genesis({restore => 0}, 'pipeline-status');
	like $out, qr/control:\s*trunk\@/,
		'the header names the branch the repository declared';
	my ($head) = Harness::Propagation::run(
		{dir => $hv->a}, 'git', 'rev-parse', '--short', 'trunk');
	chomp $head;
	like $out, qr/\Q$head\E/,
		"the header shows trunk's head";
};

subtest 'the bare run measures every read against the configured branch' => sub {
	# D36 retired the <env> argument and the cascade it scoped, so a run
	# resolves no propagation base any more and the marker warnings that
	# used to prove where each base came from are unreachable from here.
	# What is left to prove, and what this file is about, is that the whole
	# run is measured against the branch the configuration names rather
	# than against the schema default: the topology is read from trunk, the
	# source commit is trunk's own tip, and the branch check compares the
	# run against trunk and so never fires.
	plan tests => 4;

	my $c = make_harness(envs => ['qa', 'prod'], control => 'trunk',
		kit => 'omega-v2.7.0');
	$c->write_env_file('prod', pipeline => {prior_env => 'qa'});

	# The env file is committed on trunk and the run reads trunk against the
	# remote before it reads anything else, so the commit is published here.
	# An unpushed control refuses the run before any of this is reached.
	push_from($c, 'a', 'trunk');
	stand_on($c, 'trunk');

	my $short = $c->git('a')->sha('trunk', short => 1);

	# The deployment branches these environments would have are absent,
	# because only pipeline-apply cuts one, and the walk says so and
	# carries on rather than refusing.  That is what lets the run reach the
	# walk here with no branch fixture at all.
	my (undef, $err) = $c->run_genesis({restore => 0},
		'propagate', '--dry-run');

	unlike $err, qr/Propagating from control \@/,
		'the run named no branch the schema default would have named';
	like $err, qr/Propagating from trunk \@ \Q$short\E/,
		'and sourced the commit the configured branch stands on';
	like $err, qr/qa: held, awaiting.*prod: held, awaiting/s,
		'the walk covered both environments, in the order the DAG gives them';
	unlike $err, qr/must be run from/,
		'and the branch check was measured against trunk, not the default';
};

done_testing;
