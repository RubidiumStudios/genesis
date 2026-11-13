#!/usr/bin/env perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Exception;

use Genesis;
use_ok 'Service::Vault';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

# has answers yes, no, or raises (D155, T484).
#
# What it must never do is answer no for a check that did not finish, since a
# caller acts on no: it reports nothing to remove, or writes what it takes to
# be missing.  Absence is what safe says in words.  safe's silence is not
# absence, because safe exists exits 1 alike for a path that is not there and
# for a read that failed, and prints some of its errors without a prefix.

# A stand-in for the safe binary, which answers as safe would and records
# what it was asked.
my $FAKE_SAFE = 0;
my $CALLS;
sub fake_safe_path {
	my ($body) = @_;
	my $dir = workdir('fake-safe-'.++$FAKE_SAFE);
	$CALLS = "$dir/calls";
	put_file("$dir/safe", "#!/bin/bash\necho \"\$*\" >> '$CALLS'\n$body\n");
	chmod(0755, "$dir/safe");
	return "$dir:$ENV{PATH}";
}
sub calls { -f $CALLS ? split("\n", get_file($CALLS)) : () }

my $ABSENT  = q{p="${@: -1}"; p="${p#/}"; printf '!! no secret exists at path `%s`\n' "$p" >&2; exit 1};
my $REFUSED = q{printf 'Error making API request.\n\nCode: 403. Errors:\n\n* 1 error occurred:\n\t* permission denied\n' >&2; exit 1};

sub vault { Service::Vault->new('https://vault.example.com:8200', 'test-vault', 1, '', undef, '/secret/') }

subtest 'a path that holds a secret is there' => sub {
	plan tests => 3;
	local $ENV{PATH} = fake_safe_path(q{printf 'password: hunter2\nuser: admin\n'});
	ok(vault()->has('secret/myapp'), 'the path is there');
	ok(vault()->has('secret/myapp', 'password'), 'and so is a key it holds');
	ok(!vault()->has('secret/myapp', 'token'), 'while a key it does not hold is not');
};

subtest 'a path safe says holds nothing is not there' => sub {
	plan tests => 2;
	local $ENV{PATH} = fake_safe_path($ABSENT);
	is(vault()->has('secret/myapp'), 0, 'the path is not there');
	is(vault()->has('secret/myapp', 'password'), 0, 'nor is any key of it');
};

subtest 'a check that did not finish raises, and never answers no' => sub {
	plan tests => 8;
	my %failures = (
		'a refusal'            => [$REFUSED, qr/Code: 403/],
		'an unreachable vault' => [q{printf '!! dial tcp 10.0.0.1:8200: connect: connection refused\n' >&2; exit 1}, qr/connection\s+refused/],
		'an unauthenticated safe, which prints no prefix'
		                       => [q{printf 'You are not authenticated to a Vault.\n' >&2; exit 1}, qr/not\s+authenticated/],
		'a safe that exits 1 and says nothing'
		                       => [q{exit 1}, qr/secret\/myapp/],
	);
	for my $case (sort keys %failures) {
		my ($body, $says) = @{$failures{$case}};
		local $ENV{PATH} = fake_safe_path($body);
		my $answer = 'unset';
		throws_ok { $answer = vault()->has('secret/myapp') } $says, "$case is raised";
		is($answer, 'unset', "$case: no answer came back");
	}
};

subtest 'a safe killed by a signal raises' => sub {
	plan tests => 1;
	local $ENV{PATH} = fake_safe_path(q{kill -9 $$});
	throws_ok { vault()->has('secret/myapp') } qr{secret/myapp}, 'the kill is raised, naming the path';
};

done_testing;
