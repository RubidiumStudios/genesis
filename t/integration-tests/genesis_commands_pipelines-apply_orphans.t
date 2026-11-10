#!/usr/bin/env perl
# Proves T481 and T482 (D153): an environment whose file has left control is
# an orphan.  pipeline-apply names each orphan with what the pipeline left for
# it, its deployment branch, its pull request branch and open pull request,
# its rulesets, and its pipeline records, warns where its exodus record says
# it is still deployed, and by default removes nothing.  --cleanup-orphans
# removes those traces, and only those, asking first unless -y.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/run/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# An applied pipeline with qa and prod, prod deployed, held and proposing a
# pull request, and then prod's file taken off control.
sub orphaned_prod {
	my (%o) = @_;
	my $h  = make_harness(envs => ['qa', 'prod'], github => 1);
	my $gh = $h->gh;
	push_from($h, 'a', $h->control);
	my (undef, $err, $exit) = run_genesis($h, 'pipeline-apply', '-y');
	die "the first apply failed: $err\n" if $exit;

	# What a deploy and a held, proposed delivery would have left.
	$h->_write_record($h->env_path('prod'), dated => '2026-11-10 12:00:00 +0000');
	$h->_write_record($h->env_path('prod').'/hold', reason => 'freeze');
	run({dir => $h->a, onfailure => 'Failed to push the pull request branch'},
		'git', 'push', '-q', 'origin', $h->control.':refs/heads/'.$h->pr_branch('prod'));
	my $pr = gh_pull_request($gh, env => 'prod');

	$h->commit_on_control(files => {'prod.yml' => undef});
	push_from($h, 'a', $h->control);
	gh_protection($gh, admin => 0) if $o{no_admin};
	return ($h, $gh, $pr);
}

sub on_remote {
	my ($h, $branch) = @_;
	my ($out) = run({dir => $h->a, stderr => 0}, 'git', 'ls-remote', '--heads', 'origin', "refs/heads/$branch");
	return ($out // '') =~ /\S/ ? 1 : 0;
}

sub ruleset_for {
	my ($gh, $branch) = @_;
	my $state = $gh->{harness}->_gh_read;
	return scalar grep {($_->{name} // '') eq "genesis-$branch"} @{$state->{rulesets} || []};
}

sub in_vault {
	my ($h, $path) = @_;
	my (undef, $rc) = run({env => {SAFE_TARGET => $h->fixture_vault}, stderr => 0},
		Harness::Propagation::real_tool('safe'), 'exists', $path);
	return $rc ? 0 : 1;
}

subtest 'an orphan is reported and left (T481)' => sub {
	my ($h, $gh, $pr) = orphaned_prod();
	my ($slug, $prb) = ($h->slug('prod'), $h->pr_branch('prod'));
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply', '-y');
	my $said = "$out\n$err";
	is($exit, 0, 'the apply goes on') or return diag($said);

	like($said, qr/orphan\w*\b.*\bprod\b/i, 'naming prod as an orphan');
	like($said, qr/\Q$slug\E/, 'with its deployment branch');
	like($said, qr/\Q$prb\E.*#$pr|#$pr.*\Q$prb\E/s, 'its pull request branch and open pull request');
	like($said, qr/genesis-\Q$slug\E/, 'its ruleset');
	like($said, qr{\Q$slug\E/hold}, 'and its records');
	like($said, qr/still deployed/i, 'warning that it is still recorded as deployed');
	like($said, qr/terminate/, 'and how to tear it down');
	unlike($said, qr/orphan\w*\b[^\n]*\bqa\b/i, 'never naming qa');

	ok(on_remote($h, $slug), 'its branch is left');
	ok(on_remote($h, $prb), 'and its pull request branch');
	ok(ruleset_for($gh, $slug), 'and its ruleset');
	ok(in_vault($h, $h->env_path('prod').'/hold'), 'and its hold record');
};

subtest 'a dry run reports the same and removes nothing' => sub {
	my ($h, $gh) = orphaned_prod();
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply', '--dry-run');
	is($exit, 0, 'the dry run succeeds') or return diag("$out\n$err");
	like("$out\n$err", qr/orphan\w*\b.*\bprod\b/i, 'naming prod as an orphan');
	like($err, qr/already recorded qa\b/, 'applying the pipeline');
	unlike($err, qr/\b(?:standing|protect\w*|record\w*|create)\s+prod\b/, 'without the orphan in it');
	ok(on_remote($h, $h->slug('prod')), 'leaving its branch');
};

subtest '--cleanup-orphans removes the traces alone (T482)' => sub {
	my ($h, $gh, $pr) = orphaned_prod();
	my ($slug, $prb) = ($h->slug('prod'), $h->pr_branch('prod'));
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply', '-y', '--cleanup-orphans');
	my $said = "$out\n$err";
	is($exit, 0, 'the apply succeeds') or return diag($said);

	my $state = $h->_gh_read;
	my ($closed) = grep {$_->{number} == $pr} @{$state->{prs}};
	is($closed->{state}, 'closed', 'the pull request is closed');
	ok(scalar @{($state->{comments} || {})->{$pr} || []}, 'with a comment saying why');
	ok(!on_remote($h, $slug), 'the deployment branch is deleted');
	ok(!on_remote($h, $prb), 'and the pull request branch');
	ok(!ruleset_for($gh, $slug), 'and the ruleset');
	ok(!in_vault($h, $h->env_path('prod').'/hold'), 'and the hold record');
	ok(!in_vault($h, $h->env_path('prod').'/pipeline'), 'and the pipeline record');
	ok(in_vault($h, $h->env_path('prod')), 'leaving its own exodus record');
	like($said, qr/still deployed/i, 'and still warning that it is deployed');
	ok(on_remote($h, $h->slug('qa')), 'qa is untouched');
};

subtest '--cleanup-orphans asks first, and a dry run removes nothing' => sub {
	my ($h, $gh) = orphaned_prod();
	my ($out, $err, $exit) = run_genesis($h, {answers => ['n']}, 'pipeline-apply', '--cleanup-orphans');
	ok(on_remote($h, $h->slug('prod')), 'declining removes nothing');

	($out, $err, $exit) = run_genesis($h, 'pipeline-apply', '--dry-run', '--cleanup-orphans');
	is($exit, 0, 'the dry run succeeds'); diag $err;
	like("$out\n$err", qr/would remove/i, 'saying what it would remove');
	ok(on_remote($h, $h->slug('prod')), 'and removing nothing');
};

subtest 'a trace it cannot remove is reported and the apply goes on' => sub {
	my ($h, $gh) = orphaned_prod(no_admin => 1);
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply', '-y', '--cleanup-orphans');
	my $said = "$out\n$err";
	is($exit, 0, 'the apply goes on') or return diag($said);
	like($said, qr/could not remove[^\n]*genesis-\Q@{[$h->slug('prod')]}\E/i,
		'naming the ruleset it could not remove');
	ok(!on_remote($h, $h->slug('prod')), 'and removing the rest');
};

done_testing;
