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
