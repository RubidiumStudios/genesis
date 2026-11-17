#!/usr/bin/env perl
# Proves how the deploy's pre-flight stops on a read that fails (T493, D163,
# D168): it asks the caught error why the read failed, and raises it again
# under its own words with the state and the exit code the reader set.
#
# It told a failed read from every other error by the words the reader's
# message opens with, and exited UNAVAILABLE for whatever it had matched, so
# a refusal and an outage exited alike and a read that failed in other words
# was not stopped as a read at all.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis;
use Genesis::Exit qw/NOPERM UNAVAILABLE DATAERR/;
use_ok 'Genesis::Commands::Env';
use Service::Vault;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# Carp::Always, which the helper may load, appends a stack trace to a string
# die; these rows are about what the pre-flight itself raises
local $SIG{__DIE__} = 'DEFAULT';

sub reading {
	my ($read) = @_;
	my $answer = eval { Genesis::Commands::Env::_deploy_reading($read) };
	return ($answer, $@);
}

sub vault_read_failing_with {
	my ($reason) = @_;
	return sub {
		Service::Vault::bail_read_failure(
			'https://v:8200', 'secret/exodus/qa/bosh/hold', $reason, 'get secret/exodus/qa/bosh/hold');
	};
}

subtest 'a read that answers is answered' => sub {
	plan tests => 2;
	my ($answer, $err) = reading(sub { {held => 1} });
	is_deeply($answer, {held => 1}, 'what the read gave comes back');
	is($err, '', 'and nothing is raised');
};

subtest 'a read the vault refused stops the deploy as a refusal' => sub {
	plan tests => 5;
	my (undef, $err) = reading(vault_read_failing_with('permission denied'));
	my $raised = raised($err);
	is($raised && $raised->state, 'refused', 'the state is the reader\'s');
	is($raised && $raised->exitcode, NOPERM, 'and so is the exit code');
	like("$err", qr/Could not read secret\/exodus\/qa\/bosh\/hold from vault.*permission denied/s,
		'it says what the reader said');
	like("$err", qr/Nothing was deployed/, 'and that nothing was deployed');
	is(scalar(() = $raised->rendered =~ /\[FATAL\]/g), 1, 'under one prefix');
};

subtest 'a read the vault gave no answer to stops the deploy as an outage' => sub {
	plan tests => 3;
	my (undef, $err) = reading(vault_read_failing_with('Vault is sealed'));
	my $raised = raised($err);
	is($raised && $raised->state, 'unreachable', 'the state is the reader\'s');
	is($raised && $raised->exitcode, UNAVAILABLE, 'and so is the exit code');
	like("$err", qr/Nothing was deployed/, 'and it says nothing was deployed');
};

# The stop is for a read that did not finish, in whatever words it failed.
subtest 'an export Genesis does not read stops the deploy as a read that failed' => sub {
	plan tests => 3;
	my (undef, $err) = reading(sub { Service::Vault::plain_export([], 'secret/exodus/qa/bosh/hold') });
	my $raised = raised($err);
	is($raised && $raised->state, 'unread', 'the state is the reader\'s');
	is($raised && $raised->exitcode, UNAVAILABLE, 'and so is the exit code');
	like("$err", qr/Cannot use the safe export.*Nothing was deployed/s,
		'it says what the reader said, and that nothing was deployed');
};

# A record its owner judged invalid was read, and has its own account.
subtest 'an invalid record passes through as it came' => sub {
	plan tests => 3;
	my (undef, $err) = reading(sub { bail({state => 'invalid'}, "The record at #C{secret/a} is not a record.") });
	my $raised = raised($err);
	is($raised && $raised->state, 'invalid', 'the state is the owner\'s');
	is($raised && $raised->exitcode, DATAERR, 'and so is the exit code');
	is("$err", 'The record at secret/a is not a record.', 'and nothing is added to what it said');
};

subtest 'an error that is not a failed read passes through as it came' => sub {
	plan tests => 2;
	my (undef, $err) = reading(sub { die "Interrupted by user\n" });
	is($err, "Interrupted by user\n", 'a signal');
	(undef, $err) = reading(sub { bail({exitcode => 78}, "No such kit") });
	is("$err", 'No such kit', 'and a refusal with its own account');
};

done_testing;
