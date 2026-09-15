#!/usr/bin/env perl
# Proves T115 and T118: a failed check ends the run and not just the
# environment, so abort resets every branch the session committed to, nothing
# is published, the environments already walked record that nothing was
# published and the rest that they were not attempted, the report names the
# branch and the difference, and the run exits 1; and a checkout_file that dies
# partway through leaves the branch at T with a clean tree and a clean index.
#
# The second row is the one that reaches _record_commit.  A branch whose tip
# moved is one the session works out for itself by comparing tips, so the only
# way to read the record is a commit that leaves the tip where it was, and the
# row arms exactly that.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Cwd ();
use Genesis;
use Genesis::CI::Marker;
use Genesis::CI::RunFailure;
use Genesis::Top;
use Service::Git;
use Service::Git::Session;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# in_root - stand in the deployment root for the rest of the caller's scope
#
# Every row here runs from the deployment root, because propagation_files
# reads the repository through Service::Git->new('.'), and every row has to
# come back however it leaves.  A bare chdir at the end of the row is not
# enough, since a failure inside the session skips it and the next row would
# then start from the harness workdir.  The guard is handed back rather than
# kept here, so it lets go at the end of the caller's scope.
#
# This pair is a verbatim copy of the one in
# t/unit-tests/service_git_session-index_assertions.t, and the lift of both
# into the harness is landing from another worktree.  Whichever file commits
# last drops its copy and calls the harness's.
sub in_root {
	my ($dir) = @_;
	return ChdirGuard->enter($dir);
}

# failure_of - the failure where one came back, and undef otherwise
#
# A row that came back with something other than the failure class reads
# undef here, so the assertions below fail on what they mean rather than
# dying on a method called against a string.
sub failure_of {
	my ($err) = @_;
	return ref($err) eq 'Genesis::CI::RunFailure' ? $err : undef;
}

{
	package ChdirGuard;

	sub enter {
		my ($class, $dir) = @_;
		my $was = Cwd::getcwd();
		chdir $dir or die "cannot enter $dir: $!\n";
		return bless {was => $was}, $class;
	}

	sub DESTROY {
		my ($self) = @_;
		chdir $self->{was} or warn "cannot return to $self->{was}: $!\n";
	}
}

# exception - run a block that ends in bail and hand back what it said
#
# Every abort in this file goes through here, because abort ends in bail and
# a bail inside a subtest exits the file rather than failing a row.
sub exception {
	my ($code) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = '';
	eval {$code->(); 1} and return '';
	return $@;
}

subtest 'the failure ends the run and every branch goes back to T' => sub {
	plan tests => 8;

	# The kit's blueprint names one repository-side fragment, so ops/extra.yml
	# is in the set for as long as control holds it, and the embedded genesis
	# is there so the eighth kind is a file rather than a name nothing tracks.
	my $h = make_harness(
		envs => ['qa', 'dev', 'prod'], root => 'bosh',
		kit  => 't/src/ops-blueprint', embed => 1,
	);
	fixture_vault($h);
	init_branch($h, $_) for qw(qa dev prod);

	my $source = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => "---\nextra: yes\n"},
		message => 'add the fragment the blueprint names',
		push    => 1,
	);

	# The Top and both environments are built before the session begins,
	# because a deployment branch is not a repository a Top can be opened on.
	# The handle is built at the deployment root and not at the copy root,
	# because Service::Git keeps one instance per repository and fixes its
	# prefix at that first construction, and a handle with no prefix makes
	# the set come back deployment-root-relative and match nothing.
	my $in_root = in_root($h->a . '/bosh');
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $qa  = $top->load_env('qa');
	my $dev = $top->load_env('dev');

	# fault_git re-blesses the instance the line above built rather than
	# making a second one, so the session and the faults share one handle.
	my $fault = fault_git($h, copy => 'a');

	my %before = map {$_ => ref_in($h->a, 'refs/remotes/origin/' . $h->slug($_))}
		qw(qa dev prod);

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;

	# qa is delivered, dev fails its check, and prod is never reached.
	$session->switch($h->slug('qa'));
	$session->apply_files($source,
		env     => $qa,
		message => Genesis::CI::Marker::build($source, 'qa'),
	);

	# The mirror's removing half is stopped on dev, so the init file the
	# branch was cut with stays in the index and the second assertion fires.
	# The counters go back first, because qa's own delivery already took one
	# call of rm and this row means dev's.
	reset_steps($fault);
	skip_on($fault, 'rm', 1);

	$session->switch($h->slug('dev'));
	my $err = do {
		local $@;
		eval {
			$session->apply_files($source,
				env     => $dev,
				message => Genesis::CI::Marker::build($source, 'dev'),
			);
			1;
		} or $@;
	};

	isa_ok($err, 'Genesis::CI::RunFailure', 'the failure that came back');

	# Read through a guarded copy, so a row that came back with something
	# else fails the assertions below rather than dying on a method call.
	my $failure = failure_of($err);
	is($failure && $failure->exit_code, 1,
		'the run exits 1, the one bare code the design writes');
	like($failure ? $failure->report_line : '', qr{dev/bosh},
		'the report names the branch');

	exception(sub {$session->abort('the row has read what it came for')});

	is(ref_in($h->a, 'refs/heads/' . $h->slug('qa')), $before{qa},
		'the branch the session committed to is back at T');
	is(ref_in($h->a, 'refs/heads/' . $h->slug('dev')), $before{dev},
		'the branch that failed is back at T');
	is(ref_in($h->r, 'refs/heads/' . $h->slug('qa')), $before{qa},
		'nothing was published');

	my $outcomes = Genesis::CI::RunFailure::abort_outcomes(['qa', 'dev', 'prod'], 'dev');
	is_deeply($outcomes, {
		qa   => 'not published, run aborted',
		dev  => 'not published, run aborted',
		prod => 'not attempted',
	}, 'every environment walked records the abort and the rest are not attempted');

	assert_w_restored($w, 'the abort restores the working state');
};

# Proves the half of T115 that the tips cannot say.  The session resets every
# branch it committed to, and it works most of that set out by comparing each
# branch's tip against the tip it recorded at the switch, so a commit that
# leaves the tip where it was is invisible to the comparison.  The writer says
# so outright instead, and this row is where that record is read.
subtest 'a commit that left the tip where it was is still reset' => sub {
	plan tests => 5;

	my $h = make_harness(
		envs => ['qa'], root => 'bosh',
		kit  => 't/src/ops-blueprint', embed => 1,
	);
	fixture_vault($h);
	init_branch($h, 'qa');

	my $first = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => "---\nextra: yes\n"},
		message => 'add the fragment the blueprint names',
		push    => 1,
	);

	# The delivery is made in copy A and left unpublished, which is the state
	# a run is in for as long as it is walking, since a delivery is committed
	# as the walk reaches each environment and published only at the end.  The
	# local branch is therefore ahead of the remote-tracking ref the abort
	# puts it back to.
	deliver($h, 'qa', copy => 'a', control => $first, push => 0);

	my $source = commit_on_control($h,
		files   => {'bosh/dev/manifest.yml' => "---\nsimple: moved on\n"},
		message => 'edit the kit',
		push    => 1,
	);

	my $in_root = in_root($h->a . '/bosh');
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = $top->load_env('qa');
	my $fault = fault_git($h, copy => 'a');

	my $t     = ref_in($h->a, 'refs/remotes/origin/' . $h->slug('qa'));
	my $ahead = ref_in($h->a, 'refs/heads/' . $h->slug('qa'));
	isnt($ahead, $t, 'the branch starts ahead of the ref the abort puts it back to');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));

	# The commit is stopped rather than failed, so the writer runs the whole
	# of its sequence and comes back as it does on a delivery that landed,
	# and the only difference is the tip.
	skip_on($fault, 'commit', 1);
	$session->apply_files($source,
		env     => $env,
		message => Genesis::CI::Marker::build($source, 'qa'),
	);

	ok(scalar(grep {$_->[0] eq 'commit'} step_log($fault)),
		'the writer did commit, and the harness kept the commit from landing');
	is(ref_in($h->a, 'refs/heads/' . $h->slug('qa')), $ahead,
		'the commit left the tip where the switch found it');

	exception(sub {$session->abort('the row has read what it came for')});

	is(ref_in($h->a, 'refs/heads/' . $h->slug('qa')), $t,
		'the branch the writer committed to is back at T anyway');
	assert_w_restored($w, 'the abort restores the working state');
};

subtest 'a checkout_file that dies leaves the branch at T and clean' => sub {
	plan tests => 4;

	my $h = make_harness(
		envs => ['qa'], root => 'bosh',
		kit  => 't/src/ops-blueprint', embed => 1,
	);
	fixture_vault($h);
	init_branch($h, 'qa');

	my $source = commit_on_control($h,
		files   => {'bosh/dev/one.yml'   => "---\none: yes\n",
		            'bosh/dev/two.yml'   => "---\ntwo: yes\n",
		            'bosh/dev/three.yml' => "---\nthree: yes\n"},
		message => 'add three files under the kit',
		push    => 1,
	);

	my $in_root = in_root($h->a . '/bosh');
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = $top->load_env('qa');
	my $before = ref_in($h->a, 'refs/remotes/origin/' . $h->slug('qa'));

	my $fault = fault_git($h, copy => 'a');
	fail_on($fault, 'checkout_file', 3, message => 'the third write dies');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));

	my $err = do {
		local $@;
		eval {
			$session->apply_files($source,
				env     => $env,
				message => Genesis::CI::Marker::build($source, 'qa'),
			);
			1;
		} or $@;
	};
	ok($err, 'the delivery failed');

	exception(sub {$session->abort('the row has read what it came for')});
	assert_w_restored($w, 'the abort restores the working state');

	is(ref_in($h->a, 'refs/heads/' . $h->slug('qa')), $before,
		'the branch is back at T and no commit stands');
	ok($git->is_clean, 'the tree and the index are clean');
};

done_testing;
