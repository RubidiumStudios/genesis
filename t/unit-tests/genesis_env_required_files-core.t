#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';

use Test::More;
use Test::Deep;
use Test::Exception;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use_ok 'Genesis::Env';

# Build a small scratch tree for glob resolution
my $root = tempdir(CLEANUP => 1);
make_path("$root/cloud-config");
make_path("$root/overrides");
for my $rel (qw(
	cloud-config/lmelt.yml
	cloud-config/lmelt-vsphere-canwest-1-mgmt.yml
	cloud-config/lmelt-vsphere-canwest-1-lab.yml
	overrides/net.yml
	overrides/storage.yml
)) {
	open my $fh, '>', "$root/$rel" or die $!;
	close $fh;
}

subtest 'empty / malformed inputs return empty' => sub {
	is_deeply([Genesis::Env->_resolve_required_files(undef, 'x', $root)], []);
	is_deeply([Genesis::Env->_resolve_required_files([], 'x', $root)], []);
	is_deeply([Genesis::Env->_resolve_required_files(['foo'], 'x', undef)], []);
	is_deeply([Genesis::Env->_resolve_required_files(['foo'], 'x', '')], []);
	is_deeply([Genesis::Env->_resolve_required_files(
		[undef, '', 'keep'], 'x', $root
	)], ['keep'], 'skips undef/empty entries');
};

subtest '<env> placeholder substitution' => sub {
	is_deeply(
		[Genesis::Env->_resolve_required_files(
			['cloud-config/<env>.yml'],
			'lmelt-vsphere-canwest-1-mgmt',
			$root,
		)],
		['cloud-config/lmelt-vsphere-canwest-1-mgmt.yml'],
	);
};

subtest 'literal paths pass through verbatim even if nonexistent' => sub {
	is_deeply(
		[Genesis::Env->_resolve_required_files(
			['cloud-config/absent.yml', 'overrides/net.yml'],
			'any',
			$root,
		)],
		['cloud-config/absent.yml', 'overrides/net.yml'],
		'literal paths returned whether or not they exist',
	);
};

subtest 'glob expansion is relative to git root' => sub {
	my @got = Genesis::Env->_resolve_required_files(
		['overrides/*.yml'],
		'whatever',
		$root,
	);
	is_deeply(\@got, ['overrides/net.yml', 'overrides/storage.yml']);
};

subtest 'placeholder + glob combine naturally' => sub {
	# <env> expanded first, then glob
	my @got = Genesis::Env->_resolve_required_files(
		['cloud-config/lmelt-vsphere-canwest-1-*.yml'],
		'ignored',
		$root,
	);
	is_deeply(\@got, [
		'cloud-config/lmelt-vsphere-canwest-1-lab.yml',
		'cloud-config/lmelt-vsphere-canwest-1-mgmt.yml',
	]);
};

subtest 'duplicates are de-duplicated; output sorted' => sub {
	my @got = Genesis::Env->_resolve_required_files(
		[
			'overrides/net.yml',
			'overrides/*.yml',           # also matches overrides/net.yml
			'cloud-config/<env>.yml',
		],
		'lmelt-vsphere-canwest-1-mgmt',
		$root,
	);
	is_deeply(\@got, [
		'cloud-config/lmelt-vsphere-canwest-1-mgmt.yml',
		'overrides/net.yml',
		'overrides/storage.yml',
	]);
};

subtest 'unmatched glob returns nothing' => sub {
	is_deeply(
		[Genesis::Env->_resolve_required_files(
			['no-such-dir/*.yml'],
			'x',
			$root,
		)],
		[],
	);
};

subtest 'path-safety rule bails on escape attempts' => sub {
	for my $bad (
		'/etc/passwd',
		'/absolute/cloud-config.yml',
		'~/secrets.yml',
		'../escape.yml',
		'cloud-config/../../escape.yml',
		'a/b/../c/../../d.yml',
	) {
		throws_ok {
			Genesis::Env->_resolve_required_files([$bad], 'x', $root);
		} qr/escapes/, "rejects $bad";
	}

	# '..' embedded in a filename (not a segment) is allowed
	is_deeply(
		[Genesis::Env->_resolve_required_files(['foo..bar.yml'], 'x', $root)],
		['foo..bar.yml'],
		"'..' inside a filename is not treated as traversal",
	);
};

done_testing;
