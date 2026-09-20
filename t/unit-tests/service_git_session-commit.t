#!/usr/bin/env perl
# Proves T73, a session can stand on a commit, and T74, a commit the
# refresh cannot reach is refused by name at DATAERR.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Genesis;
use Genesis::Exit qw/DATAERR/;
use_ok 'Service::Git::Session';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a session stands on a commit with a detached HEAD' => sub {
	plan tests => 6;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	my $first  = deliver($h, 'qa', control => $control);
	my $second = deliver($h, 'qa',
		control => commit_on_control($h,
			files   => {'qa.yml' => "---\nkit: newer\n"},
			message => 'change qa again',
			push    => 1,
		),
	);
	refresh($h, 'a', $h->slug('qa'));

	my $git = $h->git('a');
	my $w   = snapshot_w($h, copy => 'a');

	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($first);

	is($git->sha('HEAD'), $first, 'HEAD is at the commit we asked for');
	is($git->current_branch, 'HEAD',
		'and HEAD is detached rather than on the branch');

	# Which is why the session asks its own question about where we are
	# standing: git answers the literal string HEAD here, and an operator
	# whose restore failed would be told they are standing on "HEAD", which
	# names nothing they can act on.
	like($session->_standing_on, qr/\Q$first\E/,
		'and a failed restore would name the commit rather than HEAD');

	# The deliveries were made in copy B and handed to R, so what copy A
	# holds of that branch is its remote-tracking ref and not a local one.
	is($h->tip_of($h->slug('qa'), remote => 1), $second,
		"the branch's own tip is where it was, which is not where we stand");
	like(get_file($h->a . '/qa.yml'), qr/kit: dev/,
		'the tree matches the commit and not the tip');

	$session->finish;
	assert_w_restored($w, 'finish restored the branch begin recorded');
};

subtest 'finish restores after a commit exactly as after a branch' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	my $delivered = deliver($h, 'qa', control => $control);
	refresh($h, 'a', $h->slug('qa'));

	my $git = $h->git('a');
	stand_on($h, $h->control);

	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($delivered);
	is($session->on, $delivered, 'the session records what it stands on');

	# The tip table is the set abort resets back to T, so a commit has to
	# stay out of it: it is not a branch this session could have moved.
	is_deeply([keys %{$session->{switched}}], [],
		'and records no tip for it, because a commit is not a branch it moved');
	$session->finish;

	is($git->current_branch, $h->control, 'we are back on control');
	ok($git->is_clean, 'with a clean tree and no detached HEAD left behind');
};

subtest 'a commit the refresh cannot reach is refused at DATAERR' => sub {
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	deliver($h, 'qa', control => $control);
	refresh($h, 'a', $h->slug('qa'));

	# A rewritten branch on R is what D31's force-push ban makes rare and
	# does not make impossible, so the recorded commit can be gone.  The
	# rewrite drops the commit behind the tip, so control needs a tip above
	# the one the record names before there is anything to take away.
	commit_on_control($h,
		files   => {'ops/later.yml' => "---\nlater: 1\n"},
		message => 'a later change',
		push    => 1,
	);
	my $gone = rewrite_control($h);

	# The clone is cut after the rewrite, so it never held the dropped
	# commit at all.  Copy A did hold it, and a fetch moves remote-tracking
	# refs without taking objects away, so the commit is still there to be
	# found in the copy the earlier rows use.
	my $clone = clone_copy($h);
	my $git   = $h->git($clone);

	my $session = $git->session(control => $h->control);
	$session->begin;

	my ($err, $exit) = bail_from(sub {
		$session->switch($gone, record => $h->env_path('qa'));
	});

	like($err, qr/\Q$gone\E/, 'the refusal names the commit');
	like($err, qr/\Q@{[$h->env_path('qa')]}\E/,
		'and the record it came from');
	is($exit, DATAERR, 'and it exits DATAERR');
	is($git->current_branch, $h->control, 'nothing switched');
	ok($git->is_clean, 'and the tree is untouched');

	$session->finish;
};

subtest 'an unborn HEAD is named as the branch it is, not as a commit' => sub {
	plan tests => 5;

	# No caller reaches this today, because begin refuses a repository with
	# no commits before a session exists, so the row asks the sub itself.
	# What it asks about is the answer an operator would read if a later
	# caller ever did get here, and the fallback is the only thing between
	# them and git's own fatal about a commit that cannot be read.
	my $h    = make_harness(envs => ['qa']);
	my $path = fixture_preflight($h, 'no_commits');
	my $git  = Service::Git->new($path);

	my ($named) = run({dir => $path},
		'git', 'symbolic-ref', '--short', 'HEAD');
	chomp $named;

	my $where = $git->session(control => $h->control)->_standing_on;

	like($where, qr/\Q$named\E/,
		'the phrase names the branch HEAD points at');
	like($where, qr/no commits/,
		'and says that the branch has none yet');
	unlike($where, qr/detached|fatal|ambiguous argument/,
		"rather than calling it detached or handing back git's complaint");

	# The phrase carries its own colour, because the three messages that
	# print it read it as a whole rather than wrapping it in a span of
	# their own.  The name is the part an operator types back at git, so
	# that is the part the colour is on, and the prose beside it is not
	# dressed as if it belonged to the name.
	like($where, qr/#C\{\Q$named\E\}/,
		'the branch name is the coloured half of the phrase');
	unlike($where, qr/#C\{[^}]*no commits/,
		'and the prose beside it is left outside the span');
};

# One local helper, because an assertion helper lives beside its test.  bail
# dies rather than exits whenever it is reached from inside an eval, which a
# test file always is, so there is no exit code in this process to read.  The
# refusal is caught where the code raises it instead, and the code it would
# have exited with is read off the arguments it was composed with, which is
# how every other refusal on this branch is read.
sub bail_from {
	my ($code) = @_;

	my @raised;
	{
		no warnings 'redefine', 'once';
		local *Service::Git::Session::bail =
			sub {push @raised, [@_]; die "refused\n"};
		eval {$code->(); 1};
	}
	unless (@raised) {
		diag("nothing was raised; the code died of: $@") if $@;
		return ('', undef);
	}

	my @args = @{$raised[0]};
	my $opts = ref($args[0]) eq 'HASH' ? shift(@args) : {};
	my ($format, @rest) = @args;

	return (sprintf($format, @rest), $opts->{exitcode});
}

done_testing;
