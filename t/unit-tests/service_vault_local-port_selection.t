#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::Exception;
use IO::Socket::IP ();
use POSIX ();

use_ok 'Service::Vault::Local';
use Genesis;

# Bind a listener on an ephemeral-but-known port and hand back both the
# socket (keep it in scope to hold the port) and the port number.
sub occupy {
	my ($port) = @_;
	my $sock = IO::Socket::IP->new(
		LocalAddr => '127.0.0.1',
		LocalPort => $port,
		Proto     => 'tcp',
		Listen    => 1,
		ReuseAddr => 0,
	);
	return $sock;
}

# Find a run of $count consecutive free ports to use as a test range, so
# these subtests do not fight whatever else is on the box.
sub free_range {
	my ($count) = @_;
	for (my $base = 8400; $base < 9800; $base++) {
		my @socks = grep { defined } map { occupy($base + $_) } 0..($count-1);
		if (scalar(@socks) == $count) {
			close($_) for @socks;
			return $base;
		}
		close($_) for @socks;
	}
	BAIL_OUT("could not find $count consecutive free ports for testing");
}

subtest 'skips ports that are already bound' => sub {
	plan tests => 2;

	my $base = free_range(4);
	my $held = occupy($base);
	ok($held, "test occupied port $base");

	my $port = Service::Vault::Local::_find_free_port($base, $base + 3);
	isnt($port, $base,
		"_find_free_port skips $base while it is bound (got $port)");

	close($held);
};

subtest 'skips a port whose cluster neighbour is bound' => sub {
	plan tests => 3;

	# vault binds <port> for the API listener and <port>+1 for its cluster
	# listener.  It tolerates the neighbour being taken, so this is about
	# allocating non-overlapping pairs rather than about startup failure.
	my $base = free_range(4);
	my $held = occupy($base + 1);
	ok($held, sprintf("test occupied neighbour port %d", $base + 1));

	my $port = Service::Vault::Local::_find_free_port($base, $base + 3);
	isnt($port, $base,
		"_find_free_port rejects $base because $base+1 is bound (got $port)");
	cmp_ok($port, '>', $base + 1,
		"_find_free_port lands past the occupied neighbour");

	close($held);
};

subtest 'bails when the range is exhausted' => sub {
	plan tests => 1;

	my $base = free_range(2);
	my @held = grep { defined } map { occupy($base + $_) } 0..1;

	throws_ok {
		Service::Vault::Local::_find_free_port($base, $base + 1)
	} qr/no free port/i,
		'_find_free_port bails rather than returning an unusable port';

	close($_) for @held;
};

subtest 'scan order is a permutation of the range' => sub {
	plan tests => 3;

	my @order = Service::Vault::Local::_shuffled_ports(8201, 8300, 12345);
	is(scalar(@order), 100, 'order covers every port in the range');
	is_deeply([sort { $a <=> $b } @order], [8201..8300],
		'order is exactly the range, permuted -- nothing dropped or duplicated');
	isnt(join(',', @order), join(',', 8201..8300),
		'order is not simply ascending');
};

subtest 'scan order is seed-deterministic' => sub {
	plan tests => 2;

	my @a = Service::Vault::Local::_shuffled_ports(8201, 8300, 999);
	my @b = Service::Vault::Local::_shuffled_ports(8201, 8300, 999);
	is_deeply(\@a, \@b, 'same seed yields the same order');

	my @c = Service::Vault::Local::_shuffled_ports(8201, 8300, 1000);
	isnt($a[0], $c[0],
		"different seeds diverge from the first pick ($a[0] vs $c[0])");
};

subtest 'starting ports spread across the range' => sub {
	plan tests => 2;

	# The point of varying the order is that concurrent scans under different
	# uids -- which cannot see each other's startup lock -- do not converge.
	# A clustered distribution silently defeats that while every other test
	# still passes, so assert the spread directly.  Reading the LCG's low
	# bits instead of its high ones put 43 of 2000 runs on one port here.
	my ($draws, $span) = (2000, 799);
	my %bucket;
	$bucket{ (Service::Vault::Local::_shuffled_ports(8201, 8999, $_))[0] }++
		for 1..$draws;

	my ($worst) = sort { $b <=> $a } values %bucket;
	my $expected = $draws / $span;

	cmp_ok(scalar(keys %bucket), '>', $span * 0.75,
		sprintf("first picks cover most of the range (%d/%d distinct)",
			scalar(keys %bucket), $span));
	cmp_ok($worst, '<', $expected * 8,
		sprintf("no starting port is over-represented (worst %d, uniform ~%.1f)",
			$worst, $expected));
};

subtest 'ordering leaves the global PRNG untouched' => sub {
	plan tests => 2;

	# The whole point of the local PRNG: a caller that seeded rand() for its
	# own reasons must not have that silently rewritten underneath it.
	srand(42); my $baseline = int(rand(1_000_000));

	srand(42);
	Service::Vault::Local::_shuffled_ports(8201, 8300, 777);
	is(int(rand(1_000_000)), $baseline,
		'_shuffled_ports does not disturb a seeded rand() stream');

	srand(42);
	eval { Service::Vault::Local::_find_free_port(8201, 8300) };
	is(int(rand(1_000_000)), $baseline,
		'_find_free_port does not disturb a seeded rand() stream');
};

subtest 'forked children get different scan orders' => sub {
	plan tests => 2;

	# The adversarial case: the parent has already used rand(), so its PRNG
	# state is seeded and would be inherited verbatim by every child.  A
	# global-PRNG shuffle produces identical orders here; the local PRNG must
	# not, because it is keyed on the pid rather than on inherited state.
	rand() for 1..5;

	pipe(my $reader, my $writer) or BAIL_OUT("pipe failed: $!");
	my @pids;
	for my $i (1..4) {
		my $pid = fork();
		BAIL_OUT("fork failed: $!") unless defined $pid;
		if ($pid == 0) {
			close($reader);
			my @order = Service::Vault::Local::_shuffled_ports(8201, 8999);
			# Compare a prefix of the ORDER, not just the first pick.  Two
			# children agreeing on their first port is a ~1-in-799 coincidence
			# that says nothing about correlation -- asserting on it alone made
			# this test fail roughly one run in 130.  Agreeing on the first ten
			# is not a coincidence.
			print $writer join(',', @order[0..9])."\n";
			close($writer);
			POSIX::_exit(0);
		}
		push @pids, $pid;
	}
	close($writer);
	my @picks = <$reader>;
	close($reader);
	waitpid($_, 0) for @pids;
	chomp @picks;

	is(scalar(@picks), 4, 'all four children reported a scan order');
	my %seen; $seen{$_}++ for @picks;
	is(scalar(keys %seen), 4, 'each child walks a different scan order')
		or diag("orders:\n  ".join("\n  ", @picks));
};

subtest 'port accessor reports the bound port' => sub {
	plan tests => 2;

	my $vault = Service::Vault->new(
		'http://127.0.0.1:8237', 'local_vault_test_999', 0, '', 1, '/secret/'
	);
	is($vault->port, 8237, 'port() parses the port out of the vault url');

	my $default = Service::Vault->new(
		'https://vault.example.com', 'remote', 1, '', 1, '/secret/'
	);
	is($default->port, undef, 'port() is undef when the url carries no port');
};

done_testing;
