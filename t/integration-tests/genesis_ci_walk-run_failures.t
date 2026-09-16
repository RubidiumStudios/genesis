#!/usr/bin/env perl
# Proves T165 and T166: a writer failure ends the run at 1 and a remote the
# run cannot publish to ends it at TEMPFAIL, both resetting every committed
# branch to T, publishing nothing, and reporting the two outcome words.  A
# refused commit is a writer failure like any other, and the remote's own
# error decides which of three sentences the report carries.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# The environment file each row commits by hand, written here for the reason
# the failure rows next door write one: the harness's own writer commits
# without publishing, so a row that wants a file on control publishes the
# commit it rides in on.  The body is the block mapping write_env_file lays
# down, because Genesis::Env::is_valid_env_file reads the kit's name and
# version out of a block mapping and a flow mapping of the same two keys
# leaves the repository with no environments at all.
sub env_file {
	my (%opts) = @_;
	my @lines = (
		'---', 'kit:',
		sprintf('  name:    %s', $opts{kit} // 'dev'),
		sprintf('  version: %s', $opts{version} // 'latest'),
		'  features: []', 'genesis:', "  env: $opts{env}",
	);
	push @lines, '  pipeline:', "    prior_env: $opts{prior}" if $opts{prior};
	push @lines, 'n: ' . ($opts{n} // 2);
	return join("\n", @lines, '');
}

# The three-stage pipeline every row here stands on.  It is chained, because
# the walk takes its order from the topology and an unchained roster is
# walked in the order its names sort in, so a fault armed on the second write
# would land on whichever environment that order happened to put second.
# Chained, lab is walked first, qa second, and prod last.  Each of the three
# carries a file of its own, so no commit of one of them is ever held behind
# another's undeployed set.
sub three_envs {
	return ready_harness(envs => ['lab', 'qa', 'prod'],
		kit => 'omega-v2.7.0', chained => 1);
}

sub tune_all_three {
	my ($h) = @_;
	return commit_on_control($h,
		files => {
			'lab.yml'  => env_file(env => 'lab'),
			'qa.yml'   => env_file(env => 'qa',   prior => 'lab'),
			'prod.yml' => env_file(env => 'prod', prior => 'qa'),
		},
		message => 'Tune all three', push => 1);
}

# T is R's own tip, and a run that aborts publishes nothing, so a branch that
# is back at T reads the same marker in copy A as it does in R.  Both are
# read, because a marker read off R alone stands still whether the reset
# happened or not, and the commit the run delivered is read against copy A as
# well, so a branch that kept a delivery cannot pass by standing still.
sub assert_reset {
	my ($h, $env, %opts) = @_;
	my $branch = $h->slug($env);
	is(harness_marker($h, $branch, copy => 'a'),
		harness_marker($h, $branch, copy => 'r'),
		"$env was reset to T");
	isnt(harness_marker($h, $branch, copy => 'a'), $opts{due},
		"the delivery $env did receive went with it")
		if $opts{due};
	return;
}

subtest 'a writer failure ends the run at 1 and resets everything' => sub {
	# One more than the rows, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	# Every subtest in this file is counted the same way.
	plan tests => 8;

	my $h   = three_envs();
	my $due = tune_all_three($h);

	# The second write of the run, which is qa's, because lab is walked first
	# and each of the three has one file to write.  So lab has been delivered
	# and committed to when the writer fails, and prod has not been reached.
	my $git = fault_git($h);
	fail_on($git, 'checkout_file', 2,
		message => 'could not write qa.yml into the index');

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');

	is($exit, 1, 'a run-fatal failure exits 1');
	assert_reset($h, 'lab', due => $due);
	assert_reset($h, 'qa');
	like($err, qr/^\s*lab\b.*not published, run aborted/m,
		'the already-walked environment records not published');
	like($err, qr/^\s*prod\b.*not attempted/m,
		'the unreached environment records not attempted');
	like($err, qr/\Qqa.yml\E/, 'the report names the file it could not write');
};

subtest 'an unreachable remote ends the run at TEMPFAIL' => sub {
	plan tests => 8;

	my $h   = three_envs();
	my $due = tune_all_three($h);

	# The refresh at the head of the run is the first call on the remote and
	# it stands, so the remote goes away partway through, which is the state
	# an unsurvivable failure is raised from.  The push is armed from its own
	# first call, because a run makes one push and it comes after the
	# refresh, so a remote severed once the refresh is done is one no push of
	# this run could have reached.
	sever_remote($h, after => 2);
	fail_on($h->fault_git, 'push', 1, from => 1,
		message => "fatal: unable to access '@{[$h->r]}': "
			. "Could not resolve host: the remote is unreachable");

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');

	is($exit, Genesis::Exit::TEMPFAIL, 'an unsurvivable failure exits TEMPFAIL');
	assert_reset($h, 'lab', due => $due);
	assert_reset($h, 'qa');
	assert_reset($h, 'prod');
	like($err, qr/could not reach|unreachable/i,
		'the report names the unreachable remote');
	like($err, qr/try again|retry/i, 'it names the corrective step');
};

subtest 'a refused commit ends the run at 1 and resets everything' => sub {
	plan tests => 7;

	my $h   = three_envs();
	my $due = tune_all_three($h);

	# qa's own commit, which is the second the run makes, because lab is
	# walked first and each of the three has one file to write.  So lab has
	# been delivered and committed to when the commit is refused, and prod has
	# not been reached.
	my $git = fault_git($h);
	fail_on($git, 'commit', 2, message => 'could not commit onto qa/bosh');

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');

	is($exit, 1, 'a refused commit is the writer failing, so the run exits 1');
	assert_reset($h, 'lab', due => $due);
	assert_reset($h, 'qa');
	like($err, qr/^\s*lab\b.*not published, run aborted/m,
		'the already-walked environment records not published');
	like($err, qr/^\s*prod\b.*not attempted/m,
		'the unreached environment records not attempted');
};

subtest 'a rejected credential is named rather than the network' => sub {
	plan tests => 4;

	my $h = three_envs();
	tune_all_three($h);

	# The refresh at the head of the run stands, and the push is armed with
	# the text git writes when the remote turns the credential down.
	sever_remote($h, after => 2);
	fail_on($h->fault_git, 'push', 1, from => 1,
		message => "fatal: Authentication failed for '@{[$h->r]}'");

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');

	is($exit, Genesis::Exit::TEMPFAIL, 'an unsurvivable failure exits TEMPFAIL');
	like($err, qr/credential/i, 'the report names the credential it was refused');
	unlike($err, qr/could not reach the remote/i,
		'rather than the wording an unreachable remote earns');
};

subtest 'the remote\'s own error is what the report names' => sub {
	plan tests => 4;

	my $h = three_envs();
	tune_all_three($h);

	# Nothing is armed on git here.  The remote answers every read this run
	# makes and refuses the one write, because its push URL names a
	# directory that is not a repository, so what the report carries is the
	# sentence git itself wrote rather than one composed out of an empty
	# reason.
	my $path = broken_pushurl($h);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');

	is($exit, Genesis::Exit::TEMPFAIL, 'an unsurvivable failure exits TEMPFAIL');
	# The message is wrapped to the terminal width before it is printed, and
	# where the wrap falls moves with the length of the harness's temporary
	# path, so a break can land between two words of the sentence.  The
	# whitespace is flattened and the sentence read along one line, rather
	# than the row resting on a temporary directory being as long as the
	# one this suite happens to get.
	(my $flat = $err) =~ s/\s+/ /g;
	like($flat, qr/could not reach the remote.*does not appear to be a git repository/,
		'the unreachable wording carries git\'s own error');
	like($err, qr/\Q$path\E/, 'which names the path git could not read');
};

subtest 'a push that lands nothing ends the run the same way' => sub {
	plan tests => 5;

	my $h   = three_envs();
	my $due = tune_all_three($h);

	# The production shape.  Service::Git::push never dies: it answers one
	# result per ref, and a remote nobody can resolve is every ref refused
	# with no reason beside it.  An answer carrying no result at all stands
	# for that, because the guard reads whether any ref landed.
	my $git = fault_git($h);
	skip_on($git, 'push', 1, return => []);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');

	is($exit, Genesis::Exit::TEMPFAIL, 'it is the same unsurvivable failure');
	like($err, qr/could not reach the remote/i,
		'and a push with no reason beside it reads as the remote being gone');
	assert_reset($h, 'lab', due => $due);
};

done_testing;
