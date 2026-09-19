#!perl
use strict;
use warnings;
use utf8;

# The child has no terminal, so nothing stops a deploy to ask a
# propagation question and the publish never shows its confirmation.
# Proves the half of T251 and T331 a whole run can show; the terminal
# half is in t/unit-tests/genesis_commands_env-child_stdin.t.
#
# The fixture stands a director, a bosh, and a kit up before the branches
# are cut, for the reason Task 14.6 recorded against the same rows.  A
# harness that stands none of them up deploys nothing, and a deploy that
# never succeeds hands off to no child at all, so every row below would
# read a silence it had built itself.  Every environment is delivered at
# the seeded tip as well, because the kit is a kind of the propagation set
# and a branch left at its init commit gives the walk a commit whose tree
# names a kit nothing carries.  The commit the child carries downstream is
# laid afterwards and delivered to qa alone, which is the cascade in
# miniature.

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;

plan tests => 2;

subtest 'the child asks nothing and finishes' => sub {
	plan tests => 6;

	my $h = make_harness(envs => ['qa', 'prod'], provider => 'manual');
	fixture_vault($h);
	# The kit is committed on control rather than left untracked, so the
	# commits the walk routes carry the kit each environment file names.
	fixture_bosh($h, commit => 1, catch_up => 0);
	write_env_file($h, 'prod', genesis => {pipeline => {prior_env => 'qa'}});
	push_from($h, 'a', $h->control);
	my $seeded = $h->git('a')->sha('HEAD');
	fixture_applied($h, control => $seeded);
	fixture_pipeline_record($h, 'qa', dependencies => [], discovery => 'complete');
	fixture_pipeline_record($h, 'prod', dependencies => ['qa'], discovery => 'complete');
	init_branch($h, $_) for qw/qa prod/;
	deliver($h, $_, control => $seeded) for qw/qa prod/;
	# The dependencies each environment last read, so the deploy does not
	# open on a stale-pipeline warning about a shape nothing changed.
	certify($h, 'qa', control_commit => $seeded, dependencies_read => []);
	certify($h, 'prod', control_commit => $seeded, dependencies_read => ['qa']);

	# One control commit both environments are due, delivered to qa alone,
	# so the deploy under test certifies it and the child has exactly one
	# commit to carry to prod.
	write_env_file($h, 'qa', params => {n => 2}, commit => 0);
	write_env_file($h, 'prod', genesis => {pipeline => {prior_env => 'qa'}},
		params => {n => 2}, commit => 0);
	my $control = commit_on_control($h, push => 1,
		message => 'A change both environments are due',
		files   => {map {("$_.yml" => slurp($h->a . "/$_.yml"))} qw/qa prod/});
	deliver($h, 'qa', control => $control);
	refresh($h, 'a', $h->control, map {$h->slug($_)} qw/qa prod/);

	child_recorder($h);
	stand_on($h, $h->control);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '-y');
	is($exit, 0, 'the deploy command succeeded');

	my ($child) = child_runs($h);
	ok(!$child->{stdin_is_tty}, 'the child had no terminal on standard input');
	# The row that reads the redirect rather than the absence of a terminal.
	# No command this suite spawns has a terminal whichever way it was
	# started, so the row above would stay green if the spawn handed its own
	# standard input down; this one would not.
	ok($child->{stdin_is_null}, 'the child read from /dev/null');
	is($child->{exit}, 0, 'the child proceeded and ran to completion');
	# The product's own wording, from lib/Genesis/CI/Publish.pm.
	unlike($out.$err, qr/Publish these branches\?/,
		'no confirmation was printed while the child ran');
	like($out.$err, qr/\bprod\b.*\bpropagated\b/,
		'the delta the operator would have been shown went to the log');
};

subtest 'the child publishes one branch at a time' => sub {
	plan tests => 8;

	my $h = make_harness(envs => ['qa', 'prod', 'stage'], provider => 'manual');
	fixture_vault($h);
	fixture_bosh($h, commit => 1, catch_up => 0);
	write_env_file($h, $_, genesis => {pipeline => {prior_env => 'qa'}})
		for qw/prod stage/;
	push_from($h, 'a', $h->control);
	my $seeded = $h->git('a')->sha('HEAD');
	fixture_applied($h, control => $seeded);
	fixture_pipeline_record($h, 'qa', dependencies => [], discovery => 'complete');
	fixture_pipeline_record($h, $_, dependencies => ['qa'], discovery => 'complete')
		for qw/prod stage/;
	init_branch($h, $_) for qw/qa prod stage/;
	deliver($h, $_, control => $seeded) for qw/qa prod stage/;
	certify($h, 'qa', control_commit => $seeded, dependencies_read => []);
	certify($h, $_, control_commit => $seeded, dependencies_read => ['qa'])
		for qw/prod stage/;

	# One control commit all three environments are due, so the deploy
	# leaves the child two branches to carry it to rather than one.
	write_env_file($h, 'qa', params => {n => 2}, commit => 0);
	write_env_file($h, $_, genesis => {pipeline => {prior_env => 'qa'}},
		params => {n => 2}, commit => 0) for qw/prod stage/;
	my $control = commit_on_control($h, push => 1,
		message => 'A change every environment is due',
		files   => {map {("$_.yml" => slurp($h->a . "/$_.yml"))}
			qw/qa prod stage/});
	deliver($h, 'qa', control => $control);
	refresh($h, 'a', $h->control, map {$h->slug($_)} qw/qa prod stage/);

	child_recorder($h);
	stand_on($h, $h->control);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'qa', 'deploy', '-y');
	is($exit, 0, 'the deploy command succeeded');

	# Service::Git::push runs _push_one for each ref it is handed, and the
	# publish prints one line per branch, so two lines is what one branch at
	# a time looks like from outside the process.
	my $report = $out.$err;
	for my $env (qw/prod stage/) {
		my $branch = $h->slug($env);
		like($report, qr/\Q$branch\E: published/,
			"$env was published with a push of its own");
	}
	unlike($report, qr/Publish these branches\?/,
		'and neither push was preceded by a question');

	refresh($h, 'a', $h->slug($_)) for qw/prod stage/;
	for my $env (qw/prod stage/) {
		is(harness_marker($h, 'origin/'.$h->slug($env)), $control,
			"$env carries the marker naming the certified commit");
		assert_snapshot_invariant($h, $env,
			name => "$env mirrors control over its propagation set");
	}
};
