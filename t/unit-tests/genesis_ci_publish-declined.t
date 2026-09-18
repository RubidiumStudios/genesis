#!/usr/bin/env perl
# Proves T186: a no at the confirmation puts every branch the run committed to
# back at T, publishes nothing, and records each environment as written,
# verified, and not published because the operator declined.
#
# The stage is called directly rather than through a spawned run, because the
# suite spawns its commands and a spawned command has no controlling terminal
# to be asked at, so a spawned run can only ever meet the unasked path.  That
# is the same reason the confirmation's own three terminal behaviours are
# proved this way in t/unit-tests/genesis_ci_publish-confirm.t.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Output;

use Genesis;
use Genesis::CI::Publish;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

subtest 'a no resets every branch and publishes nothing' => sub {
	plan tests => 11;

	my $h = make_harness(envs => ['lab', 'qa'], mode => 'direct', vault => 0);
	init_branch($h, 'lab');
	init_branch($h, 'qa');

	# The operator's own commit on control, published, so the re-check ahead
	# of the ask finds control in sync and the run reaches the confirmation.
	my $control = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: fourteen\n"},
		message => 'share an op with every environment',
		push    => 1,
	);

	# The walk, carried as far as the publish: a session that has committed
	# to both deployment branches and pushed neither, which is the state a
	# decline has to leave no trace of.
	my $git     = $h->git('a');
	my $session = $git->session(control => $h->control);
	$session->begin;
	for my $env (qw/lab qa/) {
		$session->switch($h->slug($env));
		$git->checkout_file($control, 'ops/shared.yml');
		$git->commit("deliver ops/shared.yml to $env", 'ops/shared.yml');
	}

	my @branches = map {$h->slug($_)} qw/lab qa/;
	my @before   = map {ref_in($h->r, "refs/heads/$_")} @branches;

	my @specs = map {
		{branch => $h->slug($_), kind => 'deployment', env => $_}
	} qw/lab qa/;
	my $records = [map {
		{
			env     => $_,
			branch  => $h->slug($_),
			pending => [{control_commit => $control, subject => 'share an op'}],
			held    => [],
			outcome => 'propagated',
		}
	} qw/lab qa/];

	my $result;
	{
		no warnings 'redefine';
		local *Genesis::CI::Publish::in_controlling_terminal = sub {1};
		set_stdin("n\n");
		my ($out, $err) = output_from {
			$result = Genesis::CI::Publish::publish_run(
				git     => $git,
				session => $session,
				remote  => 'origin',
				control => $h->control,
				records => $records,
				specs   => \@specs,
			)
		};
		reset_stdin;
		like(unfolded($out, $err), qr/Publish these branches\?/,
			'the operator was asked before anything went out');
	}
	$session->finish;

	is($result->{declined}, 1, 'the run reads as one the operator stopped');
	# A regression guard for state the decline's early return must not
	# touch, green before the fix as well as after it.
	is_deeply($result->{published}, [],
		'and it published nothing on its way out');

	is_deeply([map {ref_in($h->r, "refs/heads/$_")} @branches], \@before,
		'neither branch moved on R, because nothing was pushed');

	for my $branch (@branches) {
		is(ref_in($h->a, "refs/heads/$branch"),
			ref_in($h->a, "refs/remotes/origin/$branch"),
			"$branch was reset to T, with no stray local commit");
	}

	# The bare word and its qualifier are read apart, because the run's exit
	# status matches the whole of the outcome field against the seven words
	# I8 fixes and a phrase written into it would match none of them.
	for my $rec (@$records) {
		is($rec->{outcome}, 'not published',
			"$rec->{env} records the word I8 fixes for a branch that stayed here");
		is($rec->{outcome_detail}, 'operator declined',
			"$rec->{env} records why it was not published");
	}

	# The other regression guard, and the one ruling 30's report defaults
	# want: a pending commit left with no outcome of its own is what stops
	# the report calling it delivered.
	is($records->[0]{pending}[0]{outcome}, undef,
		'and a commit that never reached R is delivered in no sense');
};

# The reset used to raise a bug over a branch with no tracking ref, because
# nothing could put one back.  The session records each branch's pre-run tip
# now, so there is something to put every branch back to and the restore does
# it rather than refusing.
subtest 'a publish-set branch the remote never had goes back where it was' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['lab'], mode => 'direct', vault => 0);

	# The branch is cut in this clone alone and never published, which is
	# the state the pre-flight refuses before the walk starts, so a session
	# that has committed to one cannot arise from a real run.  It is cut
	# before the control commit below, so the delivery onto it has a file to
	# carry and the commit moves the tip.
	local_branch_only($h, 'lab');

	my $control = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: fifteen\n"},
		message => 'share an op with every environment',
		push    => 1,
	);

	my $git     = $h->git('a');
	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($h->slug('lab'));
	my $found = $git->sha('HEAD');
	$git->checkout_file($control, 'ops/shared.yml');
	$git->commit('deliver ops/shared.yml to lab', 'ops/shared.yml');

	# Counted and then read off the branch itself, because a reset that put
	# nothing back would leave the run's own commit on a branch nobody else
	# can see while the count still said the branch was put back.
	is(Genesis::CI::Publish::_reset_publish_set($session), 1,
		'the branch is in the set the reset puts back');
	is($git->sha($h->slug('lab')), $found,
		'and it is back at the tip this run found it at');

	$session->finish;
};

# The third case of the restore, which neither row above reaches: a branch
# this run cut, that the remote has never held and that the session recorded
# no tip for.  There is nothing to put such a branch back to, so putting it
# back is taking it off, and the tree has to step off it first because git
# will not delete the branch it stands on.
subtest 'a branch the run cut is taken off again on a decline' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['lab'], mode => 'pr', vault => 0);
	init_branch($h, 'lab');

	my $control = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nops: sixteen\n"},
		message => 'share an op with every environment',
		push    => 1,
	);

	my $git     = $h->git('a');
	my $cut     = $h->pr_branch('lab');
	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($cut, create_from => $h->slug('lab'));
	$git->checkout_file($control, 'ops/shared.yml');
	$git->commit('deliver ops/shared.yml to the pull request branch',
		'ops/shared.yml');

	ok($git->branch_exists($cut), 'the run cut the branch and stands on it');
	ok(!ref_in($h->a, "refs/remotes/origin/$cut"),
		'and the remote has never held it');

	is(Genesis::CI::Publish::_reset_publish_set($session), 1,
		'the branch is in the set the reset puts back');
	ok(!$git->branch_exists($cut),
		'and putting it back took it off, because nobody held it before');

	$session->finish;
};

done_testing;
