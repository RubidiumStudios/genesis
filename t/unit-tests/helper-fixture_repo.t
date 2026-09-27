#!/usr/bin/env perl
# fixture_repo copies a repository under t/repos into the process's own work
# area, once, and hands back the copy, so e2e files that write into the same
# fixture can run side by side.  The copy is made once per process, because
# the files that use a fixture read what their earlier subtests wrote there.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

subtest 'the copy is the process\'s own' => sub {
	plan tests => 4;

	my $copy = fixture_repo('manifest-test');
	like($copy, qr{^\Q$helper::TMP\E/}, 'it lives in the work area');
	ok(-d "$copy/.genesis", 'and carries the fixture\'s contents');

	put_file("$copy/scratch.yml", "---\nwritten: here\n");
	ok(!-e "$helper::TOPDIR/t/repos/manifest-test/scratch.yml",
		'a write to the copy leaves the fixture untouched');

	is(fixture_repo('manifest-test'), $copy,
		'and asking again gives the same copy');
};

subtest 'a later call sees what an earlier subtest wrote' => sub {
	plan tests => 1;
	ok(-f fixture_repo('manifest-test') . '/scratch.yml',
		'the copy is made once per process');
};

subtest 'an unknown fixture is refused' => sub {
	plan tests => 1;
	eval { fixture_repo('no-such-fixture') };
	like($@, qr/no fixture repository no-such-fixture/, 'naming it');
};

done_testing;
