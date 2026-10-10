#!/usr/bin/env perl
# Proves D115's one refusal: every problem a run found is named in a single
# refusal, its code is the highest-ranked problem's under D106 as noted on
# 2026-10-07 (CONFIG, NOPERM, DATAERR, UNAVAILABLE, TEMPFAIL), a run with one
# problem reads as that refusal read before, and a gate that left questions
# unasked names them and why.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Genesis::Exit qw/CONFIG NOPERM DATAERR UNAVAILABLE TEMPFAIL/;
use Genesis::CI::Preflight;

$ENV{NOCOLOR} = 1;

# What refuse_once raised, its options and its words, read as it composed
# them rather than as a terminal wrapped them.
sub refused {
	my (%opts) = @_;
	my @raised;
	no warnings qw/once redefine/;
	local *Genesis::CI::Preflight::bail = sub {
		push @raised, [@_];
		die "refused\n";
	};
	my $returned = eval {Genesis::CI::Preflight::refuse_once(%opts)};
	return {returned => $returned, raised => \@raised};
}

sub words {
	my ($raised) = @_;
	my (undef, $format, @args) = @{$raised};
	return sprintf($format, @args);
}

sub problem { Genesis::CI::Preflight::problem(@_) }

subtest 'the code is the highest-ranked problem\'s' => sub {
	plan tests => 6;
	my $code = sub {Genesis::CI::Preflight::exit_code_for(map {problem($_, 'x')} @_)};
	is($code->(DATAERR, TEMPFAIL), DATAERR, 'the repository state over a transient fault');
	is($code->(TEMPFAIL, UNAVAILABLE), UNAVAILABLE, 'an unavailable service over a transient fault');
	is($code->(DATAERR, NOPERM), NOPERM, 'a permission over the repository state');
	is($code->(NOPERM, CONFIG), CONFIG, 'configuration over a permission');
	is($code->(TEMPFAIL, UNAVAILABLE, DATAERR, NOPERM, CONFIG), CONFIG,
		'and configuration over everything');
	is($code->(TEMPFAIL), TEMPFAIL, 'one problem is its own code');
};

subtest 'nothing found is nothing refused' => sub {
	plan tests => 2;
	my $r = refused(problems => [], action => 'propagate',
		outcome => 'Nothing was written.');
	is($r->{returned}, 1, 'the run proceeds');
	is(scalar @{$r->{raised}}, 0, 'and nothing was raised');
};

subtest 'one problem reads as its refusal read before' => sub {
	plan tests => 3;
	my $r = refused(action => 'propagate', outcome => 'Nothing was written.',
		problems => [problem(CONFIG,
			'The pipeline has never been applied.  Run #C{genesis pipeline-apply}.')]);
	is(scalar @{$r->{raised}}, 1, 'one refusal');
	is($r->{raised}[0][0]{exitcode}, CONFIG, 'at the problem\'s own code');
	is(words($r->{raised}[0]),
		'Refusing to propagate.  The pipeline has never been applied.  '.
		'Run #C{genesis pipeline-apply}.  Nothing was written.',
		'in the words it had');
};

subtest 'several problems are named in one refusal' => sub {
	plan tests => 5;
	my $r = refused(action => 'propagate', outcome => 'Nothing was written.',
		problems => [
			problem(DATAERR, 'The working tree has uncommitted changes.'),
			problem(CONFIG,  'The pipeline has never been applied.'),
		]);
	is(scalar @{$r->{raised}}, 1, 'one refusal for both');
	is($r->{raised}[0][0]{exitcode}, CONFIG, 'at the highest-ranked code');
	my $said = words($r->{raised}[0]);
	like($said, qr/uncommitted changes.*never been applied/s, 'naming each, in order');
	like($said, qr/\A Refusing \s to \s propagate\./x, 'framed once');
	is(() = $said =~ /Nothing was written/g, 1, 'with the outcome said once');
};

subtest 'a gate names the questions it left unasked' => sub {
	plan tests => 3;
	my $r = refused(action => 'propagate', outcome => 'Nothing was written.',
		problems => [
			problem(DATAERR, 'The working tree has uncommitted changes.'),
			problem(DATAERR, 'The control branch control has diverged from origin/control.'),
		],
		not_checked => {
			because => 'control has diverged from origin',
			checks  => ['the pull request prefix', 'the illegal branches'],
		});
	my $said = words($r->{raised}[0]);
	like($said, qr/uncommitted changes/, 'the problems asked before the gate are named');
	like($said, qr/Not checked, because control has diverged from origin: the pull request prefix and the illegal branches\./,
		'and the questions the gate left unasked, with why');
	is($r->{raised}[0][0]{exitcode}, DATAERR, 'at the code of what was found');
};

# A teammate's T, a bare R, and the operator's clone L of it, with R then
# moved on by one commit on control and a snapshot of R taken into L.
sub moved_world {
	require Genesis;
	require Service::Git;
	my $base = helper::workdir() . sprintf('/pf-%d-%06d', $$, int(rand(1_000_000)));
	my ($t, $r, $l) = ("$base/t", "$base/r.git", "$base/l");
	mkdir_or_fail($base);
	mkdir_or_fail($t);
	my $git_in = sub {Genesis::run({dir => shift, onfailure => 'git failed'}, 'git', @_)};
	my $commit = sub {
		my ($dir, $file) = @_;
		put_file("$dir/$file", "$file\n");
		$git_in->($dir, 'add', $file);
		$git_in->($dir, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', $file);
	};
	$git_in->($t, 'init', '-q', '-b', 'control');
	$commit->($t, 'first');
	$git_in->($t, 'branch', $_) for qw(qa/bosh lab/bosh);
	$git_in->($base, 'clone', '-q', '--bare', $t, $r);
	$git_in->($t, 'remote', 'add', 'origin', $r);
	$git_in->($base, 'clone', '-q', $r, $l);
	$commit->($t, 'second');
	$git_in->($t, 'push', '-q', 'origin', 'control');

	my $git = Service::Git->new($l);
	$git->pipeline_remote('origin');
	$git->snapshot_remote(branches => ['control'], globs => ['*/bosh']);
	return {l => $l, t => $t, git => $git, run => $git_in,
		commit    => sub {$commit->($l, shift)},
		commit_in => $commit};
}

my $SNAP = 'refs/genesis/preflight/origin';
{
	package Stub::Top;
	sub new { my ($c, %o) = @_; bless {control => 'control', %o}, $c }
	sub control_branch { $_[0]{control} }
	sub source_control_remote { 'origin' }
	sub branch_for { "$_[1]/bosh" }
}

# Every ref the clone has, so a row can say the questions moved none of them.
sub refs_of {
	my ($dir) = @_;
	my ($out) = Genesis::run({dir => $dir}, 'git', 'for-each-ref',
		'--format=%(refname) %(objectname)', 'refs/heads', 'refs/remotes');
	return $out;
}

subtest "the initial state is classified against the snapshot, moving nothing" => sub {
	plan tests => 7;
	my $w   = moved_world();
	my ($l, $t, $run) = @{$w}{qw/l t run/};

	# qa/bosh carries a hand commit, dev/bosh was cut here and never pushed,
	# and lab/bosh is behind R by a commit T has not seen.
	$run->($l, 'branch', '-q', $_, "origin/$_") for qw(qa/bosh lab/bosh);
	$run->($l, 'checkout', '-q', 'qa/bosh');
	$w->{commit}->('by-hand');
	$run->($l, 'checkout', '-q', '-b', 'dev/bosh');
	$run->($l, 'checkout', '-q', 'control');
	$run->($t, 'checkout', '-q', 'lab/bosh');
	$w->{commit_in}->($t, 'lab-moves');
	$run->($t, 'push', '-q', 'origin', 'lab/bosh');
	$w->{git}->snapshot_remote(branches => ['control'], globs => ['*/bosh']);
	my $before = refs_of($l);

	my ($state, @problems) = Genesis::CI::Preflight::initial_state_problems(
		Stub::Top->new, $w->{git}, envs => [qw(qa lab dev)], tracking => $SNAP);

	is(scalar @problems, 2, 'two branches no run may start from');
	is_deeply([map {$_->{code}} @problems], [DATAERR, DATAERR], 'each at DATAERR');
	like($problems[0]{text}, qr/#C\{dev\/bosh\} has no counterpart/,
		'the branch R never had, first, as the stage asks');
	like($problems[1]{text}, qr/qa\/bosh/, 'then the hand commit');
	is($state->{branches}{lab}{state}, 'behind',
		'a branch behind R is measured against the snapshot, not T');
	is_deeply([map {$_->{branch}} @{$state->{reset} || []}], [],
		'no marker-only branch to reset');
	is(refs_of($l), $before, 'and nothing was moved to ask');
};

subtest 'a preview assumes the branches the clone lacks are created' => sub {
	plan tests => 4;

	# The clone has control alone, and R and T have qa/bosh and lab/bosh.  A
	# run creates both before its stage; a preview creates neither and reads
	# each at T, naming the creation in the conditional (D44, noted
	# 2026-10-09).
	my $w      = moved_world();
	my $before = refs_of($w->{l});

	my $state = Genesis::CI::Preflight::initial_state(Stub::Top->new, $w->{git},
		envs      => [qw(qa lab)],
		refreshed => {ok => 1, kind => 'success', created => []},
		control   => {divergence => {state => 'in-sync'}, events => []},
		dry_run   => 1);

	is($state->{branches}{qa}{assumed}, 'refs/remotes/origin/qa/bosh',
		'the branch is read at T');
	is($state->{branches}{qa}{assumed_move}, 'create', 'as an assumed creation');
	like(join("\n", @{$state->{events}}), qr{would create qa/bosh from origin/qa/bosh},
		'named as one that would be made');
	is(refs_of($w->{l}), $before, 'and nothing was created');
};

subtest 'a commit R has and T has not seen is no hand commit' => sub {
	plan tests => 2;
	my $w = moved_world();
	my ($l, $t, $run) = @{$w}{qw/l t run/};

	$run->($t, 'checkout', '-q', 'lab/bosh');
	$w->{commit_in}->($t, 'lab-moves');
	$run->($t, 'push', '-q', 'origin', 'lab/bosh');
	$w->{git}->snapshot_remote(branches => ['control'], globs => ['*/bosh']);
	$run->($l, 'branch', '-q', 'lab/bosh', "$SNAP/lab/bosh");

	my ($state, @problems) = Genesis::CI::Preflight::initial_state_problems(
		Stub::Top->new, $w->{git}, envs => ['lab'], tracking => $SNAP);
	is(scalar @problems, 0, 'a branch at what R holds carries nothing of its own');
	is($state->{branches}{lab}{state}, 'in-sync', 'and stands in step with R');
};

subtest "control's standing is read against the snapshot" => sub {
	plan tests => 10;
	my $w   = moved_world();
	my $top = Stub::Top->new;
	my $problems = sub {[Genesis::CI::Preflight::control_problems($top, $w->{git},
		tracking => $SNAP, @_)]};

	my $behind = $problems->();
	is(scalar @$behind, 1, 'control behind R is one problem');
	is($behind->[0]{code}, DATAERR, 'at DATAERR');
	like($behind->[0]{text}, qr/behind #C\{origin\/control\} by 1 commit, so it is stale/,
		'in the words the refusal had');
	unlike($behind->[0]{text}, qr/Refusing to|Nothing was written/,
		'with the frame left to the one refusal');

	$w->{run}->($w->{l}, 'merge', '-q', '--ff-only', "$SNAP/control");
	$w->{commit}->('local');
	like($problems->()->[0]{text}, qr/ahead of #C\{origin\/control\} by 1 commit, which is unpublished/,
		'control ahead of R is unpublished');
	is(scalar @{$problems->(permit_ahead => 1)}, 0, 'which a preview permits');

	$w->{run}->($w->{l}, 'checkout', '-q', '--detach');
	$w->{run}->($w->{l}, 'branch', '-q', '-D', 'control');
	is(scalar @{$problems->(creates_local => 1)}, 0,
		'a control the clone lacks is none where the run creates it');
	is($problems->()->[0]{code}, DATAERR, 'and a problem where it does not');

	# The run cannot create the branch the tree stands on, unborn, so the
	# absence is still answered there.
	$w->{run}->($w->{l}, 'checkout', '-q', '--orphan', 'control');
	like(($problems->(creates_local => 1)->[0] // {})->{text} // '',
		qr/not in\s+this clone/,
		'nor where the tree stands on control unborn, which no run can create');

	my $nowhere = [Genesis::CI::Preflight::control_problems(
		Stub::Top->new(control => 'nothing'), $w->{git}, tracking => $SNAP)];
	is($nowhere->[0]{code}, CONFIG, 'a control nowhere at all is CONFIG');
};

subtest 'a preview has no control to stand on where the clone has none' => sub {
	plan tests => 2;

	# A preview stands on control as a run does and creates nothing, so the
	# control a run would create from T is a problem for it (D44, noted
	# 2026-10-09).
	my $w = moved_world();
	$w->{run}->($w->{l}, 'checkout', '-q', '--detach');
	$w->{run}->($w->{l}, 'branch', '-q', '-D', 'control');
	my ($found) = Genesis::CI::Preflight::control_problems(Stub::Top->new,
		$w->{git}, tracking => $SNAP, preview => 1);

	is($found && $found->{code}, DATAERR, 'at DATAERR');
	like($found && $found->{text}, qr/a preview creates nothing.*git checkout control/s,
		'saying a preview creates nothing, and how to create it');
};

subtest 'every pull request environment\'s collision is named' => sub {
	plan tests => 4;
	no warnings qw/once redefine/;
	local *Stub::Top::pr_branch_problems = sub {
		my ($self, $env) = @_;
		return ("pr-$env/bosh", $env eq 'prod' ? () :
			problem(CONFIG, "The pull request branch for $env collides."));
	};
	my $topology = {
		order => [qw(lab qa prod)],
		nodes => {lab => {require_pr => 1}, qa => {require_pr => 1},
		          prod => {require_pr => 1}},
	};
	my ($branch_of, @problems) = Genesis::CI::Preflight::prefix_problems(
		Stub::Top->new, topology => $topology);
	is(scalar @problems, 2, 'every collision, not the first');
	like($problems[0]{text}, qr/for lab/, 'in the order of the topology');
	like($problems[1]{text}, qr/for qa/, 'each of them');
	is($branch_of->{prod}, 'pr-prod/bosh', 'and the branch of one that collides with nothing');
};

subtest 'the applied record is asked for, and its absence named' => sub {
	plan tests => 6;
	no warnings qw/once redefine/;
	local *Stub::Top::applied_record_path = sub {'/secret/exodus/_pipelines/bosh'};

	local *Stub::Top::applied_record = sub {undef};
	my ($none, @never) = Genesis::CI::Preflight::applied_record_problems(Stub::Top->new);
	is($never[0] && $never[0]{code}, CONFIG, 'a pipeline never applied is CONFIG');
	like($never[0] && $never[0]{text}, qr/pipeline-apply\} has never been run.*_pipelines\/bosh/s,
		'naming the record it looked for');
	unlike($never[0] && $never[0]{text}, qr/Nothing was written/, 'with the outcome left to the one refusal');

	local *Stub::Top::applied_record = sub {die "permission denied\n"};
	my (undef, @unread) = Genesis::CI::Preflight::applied_record_problems(Stub::Top->new);
	is($unread[0] && $unread[0]{code}, UNAVAILABLE, 'a vault that would not say is UNAVAILABLE');
	like($unread[0] && $unread[0]{text}, qr/Could not read the applied record.*permission denied/s,
		'with what it said');

	local *Stub::Top::applied_record = sub {{control_commit => 'abc'}};
	my ($record, @fine) = Genesis::CI::Preflight::applied_record_problems(Stub::Top->new);
	is_deeply([$record, scalar @fine], [{control_commit => 'abc'}, 0], 'and a record read is no problem');
};

subtest "GitHub's refusals are answered as problems, the first ending the reads" => sub {
	plan tests => 5;
	require Genesis::CI::PullRequest;
	no warnings qw/once redefine/;
	my $asked = 0;
	local *Genesis::CI::PullRequest::state_for_scope = sub {
		my ($top, %o) = @_;
		for my $env (@{$o{envs}}) {
			$asked++;
			$o{refuse}->({exitcode => UNAVAILABLE},
				"Could not read the review state of #C{%s}'s pull request.", $env->{env});
			last if $o{stop} && $o{stop}->();
		}
		return ('client', 'team/bosh', {});
	};

	my ($github, @problems) = Genesis::CI::Preflight::github_problems(
		Stub::Top->new, envs => [{env => 'qa'}, {env => 'prod'}]);
	is(scalar @problems, 1, 'one problem');
	is($problems[0]{code}, UNAVAILABLE, 'at its own code');
	like($problems[0]{text}, qr/review state of #C\{qa\}/, 'in its own words');
	is($asked, 1, 'and an API that would not answer is not asked again');
	is($github->{owner_repo}, 'team/bosh', 'with what was read handed back');
};

subtest 'a percent sign in a problem is not read as a format' => sub {
	plan tests => 1;
	my $r = refused(action => 'propagate', outcome => 'Nothing was written.',
		problems => [problem(DATAERR, 'The branch qa/100%done is behind.')]);
	like(words($r->{raised}[0]), qr{qa/100%done}, 'the name arrives whole');
};

done_testing;
