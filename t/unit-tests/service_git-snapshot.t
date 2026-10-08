#!/usr/bin/env perl
# Proves the snapshot D115 asks every question against: R is read into a
# namespace of the run's own and nothing the operator has moves, a leftover
# namespace is cleared before it is read again, a branch R lacks is answered
# rather than failing the read, and the promotion into T moves, creates and
# prunes the tracking refs it is told about in one step and removes the
# namespace with them.  Every repository here is private and local.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Genesis qw/run/;
use Service::Git;

my $NS = 'refs/genesis/preflight/origin';

sub commit_in {
	my ($dir, $file, $body, $message) = @_;
	put_file("$dir/$file", $body);
	run({dir => $dir}, 'git', 'add', $file);
	run({dir => $dir}, 'git', '-c', 'user.name=t', '-c', 'user.email=t@t',
		'commit', '-q', '-m', $message);
	my ($sha) = run({dir => $dir}, 'git', 'rev-parse', 'HEAD');
	chomp $sha;
	return $sha;
}

# A teammate's repository T, a bare R it pushes to, and the operator's clone
# L of R, fetched once.  R then moves on: control gains a commit, a pull
# request branch appears, a deployment branch is deleted, and branches that
# are no part of this deployment type sit beside them.
sub world {
	my $base = helper::workdir() . sprintf('/snap-%d-%06d', $$, int(rand(1_000_000)));
	my ($t, $r, $l) = ("$base/t", "$base/r.git", "$base/l");
	mkdir_or_fail($base);
	mkdir_or_fail($t);
	run({dir => $t}, 'git', 'init', '-q', '-b', 'control');
	commit_in($t, 'README', "readme\n", 'first');
	run({dir => $t}, 'git', 'branch', $_) for qw(qa/bosh gone/bosh feature/x prod/vault);
	run({dir => $base}, 'git', 'clone', '-q', '--bare', $t, $r);
	run({dir => $t}, 'git', 'remote', 'add', 'origin', $r);
	run({dir => $base}, 'git', 'clone', '-q', $r, $l);

	my %old = map {
		my ($sha) = run({dir => $l}, 'git', 'rev-parse', "refs/remotes/origin/$_");
		chomp $sha; ($_ => $sha);
	} qw(control qa/bosh gone/bosh feature/x);

	my %new;
	$new{control} = commit_in($t, 'ops.yml', "---\nn: 1\n", 'control moves');
	run({dir => $t}, 'git', 'branch', 'pr/qa/bosh', 'control');
	$new{'pr/qa/bosh'} = $new{control};
	run({dir => $t}, 'git', 'push', '-q', 'origin', 'control', 'pr/qa/bosh');
	run({dir => $t}, 'git', 'push', '-q', 'origin', ':gone/bosh');
	$new{'qa/bosh'} = $old{'qa/bosh'};

	return {t => $t, r => $r, l => $l, old => \%old, new => \%new};
}

# Every ref the operator has, HEAD's target, and the fetch record, so a row can
# say that nothing of the operator's moved.
sub operator_state {
	my ($dir) = @_;
	my ($refs) = run({dir => $dir}, 'git', 'for-each-ref',
		'--format=%(refname) %(objectname)', 'refs/heads', 'refs/remotes');
	my ($head) = run({dir => $dir}, 'git', 'symbolic-ref', 'HEAD');
	my $fetch_head = -e "$dir/.git/FETCH_HEAD"
		? do {local (@ARGV, $/) = "$dir/.git/FETCH_HEAD"; <>} : '';
	return join("\n", $refs // '', $head // '', $fetch_head);
}

sub handle {
	my ($w) = @_;
	my $git = Service::Git->new($w->{l});
	$git->pipeline_remote('origin');
	return $git;
}

subtest 'a snapshot reads R into its own namespace and moves nothing else' => sub {
	plan tests => 5;
	my $w   = world();
	my $git = handle($w);
	my $before = operator_state($w->{l});

	my $result = $git->snapshot_remote(branches => ['control'], globs => ['*/bosh']);
	ok($result->{ok}, 'the snapshot was taken') or diag(explain $result);

	is_deeply($git->snapshot_refs,
		{control => $w->{new}{control}, 'qa/bosh' => $w->{new}{'qa/bosh'},
		 'pr/qa/bosh' => $w->{new}{'pr/qa/bosh'}},
		'it holds control and every */bosh branch R has, at R\'s tips');
	ok(!grep({m{^(feature/x|prod/vault)$}} keys %{$git->snapshot_refs}),
		'and nothing of another type or no type');
	is(operator_state($w->{l}), $before,
		'no local branch, tracking ref, HEAD or fetch record moved');

	my ($t) = run({dir => $w->{l}}, 'git', 'rev-parse', 'refs/remotes/origin/control');
	chomp $t;
	is($t, $w->{old}{control},
		"control's tracking ref still names what the clone last fetched");
};

subtest 'a leftover namespace is cleared before the next snapshot' => sub {
	plan tests => 2;
	my $w   = world();
	my $git = handle($w);
	run({dir => $w->{l}}, 'git', 'update-ref', "$NS/stale/bosh", $w->{old}{control});

	my $result = $git->snapshot_remote(branches => ['control'], globs => ['*/bosh']);
	ok($result->{ok}, 'the snapshot was taken');
	ok(!exists $git->snapshot_refs->{'stale/bosh'},
		'and a ref a killed run left behind is gone from it');
};

subtest 'a branch R lacks is answered rather than failing the read' => sub {
	plan tests => 3;
	my $w   = world();
	my $git = handle($w);

	my $result = $git->snapshot_remote(branches => ['nowhere'], globs => ['*/bosh']);
	ok($result->{ok}, 'the snapshot was taken all the same');
	is_deeply($result->{absent}, ['nowhere'], 'naming the branch R lacks');
	ok(exists $git->snapshot_refs->{'qa/bosh'}, 'and the rest was read');
};

subtest 'an unreachable remote is a failed read that leaves no snapshot' => sub {
	plan tests => 3;
	my $w   = world();
	my $git = handle($w);
	run({dir => $w->{l}}, 'git', 'remote', 'set-url', 'origin', "$w->{r}-missing");

	my $result = $git->snapshot_remote(branches => ['control'], globs => ['*/bosh']);
	ok(!$result->{ok}, 'the read failed');
	ok(defined $result->{kind}, 'saying what kind of failure it was');
	is_deeply($git->snapshot_refs, {}, 'and nothing is left in the namespace');
};

subtest 'promotion moves, creates and prunes T in one step' => sub {
	plan tests => 6;
	my $w   = world();
	my $git = handle($w);
	my ($heads_before) = run({dir => $w->{l}}, 'git', 'for-each-ref',
		'--format=%(refname) %(objectname)', 'refs/heads');

	$git->snapshot_remote(branches => ['control'], globs => ['*/bosh']);
	$git->promote_snapshot(names => [qw(control qa/bosh pr/qa/bosh gone/bosh)]);

	my $t = sub {
		my ($sha, $rc) = run({dir => $w->{l}, passfail => 0, stderr => 0},
			'git', 'rev-parse', '--verify', '-q', "refs/remotes/origin/$_[0]");
		chomp $sha if defined $sha;
		return $rc ? undef : $sha;
	};
	is($t->('control'), $w->{new}{control}, "control's T moved to R's tip");
	is($t->('pr/qa/bosh'), $w->{new}{'pr/qa/bosh'}, 'a branch new on R gained its T');
	is($t->('gone/bosh'), undef, 'a branch R no longer has lost its T');
	is($t->('feature/x'), $w->{old}{'feature/x'},
		'and a T outside the names given was left alone');

	my ($heads_after) = run({dir => $w->{l}}, 'git', 'for-each-ref',
		'--format=%(refname) %(objectname)', 'refs/heads');
	is($heads_after, $heads_before, 'no local branch moved');
	is_deeply($git->snapshot_refs, {}, 'and the namespace went with the promotion');
};

subtest 'clearing removes the namespace and nothing else' => sub {
	plan tests => 2;
	my $w   = world();
	my $git = handle($w);
	$git->snapshot_remote(branches => ['control'], globs => ['*/bosh']);
	my $before = operator_state($w->{l});

	$git->clear_snapshot;
	is_deeply($git->snapshot_refs, {}, 'the namespace is empty');
	is(operator_state($w->{l}), $before, 'and the operator\'s refs are as they were');
};

# D115's questions read the snapshot rather than T, so a branch's standing is
# measured against whichever the caller names.
subtest 'a branch is measured against the snapshot when asked to be' => sub {
	plan tests => 5;
	my $w   = world();
	my $git = handle($w);
	$git->snapshot_remote(branches => ['control'], globs => ['*/bosh']);

	is($git->resolve_branch('control')->{state}, 'in-sync',
		"against T, control stands where the clone last fetched it");
	my $snap = $git->resolve_branch('control', tracking => $NS);
	is($snap->{state}, 'behind', 'against the snapshot it is behind R');
	is($snap->{behind}, 1, 'by the one commit R gained');
	is($git->resolve_branch('pr/qa/bosh', tracking => $NS)->{state}, 'no-local',
		'a branch new on R is no-local against the snapshot');
	is($git->resolve_branch('gone/bosh', tracking => $NS), undef,
		'and a branch R lost, with no local ref, is nowhere');
};

subtest 'a namespace of its own leaves the run\'s alone' => sub {
	plan tests => 2;
	my $w   = world();
	my $git = handle($w);
	my $own = 'refs/genesis/preflight/status-4242/origin';

	$git->snapshot_remote(branches => ['control'], globs => ['*/bosh']);
	my $run = $git->snapshot_refs;
	$git->snapshot_remote(namespace => $own, branches => ['control'], globs => ['*/bosh']);
	$git->clear_snapshot(namespace => $own);

	is_deeply($git->snapshot_refs, $run, "the run's snapshot is untouched");
	is_deeply($git->snapshot_refs(namespace => $own), {}, 'and the other is gone');
};

done_testing;
