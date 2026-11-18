#!/usr/bin/env perl
# `genesis <env> bosh --connect` prints export lines that the operator
# runs through `eval "$(...)"`.  Each value must reach the caller's shell
# as the same bytes the director's credentials hold, so a value with a
# dollar sign, a backtick, a backslash, a quote, or a newline must be
# quoted as one literal word: the shell neither expands it nor runs it.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Genesis::Commands::Bosh;

my $dir = tempdir(CLEANUP => 1);
my $canary = "$dir/command-ran";

my %values = (
	BOSH_CLIENT_SECRET => 'fake-$HOME-${PATH}-$(touch '.$canary.')-tail',
	BOSH_CA_CERT       => "fake-`touch $canary`-backtick",
	BOSH_CLIENT        => 'fake\\back\\\\slash\\$x\\"q\\n',
	BOSH_ENVIRONMENT   => q{fake-'single'-"double"-'"'mixed"'"'},
	BOSH_PASSWORD      => "fake-multi\nline\n\n",
	BOSH_DEPLOYMENT    => '',
);

my (undef, undef, $stdout) = capture_trace {
	Genesis::Commands::Bosh::_print_connect_exports('fake-alias', %values);
};

# Each value is written back out by the shell that evaluated the exports,
# NUL-separated, so trailing newlines survive the round trip.
put_file("$dir/exports", $stdout);
my @names = sort keys %values;
my $script = 'eval "$(cat "$1")" || exit 3; shift; for n in "$@"; do printf "%s\0" "${!n}"; done';
open my $sh, '-|', '/bin/bash', '-c', $script, 'bash', "$dir/exports", @names
	or die "cannot run bash: $!";
my $got = do {local $/; <$sh>};
close $sh;
is($? >> 8, 0, 'the caller\'s shell evaluates the exports without error');

my @got = split(/\0/, $got, -1);
pop @got; # the field after the last NUL
for my $i (0..$#names) {
	is($got[$i], $values{$names[$i]}, "$names[$i] round-trips byte for byte");
}
ok(! -e $canary, 'no command embedded in a value was run');

done_testing;
