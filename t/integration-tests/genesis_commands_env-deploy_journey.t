#!/usr/bin/env perl
# Proves T325: new, pipeline-apply, propagate, deploy, walked as one journey,
# with the awaiting pipeline-apply refusal standing before the apply and gone
# after it.
#
# Every run passes restore => 0, because genesis new commits and the journey
# takes one snapshot of its own and asserts it at the end.  The snapshot is
# taken after that commit rather than before it, because genesis new moves
# HEAD on purpose and assert_w_restored reads HEAD as one of the five parts
# of working state.  What the snapshot covers is every command after the
# environment exists, which is the whole of the journey that promises to put
# the operator back where it found them.
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

subtest 'from genesis new to a deployed record' => sub {
	plan tests => 11;

	# No environment exists yet, which is where the journey starts, and the
	# director, the fake bosh, and the kit go in before anything runs,
	# because the deploy at the far end of it has to reach a director and
	# render a manifest.  The kit is committed, because the walk reads the
	# propagation set at each control commit and a commit carrying no kit
	# refuses by name.  Its new hook is what genesis new runs to write the
	# environment file, which is the hook fixture_bosh's own kit lacks.
	my $h = make_harness(envs => []);
	fixture_vault($h);
	fixture_bosh($h, envs => ['qa'], commit => 1, hooks => {new => <<'EOS'});
cat > "$GENESIS_ROOT/$GENESIS_ENVIRONMENT.yml" <<YAML
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env: $GENESIS_ENVIRONMENT
YAML
EOS
	stand_on($h, $h->control);

	my (undef, undef, $new) = run_genesis($h, {restore => 0}, 'new', 'qa');
	is($new, 0, 'genesis new added qa on control');
	push_from($h, 'a', $h->control);

	my $w = snapshot_w($h);

	my (undef, $err0, $early) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '-y', 'r');
	is($early, Genesis::Exit::DATAERR, 'a deploy before the apply is refused');
	# Read unfolded, because the refusal is folded to the column width set at
	# the top of this file and a phrase a row looks for can arrive with the
	# fold in the middle of it.  That is how the branch-class file reads this
	# same sentence, and the two rows are about one message.
	like(unfolded($err0), qr/awaiting pipeline-apply/,
		'as awaiting pipeline-apply');

	my (undef, undef, $apply) = run_genesis($h, {restore => 0},
		'pipeline-apply', '-y');
	is($apply, 0, 'pipeline-apply cut the init branch and wrote the record');
	ok(record_at($h, $h->applied_path), 'the applied record stands');

	my (undef, undef, $prop) = run_genesis($h, {restore => 0}, 'propagate', '-y');
	is($prop, 0, 'propagate delivered and published the seed');

	refresh($h, 'a', $h->control, $h->slug('qa'));
	is($h->git('a')->resolve_branch($h->slug('qa'), remote => 'origin')->{state},
		'in-sync', 'and qa/bosh is in-sync');

	my (undef, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '-y', 'r');
	is($exit, 0, 'the deploy proceeded')
		or diag("what the deploy said:\n$err");

	my $record = newest_record($h, $h->env_path('qa').'/deployments');
	is($record->{git}{control_commit}, harness_marker($h, $h->slug('qa')),
		"the record names the control commit the branch's marker carries");

	assert_w_restored($w, 'the whole journey');
	assert_snapshot_invariant($h, 'qa', name => 'the seeded branch mirrors control');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
