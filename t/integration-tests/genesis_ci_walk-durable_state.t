#!/usr/bin/env perl
# Proves T140, T141, T142, T143, and T321: a second run writes nothing, a
# later run releases a hold by itself, the hand run covers the abnormal cases,
# two copies produce the same trees and the same markers, and two overlapping
# runs read only durable state.
#
# It proves T144 as D109 rules it.  A whole-run input the vault answers an
# error for refuses the run at UNAVAILABLE naming the path and what the vault
# said, and a repository with no vault to read says that rather than failing
# inside Perl; break_vault_reads makes the vault refuse the read.  An applied
# record that is absent refuses the run and a dry run at CONFIG, before any
# environment is walked, naming genesis pipeline-apply, while pipeline-status
# renders every environment not-propagated.  T144's contrast, an environment
# the stored applied record does not know, is not here: the walk decides that
# from an empty git.control_commit rather than from the pipeline subpath D103
# names, and that gap is its own item.
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
	push @lines, "  exodus_mount: $opts{mount}" if $opts{mount};
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
	# Four rows, and one for each run's own restoration assertion.
	plan tests => 6;

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

	# The marker standing still says the branch did not move, and this says
	# the run never asked it to: no commit was made and nothing was pushed.
	# A run that committed and reset would leave the marker where it was and
	# pass the row above on its own.
	my @wrote = grep {$_->[0] eq 'commit' || $_->[0] eq 'push'} step_log($git);
	is_deeply(\@wrote, [],
		'and the second run made no commit and pushed nothing');
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
	# Three rows, and one for each run's own restoration assertion.
	plan tests => 6;

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
	# Read off R, which is the remote both copies published to, while this
	# copy's delivery is still the one standing there.  The roll-back below
	# takes it away again.
	my $marker_c = harness_marker($h, "refs/heads/$qa", copy => 'r');

	run({dir => $h->r}, 'git', 'update-ref', "refs/heads/$qa", $before);
	refresh($h, 'a');
	run_genesis($h, {answers => ['y']}, 'propagate');
	my $from_a   = files_at($h, "refs/remotes/origin/$qa", copy => 'a');
	my $marker_a = harness_marker($h, "refs/heads/$qa", copy => 'r');

	is_deeply($from_a, $from_c, 'the two copies produce the same tree');

	# The markers as well as the trees, because the marker is what the next
	# run walks from, and two copies that wrote the same files under
	# different markers would each send the run after them somewhere else.
	# It is the marker and not the trailers, because the marker is the
	# commit subject Genesis::CI::Marker::build renders and a delivery
	# carries no trailer block at all, so a comparison of trailers is two
	# empty hashes and a row that cannot fail.
	is($marker_a, $marker_c, 'and the same markers on top of them');

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');
	like($err, qr/^\s*qa: idempotent/m, 'copy A finds nothing left to do');
};

subtest 'an applied record the vault errors on refuses the run' => sub {
	# Four rows, and one for the run's own restoration assertion.
	plan tests => 5;

	# T144's error half.  The vault answers the read at the applied record's
	# path with an error rather than with nothing, which is neither of D109's
	# two absences, so the run refuses naming the path and what the vault
	# said, where a reader that took the error for an absence would go on to
	# read the pipeline as never applied.
	my $h = two_stage();
	my $due = commit_on_control($h,
		files => {'qa.yml' => env_file(env => 'qa', prior => 'lab', n => 5)},
		message => 'Tune qa', push => 1);
	certify($h, 'lab', control_commit => $due);
	my $before = ref_in($h->r, 'refs/heads/'.$h->slug('qa'));
	break_vault_reads($h, $h->applied_path);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($err);
	is($exit, Genesis::Exit::UNAVAILABLE, 'the run refuses as the vault being unavailable');
	like($said, qr/\Q@{[$h->applied_path]}\E/, 'naming the path it could not read');
	like($said, qr/permission denied/, 'and what the vault answered');
	is(ref_in($h->r, 'refs/heads/'.$h->slug('qa')), $before,
		'and nothing was delivered');
};

subtest 'a repository with no vault to read says so' => sub {
	# Two rows, and one for the run's own restoration assertion.
	plan tests => 3;

	# With no secrets_provider.url configured the repository reads safe's
	# current target, and with that target gone there is no vault at all.
	# The operator is told that, rather than handed a Perl error about a
	# method called on nothing.
	my $h = two_stage();
	teardown_vault($h->{vault_target});

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($err);
	is($exit, Genesis::Exit::UNAVAILABLE, 'the run refuses');
	like($said, qr/no vault is available for this repository/,
		'saying there is no vault to read') or diag($said);
};

subtest 'a pipeline never applied refuses the run and not the report' => sub {
	# Eleven rows, and one for each of the three runs' restoration assertions.
	plan tests => 14;

	# T144's absent half, as D109 rules it.  With no applied record there is
	# nothing to route from, so the run refuses before it walks, naming
	# genesis pipeline-apply as the remedy, and a dry run refuses the same
	# way.  pipeline-status only reads, so it renders the state instead.
	my $h = two_stage();
	my $due = commit_on_control($h,
		files => {'qa.yml' => env_file(env => 'qa', prior => 'lab', n => 4)},
		message => 'Tune qa', push => 1);
	certify($h, 'lab', control_commit => $due);
	my $slug = $h->slug('qa');
	my $on_r = ref_in($h->r, "refs/heads/$slug");
	my $in_a = ref_in($h->a, "refs/heads/$slug");
	break_vault($h, envs => [], applied => 1);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($err);
	is($exit, Genesis::Exit::CONFIG, 'the run refuses as a configuration it cannot act on');
	like($said, qr/genesis pipeline-apply.*never been run against this repository/,
		'saying the apply has never been run here') or diag($said);
	like($said, qr/Run genesis pipeline-apply/, 'and naming it as the remedy');
	# Read off the raw stream, because a line's start is what marks an
	# environment's outcome and unfolding joins the lines.
	unlike($err, qr/^\s*(?:lab|qa): /m, 'before any environment is walked');
	# The refusal comes before anything moves (D115), so the clone's branch
	# is read against where it stood before the run, not against R.
	is(ref_in($h->r, "refs/heads/$slug"), $on_r, 'and nothing reaches R');
	is(ref_in($h->a, "refs/heads/$slug"), $in_a,
		'nor is anything committed in the clone');

	my (undef, $dry_err, $dry_exit) =
		run_genesis($h, {answers => ['y']}, 'propagate', '--dry-run');
	is($dry_exit, Genesis::Exit::CONFIG, 'a dry run refuses the same way');
	like(unfolded($dry_err), qr/never been run against this repository/,
		'with the same account');

	local $ENV{GENESIS_OUTPUT_COLUMNS} = 999;
	my ($status, undef, $status_exit) = run_genesis($h, 'pipeline-status');
	is($status_exit, 0, 'pipeline-status does not refuse');
	# The report renders the not-propagated reading in words.
	like(env_line($status, 'lab'), qr/not propagated/, 'and lab reads not-propagated');
	like(env_line($status, 'qa'), qr/not propagated/, 'as does qa');
};

subtest 'moving the pipeline mount after an apply reads as never applied' => sub {
	# T351's move.  Four rows, and one for each run's own restoration
	# assertion.
	plan tests => 6;

	# The record stays where the apply wrote it, and the pipeline's mount now
	# names somewhere else, so the pipeline reads as never applied and the
	# run refuses under D109.  A move is the key and the environments' own
	# mount together, since the load refuses an environment left off the key.
	# The apply then writes the record at the new mount, and once lab's
	# deployment record stands there too the run proceeds.
	my $h = two_stage();
	set_repo_config($h, 'pipeline.exodus_mount', '/secret/moved/');
	write_env_file($h, $_, genesis => {exodus_mount => '/secret/moved/'},
		pipeline => ($_ eq 'qa' ? {prior_env => 'lab'} : {}))
		for qw/lab qa/;
	my $due = commit_on_control($h,
		files => {'qa.yml' => env_file(env => 'qa', prior => 'lab', n => 7,
			mount => '/secret/moved/')},
		message => 'Tune qa', push => 1);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($exit, Genesis::Exit::CONFIG, 'the run refuses, the pipeline read as never applied');
	like(unfolded($err), qr{no applied record at /secret/moved/_pipelines/}s,
		'naming the address the moved key gives');

	# The harness writes its records under its own mount, which the move has
	# left behind, so it is told where the records now live.
	$h->{mount} = '/secret/moved/';
	fixture_applied($h, control => $h->git('a')->sha($h->control));
	certify($h, 'lab', control_commit => $due);
	my (undef, $again_err, $again) =
		run_genesis($h, {answers => ['y']}, 'propagate');
	is($again, 0, 'once the record stands at the new mount, the run proceeds');
	like($again_err, qr/^\s*qa: propagated/m, 'and delivers what was due');
};

subtest 'a hold answers ahead of the apply it also waits for' => sub {
	# Two rows, and one for the run's own restoration assertion.
	plan tests => 3;

	# A hold is durable state like any other, so it is read for every
	# environment the run reads.  An environment the pipeline was never applied
	# to is one the run reads and does not walk, and a hold standing over it is
	# reported rather than left unsaid.
	#
	# The qualifier names the hold rather than the apply.  A hold is a
	# decision somebody made and only a person clears it, so it outranks the
	# apply the environment is otherwise waiting for, and the apply is what
	# the environment reads as waiting for once the hold is gone.
	my $held = two_stage(certified => ['lab']);
	certify($held, 'qa');
	fixture_hold($held, 'qa', reason => 'the kit upgrade lands first');

	my (undef, $held_err) = run_genesis($held, {answers => ['y']}, 'propagate');
	like($held_err, qr/^\s*qa: held, needs clearing \(the kit upgrade lands first\)/m,
		'the hold answers ahead of the apply the environment also waits for');
	like($held_err, qr/pipeline-release/,
		'and the command that clears it is named');
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
	# A delivered commit's line ends at its quoted subject (D126).
	like($c_err, qr/^\s*control\@\Q@{[substr($due, 0, 7)]}\E "[^"]*"\s*$/m,
		'the second copy computed the same delivery');
	is(harness_marker($h, $h->slug('qa')), $due,
		'it published what copy A could not');

	unlike($c_err, qr/\Q@{[$h->a]}\E/,
		'it never read anything of copy A\'s working state');
};

done_testing;
