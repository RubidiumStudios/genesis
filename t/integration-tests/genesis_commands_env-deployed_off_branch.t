#!/usr/bin/env perl
# Proves T430: a deployed commit that is not on the environment's deployment
# branch, the last deploy having run before the pipeline from a branch of
# its own, is never checked out.  A run that takes the deployed commit by
# default reads the branch as it stands and says why; a run that asked for
# it by flag is refused at CONFIG, naming the commit and the branch.
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

subtest 'a deployed commit from another branch is never checked out' => sub {
	# Seven rows, and one more for each of the two runs' restoration
	# assertions.
	plan tests => 9;

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

	# The per-environment branch the last deploy ran from, before the
	# pipeline: its tree carries a configuration this Genesis refuses, so a
	# run that stood on it would fail rather than report.
	my $config = helper::get_file($h->a . "/${prefix}.genesis/config");
	run({dir => $h->a}, 'git', 'branch', 'qa-old', $h->control);
	my $old = commit_on_control($h,
		branch  => 'qa-old',
		files   => {"${prefix}.genesis/config" => "${config}ci:\n  enabled: true\n"},
		message => 'deployed from the old branch',
		push    => 1,
	);
	stand_on($h, $h->control);

	init_branch($h, 'qa');
	certify($h, 'qa', commit => $old, control_commit => $control);
	fixture_bosh($h, hooks => {
		info => qq{grep '^  marker:' "\$GENESIS_ROOT/\$GENESIS_ENVIRONMENT.yml"\n},
	});
	stand_on($h, $h->control);

	my $short  = substr($old, 0, 7);
	my $before = reflog_count($h);
	my ($out, $err, $exit) = run_genesis($h, 'qa', 'info');
	my $said = unfolded($out, $err);

	is($exit, 0, 'info runs');
	like($said, qr{deployed commit \Q$short\E\S* is not on \Qqa/bosh\E},
		'it says the deployed commit is not on the deployment branch');
	like($said, qr/marker:\s*the-control-version/,
		'and reads the tree it stands on');
	is(reflog_count($h), $before, 'nothing was checked out');

	($out, $err, $exit) = run_genesis($h, 'qa', 'info', '--as-deployed');
	$said = unfolded($out, $err);
	is($exit, Genesis::Exit::CONFIG, 'asked for by flag, it is refused at CONFIG');
	like($said, qr/\Q$short\E/, 'naming the commit');
	like($said, qr{\Qqa/bosh\E}, 'and the branch it is not on');
};

done_testing;
