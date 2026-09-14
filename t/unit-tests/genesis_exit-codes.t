#!perl
# Proves T7: Genesis::Exit is the one home of the named codes, it holds the
# seven values the design fixes, and no other file in the tree exits with one
# of those numbers written as a bare literal.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis::Exit qw/TEMPFAIL DATAERR ABORTED NOPERM CONFIG UNAVAILABLE SOFTWARE/;

$ENV{NOCOLOR} = 1;

# An assertion helper, so it lives beside the test that uses it.  The scan
# reads a line at a time and looks for a number in an exit position, which is
# either an `exit` statement or the `exitcode` option bail takes.  The option
# is caught however it is spelled, so a quoted key and an assignment such as
# `$opts{exitcode} = 75` are call sites as much as the fat comma is, and a
# `==` is passed over because a comparison spends nothing.  The file list
# comes from the shared sweep reader, which is anchored on the tree rather
# than on the current directory and covers every script under bin/ as well as
# every module under lib/, and each finding is named by its path within the
# tree so a diagnostic stays readable.
sub bare_exits_of {
	my (@codes) = @_;
	my $codes = join('|', @codes);
	my $top   = $ENV{GENESIS_TOPDIR};

	my @found;
	for my $file (sweep_files()) {
		(my $short = $file) =~ s{^\Q$top\E/}{};
		next if $short eq 'lib/Genesis/Exit.pm';
		open my $fh, '<', $file or die "cannot read $file: $!\n";
		while (my $line = <$fh>) {
			# Stop at the data section: Genesis::Helpers carries the kit
			# helper bash script in its __DATA__ block, and a shell exit
			# there is not a Perl call site that could spend a constant.
			last if $line =~ /^__(?:DATA|END)__\s*$/;
			# A trailing comment goes before the match, so a note that
			# names a code in prose is not read as a call site.
			my $code = strip_comment($line);
			push @found, "$short:$."
				if $code =~ /\bexit\s*\(?\s*(?:$codes)\b/
				|| $code =~ /\bexitcode\b['"]?\s*[\]\}]?\s*
				             (?:=>|=(?![=~]))\s*(?:$codes)\b/x;
		}
		close $fh;
	}
	return @found;
}

subtest 'the seven codes hold the values the design fixes' => sub {
	plan tests => 7;

	is(TEMPFAIL,    75,  'TEMPFAIL is 75, the partial propagation a retry repairs');
	is(DATAERR,     65,  'DATAERR is 65, the illegal initial state');
	is(ABORTED,     130, 'ABORTED is 130, the run the operator declined');
	is(NOPERM,      77,  'NOPERM is 77, the provider gate without --force');
	is(CONFIG,      78,  'CONFIG is 78, the misconfigured pipeline');
	is(UNAVAILABLE, 69,  'UNAVAILABLE is 69, the service that could not answer');
	is(SOFTWARE,    70,  'SOFTWARE is 70, the tracked modification after a success');
};

subtest 'the module exports the seven on request' => sub {
	plan tests => 3;

	is_deeply([sort @Genesis::Exit::EXPORT_OK],
		[sort qw/TEMPFAIL DATAERR ABORTED NOPERM CONFIG UNAVAILABLE SOFTWARE/],
		'every code is exportable by name');
	is_deeply([sort @{$Genesis::Exit::EXPORT_TAGS{all}}],
		[sort @Genesis::Exit::EXPORT_OK],
		'the :all tag carries the same seven');
	is_deeply(\@Genesis::Exit::EXPORT, [],
		'and nothing is exported by default, since CONFIG is an ordinary word');
};

# A guard rather than a row that starts red: nothing in the tree spends one of
# the seven today, so this subtest is green the moment the module exists, and
# its job is to stay green as the steps below reach for the constants.  Its
# red was shown by hand before the commit, by writing one bare literal into a
# file under lib/ and watching the sweep name the file and the line.
subtest 'nothing else in the tree writes one of the seven as a bare literal' => sub {
	plan tests => 1;

	my @offenders = bare_exits_of(qw/75 65 130 77 78 69 70/);
	is_deeply(\@offenders, [],
		'every one of the seven codes is spent through its constant')
		or diag(join("\n", map {"  $_"} @offenders));
};

done_testing;
