#!/usr/bin/env perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Exception;

use Genesis;
use_ok 'Genesis::Config';
provide_rc();
use_ok 'Genesis::Top';
use_ok 'Genesis::Env';
use_ok 'Service::Vault';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

# hold_record against a safe that cannot finish the read.
#
# The walk delivers on this answer, so the premise is the one hold_record's
# own comment states: a vault that cannot be read ends the environment rather
# than reading as unheld.  The two rows that hold today, an absent record and
# a present one, stand beside the two that the premise adds, so a fix that
# turned every answer into a refusal would show here too.

# A stand-in for the safe binary, so hold_record runs its real vault calls
# against a child process that answers as safe would.
my $FAKE_SAFE = 0;
sub fake_safe_path {
	my ($body) = @_;
	my $dir = workdir('fake-safe-'.++$FAKE_SAFE);
	put_file("$dir/safe", "#!/bin/bash\n$body\n");
	chmod(0755, "$dir/safe");
	return "$dir:$ENV{PATH}";
}

sub held_env {
	my $top = make_top(name => 'bosh', no_vault => 1);
	$top->link_dev_kit('t/src/simple');
	put_file($top->path('lab-mgmt.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
  features: []

genesis:
  env: lab-mgmt
EOF
	return $top->load_env('lab-mgmt');
}

my $vault = Service::Vault->new('https://vault.example.com:8200', 'test-vault', 1, '', undef, '/secret/');
no warnings qw/redefine once/;
local *Genesis::Env::vault = sub { $vault };
use warnings qw/redefine once/;

subtest 'an absent record reads as no hold' => sub {
	plan tests => 1;
	my $env = held_env();
	# safe exists says nothing and exits 1; get names the path.
	local $ENV{PATH} = fake_safe_path(join("\n",
		'[ "$1" = exists ] && exit 1',
		'p="${@: -1}"; p="${p#/}"',
		'printf "!! no secret exists at path \`%s\`\n" "$p" >&2',
		'exit 1',
	));
	is($env->hold_record, undef, 'nothing stored is no hold');
};

subtest 'a present record reads as the hold' => sub {
	plan tests => 1;
	my $env = held_env();
	local $ENV{PATH} = fake_safe_path(join("\n",
		'[ "$1" = exists ] && exit 0',
		'printf "at: 2026-11-12T20:00:00Z\nhostname: bastion\nreason: change freeze\nuser: ops\n"',
	));
	is_deeply($env->hold_record,
		{reason => 'change freeze', user => 'ops', hostname => 'bastion', at => '2026-11-12T20:00:00Z'},
		'the four fields come back');
};

subtest 'a refused read is not read as no hold' => sub {
	plan tests => 2;
	my $env  = held_env();
	my $path = $env->hold_record_path =~ s{^/}{}r;
	local $ENV{PATH} = fake_safe_path(
		q{printf 'Error making API request.\n\nCode: 403. Errors:\n\n* 1 error occurred:\n\t* permission denied\n' >&2; exit 1}
	);
	my $record = 'unset';
	throws_ok { $record = $env->hold_record } qr{\Q$path\E.*Code: 403}s,
		'the refusal is raised, naming the hold path';
	isnt($record, undef, 'and the environment is never answered as unheld');
};

subtest 'an unreachable vault is not read as no hold' => sub {
	plan tests => 2;
	my $env  = held_env();
	my $path = $env->hold_record_path =~ s{^/}{}r;
	local $ENV{PATH} = fake_safe_path(
		q{printf '!! dial tcp 10.0.0.1:8200: connect: connection refused\n' >&2; exit 1}
	);
	my $record = 'unset';
	throws_ok { $record = $env->hold_record } qr{\Q$path\E.*connection\s+refused}s,
		'the failure is raised, naming the hold path';
	isnt($record, undef, 'and the environment is never answered as unheld');
};

done_testing;
