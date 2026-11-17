#!/usr/bin/env perl
# Proves the walk's half of T493's run exit (D163): an environment whose
# record could not be read is answered as the unreadable state with the
# exit code the failed read's cause earns beside its reason.
#
# The walk kept the reason as one line of text and nothing else, so the run
# and the deploy that read it could not tell a refusal from an outage, and
# exited alike for both.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis;
use Genesis::Exit qw/NOPERM UNAVAILABLE DATAERR/;
use Service::Vault;
use_ok 'Genesis::CI::Walk';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# Carp::Always, which the helper may load, appends a stack trace to a string
# die; these rows are about what the walk records
local $SIG{__DIE__} = 'DEFAULT';

# FakeEnv - what env_state asks of an environment.  It has never deployed,
# and each of its reads does what the row gives it to do.
{
	package FakeEnv;
	sub new { my ($class, %reads) = @_; return bless {%reads}, $class }
	sub _read { my ($self, $which) = @_; return $self->{$which} ? $self->{$which}->() : undef }
	sub with_vault        { $_[0]->_read('with_vault'); $_[0] }
	sub deployments       { $_[0] }
	sub latest_successful { $_[0]->_read('history') }
	sub hold_record       { $_[0]->_read('hold') }
	sub proposed_record   { $_[0]->_read('proposed') }
	sub pipeline_record   { $_[0]->_read('pipeline') }
}

sub state_of { Genesis::CI::Walk::env_state(env => FakeEnv->new(@_)) }

sub failing_with {
	my ($reason) = @_;
	return sub {
		Service::Vault::bail_read_failure(
			'https://v:8200', 'secret/exodus/qa/bosh/x', $reason, 'get secret/exodus/qa/bosh/x');
	};
}

subtest 'a read the vault refused is recorded with NOPERM' => sub {
	my @reads = qw/history hold proposed pipeline/;
	plan tests => 3 * @reads;
	for my $read (@reads) {
		my $state = state_of($read => failing_with('permission denied'));
		is($state->{state}, 'unreadable', "$read: the environment is unreadable");
		is($state->{exit_code}, NOPERM, "$read: with the code a refusal earns");
		like($state->{error}, qr/^Could not read secret\/exodus\/qa\/bosh\/x from vault.*permission denied/,
			"$read: beside the reason, as it always read");
	}
};

subtest 'an outage is recorded with UNAVAILABLE, and an invalid record with DATAERR' => sub {
	plan tests => 4;
	my $state = state_of(hold => failing_with('Vault is sealed'));
	is($state->{state}, 'unreadable', 'an outage leaves the environment unreadable');
	is($state->{exit_code}, UNAVAILABLE, 'with the code an outage earns');

	$state = state_of(proposed => sub { bail({state => 'invalid'}, "The proposed record is not one Genesis writes.") });
	is($state->{state}, 'unreadable', 'an invalid record leaves the environment unreadable');
	is($state->{exit_code}, DATAERR, 'with the code an invalid record earns');
};

subtest 'a failure that names no code is recorded with none' => sub {
	plan tests => 3;
	my $state = state_of(with_vault => sub { die "No vault is configured for qa\n" });
	is($state->{state}, 'unreadable', 'the environment is unreadable');
	is($state->{exit_code}, undef, 'and carries no code');
	is($state->{error}, 'No vault is configured for qa', 'beside its reason');
};

subtest 'an environment that was read carries no code' => sub {
	plan tests => 2;
	my $state = state_of();
	is($state->{state}, 'never-certified', 'it is read as it stands');
	is($state->{exit_code}, undef, 'with no code');
};

done_testing;
