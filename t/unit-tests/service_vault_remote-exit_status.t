#!/usr/bin/env perl
# A process that holds an AppRole vault keeps a token renewer child, which the
# vault's DESTROY reaps during global destruction, after the END blocks have
# settled the exit status.  waitpid sets $?, so an unguarded reap replaced
# every pipeline task's failure with the renewer's 0, and Concourse marked a
# failed deploy green.  The exit a process chose must survive the reap.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

# The process under test is a child of its own, so its exit status is the
# real one, read the way Concourse reads it.
sub exit_of {
	my ($code) = @_;
	system($^X, '-Ilib', '-e', $code);
	return $? >> 8;
}

my $renewer = q{
	require Service::Vault::Remote;
	my $pid = fork;
	if (!$pid) { $SIG{TERM} = sub { exit 0 }; sleep 30; exit 0 }
	our $vault = bless {__renewer_pid => $pid}, 'Service::Vault::Remote';
};

is(exit_of($renewer.'exit 3;'), 3, 'an exit chosen before the renewer is reaped survives it');
is(exit_of($renewer.'die "a refusal\n";'), 255, 'and so does a death');
is(exit_of($renewer.'exit 0;'), 0, 'and a success stays one');

done_testing;
