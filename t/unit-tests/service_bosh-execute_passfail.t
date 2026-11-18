#!/usr/bin/env perl
use strict;
use warnings;

# execute() documents a passfail mode that returns true when bosh succeeds
# and false when it fails.  It handed passfail on to run(), which then
# returns only that boolean, and execute() read the exit code from the
# second value, which was never there, so every bosh command passed.  An
# interactive command also recorded no exit code in last_interactive_status.

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis;
use_ok 'Service::BOSH';
use_ok 'Service::BOSH::Director';

fake_bosh(<<'SH');
echo "bosh $*"
exit "${FAKE_BOSH_RC:-0}"
SH

sub director {
	Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
	Service::BOSH::Director->new('an-env',
		url => 'https://127.0.0.1', ca_cert => 'ca_cert', client => 'admin',
		secret => 'password', exodus_path => 'secret/exodus',
		deployment => 'some-deployment'
	);
}

subtest 'passfail reports a failing bosh command as a failure' => sub {
	local $ENV{FAKE_BOSH_RC} = 3;
	ok(!director->execute({passfail => 1}, 'deployments'), 'bosh exiting 3 is a failure');

	$ENV{FAKE_BOSH_RC} = 0;
	ok(director->execute({passfail => 1}, 'deployments'), 'bosh exiting 0 is a success');
};

subtest 'one options hash serves repeated calls unchanged' => sub {
	# A caller can keep its options in one hash and pass it to every call.
	# execute() must not change that hash, or the second call no longer
	# asks for passfail and returns the raw exit code, which is true for a
	# failure in scalar context.
	local $ENV{FAKE_BOSH_RC} = 3;
	my $bosh = director;
	my $opts = {passfail => 1, deployment => 'some-deployment', stderr => 0};
	my %before = %$opts;
	ok(!$bosh->execute($opts, 'deployments'), 'the first call reports the failure');
	ok(!$bosh->execute($opts, 'deployments'), 'the second call with the same hash reports it too');
	is_deeply($opts, \%before, 'and the hash the caller passed is unchanged');

	my $dry = {execute => 1, interactive => 0, exec_msg => 'a check'};
	my %dry_before = %$dry;
	$bosh->dryrun_of($dry, 'deployments');
	is_deeply($dry, \%dry_before, 'dryrun_of leaves its caller\'s hash unchanged too');
};

SKIP: {
	chomp(my $script = `command -v script 2>/dev/null` // '');
	skip 'script(1) is not installed', 1 unless $script;

	subtest 'passfail reports a failing interactive bosh command as a failure' => sub {
		local $ENV{FAKE_BOSH_RC} = 3;
		my $bosh = director;
		ok(!$bosh->execute({passfail => 1, interactive => 1}, 'deployments'),
			'interactive bosh exiting 3 is a failure');
		is($bosh->last_interactive_status->{rc}, 3,
			'and its exit code is recorded in the interactive status');

		$ENV{FAKE_BOSH_RC} = 0;
		ok($bosh->execute({passfail => 1, interactive => 1}, 'deployments'),
			'interactive bosh exiting 0 is a success');
	};
}

done_testing;
