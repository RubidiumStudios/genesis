#!/usr/bin/env perl
# Proves T511 (D178): genesis propagate and genesis pipeline-status, run by
# hand, act on GitHub with the token the repository's configuration names,
# read from the provider's secrets store where Concourse reads it.
#
# Both read GITHUB_AUTH_TOKEN and nothing else, so without it a writing
# propagate that delivers into a pull request refused, and the status left the
# review state unread, in a repository whose own configuration named the
# token the pipeline's propagate task runs with.
#
# The rows read which token each call to GitHub carried, since that is the
# one thing that tells the store's token from the shell's.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/run/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $STORED = 'the-token-the-store-holds';
my @SCOPES = ('concourse/main/bosh/gh', 'concourse/main/gh', 'concourse/shared/gh');
my %NAMED  = (provider => 'concourse', kit => 'omega-v2.7.0',
	source_control => {api_token => 'gh:pipeline_admin'});

# The vault is one for the whole file, so each row says where the token is.
sub hold_token {
	my ($h, $at) = @_;
	my $safe = Harness::Propagation::_real_safe();
	run({env => {SAFE_TARGET => $h->fixture_vault}, passfail => 1, stderr => 0},
		$safe, 'rm', '-f', $_) for @SCOPES;
	$h->_write_record($at, pipeline_admin => $STORED) if $at;
	return $h;
}

# A root whose prod delivers into a pull request, with a commit due.
sub due_to_prod {
	my ($at) = @_;
	my $h = ready(%NAMED);
	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');
	return hold_token($h, $at);
}

sub tokens { my %seen = map {(($_->{token} // '(none)') => 1)} gh_calls($_[0]->{gh}); sort keys %seen }

# Under an automated provider a writing propagate by hand passes the provider
# gate only when forced at a terminal, which a spawned command has none of
# (T170).  A preview passes the gate and reads the review state with the same
# token, so the rows that weigh whose token is used are previews.
subtest 'propagate with no token in the shell uses the one the store holds' => sub {
	plan tests => 6;

	my $h = due_to_prod('concourse/main/gh');
	my ($out, $err, $exit) = run_genesis($h, {no_token => 1}, 'propagate', '--dry-run');
	my $said = unfolded($out, $err);

	is($exit, 0, 'the preview runs') or diag($said);
	unlike($said, qr/a real run would refuse/i, 'and does not say a real run would refuse');
	is_deeply([tokens($h)], [$STORED], 'every call to GitHub carried the token the store holds');
	like($said, qr{GitHub token at /concourse/main/gh:pipeline_admin.*pipeline\.source_control\.api_token}s,
		'the run says where its token came from');
	unlike($said, qr/\Q$STORED\E/, 'and never prints it');
};

subtest "propagate takes the store's token over the shell's" => sub {
	plan tests => 4;

	my $h = due_to_prod('concourse/main/gh');
	my ($out, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');
	my $said = unfolded($out, $err);

	is($exit, 0, 'the preview runs') or diag($said);
	is_deeply([tokens($h)], [$STORED], 'every call carried the token the store holds');
	like($said, qr{GitHub token at /concourse/main/gh:pipeline_admin.*in place of GITHUB_AUTH_TOKEN}s,
		"and the run says it set the shell's aside");
};

# The gate's refusal and this one are said as one (D115), and the code is
# the first's.
subtest 'a writing propagate with no token anywhere says why the store gave none' => sub {
	plan tests => 4;

	my $h = due_to_prod(undef);
	my ($out, $err, $exit) = run_genesis($h, {no_token => 1}, 'propagate', '-y');
	my $said = unfolded($out, $err);

	isnt($exit, 0, 'the run is refused') or diag($said);
	like($said, qr{GITHUB_AUTH_TOKEN is not set and gh\.pipeline_admin, which pipeline\.source_control\.api_token names, is at none of /concourse/main/bosh/gh, /concourse/main/gh, /concourse/shared/gh},
		'naming the reference and every path it looked at');
	is(scalar(gh_calls($h->{gh})), 0, 'and no call was made to the API');
};

# The compiler hands the task its token in the environment, so a task reads
# no store for it.  A preview, because all the row weighs is whose token the
# review state was read with.
subtest 'a pipeline task keeps the token it was handed' => sub {
	plan tests => 3;

	my $h = due_to_prod('concourse/main/gh');
	my ($out, $err, $exit) = run_genesis($h, {pipeline_task => 1}, 'propagate', '--dry-run');

	is($exit, 0, 'the preview runs') or diag(unfolded($out, $err));
	is_deeply([tokens($h)], [$h->{gh}{token}], 'and every call carried the token in its environment');
};

subtest 'pipeline-status with no token in the shell reads the review state' => sub {
	plan tests => 6;

	my ($h, $gh, $pr) = with_open_pr(%NAMED);
	hold_token($h, 'concourse/main/gh');

	my ($out, $err, $exit) = run_genesis($h, {no_token => 1}, 'pipeline-status');
	is($exit, 0, 'the report is produced') or diag($err);
	like(env_line($out, 'qa'), qr/\[PR #$pr open: unreviewed\]/, 'with the pull request read');
	unlike(plain($out), qr/possibly outdated/, 'and validated, so not flagged as unread');
	is_deeply([tokens($h)], [$STORED], 'every call carried the token the store holds');
	unlike("$out\n$err", qr/GitHub token at|\Q$STORED\E/, 'and nothing is said of the token');
};

subtest 'pipeline-status with no token anywhere still reports, and says why' => sub {
	plan tests => 6;

	my ($h, $gh, $pr) = with_open_pr(%NAMED);
	hold_token($h, undef);

	my ($out, $err, $exit) = run_genesis($h, {no_token => 1}, 'pipeline-status');
	is($exit, 0, 'the report is produced at exit 0') or diag($err);
	like(env_line($out, 'qa'), qr/review state unread, possibly outdated/, 'with the state unread, as before');
	like($err, qr{gh\.pipeline_admin, which pipeline\.source_control\.api_token names, is at none of},
		'standard error says why the store gave no token');
	unlike($out, qr/pipeline_admin|api_token/, 'and nothing of it is on standard output');
	is(scalar(gh_calls($gh)), 0, 'no call was made to the API');
};

done_testing;
