#!/usr/bin/env perl
# Proves T90, T91, T99, T100, and T105: control is created from the remote
# where only the remote has it, refused where it exists nowhere, and checked
# in both directions where both have it.
#
# Every phrase is matched across the wrap.  A refusal is wrapped to the
# terminal width before it reaches standard error, so a clause the reader sees
# on one line can arrive with a newline and an indent inside it.
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

subtest 'an unpushed control commit refuses the run as unpushed' => sub {
	# Seven rows, and one more for the run's own restoration assertion.
	plan tests => 8;

	my $h    = make_harness(envs => ['qa', 'prod']);
	my $slug = $h->slug('qa');
	init_branch($h, $_) for qw/qa prod/;
	refresh($h, 'a', $slug, $h->slug('prod'));

	my $before_qa   = ref_in($h->a, "refs/heads/$slug");
	my $before_prod = ref_in($h->a, "refs/heads/@{[$h->slug('prod')]}");

	commit_on_control($h,
		files   => {'qa.yml' => "---\nkit:\n  name: dev\n"},
		message => 'change qa by hand on control',
		push    => 0);

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::DATAERR, 'the run exits DATAERR');
	like($err, qr/\bahead\b/, 'the refusal names the state');
	like($err, qr/by\s+1\s+commit\b/, 'and names the count');
	# The number governs the verb, so the clause reads aloud at one commit
	# as well as at four.
	like($err, qr/which\s+is\s+unpublished/, 'and the clause agrees with it');
	like($err, qr/git\s+push\s+origin\s+control/,
		'and gives the command that fixes it');
	is(ref_in($h->a, "refs/heads/$slug"), $before_qa, 'qa/bosh did not move');
	is(ref_in($h->a, "refs/heads/@{[$h->slug('prod')]}"), $before_prod,
		'prod/bosh did not move either');
};

subtest 'a teammate ahead on control refuses the run as stale' => sub {
	# Five rows, and one more for the run's own restoration assertion.
	plan tests => 6;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');

	my $before_l = ref_in($h->a, "refs/heads/@{[$h->control]}");
	publish_from_b($h,
		files   => {'ops/shared.yml' => "---\nfrom: the teammate\n"},
		message => 'a teammate publishes onto control');

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::DATAERR, 'the run exits DATAERR');
	like($err, qr/\bbehind\b/, 'the refusal names the state');
	like($err, qr/by\s+1\s+commit\b/, 'and names the count');
	like($err, qr/git\s+pull\s+--rebase\s+origin\s+control/,
		'and gives the remedy');
	is(ref_in($h->a, "refs/heads/@{[$h->control]}"), $before_l,
		'control was not moved in either direction');
};

subtest 'control on the remote alone is created and reported' => sub {
	# Five rows, and one more for the run's own restoration assertion.
	plan tests => 6;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	refresh($h, 'a', $h->slug('qa'));

	# The working tree steps off control onto control's own commit rather
	# than onto an environment branch.  Git refuses to fetch into the branch
	# it is standing on, so the ref has to be free before the refresh can
	# create it, and an environment branch carries none of the repository's
	# configuration, so a command run from one has no pipeline to read.
	my $stood_on = ref_in($h->a, "refs/heads/@{[$h->control]}");
	stand_on($h, $stood_on);

	# The remote then moves, which is what makes the row discriminate.  With
	# the remote sitting on the commit the working tree is detached at, a ref
	# created off HEAD and a ref created off the remote are the same sha and
	# the assertion below could not tell them apart.
	publish_from_b($h,
		files   => {'ops/shared.yml' => "---\nfrom: the teammate\n"},
		message => 'a teammate publishes onto control');

	delete_local($h, 'a', $h->control);
	is(ref_in($h->a, "refs/heads/@{[$h->control]}"), undef,
		'copy A has no local control ref');

	my (undef, $err, $exit) = run_genesis($h, 'pipeline-status');

	is($exit, 0, 'the command carries on normally');
	is(ref_in($h->a, "refs/heads/@{[$h->control]}"),
		ref_in($h->r, $h->control),
		'the local ref is created from what the remote holds');
	isnt(ref_in($h->a, "refs/heads/@{[$h->control]}"), $stood_on,
		'and not from the commit the working tree was standing on');
	# Genesis accounts for itself on standard error, so the event line comes
	# back in the second value rather than the first.
	like($err, qr{created\s+control\s+from\s+origin/control},
		'and the creation is reported as an event line');
};

subtest 'control nowhere refuses every pipeline command' => sub {
	# Eight rows, and one more for each of the three runs.
	plan tests => 11;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	unset_control($h);

	my $control = $h->control;
	for my $argv (['propagate'], ['pipeline-status']) {
		my (undef, $err, $exit) = run_genesis($h, @$argv);
		is($exit, Genesis::Exit::CONFIG, "@$argv exits CONFIG");
		like($err,
			qr/control\s+branch\s+\Q$control\E\s+exists\s+neither\s+on\s+\S*origin\S*\s+nor\s+locally/,
			"@$argv names the branch and both places");
	}

	my (undef, $deploy_err, $deploy_exit) = run_genesis($h, 'qa', 'deploy');
	is($deploy_exit, Genesis::Exit::CONFIG, 'the deploy exits CONFIG');
	like($deploy_err, qr/Refusing\s+to\s+deploy/, 'in its own words');
	like($deploy_err, qr/Nothing\s+was\s+deployed/,
		'with its own closing sentence');

	is(ref_in($h->r, $h->control), undef, 'no command created control anywhere');
};

subtest 'the unrefreshed control branch, reproduced' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h    = make_harness(envs => ['qa']);
	my $slug = $h->slug('qa');
	init_branch($h, 'qa');
	refresh($h, 'a', $slug);

	my $before_qa = ref_in($h->a, "refs/heads/$slug");
	publish_from_b($h,
		files   => {'qa.yml' => "---\nkit:\n  name: dev\n"},
		message => 'a teammate changes qa on control');

	# The baseline never named control in its refresh, so copy A's control
	# stayed where it was and the run propagated from it and reported
	# success.  The refresh names control now, so the run sees behind.
	is($h->git('a')->resolve_branch($h->control)->{state}, 'in-sync',
		'copy A has not refreshed yet, so it still believes it is current');

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::DATAERR, 'the refreshed run refuses instead');
	like($err, qr/\bbehind\b/, 'naming the stale control branch');
	is(ref_in($h->a, "refs/heads/$slug"), $before_qa,
		'and nothing was propagated from the old state');
};

subtest 'a control branch the remote has never had refuses the run' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');

	# Control is cut here and published nowhere, which is the repository an
	# operator has while the branch is still only theirs.  The unsetting takes
	# it off the remote, out of both copies and out of their tracking refs, and
	# the cut puts it back in this clone alone.
	unset_control($h);
	local_branch($h, $h->control);
	stand_on($h, $h->control);

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::DATAERR, 'the run exits DATAERR');
	like($err, qr/exists\s+here\s+and\s+not\s+on\s+\S*origin/,
		'the refusal names the state');
	like($err, qr/git\s+push\s+-u\s+origin\s+@{[$h->control]}/,
		'and gives the command that publishes it');
	is(ref_in($h->r, $h->control), undef, 'and nothing published it for them');
};

subtest 'a repository with no remote never reaches the control check' => sub {
	# Two rows, and one more for the run's own restoration assertion.
	plan tests => 3;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');

	# Every remote goes.  The configuration refuses first, where the source
	# control's remote is derived, so no command reaches the control check at
	# all.  That is why the check composes its own remedy without a command
	# where it has no remote to name: the words that stand in for a remote are
	# a guard against printing them inside a command, and not a path an
	# operator can walk.
	set_remotes($h, remotes => {}, copy => 'a');

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::CONFIG, 'the run exits CONFIG');
	like($err,
		qr/pipeline\.source_control\.remote\s+could\s+not\s+be\s+derived/,
		'and the refusal is the derivation\'s, well before the control check');
};

subtest 'control on the remote that the refresh could not write refuses' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	refresh($h, 'a', $h->slug('qa'));

	# The working tree stays on control and the ref underneath it goes, which
	# leaves an unborn branch.  Git refuses to fetch into the branch it stands
	# on, so the refresh gives control the tracking refspec, the local ref is
	# never written, and the query answers no-local rather than a divergence.
	delete_local($h, 'a', $h->control);
	is(ref_in($h->a, "refs/heads/@{[$h->control]}"), undef,
		'copy A has no local control ref');

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::DATAERR, 'the run exits DATAERR');
	like($err,
		qr{is\s+on\s+\S*origin/@{[$h->control]}\S*\s+and\s+not\s+in\s+this\s+clone},
		'the refusal says the remote has it and this clone does not');
	unlike($err, qr/by\s+0\s+commits/,
		'and it never reads a staleness out of two counts that are zero');
};

subtest 'a control diverged both ways refuses the run' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');

	# The two rows at the top of this file take the halves one at a time,
	# and this one takes them together, because a control that is both
	# unpublished and stale is refused in words of its own rather than in
	# either half's.  Propagation delivers control's commits onto each
	# environment branch and then pushes what it wrote, so a control in
	# this state is one it must not deliver from.
	diverge($h);
	my $before_qa = ref_in($h->a, "refs/heads/@{[$h->slug('qa')]}");

	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, Genesis::Exit::DATAERR, 'the run exits DATAERR');
	like($err, qr/both\s+unpublished\s+and\s+stale/,
		'the refusal names both halves of the divergence');
	like($err, qr/Nothing\s+was\s+written/,
		'and closes in the command\'s own words');
	is(ref_in($h->a, "refs/heads/@{[$h->slug('qa')]}"), $before_qa,
		'and no environment branch was written to');
};

done_testing;
