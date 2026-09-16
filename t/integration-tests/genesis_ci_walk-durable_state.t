#!/usr/bin/env perl
# Proves T140, T141, T142, T143, T144, and T321: a second run writes nothing,
# a later run releases a hold by itself, the hand run covers the abnormal
# cases, two copies agree, an unreadable input refuses, and two overlapping
# runs read only durable state.
#
# Genesis accounts for itself on standard error, which is where info writes,
# so every report a row reads comes out of the second value run_genesis
# answers rather than the first.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/run/;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# The environment file a row commits by hand, written here for the reason the
# failure rows next door write one: the harness's own writer commits without
# publishing, so a row that wants a file on control publishes the commit it
# rides in on.  The body is the block mapping write_env_file lays down,
# because Genesis::Env::is_valid_env_file reads the kit's name and version out
# of a block mapping and a flow mapping of the same two keys leaves the
# repository with no environments at all.
sub env_file {
	my (%opts) = @_;
	my @lines = (
		'---', 'kit:',
		sprintf('  name:    %s', $opts{kit} // 'dev'),
		sprintf('  version: %s', $opts{version} // 'latest'),
		'  features: []', 'genesis:', "  env: $opts{env}",
	);
	push @lines, '  pipeline:', "    prior_env: $opts{prior}" if $opts{prior};
	push @lines, '    track_additional_files:', '      - ops/shared.yml';
	push @lines, "n: " . ($opts{n} // 1);
	push @lines, "case: $opts{case}" if defined $opts{case};
	return join("\n", @lines, '');
}

# The two-stage pipeline every row here stands on, in the shape the failure
# files next door build theirs.  qa follows lab, so an ancestor that has not
# deployed a file holds the commit that touches it, and both environments
# track one shared file, so a commit touching that file stands in both sets
# and a hold has something to stand over.
sub two_stage {
	my (%opts) = @_;
	return ready_harness(
		envs    => ['lab', 'qa'],
		kit     => 'omega-v2.7.0',
		chained => 1,
		tracked => ['ops/shared.yml'],
		%opts,
	);
}

subtest 'a second run over delivered state writes nothing' => sub {
	# Three rows, and one for each run's own restoration assertion.
	plan tests => 5;

	my $h = two_stage();
	my $due = commit_on_control($h,
		files => {'qa.yml' => env_file(env => 'qa', prior => 'lab', n => 1)},
		message => 'Tune qa', push => 1);
	certify($h, 'lab', control_commit => $due);

	run_genesis($h, {answers => ['y']}, 'propagate');
	my $after_first = harness_marker($h, $h->slug('qa'));

	my $git = fault_git($h);
	reset_steps($git);
	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');

	is($exit, 0, 'the second run succeeded');
	is(harness_marker($h, $h->slug('qa')), $after_first, 'nothing was written');
	like($err, qr/^\s*qa: idempotent/m, 'every environment records idempotent');
};

subtest 'a later run releases a hold with no cascade' => sub {
	# Three rows, and one for each run's own restoration assertion.
	plan tests => 5;

	my $h = two_stage();
	my $shared = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nshared: 2\n"},
		message => 'Bump shared ops', push => 1);

	run_genesis($h, {answers => ['y']}, 'propagate');
	isnt(harness_marker($h, $h->slug('qa')), $shared, 'qa was held first');

	certify($h, 'lab', control_commit => $shared);
	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	is(harness_marker($h, $h->slug('qa')), $shared,
		'the bare run released the hold by itself');
	unlike($err, qr/cascade/i, 'no cascade was named anywhere');
};

subtest 'the hand run covers the three abnormal cases' => sub {
	# Six rows, and one for each run's own restoration assertion.  The
	# failed-partway case runs one command more than the other two.
	plan tests => 13;

	for my $case (qw/no-propagate failed-partway teammate-deployed/) {
		my $h = two_stage();
		my $due = commit_on_control($h,
			files => {'qa.yml' => env_file(env => 'qa', prior => 'lab',
			                               case => $case)},
			message => "Tune qa for $case", push => 1);
		certify($h, 'lab', control_commit => $due);

		if ($case eq 'failed-partway') {
			my $git = fault_git($h);
			fail_on($git, 'commit', 1, message => 'the first run died');
			run_genesis($h, {answers => ['y']}, 'propagate');
			# A second fault_git rewrites the plan empty, which is what takes
			# the arming off again.  reset_steps empties the log and the
			# counters and leaves the armed step where it was, so the hand
			# run below would meet the same death the first run did.
			fault_git($h);
		} elsif ($case eq 'teammate-deployed') {
			certify($h, 'lab', control_commit => $due,
				at => '2026-09-13 00:00:00 +0000');
		}

		my (undef, $preview) = run_genesis($h, 'propagate', '--dry-run');
		like($preview, qr/\Q@{[substr($due, 0, 7)]}\E/,
			"$case: the preview names what is due");

		run_genesis($h, {answers => ['y']}, 'propagate');
		is(harness_marker($h, $h->slug('qa')), $due,
			"$case: the hand run delivered exactly what was due");
	}
};

subtest 'two copies and two identities agree' => sub {
	# Two rows, and one for each run's own restoration assertion.
	plan tests => 5;

	my $h = two_stage();
	my $due = commit_on_control($h,
		files => {'qa.yml' => env_file(env => 'qa', prior => 'lab', n => 3)},
		message => 'Tune qa', push => 1);
	certify($h, 'lab', control_commit => $due);

	my $qa = $h->slug('qa');
	my $before = ref_in($h->r, "refs/heads/$qa");

	# A copy cut from R now, standing on the same durable state and carrying
	# a committer identity of its own, runs first.  What it published is put
	# back afterwards, so copy A meets exactly the state this copy met.
	my $copy = clone_copy($h);
	run_genesis_in($h, $copy, {answers => ['y']}, 'propagate');
	my $from_c = files_at($h, "refs/remotes/origin/$qa", copy => $copy);

	run({dir => $h->r}, 'git', 'update-ref', "refs/heads/$qa", $before);
	refresh($h, 'a');
	run_genesis($h, {answers => ['y']}, 'propagate');
	my $from_a = files_at($h, "refs/remotes/origin/$qa", copy => 'a');

	is_deeply($from_a, $from_c, 'the two copies produce the same tree');

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');
	like($err, qr/^\s*qa: idempotent/m, 'copy A finds nothing left to do');
};

subtest 'an absent input is read and never guessed at' => sub {
	# Six rows, and one for each run's own restoration assertion.
	plan tests => 8;

	# An applied record that is absent is not an input the run cannot read.
	# D94 gives the absence its own reading, which is that the pipeline awaits
	# genesis pipeline-apply, so the run takes that reading, says which one it
	# took, and carries on rather than refusing over it.
	my $h = two_stage();
	my $due = commit_on_control($h,
		files => {'qa.yml' => env_file(env => 'qa', prior => 'lab', n => 4)},
		message => 'Tune qa', push => 1);
	certify($h, 'lab', control_commit => $due);
	break_vault($h, envs => [], applied => 1);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($exit, 0, 'an absent applied record is read rather than refused');
	like($err, qr/not-propagated/, 'the run says which reading it took');
	like($err, qr/pipeline-apply/, 'and names the command that records one');
	like($err, qr/^\s*qa: propagated/m, 'while still delivering what was due');

	# A hold is durable state like any other, so it is read for every
	# environment the run reads.  An environment the pipeline was never applied
	# to is one the run reads and does not walk, and D56 asks that a hold
	# standing over it be reported rather than left unsaid.
	my $held = two_stage(certified => ['lab']);
	certify($held, 'qa');
	fixture_hold($held, 'qa', reason => 'the kit upgrade lands first');

	my (undef, $held_err) = run_genesis($held, {answers => ['y']}, 'propagate');
	like($held_err, qr/^\s*qa: held, awaiting pipeline-apply/m,
		'the environment still reads as awaiting the apply');
	like($held_err, qr/pipeline-release/,
		'and the hold standing over it is reported too');
};

subtest 'two overlapping runs read only durable state' => sub {
	# Three rows, and one for each run's own restoration assertion.
	plan tests => 5;

	my $h = two_stage();
	my $due = commit_on_control($h,
		files => {'qa.yml' => env_file(env => 'qa', prior => 'lab', n => 6)},
		message => 'Tune qa', push => 1);
	certify($h, 'lab', control_commit => $due);

	# The second copy is cut before either run starts, so the two overlap in
	# time over one durable state.
	my $copy = clone_copy($h);

	# Copy A computes and commits, and cannot publish.
	my $git = fault_git($h);
	fail_on($git, 'push', 1, message => 'copy A is still mid-run');
	run_genesis($h, {answers => ['y']}, 'propagate');

	my (undef, $c_err) =
		run_genesis_in($h, $copy, {answers => ['y']}, 'propagate');
	like($c_err, qr/\Q@{[substr($due, 0, 7)]}\E.*deliver/,
		'the second copy computed the same delivery');
	is(harness_marker($h, $h->slug('qa')), $due,
		'it published what copy A could not');

	unlike($c_err, qr/\Q@{[$h->a]}\E/,
		'it never read anything of copy A\'s working state');
};

done_testing;
