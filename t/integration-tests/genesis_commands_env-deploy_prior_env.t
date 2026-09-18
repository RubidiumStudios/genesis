#!/usr/bin/env perl
# Proves T226, the predecessor's name read through the merged environment
# hierarchy with no kit behind the read; T326, one read of the predecessor's
# exodus record per deploy, taken before the environment itself is loaded;
# and T328, the check's three cases with L unchanged on every path.
#
# The first subtest builds no director on purpose.  A deploy that reaches the
# predecessor check only after it has loaded the environment and connected to
# BOSH cannot refuse a repository that has no director to connect to, so a
# harness without one is how a row sees which side of the load the check sits
# on.  Every other subtest calls fixture_bosh, because a deploy that is meant
# to reach its end needs the three things that builder puts up.
#
# Every run passes --no-propagate.  The auto-cascade hands off to a child
# genesis propagate, which M15 owns and which fails today, and a row about
# what the deploy read should not be reading the child's work as the deploy's
# own.
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

# The leaf and the file above it in its own hierarchy.  Genesis names an
# ancestor by a cumulative hyphen-prefix of the environment, so these two are
# a site file and a leaf that inherits from it, and a key set on the site
# file is invisible to any reader that opens the leaf alone.
my $LEAF = 'us-east-qa';
my $SITE = 'us-east';

subtest 'the predecessor is named by a site file, and read before the load' => sub {
	plan tests => 7;

	# inherited_harness is this shape by name: it writes the pipeline keys at
	# a site file rather than at the leaf, which is the merged read D79 asks
	# for, and it writes them before the seeding is finished so the delivery
	# that follows carries the file onto the deployment branch.  A key
	# written after the delivery would sit on control alone, and the deploy
	# reads the file the branch it stands on carries.
	my $h = inherited_harness(
		envs          => ['lab', $LEAF],
		site          => $SITE,
		pipeline_keys => {prior_env => 'lab'},
		certified     => [$LEAF],
	);
	# The kit alone, without the director fixture_bosh puts up beside it, so
	# the one thing this deploy cannot do is reach a director.  A check made
	# after the environment is loaded meets that first and says so.
	fixture_kit($h);

	my (undef, $err, $exit) = run_genesis($h,
		$LEAF, 'deploy', '--no-propagate', '-y', 'r');

	is($exit, Genesis::Exit::DATAERR,
		'the inherited predecessor was found, and its refusal exits DATAERR');
	like(unfolded($err), qr/never been successfully deployed/,
		'so the check read the key the site file carries');
	like(unfolded($err), qr/\blab\b/, 'naming the predecessor it names');
	like(unfolded($err), qr/\Q$LEAF\E/,
		'and naming the environment it refused to deploy');
	unlike(unfolded($err), qr/director/i,
		'and it refused before the environment was loaded or a director dialled');

	# The other half of T226, asserted rather than left to follow from the
	# row above.  It is a guard: the read is made through Genesis::Env->bare,
	# which loads no kit, so nothing said here can name one and the row is
	# green on arrival.  What it catches is the read moved onto a loaded
	# environment in a repository whose kit cannot be resolved, where Genesis
	# answers in its own words about a dev kit and the operator hears about
	# the kit rather than about the predecessor they deployed out of order.
	unlike(unfolded($err), qr/dev kit/i,
		'and no kit stood behind the read that found it');
};

subtest "the predecessor's record is read once, before the environment loads" => sub {
	plan tests => 4;

	my $h = two_env_harness(chained => 1);
	fixture_bosh($h);

	my (undef, undef, $exit) = run_genesis($h,
		'qa', 'deploy', '--no-propagate', '-y', 'r');
	is($exit, 0, 'the deploy ran');

	# The log is every vault path this run read, in order.  The count is a
	# guard rather than a discriminator: one reader exists today, and what it
	# catches is the pre-flight's read landing beside the one it replaces,
	# which is two reads of one path in a single deploy.  The order is the
	# discriminator, and it is red until the read moves: a check made after
	# load_env reads the environment's own record first, to reach the
	# director, and the predecessor's only after that.
	#
	# The harness names an exodus path with a leading slash and safe is
	# handed one without, so the slash is taken off both sides rather than
	# left to a match that would answer no to every path the log holds.
	my $log = vault_read_log($h);
	(my $prior = $h->env_path('lab') . '/deployments') =~ s{^/+}{};
	(my $own   = $h->env_path('qa')) =~ s{^/+}{};
	my @at_prior = grep {$log->[$_] =~ m{^/*\Q$prior\E$}}      0 .. $#$log;
	my ($at_own) = grep {$log->[$_] =~ m{^/*\Q$own\E(?:/|$)}}  0 .. $#$log;

	is(scalar(@at_prior), 1, "lab's record was read exactly once");
	ok(@at_prior && defined($at_own) && $at_prior[0] < $at_own,
		"and it was read before qa's own record, which the load reads")
		or diag("the paths this run read:\n" . join("\n", @$log));
};

subtest 'the three prior-env cases, with L unchanged on each' => sub {
	plan tests => 9;

	my %expect = (
		'no record'   => Genesis::Exit::DATAERR,
		'no control'  => 0,
		'post-failed' => 0,
	);
	for my $case (sort keys %expect) {
		# chained names lab as qa's predecessor on the environment file the
		# seeding commits, so the delivery carries the key; certified takes
		# lab's own record away, so each case writes the record it is about
		# and nothing writes one underneath it.
		my $h = two_env_harness(chained => 1, certified => ['qa']);
		my $control = tip_of($h, $h->control);

		# Both of these cases are guards, green on arrival, and each is
		# written for the wrong implementation it catches.
		#
		# post-failed: result, not state.  _prior_env_record reads the
		# deployment audit, where certify writes result, and certify's state
		# option writes the flat record beside it, where it writes success
		# whatever the audit says.  So a check reading the flat record's
		# state passes this fixture and this row would not catch it.  What it
		# does catch is a filter narrowed to result eq 'success': the entry
		# would be skipped, the predecessor would read as never deployed, and
		# a deploy the design lets through would refuse at DATAERR.
		certify($h, 'lab', result => 'post-failed', control_commit => $control)
			if $case eq 'post-failed';
		# no control: a predecessor that deployed and certified nothing.
		# Under D43 it holds everything below it and the due set is empty,
		# which is a state this check passes rather than one it refuses.
		# What this catches is a check that asked which commit the
		# predecessor certified rather than whether it had deployed at all,
		# which would refuse here.
		#
		# The two warning rows of the brief's subtest for this state, that
		# the warning names the holding ancestor and says nothing is due, are
		# Task 13.9's: _warn_commits_due does not exist yet, so a row here
		# would be reading a warning nothing prints.
		certify($h, 'lab', control_commit => undef) if $case eq 'no control';

		fixture_bosh($h);
		my $before = heads_in($h);

		my (undef, undef, $exit) = run_genesis($h,
			'qa', 'deploy', '--no-propagate', '-y', 'r');
		is($exit, $expect{$case}, "the $case case ends as the design says");
		is_deeply(heads_in($h), $before, "and L is unchanged on the $case path");
	}
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
