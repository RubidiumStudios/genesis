#!/usr/bin/env perl
# Proves T247: a secrets command that rotates against the branch tip while the
# certified commit is older warns that the version it served is not the
# certified one and names the risk of a redeploy.
#
# What the rows catch: an implementation that warned on every run, which the
# --as-deployed row catches by asking for silence where the run served exactly
# what the environment is certified at; one that never warned, which the two
# message rows catch; and one that warned by comparing the deployed commit
# against the certified commit, two facts that are kept apart, which would
# warn on every environment ever deployed, including the --as-deployed run.
#
# Two rows joined the subtest later, which are the check-secrets run's own.
# The message row among them was red when it was written, red having been
# produced by taking the warning's call out of check_secrets and putting it
# back afterwards.  The exit row beside it arrived green, and it is what keeps
# the message row honest, since a run that died before it finished its work
# would reach no warning either.  Together they hold a second of the four call
# sites, so an edit that dropped the warning from one command alone is caught
# by something.
#
# The warning the rows read says "the secrets this run served" where the
# wording it replaced said "the secrets just written".  That earlier wording
# is wrong for two of the four commands that raise it, check-secrets
# validating and remove-secrets removing, and it is wrong again for any run
# that errored before it wrote anything, because the call sits above each
# command's own error bail.  The rows match on the sentence's later words, so
# they would pass under either wording.  The departure is recorded here
# because the message no longer reads the way it once did.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'rotating against the tip says which version it served' => sub {
	# Seven rows, and one more for each of the three runs' own restoration
	# assertions.
	plan tests => 10;

	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');

	my $control = commit_on_control($h,
		files   => {'ops/base.yml' => "---\nversion: one\n"},
		message => 'the certified content',
		push    => 1,
	);
	init_branch($h, 'qa');
	my $deployed = deliver($h, 'qa', control => $control);
	certify($h, 'qa', commit => $deployed, control_commit => $control);

	my $later = commit_on_control($h,
		files   => {'ops/base.yml' => "---\nversion: two\n"},
		message => 'the coming version',
		push    => 1,
	);
	deliver($h, 'qa', control => $later);
	refresh($h, 'a');

	# Every delivery above is published from the teammate's copy, so the
	# operator's own clone still holds the deployment branch where the apply
	# cut it, at a root commit that carries no marker at all.  The builder's
	# catch-up brings it up to the delivery, which is what a pull would have
	# done, and without it the tip this row is about is a commit that was
	# never delivered anything.  The kit is the one the harness installed,
	# so the builder is told to leave it alone, and it runs before the row
	# stands anywhere.
	fixture_bosh($h, kit => 0);
	stand_on($h, $h->control);

	# The spaces in the phrase are read as any run of whitespace, because
	# Genesis wraps its warnings at the terminal width and the two commits it
	# names are forty characters each, so where the break falls depends on
	# the shas the fixture happened to write.  The row is about the words the
	# command says and not about where the renderer wrapped them.
	my ($out, $err, $exit) = run_genesis($h, 'qa', 'rotate-secrets', '-y');
	is($exit, 0, 'the rotation succeeded');
	like($out.$err, qr/not\s+the\s+certified/i,
		'the command says the version it served is not the certified one');
	like($out.$err, qr/redeploy/i, 'the warning names what a redeploy would do');

	# The as-deployed run serves the certified version, so it says nothing.
	my ($clean_out, $clean_err, $clean_exit) =
		run_genesis($h, 'qa', 'rotate-secrets', '--as-deployed', '-y');
	is($clean_exit, 0, 'the as-deployed rotation succeeded');
	unlike($clean_out.$clean_err, qr/not\s+the\s+certified/i,
		'serving the running version raises nothing');

	# The warning belongs to the whole secrets family and not to the rotation
	# alone, so a second command of the four says it too.  check-secrets is
	# the one worth naming, because it writes no value at all and is
	# therefore the command the wording has to be true of.  It reads what the
	# two rotations above left in the vault, so it finds its secrets and
	# reports on them rather than bailing over what is missing.
	my ($check_out, $check_err, $check_exit) =
		run_genesis($h, 'qa', 'check-secrets');
	is($check_exit, 0, 'the check succeeded');
	like($check_out.$check_err, qr/not\s+the\s+certified/i,
		'check-secrets says which version it served as well')
		or diag("what the check said:\n$check_out$check_err");
};

# Proves that the warning keeps out of the way where there is no repository to
# read a control commit from.  The four secrets commands ran in a plain
# deployments directory long before the warning existed, and that is what an
# operator has who keeps their environments in a directory git never touched,
# as well as what the end-to-end fixture builds with genesis init.  The
# warning compares two control commits, so a directory with no repository has
# nothing to compare and says nothing at all.
#
# The rows catch an implementation that opens a git handle before it has asked
# whether there is a repository here, which is how the warning arrived.  Such a
# run does the command's real work and then dies on the way out, so the exit
# rows are what fail and the message rows say why.
subtest 'a deployments directory with no repository is served in silence' => sub {
	plan tests => 4;

	# The repository carries no pipeline section at all, because the plain
	# deployments directory this row is about is one an operator made with
	# genesis init and never wired to a pipeline, and that is the shape the
	# end-to-end fixture builds as well.
	my $h = make_harness(
		envs => ['qa'], kit => 'omega-v2.7.0', pipeline => 'none');

	# Copy A's working tree taken as it stands, with its repository left
	# behind, so the directory holds the same deployment root, the same kit,
	# and the same environment file, and differs from copy A in nothing but
	# the repository.  The copy is named to the harness the way the two
	# repositories are, because that is how a run picks up the fixture vault
	# and the path the harness assembles.
	# Named before the copy is made, because an empty working directory
	# answer would aim the removal at a path outside the fixture.  The test
	# is on what workdir answered, since the name below always carries its
	# own suffix and so can never read as empty.
	my $work = workdir();
	die "the working directory answered nothing, so the copy has no path\n"
		unless length($work // '') && $work ne '/';

	my $plain = $work . '/no-repo-deployments';
	system('cp', '-R', $h->a, $plain) == 0
		or die "cannot copy the deployments directory: $?\n";
	system('rm', '-rf', "$plain/.git") == 0
		or die "cannot take the repository off the copy: $?\n";
	$h->{plain} = $plain;

	# The restoration assertion reads a branch and a HEAD, and this directory
	# has neither, so these two runs are not asked for it.
	my ($add_out, $add_err, $add_exit) =
		run_genesis($h, {copy => 'plain', restore => 0}, 'qa', 'add-secrets');
	is($add_exit, 0, 'add-secrets succeeds outside a repository')
		or diag("what add-secrets said:\n$add_out$add_err");
	unlike($add_out.$add_err, qr/not a git repository/i,
		'add-secrets says nothing about a repository it does not need')
		or diag("what add-secrets said:\n$add_out$add_err");

	# check-secrets reads back what the run above wrote, so it finds its
	# secrets and reports on them rather than bailing over what is missing.
	my ($check_out, $check_err, $check_exit) =
		run_genesis($h, {copy => 'plain', restore => 0}, 'qa', 'check-secrets');
	is($check_exit, 0, 'check-secrets succeeds outside a repository')
		or diag("what check-secrets said:\n$check_out$check_err");
	unlike($check_out.$check_err, qr/not a git repository/i,
		'check-secrets says nothing about a repository it does not need')
		or diag("what check-secrets said:\n$check_out$check_err");
};

done_testing;
