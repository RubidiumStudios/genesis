#!/usr/bin/env perl
# Proves T122 and T129: the apply creates each missing deployment branch as an
# orphan root commit adding one init file under the [ci skip] subject, names it
# from the deployment slug, and leaves the operator's working state alone.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{NOCOLOR} = 1;

# _read_in - one line of git's answer in a repository, or undef where the ref
# is absent
#
# The stderr is captured apart from the output rather than folded into it, so
# a row running before the branch exists reads nothing back rather than
# reading git's complaint about the name it asked for.
sub _read_in {
	my ($dir, @cmd) = @_;
	my ($out, $rc) = run({dir => $dir, stderr => 0}, 'git', @cmd);
	return undef if $rc || !defined $out;
	chomp $out;
	return $out;
}

subtest 'an environment with no branch gets an orphan init branch' => sub {
	# Six rows, and one more for the run's own restoration assertion, which
	# run_genesis makes unless a row turns it off.  The creation is plumbing,
	# so a working state that moved would be a defect this row should catch.
	plan tests => 7;

	my $h = make_harness(envs => ['qa']);
	my (undef, undef, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the apply exits 0');

	my $sha = ref_in($h->r, 'qa/bosh');
	ok($sha, 'R carries qa/bosh');

	is_deeply(tree_of($h->r, 'qa/bosh'), ['init'],
		'the init branch holds the init file alone');

	is(_read_in($h->r, 'log', '-1', '--format=%s', 'qa/bosh'),
		'Initialize qa/bosh branch [ci skip]',
		'the root commit carries the subject and the [ci skip] marker');

	is(_read_in($h->r, 'log', '-1', '--format=%P', 'qa/bosh'), '',
		'the init commit is an orphan root');

	my $shared = run({dir => $h->r, passfail => 1},
		'git', 'merge-base', '--is-ancestor', $h->control, 'qa/bosh');
	ok(!$shared, 'it shares no history with control');
};

subtest 'a standing branch is left where it is' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa']);
	my $before = init_branch($h, 'qa');

	my (undef, undef, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the apply exits 0 with the branch already standing');

	is(ref_in($h->r, 'qa/bosh'), $before,
		'the standing branch was not recreated');
};

subtest 'two roots serving one environment get two branches' => sub {
	# Four rows, and one restoration assertion for each of the two runs.
	plan tests => 6;

	my $h = make_harness(envs => ['qa']);
	add_deployment_root($h, type => 'doomsday', envs => ['qa'], path => 'doomsday');

	my (undef, undef, $first)  = run_genesis($h, 'pipeline-apply');
	my (undef, undef, $second) = run_genesis($h, {dir => 'doomsday'}, 'pipeline-apply');
	is($first,  0, 'the apply in the bosh root exits 0');
	is($second, 0, 'the apply in the doomsday root exits 0');

	my @branches = sort split /\n/,
		(_read_in($h->r, 'for-each-ref', '--format=%(refname:short)', 'refs/heads') // '');

	is_deeply([grep {$_ ne $h->control} @branches], ['qa/bosh', 'qa/doomsday'],
		'each deployment has its own branch, composed from its own type');
	ok(!(grep {$_ eq 'qa'} @branches),
		'nothing cut the bare environment name the baseline would have used');
};

done_testing;
