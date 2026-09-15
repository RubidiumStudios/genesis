#!/usr/bin/env perl
# Proves T113 and T114: the index check fails and makes no commit when a
# staged file no longer matches the source, and the ls-files check fails and
# makes no commit when the branch keeps a path the set does not hold, while
# the mirror removes a leftover init and a path that left the set.
#
# Each row composes its own scene out of harness primitives rather than
# through stale_set_delivery, for two reasons.  That helper narrows
# genesis.pipeline.track_additional_files to empty, and the harness's own
# reader of the set treats a declared list as narrowing the kit and ops kinds
# away, so with a kit loaded the two readers disagree about a branch the
# writer delivered correctly.  It also delivers with nothing kept, and the
# init file the mirror has to remove is gone by the time it returns.
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

sub exception {
	my ($code) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = '';
	eval {$code->(); 1} and return '';
	return $@;
}

subtest 'the index check refuses a staged file that left its source' => sub {
	plan tests => 5;

	# The kit's blueprint names one repository-side fragment, so ops/extra.yml
	# is in the set for as long as control holds it, and the embedded genesis
	# is there so the eighth kind is a file rather than a name nothing tracks.
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
	deliver($h, 'qa', copy => 'a', control => $first);

	# One path moves between the delivered commit and the source, so the
	# writer has exactly one file to check out and the row knows which call
	# of checkout_file to stop.
	my $source = commit_on_control($h,
		files   => {'bosh/dev/manifest.yml' => "---\nsimple: moved on\n"},
		message => 'edit the kit',
		push    => 1,
	);

	# The Top and the environment are built before the session begins,
	# because a deployment branch is not a repository a Top can be opened on.
	# The handle is built at the deployment root and not at the copy root,
	# because Service::Git keeps one instance per repository and fixes its
	# prefix at that first construction, and a handle with no prefix makes
	# the set come back deployment-root-relative and match nothing.
	my $in_root = in_root($h->a . '/bosh');
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = $top->load_env('qa');

	# fault_git re-blesses the instance the line above built rather than
	# making a second one, so the session and the faults share one handle.
	my $fault = fault_git($h, copy => 'a');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));
	my $before = ref_in($h->a, $h->slug('qa'));

	# The writing half is stopped and a blob the source carries nowhere is
	# staged in its place, so the index holds a propagation path that no
	# longer matches the commit the writer says it is delivering.
	skip_on($fault, 'checkout_file', 1);
	helper::put_file($h->a . '/bosh/dev/manifest.yml',
		"---\nsimple: tampered\n");
	run({dir => $h->a}, 'git', 'add', '--', 'bosh/dev/manifest.yml');

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

	isa_ok($err, 'Genesis::CI::RunFailure', 'the failure that came back');

	# Read through a guarded copy, so a row that came back with something
	# else fails the assertions below rather than dying on a method call.
	my $failure = failure_of($err);
	is($failure && $failure->kind, 'run-fatal', 'it is the run-fatal class');
	is(ref_in($h->a, $h->slug('qa')), $before, 'no commit was made');
	like($failure ? $failure->report_line : '',
		qr{qa/bosh.*bosh/dev/manifest\.yml},
		'the failure names the branch and the difference');

	exception(sub {$session->abort('the row has read what it came for')});
	assert_w_restored($w, 'the session restores the working state');
};

subtest 'the mirror removes what the set no longer holds' => sub {
	plan tests => 4;

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
	# The init file is kept, because a plain delivery takes it off by
	# construction and this row needs both leftovers standing on one branch.
	deliver($h, 'qa', copy => 'a', control => $first, keep => ['init']);

	# The fragment leaves the set, for a reason the working tree and the
	# delivered commit agree about, and the kit file moves beside it so the
	# writing half of the mirror runs as well as the removing half.
	my $source = commit_on_control($h,
		files   => {
			'bosh/ops/extra.yml'    => undef,
			'bosh/dev/manifest.yml' => "---\nsimple: moved on\n",
		},
		message => 'delete the fragment and edit the kit',
		push    => 1,
	);

	my $in_root = in_root($h->a . '/bosh');
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = $top->load_env('qa');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));

	my $result = $session->apply_files($source,
		env     => $env,
		message => Genesis::CI::Marker::build($source, 'qa'),
	);

	# Read before the finish, because finish puts control's index back and
	# the index this row is asking about is the one the writer left.
	my @left = grep {!m{^bosh/}} $git->ls_files;
	is_deeply([@left], [], 'git ls-files minus the set comes back empty');

	$session->finish;
	assert_w_restored($w, 'the session restores the working state');

	is_deeply([sort @{$result->{removed}}], ['bosh/ops/extra.yml', 'init'],
		'the leftover init and the fragment that left the set both went');

	assert_snapshot_invariant($h, 'qa', copy => 'a',
		name => 'the branch holds its source');
};

subtest 'the second assertion fires when the removal is stopped' => sub {
	plan tests => 4;

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
	# The init file is the one leftover this row leaves standing, and it is
	# the leftover the design says fires in practice.  A stale path that sits
	# under one of the set's own pathspecs would trip the first assertion
	# instead, which is a different refusal.
	deliver($h, 'qa', copy => 'a', control => $first, keep => ['init']);

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

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));
	my $before = ref_in($h->a, $h->slug('qa'));

	# The removing half is stopped, so the index keeps a path outside the
	# set.  A removal git refuses is silent for the same reason, which is
	# why the check and not the sequence is what catches it.
	skip_on($fault, 'rm', 1);

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

	isa_ok($err, 'Genesis::CI::RunFailure', 'the failure that came back');

	my $failure = failure_of($err);
	is(ref_in($h->a, $h->slug('qa')), $before, 'no commit was made');
	like($failure ? $failure->report_line : '', qr{:\s*init$},
		'the failure names the path the index still holds');

	exception(sub {$session->abort('the row has read what it came for')});
	assert_w_restored($w, 'the session restores the working state');
};

done_testing;
