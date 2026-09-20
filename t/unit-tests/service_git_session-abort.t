#!/usr/bin/env perl
# Proves T60, a failed restore is loud; T61, a fault between the first file
# write and the commit leaves nothing staged; T65, an abort resets what the
# session wrote and leaves control alone; and T66, nothing force-writes the
# local control ref.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Cwd qw/getcwd/;
use Genesis;
use Genesis::Exit qw/SOFTWARE/;
use_ok 'Service::Git::Session';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the baseline swallowed a failed restore' => sub {
	plan tests => 4;

	# H2's shape, read where it lived.  Once restore_branch is gone at the
	# last task of this step there is nothing left to run, so the evidence
	# is the code itself: passfail set and the result dropped on the floor.
	#
	# The read is asked of the repository by name and both halves of its
	# answer are weighed, because a tree that does not hold the baseline
	# commit hands back nothing at all, and nothing satisfies the first row
	# below and fails the second for a reason that has no bearing on what
	# the baseline actually did.
	my ($baseline, $rc) = run({dir => $helper::TOPDIR, stderr => 0},
		'git', 'show', '048a9933:lib/Service/Git.pm');
	is($rc, 0, 'the baseline commit is in this repository to read');
	ok(defined $baseline && length $baseline,
		'and the file it names came back with it');

	my ($sub) = ($baseline // '') =~ /sub restore_branch \{(.*?)\n\}/s;
	like($sub, qr/passfail\s*=>\s*1/,
		'the baseline restore ran its checkout with passfail set');
	unlike($sub, qr/bail|die|onfailure/,
		'and raised nothing when it failed, which is H2');
};

subtest 'a failed restore reaches the stuck state and dies naming both' => sub {
	plan tests => 5;

	# A stuck session is one that could not put the working tree back, and
	# it leaves this process standing in the repository it gave up on, so
	# the directory is taken now and put back at the end of the row.  A
	# later row that reads a relative path would otherwise read it against
	# a temporary repository rather than against the tree under test.
	my $cwd = getcwd();

	my $h   = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $git = fault_git($h, copy => 'a');
	my $session = $git->session(control => $h->control);

	$session->begin;
	$session->switch($h->slug('qa'));

	# The step counter is persistent by design, and the switch above spent
	# checkout call one, so the count goes back to nought before the fault
	# is armed and the restore's checkout is the call the row names.
	reset_steps($git);

	# The restore itself fails, which is the case the baseline swallowed.
	fail_on($git, 'checkout', 1, from => 1, message => 'index is in the way');
	my $err = exception(sub { $session->abort('the writer could not finish') });

	like($err, qr/the writer could not finish/,
		'the stuck error names the original error');
	like($err, qr/index is in the way/,
		'and the restore failure beside it');
	like($err, qr/\Q@{[$h->control]}\E/,
		'and the branch we could not return to');
	like($err, qr/\Q@{[$h->slug('qa')]}\E/,
		'and the branch we are stuck on');
	ok(!$session->active, 'the session is closed, stuck rather than open');

	chdir($cwd) or die "cannot return to $cwd: $!\n";
};

subtest 'a reset that cannot run is loud rather than carried through' => sub {
	plan tests => 4;

	# The discard is made to fail by taking the write bit off the directory
	# git has to unlink in, and root is not subject to that bit: as root
	# the discard would succeed, the abort would take its ordinary path,
	# and two of these rows would go red over a permission rather than over
	# the code.  The harness cannot arm this fault instead, because its
	# plan wraps Service::Git methods and the discard is a bare run inside
	# the session.
	SKIP: {
		skip 'cannot fail a discard as root', 4 if $> == 0;

		my $cwd = getcwd();

		my $h = make_harness(envs => ['qa']);
		init_branch($h, 'qa');
		my $control = commit_on_control($h,
			files   => {'ops/one.yml' => "---\none: true\n"},
			message => 'an ops file for qa',
			push    => 1,
		);

		my $git = $h->git('a');
		my $session = $git->session(control => $h->control);
		$session->begin;
		$session->switch($h->slug('qa'));
		$git->checkout_file($control, 'ops/one.yml');
		$git->commit('deliver ops/one.yml', 'ops/one.yml');

		# Something wrote into the tree, and the directory it wrote into
		# cannot be written again, which is a discard git reports and
		# cannot make.  An abort that read nothing back would go on to
		# check out control over a tree that still holds those changes.
		my $ops  = $h->a . '/ops';
		my $mode = (stat($ops))[2] & 07777;
		put_file($h->a . '/ops/one.yml', "---\none: written by a hook\n");
		chmod 0500, $ops;
		my ($err, $exit) = bail_from(sub {$session->abort('the run failed')});
		chmod $mode, $ops;

		# The words asked for are the message's own and appear nowhere in
		# this row's name or in the error handed to abort, because
		# Carp::Always folds a backtrace into a caught death and a
		# backtrace carries both of those strings, so a looser pattern
		# would match the row's own name.
		like($err, qr/\Athe run failed/,
			'the refusal opens with the original error');
		like($err, qr/could not be discarded/,
			'and says the uncommitted changes are still in the tree');
		like($err, qr/\Q@{[$h->slug('qa')]}\E/,
			'and names the branch we are left standing on');
		is($exit, SOFTWARE, 'and it exits SOFTWARE, because this is a defect');

		# The refusal comes before the restore, so this process is still
		# standing in the repository the abort gave up on.
		chdir($cwd) or die "cannot return to $cwd: $!\n";
	}
};

subtest 'a fault between the first write and the commit leaves nothing staged' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files => {
			'qa.yml'     => "---\nkit: dev\n",
			'ops/one.yml' => "---\none: true\n",
		},
		message => 'two files for qa',
		push    => 1,
	);

	my $git = fault_git($h, copy => 'a');
	my $session = $git->session(control => $h->control);
	my $w = snapshot_w($h, copy => 'a');

	$session->begin;
	$session->switch($h->slug('qa'));

	# Fail after the first checkout_file and before the commit, which is
	# exactly the window H1 names.
	fail_on($git, 'checkout_file', 2, message => 'disk went away');
	my $err = exception(sub {
		eval {
			$git->checkout_file($control, 'qa.yml');
			$git->checkout_file($control, 'ops/one.yml');
			$git->commit('deliver qa', 'qa.yml', 'ops/one.yml');
			1;
		} or $session->abort($@);
	});

	like($err, qr/disk went away/, 'the fault reached the caller');
	ok($git->is_clean,
		'the tree and the index are both clean, so nothing stayed staged');
	is($git->current_branch, $h->control,
		'and we stand on the branch begin recorded');
	assert_w_restored($w, 'working state is whole after the fault');
};

subtest 'abort resets every branch it committed to and leaves control alone' => sub {
	plan tests => 5;

	my $h = make_harness(envs => ['qa', 'prod']);
	init_branch($h, 'qa');
	init_branch($h, 'prod');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);

	my $git = $h->git('a');
	my $qa_t   = $git->sha('refs/remotes/origin/' . $h->slug('qa'));
	my $prod_t = $git->sha('refs/remotes/origin/' . $h->slug('prod'));
	my $control_before = $git->sha($h->control);

	my $session = $git->session(control => $h->control);
	$session->begin;
	for my $env (qw/qa prod/) {
		$session->switch($h->slug($env));
		$git->checkout_file($control, 'qa.yml');
		$git->commit("deliver to $env", 'qa.yml');
	}
	exception(sub { $session->abort('the run failed') });

	is($git->sha($h->slug('qa')), $qa_t,
		'qa/bosh sits back at its remote-tracking ref');
	is($git->sha($h->slug('prod')), $prod_t,
		'prod/bosh sits back at its remote-tracking ref');
	is($git->sha($h->control), $control_before,
		"control's local ref is untouched");
	is($git->current_branch, $h->control, 'and we are back on control');
	ok($git->is_clean, 'with a clean tree');
};

subtest 'abort takes off a branch this run cut' => sub {
	plan tests => 4;

	# A pull request branch is derived state: the run cuts it from the
	# deployment branch where neither side holds it, and an abort owes it
	# the absence it found rather than a reset to some tip.  A branch left
	# standing here is a half-written derived branch nobody asked for, and
	# the next run reads it as work somebody else did.
	my $h = make_harness(envs => ['qa'], mode => 'pr');
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);

	my $git    = $h->git('a');
	my $cut    = $h->pr_branch('qa');
	my $qa_t   = $git->sha('refs/remotes/origin/' . $h->slug('qa'));

	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($h->slug('qa'));
	$session->switch($cut, create_from => $h->slug('qa'));
	$git->checkout_file($control, 'qa.yml');
	$git->commit('deliver to the pull request branch', 'qa.yml');

	# The abort runs with the tree standing on the branch it is about to
	# take off, which is where a delivery that died halfway leaves it.
	exception(sub { $session->abort('the run failed') });

	ok(!$git->branch_exists($cut),
		'the branch this run cut is gone, because nobody held it before');
	is($git->sha($h->slug('qa')), $qa_t,
		'the deployment branch it was cut from is back at its remote tip');
	is($git->current_branch, $h->control, 'and we are back on control');
	ok($git->is_clean, 'with a clean tree');
};

subtest 'a branch that cannot go back does not strand the operator' => sub {
	plan tests => 4;

	# The abort answers for two different things: the branches this run
	# wrote, and the branch the operator started on.  Run as one attempt,
	# whichever of them fails first takes the other with it, and the half
	# that failed decides which kind of mess is left.  Here the branch
	# restore is the half that fails, and the operator must still be put
	# back rather than left standing on a branch this run cut.
	my $cwd = getcwd();

	my $h = make_harness(envs => ['qa'], mode => 'pr');
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);

	my $git = fault_git($h, copy => 'a');
	my $cut = $h->pr_branch('qa');

	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($h->slug('qa'));
	$session->switch($cut, create_from => $h->slug('qa'));
	$git->checkout_file($control, 'qa.yml');
	$git->commit('deliver to the pull request branch', 'qa.yml');

	# The tree stands on the branch the restore is about to take off, so
	# the restore has to step off it first, and that step is the checkout
	# the fault below breaks.  The counter is reset because the switches
	# above have already spent several checkouts of their own.
	#
	# That one call is armed and no later one is, because the return to the
	# operator's branch is a checkout too and this row is about the return
	# surviving a branch restore that failed.  Arming from the first call
	# onward would break the return as well and prove nothing.
	reset_steps($git);
	fail_on($git, 'checkout', 1, message => 'the branch is in the way');

	my $err = exception(sub {$session->abort('the writer could not finish')});

	is($git->current_branch, $h->control,
		'the operator is back on the branch they started from');
	like($err, qr/the writer could not finish/,
		'the error names what the run failed at');
	like($err, qr/the branch is in the way/,
		'and the branch restore that failed beside it');
	ok(!$session->active, 'the session is closed either way');

	chdir($cwd) or die "cannot return to $cwd: $!\n";
};

subtest 'control behind its remote-tracking ref is still left alone' => sub {
	plan tests => 3;

	# The session never rebases control and never says anything about it.
	# The message that tells the operator to rebase by hand belongs to the
	# pre-flight, which refuses a control that is behind or ahead.
	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	publish_from_b($h,
		files   => {'ahead.yml' => "---\nahead: true\n"},
		message => 'a teammate publishes',
		branch  => $h->control,
	);
	refresh($h, 'a', $h->control);

	my $git = $h->git('a');
	my $before = $git->sha($h->control);
	isnt($before, $git->sha('refs/remotes/origin/' . $h->control),
		'control is behind its remote-tracking ref');

	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($h->slug('qa'));
	exception(sub { $session->abort('the run failed') });

	is($git->sha($h->control), $before,
		'and the abort did not move it in either direction');
	ok(!grep({$_ eq $h->control} $session->committed_branches),
		'control is never in the set the abort resets');
};

subtest 'a local commit on control survives the session' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');
	my $mine = local_only_commit($h, $h->control,
		marker  => 0,
		files   => {'mine.yml' => "---\nmine: true\n"},
		message => 'work I have not pushed',
	);

	my $git = $h->git('a');
	my $session = $git->session(control => $h->control);
	$session->begin;
	$session->switch($h->slug('qa'));
	$git->checkout_file($mine, 'mine.yml');
	$git->commit('deliver mine.yml', 'mine.yml');
	exception(sub { $session->abort('the run failed') });

	is($git->sha($h->control), $mine,
		'the unpushed commit on control is still control HEAD');
	ok($git->is_ancestor($mine, $git->sha($h->control)),
		'and it was never discarded');

	# I2 is a rule about refs, so the last assertion reads the verbs: no
	# verb of the session writes the control ref under any name.  The path
	# is absolute because the rows above stand this process in temporary
	# repositories of their own, and this one is asking about the module
	# under test rather than about wherever we happen to be.
	my $module = get_file($helper::TOPDIR . '/lib/Service/Git/Session.pm');
	unlike($module, qr/update-ref[^\n]*control|reset --hard[^\n]*control/,
		'no verb of the session force-writes the local control ref');
};

sub exception {
	my ($code) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = '';
	eval { $code->(); 1 } and return '';
	return $@;
}

# The second assertion helper, because a row that weighs an exit code cannot
# read one out of this process: bail dies rather than exits whenever it is
# reached from inside an eval, and a test file always is.  The refusal is
# caught where the code raises it, and the code it would have exited with is
# read off the arguments it was composed with.
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
