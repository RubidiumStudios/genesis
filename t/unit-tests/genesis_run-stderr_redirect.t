#!perl
# `stderr` is a shell redirect target, so a value that looks like a file
# descriptor is not one.
#
# Genesis::run wraps commands as `{ CMD ; } 2>$opts{stderr}`, which makes
# `stderr => 1` render `2>1` -- creating a file literally named "1" in the
# working directory rather than merging the streams.  It is silent: the
# command still succeeds and nothing reports the stray file.  A kit hook
# made this mistake in four places and the resulting file was committed to
# a deployment repository before anyone noticed.
#
# No caller ever wants a file whose name is a bare integer, so an integer
# is taken as the file descriptor it plainly means.  0 is the exception:
# it already means "capture stderr separately", a documented contract with
# callers throughout the tree, and it keeps that meaning.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis;

# Run a command that writes to both streams, from a scratch directory, so
# any stray redirect target shows up as a file we can see.
sub run_in_scratch {
	my (%opts) = @_;
	my $dir = workdir();
	my @result = run(
		{%opts, dir => $dir},
		'echo "on-stdout"; echo "on-stderr" >&2'
	);
	opendir(my $dh, $dir) or die "cannot read scratch dir: $!";
	my @stray = grep {!/^\.\.?$/} readdir($dh);
	closedir($dh);
	return (\@result, [sort @stray], $dir);
}

subtest 'an integer is a file descriptor, not a filename' => sub {
	plan tests => 4;

	my ($result, $stray) = run_in_scratch(stderr => 1);
	is_deeply($stray, [], 'no file named "1" is left behind');
	like($result->[0], qr/on-stdout/, 'stdout is captured');
	like($result->[0], qr/on-stderr/, 'and stderr was merged into it');
	is($result->[1], 0, 'the command still succeeds');
};

subtest 'the same holds for other descriptors' => sub {
	plan tests => 2;

	# 2>&2 is a no-op that leaves stderr on the terminal; the point is
	# only that it must not create a file called "2".
	my ($result, $stray) = run_in_scratch(stderr => 2);
	is_deeply($stray, [], 'no file named "2" is left behind');
	like($result->[0], qr/on-stdout/, 'stdout is still captured');
};

subtest 'zero keeps its established meaning' => sub {
	plan tests => 3;

	# 0 means "capture stderr separately", not "&0".  Callers across the
	# tree depend on the third return value, so this must not be swept
	# into the descriptor rule.
	my ($result, $stray) = run_in_scratch(stderr => 0);
	is_deeply($stray, [], 'nothing is written into the working directory');
	unlike($result->[0], qr/on-stderr/, 'stderr is kept out of stdout');
	like($result->[2], qr/on-stderr/, 'and returned as the third value');
};

subtest 'explicit forms are untouched' => sub {
	plan tests => 3;

	my ($merged, $stray) = run_in_scratch(stderr => '&1');
	like($merged->[0], qr/on-stderr/, "'&1' still merges");
	is_deeply($stray, [], "and writes no file");

	# A genuine path is still honoured -- the coercion must not swallow
	# the ability to name a destination.
	my $dir = workdir();
	run({dir => $dir, stderr => "$dir/errors.log"},
		'echo "on-stdout"; echo "on-stderr" >&2');
	ok(-s "$dir/errors.log", 'an explicit path still receives stderr');
};

done_testing;
