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
	is_deeply([Genesis::Env->_resolve_track_additional_files(undef, 'x', $root)], []);
	is_deeply([Genesis::Env->_resolve_track_additional_files([], 'x', $root)], []);
	is_deeply([Genesis::Env->_resolve_track_additional_files(['foo'], 'x', undef)], []);
	is_deeply([Genesis::Env->_resolve_track_additional_files(['foo'], 'x', '')], []);
	is_deeply([Genesis::Env->_resolve_track_additional_files(
		[undef, '', 'keep'], 'x', $root
	)], ['keep'], 'skips undef/empty entries');
};

subtest '<env> placeholder substitution' => sub {
	is_deeply(
		[Genesis::Env->_resolve_track_additional_files(
			['cloud-config/<env>.yml'],
			'lmelt-vsphere-canwest-1-mgmt',
			$root,
		)],
		['cloud-config/lmelt-vsphere-canwest-1-mgmt.yml'],
	);
};

subtest 'literal paths pass through verbatim even if nonexistent' => sub {
	is_deeply(
		[Genesis::Env->_resolve_track_additional_files(
			['cloud-config/absent.yml', 'overrides/net.yml'],
			'any',
			$root,
		)],
		['cloud-config/absent.yml', 'overrides/net.yml'],
		'literal paths returned whether or not they exist',
	);
};

subtest 'glob expansion is relative to git root' => sub {
	my @got = Genesis::Env->_resolve_track_additional_files(
		['overrides/*.yml'],
		'whatever',
		$root,
	);
	is_deeply(\@got, ['overrides/net.yml', 'overrides/storage.yml']);
};

subtest 'placeholder + glob combine naturally' => sub {
	# <env> expanded first, then glob
	my @got = Genesis::Env->_resolve_track_additional_files(
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
	my @got = Genesis::Env->_resolve_track_additional_files(
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
		[Genesis::Env->_resolve_track_additional_files(
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
			Genesis::Env->_resolve_track_additional_files([$bad], 'x', $root);
		} qr/escapes/, "rejects $bad";
	}

	# '..' embedded in a filename (not a segment) is allowed
	is_deeply(
		[Genesis::Env->_resolve_track_additional_files(['foo..bar.yml'], 'x', $root)],
		['foo..bar.yml'],
		"'..' inside a filename is not treated as traversal",
	);
};

subtest 'a parent segment spelled as a character class is refused' => sub {
	plan tests => 2;

	# A character class spells the two characters without writing them, so
	# the pattern reads as innocent and the expansion does not.  The set is
	# what gets copied between branches, so a path resolving outside the
	# deployment root would put one there.
	my $deep = tempdir(CLEANUP => 1);
	make_path("$deep/inner");
	open my $fh, '>', "$deep/outside.yml" or die $!;
	close $fh;

	throws_ok {
		Genesis::Env->_resolve_track_additional_files(
			['.[.]/outside.yml'], 'x', "$deep/inner"
		);
	} qr/escapes/, 'the entry is refused however the segment is spelled';

	is_deeply(
		[Genesis::Env->_resolve_track_additional_files(
			['[o]utside.yml'], 'x', $deep
		)],
		['outside.yml'],
		'while a class that stays inside the root still resolves',
	);
};

subtest 'a brace group is a glob' => sub {
	plan tests => 1;

	# The translator names brace alternation as one of the three things a
	# glob means, so a pattern whose only glob character is a brace has to
	# reach it.  Reading it as a literal name adds a file that can never
	# exist and leaves both real ones out of the set.
	my $braced = tempdir(CLEANUP => 1);
	for my $rel (qw(app.yml db.yml other.yml)) {
		open my $fh, '>', "$braced/$rel" or die $!;
		close $fh;
	}

	is_deeply(
		[Genesis::Env->_resolve_track_additional_files(
			['{app,db}.yml'], 'x', $braced
		)],
		['app.yml', 'db.yml'],
		'both alternatives resolve and nothing else joins them',
	);
};

done_testing;
