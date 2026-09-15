#!/usr/bin/env perl
# Proves T97 and T98: a local deployment branch the remote lacks, and one
# that shares no ancestor with the remote's, each refuse the whole run
# before any write, naming the branch and the remedy in order.
#
# Every phrase is matched across the wrap.  A refusal is wrapped to the
# terminal width before it reaches standard error, so a clause the reader
# sees on one line can arrive with a newline and an indent inside it.
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

subtest 'a local branch the remote never had refuses the run' => sub {
	# Eight rows, and one more for the run's own restoration assertion.
	plan tests => 9;

	my $h   = make_harness(envs => ['qa', 'lab']);
	my $qa  = $h->slug('qa');
	my $lab = $h->slug('lab');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	my $before_qa  = ref_in($h->a, "refs/heads/$qa");
	my $stray      = local_branch_only($h, 'lab');
	# An ops file rather than a rewritten qa.yml.  The environment file is
	# where the pipeline metadata lives, so overwriting it empties the
	# topology and the run bails on that several steps before the refusal
	# this row is about.
	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nfrom: the operator\n"},
		message => 'an operator commit to propagate',
		push    => 1);

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::DATAERR, 'the run exits DATAERR');
	like($err, qr/has\s+no\s+counterpart\s+on\s+\S*origin/,
		'the refusal names why it stopped');
	like($err, qr/\Q$lab\E/, 'and names the branch');
	like($err, qr/Genesis\s+deletes\s+nothing/,
		'and says Genesis deletes nothing');
	like($err, qr/git\s+branch\s+-D\s+\Q$lab\E.*genesis\s+pipeline-apply/s,
		'and gives the remedy in order, which ends at pipeline-apply');
	like($err, qr/Nothing\s+was\s+written/, 'and says nothing was written');
	is(ref_in($h->a, "refs/heads/$qa"), $before_qa,
		'the environment that was fine was not written either');
	is(ref_in($h->a, "refs/heads/$lab"), $stray,
		'and the offending branch is still there, because Genesis deletes nothing');
};

subtest 'a local branch sharing no ancestor with the remote refuses the run' => sub {
	# Seven rows, and one more for the run's own restoration assertion.
	plan tests => 8;

	my $h  = make_harness(envs => ['qa']);
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	my $orphan = unrelated_branch($h, 'qa');
	# An ops file, for the reason the first subtest gives.
	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nfrom: the operator\n"},
		message => 'an operator commit to propagate',
		push    => 1);

	is($h->git('a')->merge_base($qa, "origin/$qa"), '',
		'the two tips really do share no ancestor');

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::DATAERR, 'the run exits DATAERR');
	like($err, qr{shares\s+no\s+ancestor\s+with\s+\S*origin/\Q$qa\E},
		'the refusal names why it stopped');
	like($err, qr/never\s+applies\s+across\s+unrelated\s+histories/,
		'and says the reset does not apply here');
	like($err, qr/git\s+branch\s+-D\s+\Q$qa\E.*genesis\s+propagate/s,
		'and gives the remedy in order, which ends at propagate');
	is(ref_in($h->a, "refs/heads/$qa"), $orphan,
		'the branch was neither reset nor deleted');
	is(ref_in($h->r, $qa), ref_in($h->b, "refs/heads/$qa") // ref_in($h->r, $qa),
		'and the remote was not touched');
};

subtest 'the reset never applies across unrelated histories' => sub {
	# Two rows, and one more for the run's own restoration assertion.
	plan tests => 3;

	my $h  = make_harness(envs => ['qa']);
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	my $orphan = unrelated_branch($h, 'qa');
	# No message, because the harness discards one whenever a marker is
	# asked for and the subject is the marker itself.
	local_only_commit($h, $qa,
		marker => ref_in($h->a, "refs/heads/@{[$h->control]}"));
	# The commit helper checks the branch out and leaves the copy there, and
	# the orphan tree carries no deployment root, so the copy stands back on
	# control before the command runs.
	stand_on($h, $h->control);

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::DATAERR,
		'a marker on every local commit does not buy a reset here');
	like($err, qr/shares\s+no\s+ancestor/,
		'the unrelated-history refusal is the one that speaks');
};

done_testing;
