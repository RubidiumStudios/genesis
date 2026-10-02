#!/usr/bin/env perl
# An ancestor's manual flag is the topology node's (D117), handed to hold_for
# beside the ancestor's name and certified record.  The walk reads no
# pipeline key off the ancestor's environment, so the environment here dies
# if anything asks it for one.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use Genesis::CI::Walk;

package Trap {
	sub new {bless {}, shift}
	sub lookup {die "the walk read $_[1] off the environment\n"}
}

# The ancestor's undeployed set is the shared file, whatever is asked, so
# the commit being routed overlaps it and the reason is the overlap's.
no warnings 'redefine';
local *Genesis::CI::Walk::undeployed_set = sub {('ops/shared.yml')};
use warnings 'redefine';

sub hold_with {
	my (%opts) = @_;
	return Genesis::CI::Walk::hold_for(
		git       => undef,
		commit    => 'c7',
		files     => ['ops/shared.yml'],
		provider  => $opts{provider},
		ancestors => [{
			name      => 'lab',
			env       => Trap->new,
			manual    => $opts{manual},
			certified => {state => 'certified', control_commit => 'c1'},
		}],
	);
}

subtest "the ancestor's manual flag is the node's" => sub {
	plan tests => 3;

	my $held = eval {hold_with(provider => 'concourse', manual => 1)};
	is($@, '', 'no pipeline key is read off the ancestor\'s environment');
	is($held->{ancestor_state}, 'awaiting its trigger',
		'an automated provider with a manual ancestor awaits its trigger');
	is(eval {hold_with(provider => 'concourse', manual => 0)->{ancestor_state}},
		'awaiting deployment', 'and one without the flag awaits deployment');
};

subtest 'the flag is inert under the manual provider' => sub {
	plan tests => 1;

	is(eval {hold_with(provider => 'manual', manual => 1)->{ancestor_state}},
		'awaiting deployment', 'a person, not a trigger, deploys it');
};

done_testing;
