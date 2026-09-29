#!/usr/bin/env perl
# Genesis::Env::proposed_record answers undef where no proposed record stands.
# The vault's get_path answers {} for a path that holds nothing, and a hash
# with every field empty is true, so each caller that asks whether a pull
# request is proposed was told there was one: the deploy's due-commits warning
# printed "PR # proposes control@, not yet merged" with nothing in either slot.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;

use Genesis::Env;

# FakeEnv - the two things proposed_record asks of an environment
{
	package FakeEnv;
	sub new { my ($class, %opts) = @_; return bless {%opts}, $class }
	sub proposed_record_path { 'secret/exodus/qa/bosh/proposed' }
	sub vault { $_[0] }
	sub get_path { $_[0]->{holds} }
}

sub proposed { Genesis::Env::proposed_record(FakeEnv->new(holds => $_[0])) }

subtest 'no record answers undef' => sub {
	plan tests => 2;
	is(proposed({}), undef, 'a path holding nothing is no proposed record');
	is(proposed(undef), undef, 'nor is a read that answered nothing at all');
};

subtest 'a record answers its fields' => sub {
	plan tests => 1;
	is_deeply(
		proposed({control_commit => 'abc123', number => 7,
		          url => 'https://github.example/pr/7', at => '2026-09-28'}),
		{control_commit => 'abc123', number => 7,
		 url => 'https://github.example/pr/7', at => '2026-09-28'},
		'the four fields come back');
};

done_testing;
