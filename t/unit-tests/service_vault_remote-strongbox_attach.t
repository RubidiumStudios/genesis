#!/usr/bin/env perl
# Strongbox must not decide whether a vault can be reached.
#
# attach put strongbox into the find filter alongside url, namespace and
# verify, and bailed when nothing matched.  Strongbox is a seal-state
# sidecar on port 8484: it changes nothing about which secrets exist or
# where they are read from, so two targets identical but for that flag are
# the same vault.  When safe made the flag opt-in, every repository that had
# recorded it as on stopped resolving, over a difference that does not
# affect the connection at all.
#
# It still carries information, so it is not simply ignored:
#   - both sides stated and disagreeing is a real contradiction, and bails
#   - the repository stating it while ~/.saferc is silent is the upgrade
#     case, and warns, because safe will not use Strongbox until the target
#     says so and the operator needs to hear that
#   - it can still break a tie between several otherwise-identical targets,
#     which is disambiguation rather than exclusion
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;

use_ok 'Service::Vault';
use_ok 'Service::Vault::Remote';

$ENV{GENESIS_OUTPUT_COLUMNS} = 200;
$ENV{NOCOLOR} = 1;

sub target {
	my (%args) = @_;
	return Service::Vault::Remote->new(
		$args{url}       // 'https://vault.example.com',
		$args{name}      // 'ops',
		$args{verify}    // 0,
		$args{namespace} // '',
		$args{strongbox},              # undef means ~/.saferc is silent
		'/secret/'
	);
}

# Run attach against a fixed set of known targets, capturing whatever it
# writes to stderr and whatever it dies with.
sub attach_with {
	my ($targets, %opts) = @_;

	no warnings 'redefine';
	local *Service::Vault::find = sub {
		my ($class, %filter) = @_;
		my @matches = @$targets;
		for my $q (keys %filter) {
			@matches = grep {
				defined($_->{$q}) && defined($filter{$q}) && $_->{$q} eq $filter{$q}
			} @matches;
		}
		return @matches;
	};
	local *Service::Vault::Remote::connect_and_validate = sub {$_[0]};
	use warnings 'redefine';

	my ($stderr, $result, $err) = ('');
	{
		local *STDERR;
		open STDERR, '>', \$stderr or die "cannot capture stderr: $!";
		$result = eval {
			Service::Vault::Remote->attach(url => 'https://vault.example.com', %opts)
		};
		$err = $@;
	}
	return ($result, $err, $stderr);
}

subtest 'an unstated target no longer blocks a repository that states it' => sub {
	plan tests => 3;

	# The upgrade case: safe v1.20.0+ reports nothing for a target whose
	# rc never carried the key, while the repository still records true.
	my ($vault, $err, $stderr) = attach_with(
		[target(strongbox => undef)], strongbox => 1
	);

	ok($vault, 'the vault resolves instead of bailing');
	is($err, '', 'nothing was raised');
	like($stderr.$err, qr/strongbox/i,
		'and the divergence is reported rather than passed over silently');
};

subtest 'agreement is quiet' => sub {
	plan tests => 2;

	my ($vault, $err, $stderr) = attach_with(
		[target(strongbox => 1)], strongbox => 1
	);
	ok($vault, 'the vault resolves');
	unlike($stderr, qr/strongbox/i, 'with nothing to say about strongbox');
};

subtest 'a stated disagreement is still an error' => sub {
	plan tests => 2;

	# Both sides made a statement and they contradict.  That is worth
	# stopping for, unlike one side simply having no opinion.
	my ($vault, $err) = attach_with(
		[target(strongbox => 0)], strongbox => 1
	);
	ok(!$vault, 'no vault is returned');
	like($err, qr/strongbox/i, 'and the error is about strongbox');
};

subtest 'a repository with no opinion accepts either target' => sub {
	plan tests => 2;

	for my $sb (0, 1) {
		my ($vault) = attach_with([target(strongbox => $sb)]);
		ok($vault, "resolves against a target stating strongbox=$sb");
	}
};

subtest 'strongbox breaks a tie without ever excluding' => sub {
	plan tests => 2;

	# Two targets alike but for the flag used to be separated by the
	# filter.  They must not now collide as ambiguous duplicates: the
	# recorded value picks one.
	my @pair = (target(name => 'ops-sb', strongbox => 1),
	            target(name => 'ops-no', strongbox => 0));

	my ($chosen) = attach_with([@pair], strongbox => 1);
	is(ref($chosen) && $chosen->name, 'ops-sb',
		'the target matching the recorded value is chosen');

	my ($other) = attach_with([@pair], strongbox => 0);
	is(ref($other) && $other->name, 'ops-no',
		'and the other one when the recorded value is the other way');
};

subtest 'the similar-targets report does not invent expectations' => sub {
	plan tests => 2;

	# No target matches on namespace, so the report lists what was found.
	# verify and namespace are only conditionally in the filter, and the
	# old code compared all four regardless -- warning on an undefined
	# value and printing (expected '') for one nobody asked about.
	my ($vault, $err, $stderr) = attach_with(
		[target(namespace => 'other')], namespace => 'wanted'
	);

	ok(!$vault, 'no vault resolves');
	unlike($err.$stderr, qr/\(expected ''\)|uninitialized/,
		'no empty expectation and no uninitialised-value warning');
};

done_testing;
