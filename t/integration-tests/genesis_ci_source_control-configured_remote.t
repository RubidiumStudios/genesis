#!/usr/bin/env perl
# Proves T57's "never the first entry of git remote" for the commands that
# use the remote, not only for the value describe reports: with a second
# remote that git lists ahead of origin, propagate refreshes from, checks
# control against, and publishes to the remote pipeline.source_control.remote
# resolves to, and pipeline-status reads the same one (D29).
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# mirror sorts ahead of origin, as dev does, and stays empty: a command that
# took the first remote git lists would find no control there.
sub two_remotes {
	my $h = ready_harness(delivered => ['qa'], certified => ['lab', 'qa'],
		kit => 'omega-v2.7.0', source_control => {remote => 'origin'});
	my $mirror = second_remote($h, name => 'mirror');
	return ($h, $mirror);
}

subtest 'propagate uses the configured remote throughout' => sub {
	# Four rows, and the run's own restoration assertion.
	plan tests => 5;

	my ($h, $mirror) = two_remotes();
	my $due = commit_on_control($h,
		files   => {'qa.yml' =>
			"---\nkit:\n  name: dev\ngenesis:\n  env: qa\nn: 1\n"},
		message => 'Tune qa',
		push    => 1,
	);
	certify($h, 'lab', control_commit => $due);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($exit, 0, 'the run succeeds') or diag($err);
	unlike($err, qr{\bmirror\b}, 'and never names the other remote');

	my ($subject) = subjects_of($h, $h->slug('qa'), 1);
	like($subject, qr{\@\Q@{[substr($due, 0, 7)]}\E},
		'the delivery landed on origin');
	is_deeply([sort keys %{refs_in($mirror, prefix => 'refs/heads')}], [],
		'and nothing was pushed to the remote git lists first');
};

# Proves T355's run: with a fork beside the canonical repository, a real
# propagate refreshes from, checks against and publishes to the canonical one
# though control tracks the fork (D118).  The canonical remote is named by its
# GitHub URL, which identifies it, and an insteadOf rewrite sends its traffic
# to the harness's bare repository; the fork's URL reaches nothing, so a run
# that touched it would fail.
subtest 'a fork beside the canonical repository is never used' => sub {
	# Four rows, and the run's own restoration assertion.
	plan tests => 5;

	# No remote is named in the configuration, so the match alone decides.
	my $h = ready_harness(delivered => ['qa'], certified => ['lab', 'qa'],
		kit => 'omega-v2.7.0');
	my $due = commit_on_control($h,
		files   => {'qa.yml' =>
			"---\nkit:\n  name: dev\ngenesis:\n  env: qa\nn: 2\n"},
		message => 'Tune qa again',
		push    => 1,
	);
	certify($h, 'lab', control_commit => $due);

	my $canonical = 'https://github.com/genesis/bosh-deployments.git';
	set_remotes($h,
		remotes  => {origin => 'git@github.com:someone/bosh-deployments.git',
		             upstream => $canonical},
		upstream => 'origin',
		fetch    => 0,
	);
	run({dir => $h->a}, 'git', 'config', "url.@{[$h->r]}.insteadOf", $canonical);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($exit, 0, 'the run succeeds') or diag($err);
	unlike($err, qr{someone/bosh-deployments|\borigin\b}, 'and never names the fork');

	my ($subject) = run({dir => $h->r}, 'git', 'log', '-1', '--format=%s',
		$h->slug('qa'));
	like($subject, qr{\@\Q@{[substr($due, 0, 7)]}\E},
		'the delivery landed on the canonical repository');
	is(ref_in($h->a, 'refs/remotes/origin/' . $h->slug('qa')), undef,
		'and nothing was fetched from or pushed to the fork');
};

subtest 'pipeline-status reads the configured remote' => sub {
	# Three rows, and the run's own restoration assertion.
	plan tests => 4;

	my ($h) = two_remotes();
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--json');
	is($exit, 0, 'the report runs') or diag($err);
	unlike("$out$err", qr{\bmirror\b}, 'and never names the other remote');

	require JSON::PP;
	my $json = eval {JSON::PP::decode_json($out)} || {};
	is(($json->{control}{local} || {})->{state}, 'in-sync',
		'local control is measured against origin, where it stands in step');
};

done_testing;
