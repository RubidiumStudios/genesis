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
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	refresh($h, 'a', $h->slug('qa'));

	# The working tree steps off control onto control's own commit rather
	# than onto an environment branch.  Git refuses to fetch into the branch
	# it is standing on, so the ref has to be free before the refresh can
	# create it, and an environment branch carries none of the repository's
	# configuration, so a command run from one has no pipeline to read.
	stand_on($h, ref_in($h->a, "refs/heads/@{[$h->control]}"));
	delete_local($h, 'a', $h->control);
	is(ref_in($h->a, "refs/heads/@{[$h->control]}"), undef,
		'copy A has no local control ref');

	my (undef, $err, $exit) = run_genesis($h, 'pipeline-status');

	is($exit, 0, 'the command carries on normally');
	is(ref_in($h->a, "refs/heads/@{[$h->control]}"),
		ref_in($h->r, $h->control),
		'the local ref is created from what the remote holds');
	# Genesis accounts for itself on standard error, so the event line comes
	# back in the second value rather than the first.
	like($err, qr{created\s+control\s+from\s+origin/control},
		'and the creation is reported as an event line');
};

subtest 'control nowhere refuses every pipeline command' => sub {
	# Ten rows, and one more for each of the four runs.
	plan tests => 14;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	unset_control($h);

	for my $argv (['propagate'], ['pipeline-status'], ['pipeline-prepare']) {
		my (undef, $err, $exit) = run_genesis($h, @$argv);
		is($exit, Genesis::Exit::CONFIG, "@$argv exits CONFIG");
		like($err, qr/exists\s+neither\s+on\s+\S*origin\S*\s+nor\s+locally/,
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

done_testing;
