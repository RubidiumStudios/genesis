#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;
use Test::Exception;
use JSON::PP qw/decode_json/;
use Scalar::Util qw/refaddr/;

use_ok 'Service::Vault::Local';
use Genesis;

# A process can start, stop, and start again a local vault under the same
# name, as two entombed manifest builds in one deploy do.  The vaults are
# real, and so is the ~/.saferc they register in, under the test's own HOME.

put_file "$ENV{HOME}/.vault_token", '';
local $ENV{SAFE_TARGET} = undef;

# local_targets - the local vault targets ~/.saferc lists, by name.
sub local_targets {
	my $json = qx(SAFE_TARGET= safe targets --json);
	return sort grep {/^local_vault_/} map {$_->{name}} @{decode_json($json || '[]')};
}

my $first = Service::Vault::Local->create('recreate');
my $alias = $first->name;
is $first->status, 'ok', 'the first local vault answers';
lives_ok { $first->set('secret/recreate', 'value', 'first') } 'and takes a write';
$first->shutdown;
ok !$first->{safe_pid}, 'it is stopped by its shutdown';
is_deeply [local_targets()], [], 'which removes its target from ~/.saferc';
is Service::Vault::Local->rebind($alias), undef,
	'and leaves nothing for a rebind to return';

my $second = Service::Vault::Local->create('recreate');
isnt refaddr($second), refaddr($first), 'creating it again does not hand back the stopped vault';
is $second->name, $alias, 'but a new vault under the same name';
ok $second->{safe_pid}, 'which is running';
is $second->status, 'ok', 'and answers';
lives_ok { $second->set('secret/recreate', 'value', 'second') } 'and takes a write';
is $second->get('secret/recreate', 'value'), 'second', 'which reads back';
is_deeply [local_targets()], [$alias], 'with one target registered for it';
is refaddr(Service::Vault::Local->create('recreate')), refaddr($second),
	'and a running vault is still shared by every create of its name';

$second->shutdown;
is_deeply [local_targets()], [], 'and its shutdown leaves no target behind';

done_testing;
