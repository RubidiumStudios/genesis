#!/usr/bin/env perl
# Proves T165 and T166 at the sub that decides them: both of D82's classes
# leave walk_one for the run to end on, and everything else is confined to
# the environment that raised it.  The two run-ending rows are what cover
# the two names is_run_fatal accepts, and the third row is the contrast that
# stops the other two passing because walk_one re-raised everything.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use Genesis::CI::Walk;
use Genesis::CI::RunFailure;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# A session that records what it was asked for and does none of it, because
# what the rows below weigh is whether walk_one reached for the per-branch
# discard at all.  walk_one asks a session for that and for nothing else.
{
	package Recording::Session;
	sub new     {bless {discarded => []}, shift}
	sub discard {
		my ($self, $branch) = @_;
		push @{$self->{discarded}}, $branch;
		return $self;
	}
}

# One environment's record as plan builds it, far enough along that a row can
# see whether walk_one wrote an outcome onto it.
sub a_record {
	return {
		env     => 'qa',
		branch  => 'qa/bosh',
		pending => [{control_commit => 'abcdef1234567890', subject => 'Tune qa'}],
		held    => [],
		error   => undef,
		outcome => undef,
	};
}

# The error walk_one left for the caller, or undef where it caught it.  It is
# read this way rather than through a bare eval, because a row that only
# counted a death could not tell a re-raise from a death inside the guard.
sub raised_by {
	my (%args) = @_;
	local $@;
	return undef if eval {Genesis::CI::Walk::walk_one(%args); 1};
	return $@;
}

subtest 'a run-fatal failure leaves walk_one for the run to end on' => sub {
	plan tests => 5;

	my $session = Recording::Session->new;
	my $record  = a_record();
	my $failure = Genesis::CI::RunFailure->fatal(
		message => 'the staged propagation set does not match its source',
		branch  => 'qa/bosh',
		paths   => ['qa.yml'],
	);

	my $err = raised_by(session => $session, record => $record,
		deliver => sub {die $failure});

	is(ref($err), 'Genesis::CI::RunFailure', 'the failure is re-raised whole');
	is($err->kind, 'run-fatal', 'still carrying the class it was raised as');
	is($err->exit_code, 1, 'and the status D82 gives that class');
	is($record->{outcome}, undef,
		'the environment records no outcome of its own');
	is_deeply($session->{discarded}, [],
		'and its branch is left standing for the abort to reset');
};

subtest 'an unsurvivable failure leaves walk_one the same way' => sub {
	plan tests => 5;

	my $session = Recording::Session->new;
	my $record  = a_record();
	my $failure = Genesis::CI::RunFailure->unsurvivable(
		message => 'could not reach the remote origin',
		remedy  => 'try again once the remote is reachable',
	);

	my $err = raised_by(session => $session, record => $record,
		deliver => sub {die $failure});

	is(ref($err), 'Genesis::CI::RunFailure', 'the failure is re-raised whole');
	is($err->kind, 'unsurvivable', 'still carrying the class it was raised as');
	is($err->exit_code, Genesis::Exit::TEMPFAIL,
		'and the status D82 gives that class');
	is($record->{outcome}, undef,
		'the environment records no outcome of its own');
	is_deeply($session->{discarded}, [],
		'and its branch is left standing for the abort to reset');
};

subtest 'anything else is confined to the environment that raised it' => sub {
	plan tests => 4;

	my $session = Recording::Session->new;
	my $record  = a_record();

	my $err = raised_by(session => $session, record => $record,
		deliver => sub {die "the blueprint hook exited 1\n"});

	is($err, undef, 'nothing is left for the caller to end the run on');
	is($record->{outcome}, 'failed', 'the environment records failed');
	is($record->{error}, 'the blueprint hook exited 1',
		'with the error it raised, on one line');
	is_deeply($session->{discarded}, ['qa/bosh'],
		'and its branch goes back to T while the run walks on');
};

done_testing;
