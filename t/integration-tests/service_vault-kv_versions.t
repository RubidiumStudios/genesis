#!/usr/bin/env perl
# Proves T496: the vault readers, the strict has, the write and the clear
# answer alike on a KV version 1 mount and a KV version 2 mount (D166).
#
# The suite's vault mounts secret/ as version 2, so nothing else in it meets
# version 1, which many long-lived vaults still are.  The two differ exactly
# where a reader decides between a value and an absence: what safe says for a
# path with nothing at it, a secret whose newest version was deleted or
# destroyed, which only version 2 has, and an export that comes back empty.
#
# So this mounts one engine of each version on a real vault and asks every
# reader the same questions of each: a path never written, one written, one
# cleared, and on version 2 one whose newest version is deleted and one whose
# newest version is destroyed.  Every absence reads as the reader's own word
# for absent, and the word does not depend on the mount.
#
# A read the vault refuses is the other half of D155 and is not here: it
# needs a token with a policy, and the rows that give safe's refusal to each
# reader are in the unit tier, against a stand-in safe.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Exception;

use Genesis;
use_ok 'Service::Vault';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 120;

my $target = vault_ok('genesis-kv-versions');

sub safe {
	my (@args) = @_;
	my $out = qx(SAFE_TARGET=$target safe @args 2>&1);
	return ($out, $? >> 8);
}

# The engines are mounted through the API rather than the vault CLI, which a
# host running the suite need not have.
my %VERSION = (kv1 => 1, kv2 => 2);
for my $mount (sort keys %VERSION) {
	my ($said, $rc) = safe(sprintf(
		q{curl --data-only POST sys/mounts/%s '{"type":"kv","options":{"version":"%d"}}'},
		$mount, $VERSION{$mount}));
	is($rc, 0, "a KV version $VERSION{$mount} engine is mounted at $mount/") or diag($said);
}
{
	my ($said) = safe(q{curl --data-only GET sys/mounts});
	my $mounts = eval {JSON::PP::decode_json($said)} || {};
	is_deeply(
		{map {($_ => ($mounts->{"$_/"}{options} || {})->{version})} sort keys %VERSION},
		{kv1 => '1', kv2 => '2'},
		'and the vault reports each at the version it was asked for') or diag($said);
}

# What every reader says of a path with nothing to read at it, and of one
# holding the two keys below.  These are the readers' own contracts, and the
# rows hold each mount to them.
my %WRITTEN = (a => 'one', b => 'two');

sub reads_as_absent {
	my ($v, $path, $state) = @_;
	subtest "$state reads as absent" => sub {
		plan tests => 7;
		is($v->has($path), 0, 'has answers no');
		is($v->has($path, 'a'), 0, 'has answers no for a key of it');
		is_deeply($v->get($path), {}, 'get answers an empty set of keys');
		is($v->get($path, 'a'), undef, 'get answers undef for a key of it');
		is_deeply($v->get_path($path), {}, 'get_path answers an empty tree');
		is($v->get_path_strict($path), undef, 'get_path_strict answers undef');
		is($v->read_flattened_secret($path), undef, 'read_flattened_secret answers undef');
	};
}

sub reads_as_written {
	my ($v, $path, $state) = @_;
	subtest "$state reads as what was written" => sub {
		plan tests => 9;
		is($v->has($path), 1, 'has answers yes');
		is($v->has($path, 'a'), 1, 'has answers yes for a key it holds');
		is($v->has($path, 'z'), 0, 'and no for one it does not');
		is_deeply($v->get($path), \%WRITTEN, 'get answers the keys');
		is($v->get($path, 'a'), 'one', 'get answers one key\'s value');
		is($v->get($path, 'z'), undef, 'and undef for a key it does not hold');
		is_deeply($v->get_path($path), \%WRITTEN, 'get_path answers the keys');
		is_deeply($v->get_path_strict($path), \%WRITTEN, 'get_path_strict answers the keys');
		is_deeply($v->read_flattened_secret($path), \%WRITTEN, 'read_flattened_secret answers the keys');
	};
}

for my $mount (sort keys %VERSION) {
	subtest "KV version $VERSION{$mount}, at $mount/" => sub {
		my $v = Service::Vault->new($helper::VAULT_URL, $target, 0, '', undef, "/$mount/");

		reads_as_absent($v, "$mount/conf/never", 'a path never written');
		lives_ok { $v->clear("$mount/conf/never") } 'clearing a path never written is no error';

		lives_ok { $v->set("$mount/conf/written", %WRITTEN) } 'a write goes through';
		reads_as_written($v, "$mount/conf/written", 'a path written');

		$v->set("$mount/conf/cleared", %WRITTEN);
		lives_ok { $v->clear("$mount/conf/cleared") } 'a clear goes through';
		reads_as_absent($v, "$mount/conf/cleared", 'a path cleared');

		lives_ok { $v->set("$mount/conf/cleared", %WRITTEN) } 'a write over a cleared path goes through';
		reads_as_written($v, "$mount/conf/cleared", 'a cleared path written again');

		lives_ok {
			$v->set_path("$mount/conf/nested", {top => {inner => 'x'}, flat => 'y'}, flatten => 1)
		} 'a nested write goes through';
		is_deeply($v->get_path_strict("$mount/conf/nested"), {top => {inner => 'x'}, flat => 'y'},
			'and reads back nested');

		if ($VERSION{$mount} == 2) {
			# Only version 2 keeps versions, so only it can hold a secret
			# whose newest version is gone while the secret is still listed.
			$v->set("$mount/conf/deleted", %WRITTEN);
			my ($said, $rc) = safe("delete $mount/conf/deleted");
			is($rc, 0, 'the newest version is deleted') or diag($said);
			like((safe("versions $mount/conf/deleted"))[0], qr/^1\s+deleted/m, 'and the vault lists it as deleted');
			reads_as_absent($v, "$mount/conf/deleted", 'a secret whose newest version is deleted');

			# Two versions, because destroying a secret's only version takes
			# the secret away altogether, which is the never-written case.
			$v->set("$mount/conf/destroyed", a => 'older');
			$v->set("$mount/conf/destroyed", %WRITTEN);
			($said, $rc) = safe("delete --destroy $mount/conf/destroyed");
			is($rc, 0, 'the newest version is destroyed') or diag($said);
			like((safe("versions $mount/conf/destroyed"))[0], qr/^2\s+destroyed/m, 'and the vault lists it as destroyed');
			reads_as_absent($v, "$mount/conf/destroyed", 'a secret whose newest version is destroyed');
		}
	};
}

teardown_vault($target);
done_testing;
