#!/usr/bin/env perl
# A fake BOSH director listens on a port of its own, so test files starting
# directors side by side never take one another's, and the bosh config names
# that port, so a command dials the director its own test started.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use IO::Socket::IP;
use Genesis qw/slurp/;

subtest 'a director listens on a port of its own, named in the config' => sub {
	plan tests => 4;

	my ($one, $two) = fake_bosh_directors('first-env', 'second-env');
	isnt($one->port, $two->port, 'two directors take two ports');

	my $config = slurp("$ENV{HOME}/.bosh/config");
	like($config, qr{url: https://127\.0\.0\.1:${\ $one->port}\n(?:.*\n)*?\s+alias: first-env},
		"the config names each director's own port");

	ok(IO::Socket::IP->new(PeerHost => '127.0.0.1', PeerPort => $one->port, Timeout => 2),
		'and something answers there');
	is(fake_bosh_director('explicit', $two->port + 1)->port, $two->port + 1,
		'a port asked for is the one taken');
};

subtest 'directors started side by side do not collide' => sub {
	plan tests => 1;

	# Three files starting a director at once, each reporting the port it
	# got and whether its own listener answered there.
	my @kids = map {
		open(my $fh, '-|', $^X, "-I$helper::TOPDIR/t", '-e', <<'EOS') or die $!;
use helper;
my $d = fake_bosh_director('side-by-side');
my $ok = IO::Socket::IP->new(PeerHost => '127.0.0.1', PeerPort => $d->port, Timeout => 2) ? 1 : 0;
print $d->port, " $ok\n";
EOS
		$fh;
	} 1 .. 3;
	my @got = map {my $line = <$_>; close $_; [split ' ', ($line // '')]} @kids;
	my %ports = map {($_->[0] // '') => 1} @got;
	ok(keys(%ports) == 3 && !grep({!$_->[1]} @got),
		'each got a port of its own, and its own listener answered') or diag explain \@got;
};

done_testing;
