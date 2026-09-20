#!/usr/bin/env perl
# The manifest parser's two answers, which are the ordered list of test files
# a section names and the warning it raises for a test file on disk that the
# section never mentions.  Both are read against a tree built here rather than
# against the suite's own manifest, so a row says what it means without moving
# whenever a test file is added.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Cwd ();
use File::Temp ();

my $PARSER = Cwd::abs_path('t/bin/parse-manifest')
	or BAIL_OUT('cannot resolve t/bin/parse-manifest');

# Builds a tree of empty test files and a manifest naming some of them, runs
# the parser inside it, and answers what it printed and what it warned.
sub parse {
	my ($manifest, $files, @sections) = @_;

	my $tmp = File::Temp::tempdir(CLEANUP => 1);
	for my $rel (@$files) {
		my $path = "$tmp/t/$rel";
		my $dir  = $path =~ s{/[^/]+$}{}r;
		system('mkdir', '-p', $dir) == 0 or die "could not make $dir\n";
		open my $fh, '>', $path or die "could not write $path: $!\n";
		close $fh;
	}
	open my $fh, '>', "$tmp/manifest.txt" or die "could not write a manifest: $!\n";
	print $fh $manifest;
	close $fh;

	my $was = Cwd::getcwd();
	chdir $tmp or die "could not stand in $tmp: $!\n";
	my $out = qx($^X $PARSER manifest.txt @{[join ' ', @sections]} 2>$tmp/err);
	chdir $was or die "could not stand back in $was: $!\n";

	open my $err, '<', "$tmp/err" or die "could not read the warnings: $!\n";
	my @warned = <$err>;
	close $err;

	return ([grep {length} split /\n/, $out], [grep {length} map {s/\s+$//r} @warned]);
}

my $MANIFEST = <<'EOM';
[unit-tests]
unit-tests/listed.t    # a test in a directory
top-listed.t           # a test at the top of t/

[integration-tests]
integration-tests/listed.t
EOM

my @FILES = qw(
	unit-tests/listed.t
	unit-tests/unlisted.t
	top-listed.t
	top-unlisted.t
	integration-tests/listed.t
);

subtest 'the section is printed in the order the manifest gives it' => sub {
	plan tests => 1;

	my ($printed) = parse($MANIFEST, \@FILES, 'unit-tests');
	is_deeply($printed, ['t/unit-tests/listed.t', 't/top-listed.t'],
		'both entries are printed, the directory one and the top-level one');
};

subtest 'a test file the section never mentions is warned about' => sub {
	plan tests => 3;

	my (undef, $warned) = parse($MANIFEST, \@FILES, 'unit-tests');

	ok((grep {/unregistered: unit-tests\/unlisted\.t$/} @$warned),
		'a file in a directory the section names is warned about');
	ok((grep {/unregistered: top-unlisted\.t$/} @$warned),
		'and so is a file at the top of t/, which the entries also live at');
	ok(!(grep {/unregistered: top-listed\.t$/} @$warned),
		'while the top-level file the section does name is left alone');
};

# The top of t/ is read on every run, so a section holding no entry of its own
# up there would report every top-level file as unregistered unless the whole
# manifest is what the answer is measured against.
subtest 'a top-level file another section lists is not warned about' => sub {
	plan tests => 2;

	my (undef, $warned) = parse($MANIFEST, \@FILES, 'integration-tests');

	ok(!(grep {/unregistered: top-listed\.t$/} @$warned),
		'the entry the other section carries is registration enough');
	ok((grep {/unregistered: top-unlisted\.t$/} @$warned),
		'and a top-level file no section carries is still reported');
};

done_testing;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
