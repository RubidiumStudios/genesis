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

	is($records->[0]{pending}[0]{outcome}, undef,
		'and a commit that never reached R is delivered in no sense');
};

done_testing;
