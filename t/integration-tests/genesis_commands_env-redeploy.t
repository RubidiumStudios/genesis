#!/usr/bin/env perl
# Proves T240: with a record naming a qa/bosh commit older than the tip,
# --redeploy checks that commit out detached inside the session, deploys it
# rather than the tip, writes a fresh record naming the same two hashes, and
# restores the operator's starting branch at finish.
#
# What the rows catch: an implementation that deployed the tip under the flag,
# which puts the coming content in the manifest; one that moved the certified
# commit on a redeploy, which the control-commit row catches and which would
# wake every dependent for content that never moved; one that overwrote the
# previous record rather than adding to the set, which the count row catches;
# and one that never told the operator it was redeploying something other than
# what they have on their branch.
#
# Most of this file was green when it was written, because the gate that
# switches the deploy onto the recorded commit landed a step above it, and it
# says so row by row rather than reading as a proof of what this step wrote.
# The exit row, the two marker rows, the two record rows, the count row, and
# the restoration row were all green on arrival, and each stands as a guard
# holding that behaviour still while the steps after this one change the
# deploy around it.  The one row that was red is the sentence row, which asks
# the run to say which commit it is redeploying, and the notice in the
# deploy's pre-flight is what turns it green.
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

subtest 'the redeploy deploys the recorded commit and not the tip' => sub {
	plan tests => 8;

	# The discriminator is a marker line in the environment file, read and
	# printed by the kit's blueprint hook on its way to writing a manifest,
	# which is how the deploy's own output names the version it rendered.
	# The manifest itself is the harness kit's fixed two lines, so a row
	# asking what BOSH received asks the hook that read the tree rather than
	# a manifest that says the same thing whichever commit it was rendered
	# from.
	my $deployed_env = <<'YAML';
---
kit:
  name:     dev
  version:  latest
  features: []
genesis:
  env:      qa
params:
  marker: the-deployed-version
YAML
	my $tip_env = <<'YAML';
---
kit:
  name:     dev
  version:  latest
  features: []
genesis:
  env:      qa
params:
  marker: the-coming-version
YAML

	my $h = make_harness(envs => ['qa'], type => 'bosh');

	my $control = commit_on_control($h,
		files   => {'qa.yml' => $deployed_env},
		message => 'the certified content',
		push    => 1,
	);
	init_branch($h, 'qa');
	my $deployed = deliver($h, 'qa', control => $control);
	certify($h, 'qa', commit => $deployed, control_commit => $control);

	my $later = commit_on_control($h,
		files   => {'qa.yml' => $tip_env},
		message => 'the undeployed content',
		push    => 1,
	);
	deliver($h, 'qa', control => $later);
	refresh($h, 'a');

	# The director, the bosh, and the kit a whole deploy needs, with a
	# blueprint hook that prints the marker of the tree it ran in.  The
	# builder's catch-up brings the operator's copy of the deployment branch
	# up to the delivery, which is what a pull would have done, and it runs
	# before the row stands anywhere.
	fixture_bosh($h,
		hooks => {
			blueprint =>
				qq{grep '^  marker:' "\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml" >&2\n}.
				qq{cat > manifest.yml <<'MANIFEST'\n---\nharness: deployed\nMANIFEST\n}.
				qq{echo manifest.yml\n},
		},
	);

	stand_on($h, $h->control);
	my $before = snapshot_w($h);

	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '--redeploy', '--no-propagate', '-y');

	is($exit, 0, 'the redeploy succeeded')
		or diag("what the redeploy said:\n$err");

	# Genesis prints its notices through the log, which is standard error, so
	# the sentence is read off both streams together rather than off standard
	# output alone.
	like("$out$err", qr/\Q$deployed\E/,
		'the run says which commit it is redeploying');

	like("$out$err", qr/marker:\s*the-deployed-version/,
		'BOSH received the content of the commit that was running');
	unlike("$out$err", qr/marker:\s*the-coming-version/,
		'BOSH did not receive the undeployed content');

	my $records = $h->env_path('qa') . '/deployments';
	is(scalar(@{record_keys($h, $records)}), 2,
		'a fresh record was written beside the first');

	my $newest = newest_record($h, $records);
	is($newest->{git}{commit}, $deployed,
		'the fresh record names the same deployed commit');
	is($newest->{git}{control_commit}, $control,
		'the certified commit did not move');

	assert_w_restored($before, 'finish restored the branch the operator started on');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
