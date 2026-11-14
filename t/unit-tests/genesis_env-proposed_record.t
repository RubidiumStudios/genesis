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

use Test::Exception;
use Genesis::Env;

# FakeEnv - what proposed_record asks of an environment.  Its vault's
# get_path answers what it holds, or dies as the strict reader does when it
# is given a failure.
{
	package FakeEnv;
	sub new { my ($class, %opts) = @_; return bless {%opts}, $class }
	sub name { 'qa' }
	sub proposed_record_path { 'secret/exodus/qa/bosh/proposed' }
	sub vault { $_[0] }
	sub get_path { die $_[0]->{fails} if $_[0]->{fails}; $_[0]->{holds} }
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

# A deploy and a propagate run both act on whether a proposal stands, so a
# read that did not finish has to stop them, not read as no proposal.
subtest 'a read that fails raises, and is never no record' => sub {
	plan tests => 2;
	for my $case (
		['a refusal', "Could not read secret/exodus/qa/bosh/proposed from vault at https://v:8200: Code: 403. permission denied\n", qr/Code: 403/],
		['an outage', "Could not read secret/exodus/qa/bosh/proposed from vault at https://v:8200: connection refused\n", qr/connection refused/],
	) {
		my ($what, $error, $reason) = @$case;
		throws_ok { Genesis::Env::proposed_record(FakeEnv->new(fails => $error)) }
			qr{Could not read secret/exodus/qa/bosh/proposed.*$reason}s, "$what raises with what the vault said";
	}
};

# The record's owner judges it: what set_proposed writes always carries a
# control commit and a pull request number.
subtest 'a record that is not a proposal raises, naming the record and what it holds' => sub {
	my %bad = (
		'no control commit'        => [{number => 7, url => 'u', at => 'a'},                      qr/no\s+control\s+commit/],
		'no pull request number'   => [{control_commit => 'abc123', url => 'u', at => 'a'},       qr/no\s+pull\s+request\s+number/],
		'a field that is a subtree' => [{control_commit => {deeper => 'abc123'}, number => 7},    qr/control_commit.*not\s+a\s+value/s],
		'only fields it never writes' => [{reason => 'left by something else'},                   qr/no\s+control\s+commit/],
	);
	plan tests => 3 * keys %bad;
	for my $case (sort keys %bad) {
		my ($holds, $found) = @{$bad{$case}};
		throws_ok { proposed($holds) } qr{proposed\s+record\s+for\s+qa.*secret/exodus/qa/bosh/proposed}s,
			"$case: raises, naming the environment and the path";
		throws_ok { proposed($holds) } $found, "$case: says what it found";
		throws_ok { proposed($holds) } qr{safe\s+get\s+secret/exodus/qa/bosh/proposed}s,
			"$case: and how to look at it";
	}
};

done_testing;
