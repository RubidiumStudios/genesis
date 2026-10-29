#!/usr/bin/env perl
# Proves T444: a redeploy stands only on a recorded deployed commit that is
# on the environment's deployment branch (D128).  Four repositories, one per
# state a flagged run is refused in: no record at all, a record naming no
# commit, a commit this clone holds on another branch only, and a commit this
# clone does not hold, which is what a pipeline task's single-branch clone
# sees of a commit deployed from the branch before the pipeline.  In each,
# --redeploy and --as-deployed are refused at CONFIG with nothing checked out
# and nothing deployed, and info with no flag still reads the tip.
#
# What the rows catch: the tip taken for a redeploy of an environment that
# has never deployed, which deploys content nobody has deployed yet; and the
# refusal decided by what the clone holds, which answered the held commit at
# CONFIG and the one it did not hold at DATAERR as a rewritten branch.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

sub reflog_count {
	my ($h) = @_;
	my ($out) = run({dir => $h->a}, 'git', 'reflog', '--format=%H');
	return scalar(grep {/\S/} split /\n/, $out // '');
}

# The environment on control and its init-only deployment branch, with the
# record left to the caller, which is the one thing the four states differ in.
sub repository {
	my ($record) = @_;
	my $h = make_harness(envs => ['qa'], type => 'bosh');
	my $prefix = $h->{root} ? "$h->{root}/" : '';

	my $control = commit_on_control($h,
		files   => {"${prefix}qa.yml" => <<'YAML'},
---
kit:
  name:     dev
  version:  latest
  features: []
genesis:
  env:      qa
params:
  marker: the-control-version
YAML
		message => 'the content on control',
		push    => 1,
	);
	init_branch($h, 'qa');
	my $commit = $record->($h, $control);
	fixture_bosh($h, hooks => {
		info => qq{grep '^  marker:' "\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml"\n},
	});
	stand_on($h, $h->control);
	return ($h, $commit);
}

sub refused {
	my ($name, $record) = @_;
	subtest $name => sub {
		my ($h, $commit) = repository($record);
		my $before = reflog_count($h);

		for my $flagged (['deploy', '--redeploy'], ['info', '--as-deployed']) {
			my ($out, $err, $exit) = run_genesis($h, 'qa', @$flagged);
			my $said = unfolded($out, $err);
			is($exit, Genesis::Exit::CONFIG, "$flagged->[1] is refused at CONFIG");
			like($said, qr/Refusing to target the deployed commit for qa\b/,
				'naming the environment');
			like($said, qr{\Qqa/bosh\E}, 'and the deployment branch');
			if ($commit) {
				like($said, qr/\Q@{[substr($commit, 0, 8)]}\E/, 'and the commit');
				like($said, qr{/secret/exodus/qa/bosh/deployments},
					'and the record it came from');
			}
			unlike($said, qr/\bbosh deploy\b/i, 'nothing was deployed');
		}
		is(reflog_count($h), $before, 'nothing was checked out');

		my ($out, $err, $exit) = run_genesis($h, 'qa', 'info');
		my $said = unfolded($out, $err);
		is($exit, 0, 'info with no flag runs');
		like($said, qr/marker:\s*the-control-version/, 'and reads the tip');
		like($said, qr{deployed commit \Q@{[substr($commit, 0, 7)]}\E\S* is not on \Qqa/bosh\E},
			'saying the deployed commit is not on the branch') if $commit;
		done_testing;
	};
}

refused('an environment with no record' => sub { undef });

refused('a record that names no commit' => sub {
	my ($h, $control) = @_;
	certify($h, 'qa', control_commit => $control);
	return undef;
});

refused('a commit held on another branch only' => sub {
	my ($h, $control) = @_;
	run({dir => $h->a}, 'git', 'branch', 'qa-old', $h->control);
	my $old = commit_on_control($h,
		branch  => 'qa-old',
		files   => {'ops/old.yml' => "---\nfrom: the old branch\n"},
		message => 'deployed from the old branch',
		push    => 1,
	);
	certify($h, 'qa', commit => $old, control_commit => $control);
	return $old;
});

refused('a commit this clone does not hold' => sub {
	my ($h, $control) = @_;
	my $gone = 'ba07e79921902dfa4076d8fe4f714b13b486235b';
	certify($h, 'qa', commit => $gone, control_commit => $control);
	return $gone;
});

done_testing;
