#!perl
#
# pack's argument handling.
#
# A user reading "[<version> [<output path/file>]]" typed
#
#     ./pack v3.2.0 output ~/bin/g32
#
# taking "output" for a literal keyword.  pack accepted it, used "output"
# as the filename, and discarded the path they meant.  These cover the
# rejections that turn that into an error, and the forms that must keep
# working.
#
# Only argument handling is exercised -- nothing here builds an archive,
# so the tests stay fast and need no git state.

use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

my $PACK = 'pack';

# Runs pack and returns (stdout+stderr, exit code).  Nothing reaches the
# packaging stage: every case here is rejected during argument parsing, or
# is --help.
sub pack_with {
	my (@args) = @_;
	my $out = qx(./$PACK @args 2>&1);
	return ($out, $? >> 8);
}

subtest 'the reported mistake is refused' => sub {
	my ($out, $rc) = pack_with(qw(v3.2.0 output ~/bin/g32));
	isnt $rc, 0, 'a third argument is an error, not silently dropped';
	like $out, qr/at most 2 arguments/, 'says how many are allowed';
	like $out, qr/\bgot 3\b/,           'and how many it got';
	like $out, qr/usage:/,              'and shows the usage';
};

subtest 'version is validated' => sub {
	my ($out, $rc) = pack_with('notaversion');
	isnt $rc, 0, 'a non-version is refused';
	like $out, qr/is not a version/, 'says what was wrong with it';
	like $out, qr/usage:/,           'and shows the usage';
};

subtest 'unknown options are refused' => sub {
	# Without this, an unrecognised flag becomes the version and fails
	# the semver check, which reports the wrong problem.
	my ($out, $rc) = pack_with('--strip-pod', '3.2.0');
	isnt $rc, 0, 'refused';
	like $out, qr/unrecognised option '--strip-pod'/,
		'names the option rather than complaining about the version';
};

subtest 'accepted version forms' => sub {
	# Whatever Genesis::semver accepts, pack must accept: a version it
	# rejects here is one genesis would have been happy with later.
	#
	# Checked by way of a deliberately over-long argument list, so the run
	# always stops at the count and can never reach the packaging stage.
	# Asking with a valid-looking invocation instead would build a real
	# executable into the repository the moment a guard changed.
	for my $v (qw(3 3.2 3.2.0 v3.2.0 V3.2.0 3.2.0-rc1 3.2.0-rc.1 3.2.0+build7)) {
		my ($out, $rc) = pack_with($v, 'a', 'b');
		like   $out, qr/at most 2 arguments/, "$v reaches the argument-count check";
		unlike $out, qr/is not a version/,    "$v is accepted as a version";
	}
};

subtest 'help is available and exits clean' => sub {
	for my $flag (qw(-h --help)) {
		my ($out, $rc) = pack_with($flag);
		is $rc, 0, "$flag exits 0";
		like $out, qr/usage:.*VERSION.*OUTFILE/s, "$flag shows the argument names";
		like $out, qr/Examples:/,                 "$flag shows worked examples";
	}
};

subtest 'usage names the arguments unambiguously' => sub {
	# The original text read as though "output" were a word to type.
	my ($out) = pack_with('--help');
	unlike $out, qr/<output path\/file>/,
		'the phrasing that was misread is gone';
	like $out, qr{\./pack v3\.2\.0 ~/bin/g32},
		'and an example shows the exact two-argument form';
};

subtest 'nothing was built into the repository' => sub {
	# Every case above is refused during argument parsing, so no archive
	# should exist.  Proving it here means a future change that lets one
	# through is caught by this test rather than by a stray executable
	# turning up in git status days later.
	my @built = grep {-f $_ && !-l $_} qw(a b output 3.2.0 --help notaversion);
	is_deeply \@built, [], 'no pack output left behind'
		or diag("stray: @built");
};

done_testing;
