#!perl
# Proves T366: the host is asked about the repository before anything is
# written, by the runs that already call it (D118, noted 2026-10-15).  A
# repository that does not exist, or that the token cannot push to, is a
# pre-flight problem collected with the others (D115), and a run that never
# calls the host makes no call to ask.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit qw/CONFIG/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# The double's calls that ask about the repository itself, as against its
# pulls, rulesets or protection.
sub repository_asks {
	my ($h) = @_;
	return grep {($_->{method} // '') eq 'GET'
		&& ($_->{url} // '') =~ m{/repos/[^/]+/[^/?]+(?:\?|$)}} gh_calls($h->{gh});
}

sub protection_calls {
	my ($h) = @_;
	return grep {($_->{url} // '') =~ m{/(rulesets|protection)\b}} gh_calls($h->{gh});
}

subtest 'an apply is refused for a repository the host does not have' => sub {
	# Four rows, and one for the run's restoration assertion.
	plan tests => 5;

	my $h = make_harness(envs => ['qa'], github => 1);
	gh_repository($h->{gh}, missing => 1);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply', '-y');
	my $said = unfolded($out, $err);

	is($exit, CONFIG, 'the apply is refused at CONFIG') or diag($said);
	like($said, qr/does not exist, or this token cannot see it/,
		'saying the repository is not there for this token');
	is(ref_in($h->r, $h->slug('qa')), undef, 'before any deployment branch is cut');
	is(scalar(protection_calls($h)), 0, 'or any protection applied');
};

subtest 'an apply is refused for a repository the token cannot push to' => sub {
	# Three rows, and one for the run's restoration assertion.
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], github => 1);
	gh_repository($h->{gh}, push => 0);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply', '-y');
	my $said = unfolded($out, $err);

	is($exit, CONFIG, 'the apply is refused at CONFIG') or diag($said);
	like($said, qr/cannot push to it/, 'naming push as what was refused');
	is(ref_in($h->r, $h->slug('qa')), undef, 'and nothing is cut');
};

subtest 'a propagate names a missing repository with its other problems' => sub {
	# Four rows.  The run's own restoration assertion is off, because the
	# working tree is left dirty on purpose and put back by hand below.
	plan tests => 4;

	my $h = ready(kit => 'omega-v2.7.0');
	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');
	gh_repository($h->{gh}, missing => 1);
	put_file($h->a . '/prod.yml', "---\nchanged: 1\n");

	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'propagate', '-y');
	my $said = unfolded($out, $err);
	run({dir => $h->a}, 'git', 'checkout', '--', 'prod.yml');

	is($exit, CONFIG, 'the run is refused at CONFIG') or diag($said);
	like($said, qr/does not exist, or this token cannot see it/, 'naming the repository');
	like($said, qr/uncommitted changes/, 'and the other problem, in the same refusal');
	is(() = $said =~ /Refusing to /g, 1, 'which is one refusal');
};

subtest 'a run that never calls the host makes no call to ask' => sub {
	# Three rows, and one for each run's restoration assertion.
	plan tests => 6;

	my $h = make_harness(envs => ['qa'], github => 1);
	run_genesis($h, 'pipeline-apply', '--dry-run');
	is(scalar(repository_asks($h)), 0, 'a dry run with a token asks nothing');

	my $p = make_harness(envs => ['lab', 'qa'], github => 1, kit => 'omega-v2.7.0');
	$p->ready_envs;
	due_commit($p, $_, params => {instances => 2},
		message => 'Raise the cf instance count') for qw/lab qa/;
	run_genesis($p, 'propagate', '-y');
	is(scalar(repository_asks($p)), 0,
		'a propagate with no pull request environment asks nothing');

	my $m = make_harness(envs => ['qa'], github => 1, provider => 'manual');
	run_genesis($m, {no_token => 1}, 'pipeline-apply', '-y');
	is(scalar(gh_calls($m->{gh})), 0, 'and a manual pipeline with no token calls nothing');
};

done_testing;
