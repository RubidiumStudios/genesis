#!/usr/bin/env perl
# Proves T160, T161, and T162: the triggering and non-triggering split, the
# overlap that ignores non-triggering paths, the embedded genesis as the
# eighth kind, and the set read from the delivered commit's own tree.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/run/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# The environment file the rows below commit, written by hand because
# write_env_file renders a hash of scalars and flat lists and no deeper,
# and a reaction is a list of maps.  The reaction is declared so that
# bin/pre-deploy is a path of qa's set, since a script nothing declares is
# in no kind at all and would neither route nor travel.
sub qa_file {
	my ($leaf) = @_;
	return join("\n",
		'---',
		'kit:',
		'  name:    dev',
		'  version: latest',
		'  features: []',
		'genesis:',
		'  env: qa',
		'  reactions:',
		'    pre-deploy:',
		'      - script: pre-deploy',
		(defined $leaf ? "leaf: $leaf" : ()),
		'');
}

# lab's file, which declares the same reaction.  A script an environment
# declares as a reaction is non-triggering content of that environment's set,
# which is what the overlap row below turns on.
sub lab_reacting {
	return join("\n",
		'---',
		'kit:',
		'  name:    dev',
		'  version: latest',
		'  features: []',
		'genesis:',
		'  env: lab',
		'  reactions:',
		'    pre-deploy:',
		'      - script: pre-deploy',
		'');
}

# qa's file, which tracks that same script instead of declaring it.  A tracked
# path is triggering, because an operator names one precisely because the
# deployment needs it, so the one file is non-triggering for lab and
# triggering for qa.
sub qa_tracking {
	return join("\n",
		'---',
		'kit:',
		'  name:    dev',
		'  version: latest',
		'  features: []',
		'genesis:',
		'  env: qa',
		'  pipeline:',
		'    prior_env: lab',
		'    track_additional_files:',
		'    - bin/pre-deploy',
		'');
}

subtest 'a non-triggering change is routed nowhere and arrives later' => sub {
	# Five rather than four, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	plan tests => 5;

	my $h = ready_harness(kit => 'omega-v2.7.0');

	# The declaration and the script arrive together, so every commit below
	# this one is read against an environment that names the reaction.
	commit_on_control($h,
		files => {
			'qa.yml'         => qa_file(),
			'bin/pre-deploy' => "#!/bin/sh\necho pre\n",
		},
		message => 'Declare a pre-deploy reaction',
		push    => 1,
	);

	# The configuration is changed through the writer that knows the schema,
	# because an undeclared key is refused by name at configuration load and
	# a hand-written file would be a repository no command can read.  The
	# write is left uncommitted so that both non-triggering paths travel in
	# the one commit below.
	my $script = "#!/bin/sh\necho pre, and then some\n";
	set_repo_config($h, 'pipeline.name', 'touched', commit => 0);
	commit_on_control($h,
		files => {
			'.genesis/config' => slurp($h->a . '/.genesis/config'),
			'bin/pre-deploy'  => $script,
		},
		message => 'Adjust the config and a reaction script',
		push    => 1,
	);
	my $triggering = commit_on_control($h,
		files   => {'qa.yml' => qa_file(2)},
		message => 'Tune qa',
		push    => 1,
	);
	certify($h, 'lab', control_commit => $triggering);

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');
	unlike($err, qr/Adjust the config/,
		'the non-triggering commit records no per-commit outcome');

	is(harness_marker($h, $h->slug('qa')), $triggering,
		'the marker names the triggering commit alone');

	# The two paths were on the branch before this run, so what proves they
	# arrived is what they now hold rather than that they are there at all.
	my $ref = 'refs/remotes/origin/' . $h->slug('qa');
	like(blob_at($h->a, $ref, '.genesis/config'), qr/touched/,
		'the config arrived in the next delivery\'s snapshot');
	is(blob_at($h->a, $ref, 'bin/pre-deploy'), $script,
		'the reaction script arrived with it');
};

subtest 'non-triggering paths add nothing to the overlap' => sub {
	plan tests => 3;

	# lab comes before qa, so lab's undeployed set is what may hold a commit
	# for qa, and the row turns on one path being in both environments' sets
	# with a different mark in each.
	my $h = ready_harness(kit => 'omega-v2.7.0', chained => 1);
	commit_on_control($h,
		files => {
			'lab.yml'        => lab_reacting(),
			'qa.yml'         => qa_tracking(),
			'bin/pre-deploy' => "#!/bin/sh\necho pre\n",
		},
		message => 'Declare the shared reaction script',
		push    => 1,
	);

	# lab has not deployed this change to the script, and the script is a
	# reaction of lab's, so it is not content lab has to prove before qa may
	# have it.  Were it counted, qa would be held on the commit that touched
	# it.
	my $touched = commit_on_control($h,
		files   => {'bin/pre-deploy' => "#!/bin/sh\necho pre, and then some\n"},
		message => 'Adjust the shared reaction script',
		push    => 1,
	);

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');
	is(harness_marker($h, $h->slug('qa')), $touched,
		'qa received the script it tracks despite lab not having deployed it');
	unlike($err, qr/held by .?lab/, 'no hold was recorded for qa');
};

subtest 'the embedded genesis is triggering content of its own' => sub {
	plan tests => 2;

	my $h = ready_harness(kit => 'omega-v2.7.0');
	my $embedded = commit_on_control($h,
		files   => {'.genesis/bin/genesis' => "#!/bin/sh\n# v3.2.1\n"},
		message => 'Embed a newer genesis',
		push    => 1,
	);
	certify($h, 'lab', control_commit => $embedded);

	run_genesis($h, {answers => ['y']}, 'propagate');
	is(harness_marker($h, $h->slug('qa')), $embedded,
		'the embedded genesis was delivered on its own');
};

subtest 'a restructure reads each commit\'s own tree' => sub {
	# Five: three assertions and the restoration one each of the two runs
	# makes.  The second run starts inside bosh/, because that is where an
	# operator stands after the restructure and it is the one directory that
	# checking out a pre-restructure deployment branch takes away underneath
	# them.  What the session does about that is proved in
	# t/unit-tests/service_git_session-lifecycle.t.
	plan tests => 5;

	my $h = ready_harness(kit => 'omega-v2.7.0');
	my $before = commit_on_control($h,
		files   => {'qa.yml' => qa_file(4)},
		message => 'Tune qa at the root',
		push    => 1,
	);
	certify($h, 'lab', control_commit => $before);
	run_genesis($h, {answers => ['y']}, 'propagate');
	certify($h, 'qa', control_commit => $before);

	# Everything control holds moves under the new root, the kit included,
	# because a deployment root without its kit is a set the reader refuses
	# to answer.  The paths are taken from the tree rather than listed here,
	# so the move carries whatever the harness seeded.
	my $held = $h->files_at($h->control, copy => 'a');
	my %moved = map {($_ => undef, "bosh/$_" => $held->{$_})} keys %$held;
	my $restructure = commit_on_control($h,
		files   => \%moved,
		message => 'Move the deployment root under bosh/',
		push    => 1,
	);
	certify($h, 'lab', control_commit => $restructure);

	run_genesis($h, {answers => ['y'], dir => 'bosh'}, 'propagate');

	my @files = @{tree_of($h->a, 'refs/remotes/origin/'.$h->slug('qa'))};
	ok(in_set('bosh/qa.yml', @files), 'the moved set arrived');
	ok(!in_set('qa.yml', @files),
		'the root-level file fell out with the mirror');
	is(harness_marker($h, $h->slug('qa')), $restructure,
		'the restructure carries its own marker');
};

done_testing;
