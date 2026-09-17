#!/usr/bin/env perl
# Proves T86, T87, and T109: a branch that is behind is fast-forwarded
# before the walk, the diff base stays the local ref, and a teammate's
# published delivery is no longer invisible to it.
#
# The claim about the diff base is made by a pair.  One half shows that a
# delivery already on the branch is not delivered again, and the other that a
# change control still holds is named as pending, because a diff taken
# against a ref that is not there comes back empty and so satisfies the first
# half on its own.
#
# Every phrase is matched across the wrap.  An event line is wrapped to the
# terminal width before it reaches standard error, so a clause the reader
# sees on one line can arrive with a newline and an indent inside it.
#
# Genesis accounts for itself on standard error, which is where info writes,
# so every line the run reports is read out of the second value rather than
# the first.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a branch that is behind is fast-forwarded before the walk' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h  = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	# An ops file rather than a rewritten qa.yml.  The environment file is
	# where the pipeline metadata lives, so overwriting it empties the
	# topology and the run bails on that several steps before the
	# fast-forward this row is about.
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nfrom: control\n"}, push => 1);
	my $theirs = deliver($h, 'qa', control => $control, copy => 'b');
	refresh($h, 'a', $qa);

	is($h->git('a')->resolve_branch($qa)->{state}, 'behind',
		'copy A starts the run behind the remote');

	my (undef, $err) = run_genesis($h, 'propagate');

	is($h->git('a')->resolve_branch($qa)->{state}, 'in-sync',
		'the pre-flight moved it up to the tracking ref');
	like($err, qr{fast-forwarded\s+\Q$qa\E}, 'and reported the move');
	ok((grep { $_ eq $theirs } commits_on($h->a, "refs/heads/$qa")),
		"the teammate's commit is on the branch, not diffed around");
};

subtest 'the fast-forward discards no commit anywhere' => sub {
	# Three rows, and one more for the run's own restoration assertion.
	plan tests => 4;

	my $h  = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nfrom: control\n"}, push => 1);
	my $theirs  = deliver($h, 'qa', control => $control, copy => 'b');
	my @on_r    = commits_on($h->r, $qa);

	run_genesis($h, 'propagate');

	is(ref_in($h->a, "refs/heads/$qa"), ref_in($h->a, "refs/remotes/origin/$qa"),
		'the local ref and the tracking ref agree afterwards');
	ok((grep { $_ eq $theirs } commits_on($h->a, "refs/heads/$qa")),
		"the teammate's delivery survived the run");
	is_deeply([grep { my $c = $_; grep { $_ eq $c } commits_on($h->r, $qa) } @on_r],
		[@on_r], 'and every commit that was on the remote is still there');
};

subtest 'a teammate delivery already on the branch is not delivered twice' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h  = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nfrom: control\n"}, push => 1);

	# The teammate has already delivered this very control commit, which on
	# the baseline the diff could not see, because it compared the local
	# ref to the source and the local ref had not moved.
	my $theirs = deliver($h, 'qa', control => $control, copy => 'b');
	my @before = commits_on($h->r, $qa);

	my (undef, $err) = run_genesis($h, 'propagate');

	# The walk is where the diff is taken, so a run that reaches its banner
	# is a run whose diff base is the branch the pre-flight settled.  The
	# guard between the two stages reads the deployment slug now, so a typed
	# repository no longer stops at it.
	like($err, qr{Propagating from}, 'the run reaches the walk');
	is(ref_in($h->a, "refs/heads/$qa"), $theirs,
		'the branch ends at the delivery the teammate published');
	is_deeply([commits_on($h->r, $qa)], \@before,
		'and nothing new was written for that environment');
	unlike($err, qr{\Q$qa\E.*propagated}, 'the run reports no delivery for it');
};

subtest 'the diff base names what control still has to deliver' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	# The positive half of the pair.  The two subtests above prove that a
	# delivery already on the branch is not delivered again, and a diff
	# taken against a ref that is not there is empty too, so on its own
	# that claim holds whether the base names the settled branch or
	# nothing at all.  Here control carries a change nobody has delivered,
	# and only a base that names a real ref can find it.
	my $h  = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);

	# The branch is brought level with control first, so the one thing the
	# walk can find is the commit made after it.  That commit lands a kit
	# overrides file, which is one of the kinds the propagation set holds
	# outright; an ops file is in the set only where the kit's blueprint
	# draws on it, and this kit's does not.
	deliver($h, 'qa', copy => 'b',
		control => ref_in($h->a, 'refs/heads/' . $h->control));
	commit_on_control($h,
		files => {'kit-overrides.yml' => "---\nfrom: control\n"}, push => 1);

	# A dry run, because what this row is about is which files the walk
	# finds rather than what the delivery writes.
	my (undef, $err) = run_genesis($h, 'propagate', '--dry-run');

	like($err, qr{^\s*qa:\s+would propagate}m,
		'the walk names the environment as receiving the change');
	# qa's own block, counted rather than matched.  A pattern that finds one
	# would-deliver line finds it in a block of two just as readily, and what
	# this row is about is that the base named the settled branch and so
	# found the one commit standing after it.
	my ($block) = $err =~ /^\s*qa: would propagate\n(.*)\z/ms;
	is(scalar(() = ($block // '') =~ /would deliver/g), 1,
		'exactly one commit is due to it');
	like($err, qr{kit-overrides\.yml}, 'and names the file control added');
	unlike($err, qr{No changes to propagate},
		'so the run does not report an empty pipeline');
};

subtest 'a dry run assumes the fast-forward and moves nothing' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h  = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $qa = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $qa);
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nfrom: control\n"}, push => 1);
	deliver($h, 'qa', control => $control, copy => 'b');
	refresh($h, 'a', $qa);

	my $before = ref_in($h->a, "refs/heads/$qa");

	my (undef, $err) = run_genesis($h, 'propagate', '--dry-run');

	is(ref_in($h->a, "refs/heads/$qa"), $before,
		'the dry run left the branch where it stood');
	is($h->git('a')->resolve_branch($qa)->{state}, 'behind',
		'so it is still behind the remote');
	# The warning says only that the fast-forward is assumed.  The sentence
	# naming the counts is the event line, which the caller prints under
	# either kind of run, so the warning does not repeat it.  It takes the
	# shape the preview's own two caveats take, so an operator reading all
	# three reads one kind of sentence.
	like($err, qr/This\s+preview\s+assumes\s+\Q$qa\E\s+is\s+fast-forwarded\s+first/,
		'and the report says it assumes the fast-forward a real run would make');
	# A report that assumes the move has to read as though it had been
	# made, so the diff is taken from the ref a real run would have left
	# the branch on rather than from the ref it is still standing on.
	unlike($err, qr{^\s*qa:\s+would deliver}m,
		'and it names nothing as pending that the teammate already delivered');
};

subtest 'an environment with no branch is reported as awaiting the apply' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	# The kit is here because the walk loads each environment before it
	# reports on it, and an environment whose kit cannot be resolved never
	# reaches the report these rows read.
	my $h  = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $qa = $h->slug('qa');

	# No branch for qa on either side, which is the one state the pre-flight
	# records nothing for.  Nothing stands between the two stages now, so a
	# plain run reaches the walk and the walk says what the environment is
	# waiting for.
	my (undef, $err, $exit) = run_genesis($h, 'propagate');

	is($exit, 0, 'a missing branch does not refuse the run');
	my @said = ($err =~ m{^\s*qa:\s+held,\s+awaiting\s+pipeline-apply}mg);
	is(scalar @said, 1,
		'the walk reports it as awaiting the apply exactly once');
	# Cutting the branch belongs to genesis pipeline-apply, and a run that
	# cut one here would cut it under the environment's own name, which is
	# the ref the real branch needs.
	is(ref_in($h->a, "refs/heads/$qa"), undef,
		'and no deployment branch was created');
	is(ref_in($h->a, 'refs/heads/qa'), undef,
		'nor one under the environment\'s own name');
};

done_testing;
