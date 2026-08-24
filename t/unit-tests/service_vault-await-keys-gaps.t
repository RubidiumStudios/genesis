#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;

use_ok 'Service::Vault';
use Genesis;

sub make_vault {
	my (%args) = @_;
	return Service::Vault->new(
		$args{url}  // 'https://vault.example.com:8200',
		$args{name} // 'test-vault',
		1, '', undef, '/secret/'
	);
}

# -------------------------------------------------------------------------
# A model of the topology openbao#3877 describes: the leader is immediately
# consistent, and a standby serves reads exactly one operation behind.
#
#   - a write (set / rm) lands on the leader
#   - a read (paths / exists) is answered from the standby's view, and the
#     standby then catches up, so it is always one operation stale
#   - safe set is read-modify-write, and its read goes through the same
#     standby, so it merges into the stale view
#
# $state->{leader} is what the path actually holds afterwards.
# -------------------------------------------------------------------------
sub install_lagging_vault {
	my (%opt) = @_;
	my $state = {
		leader  => {map {($_ => 1)} @{$opt{preexisting} // []}},
		standby => {map {($_ => 1)} @{$opt{preexisting} // []}},
		calls   => [],
	};

	my $handler = sub {
		my ($self, @args) = @_;
		shift(@args) if ref($args[0]) eq 'HASH';   # query({opts}, ...) form
		my $cmd = shift(@args);
		push(@{$state->{calls}}, $cmd);

		if ($cmd eq 'set') {
			my ($path, @pairs) = @args;
			# read-modify-write, through the standby's stale view
			my %base = %{$state->{standby}};
			$base{$_} = 1 for map {(split /=/, $_, 2)[0]} @pairs;
			$state->{leader} = \%base;
			return ('', 0, '');
		}
		if ($cmd eq 'rm') {
			$state->{leader} = {};
			return ('', 0, '');
		}
		if ($cmd eq 'exists') {
			my $answer = scalar(keys %{$state->{standby}}) ? 1 : 0;
			$state->{standby} = {%{$state->{leader}}};   # catches up after answering
			return $answer;
		}
		if ($cmd eq 'paths') {
			my $path = $args[-1];
			my @answer = map {"$path:$_"} sort keys %{$state->{standby}};
			$state->{standby} = {%{$state->{leader}}};   # catches up after answering
			return (join("\n", @answer), 0, '');
		}
		return ('', 0, '');
	};

	no warnings 'redefine', 'once';
	*Service::Vault::query = $handler;
	use warnings 'redefine', 'once';

	return $state;
}

# A payload comfortably past the 900-character chunking guard.
sub chunky_data {
	my $n = shift // 45;
	return {map {("key-with-a-reasonably-long-name-$_" => "value-$_" x 4)} (1..$n)};
}

# -------------------------------------------------------------------------
# GAP 1 (structural): set_path never confirms its own final state.
#
# _await_keys is called only from inside the chunk-flush branch, so every
# write it guards is guarded by the read that FOLLOWS it.  The last write
# has no read after it, and a single-chunk payload has no read at all.
# -------------------------------------------------------------------------
subtest 'set_path confirms its result before returning' => sub {
	plan tests => 2;

	{
		my $state = install_lagging_vault();
		my $v = make_vault(name => 'tail-multi');
		$v->set_path('secret/tail/multi', chunky_data(), flatten => 1);
		is($state->{calls}[-1], 'paths',
			'multi-chunk: the last thing set_path does is confirm, not write');
	}

	{
		my $state = install_lagging_vault();
		my $v = make_vault(name => 'tail-single');
		$v->set_path('secret/tail/single', {alpha => 1, beta => 2}, flatten => 1);
		is($state->{calls}[-1], 'paths',
			'single-chunk: an unchunked write is confirmed too');
	}
};

# -------------------------------------------------------------------------
# GAP 2: clear => 1 is never confirmed, so the emptying can be raced by the
# very first write and pre-existing keys survive into the new value.
#
# _await_keys checks that the wanted keys are PRESENT.  Resurrected keys are
# extra, so every confirm passes while the result is wrong.
#
# Both real callers -- Commands/Env.pm:942 and Hook/PostDeploy.pm:61 -- write
# the director's exodus network map with exactly flatten => 1, clear => 1.
# -------------------------------------------------------------------------
subtest 'clear => 1 does not leave stale keys behind' => sub {
	plan tests => 3;

	my @stale = map {"removed-subnet-$_"} (1..3);

	{
		my $state = install_lagging_vault(preexisting => [@stale]);
		my $v = make_vault(name => 'clear-single');
		$v->set_path('secret/clear/single', {alpha => 1, beta => 2},
			flatten => 1, clear => 1);
		my @survived = grep {$state->{leader}{$_}} @stale;
		is_deeply(\@survived, [],
			'single-chunk: nothing from before the clear survives');
	}

	{
		my $state = install_lagging_vault(preexisting => [@stale]);
		my $v = make_vault(name => 'clear-multi');
		my $err = '';
		eval {
			$v->set_path('secret/clear/multi', chunky_data(),
				flatten => 1, clear => 1);
			1;
		} or $err = $@;

		my @survived = grep {$state->{leader}{$_}} @stale;
		is_deeply(\@survived, [],
			'multi-chunk: nothing from before the clear survives');
		ok($err || !@survived,
			'and if they do survive, it is reported rather than returned clean');
	}
};

# -------------------------------------------------------------------------
# CONTROL: without clear => 1, the guard does exactly what it was written to
# do.  Under the same lagging standby every chunk lands.  This is what
# separates the two gaps above from "the model breaks everything".
# -------------------------------------------------------------------------
subtest 'CONTROL: the guard protects the chunks it covers' => sub {
	plan tests => 3;

	my $state = install_lagging_vault();
	my $v = make_vault(name => 'control');
	my $data = chunky_data();
	$v->set_path('secret/control', $data, flatten => 1);

	cmp_ok(scalar(grep {$_ eq 'set'} @{$state->{calls}}), '>', 1,
		'the payload did chunk');
	cmp_ok(scalar(grep {$_ eq 'paths'} @{$state->{calls}}), '>=', 1,
		'and the chunks were confirmed');

	my @missing = grep {!$state->{leader}{$_}} keys %$data;
	is_deeply(\@missing, [], 'every key asked for is in the final value');
};

# CONTROL: the clear subtests really did reach safe rm, so the stale keys
# above came back after a genuine delete rather than never being removed.
subtest 'CONTROL: clear => 1 issues the rm' => sub {
	plan tests => 1;

	my $state = install_lagging_vault(preexisting => ['stale-key']);
	my $v = make_vault(name => 'clear-control');
	$v->set_path('secret/clear/control', {alpha => 1}, flatten => 1, clear => 1);
	ok(scalar(grep {$_ eq 'rm'} @{$state->{calls}}),
		'clear => 1 reached safe rm');
};

# -------------------------------------------------------------------------
# The original #586 symptom, injected at a chosen chunk.
#
# A 45-key payload goes out as four safe set calls.  Inject one stale base --
# the exact fault the guard exists to catch -- and vary which call gets it.
# Reads here are immediately consistent, so nothing but the injected fault is
# in play.
#
# Chunks 1..N-1 are covered by the confirm that FOLLOWS them.  The last chunk
# has no confirm after it, so the same fault is silent there, and the value
# left behind is the last chunk alone -- 'v50: 10 keys, no azs'.
# -------------------------------------------------------------------------
sub install_racing_vault {
	my (%opt) = @_;
	my $state = {store => {}, calls => [], sets => 0};

	my $handler = sub {
		my ($self, @args) = @_;
		shift(@args) if ref($args[0]) eq 'HASH';
		my $cmd = shift(@args);
		push(@{$state->{calls}}, $cmd);

		if ($cmd eq 'set') {
			my ($path, @pairs) = @args;
			$state->{sets}++;
			# this write's read-modify-write is served by a node that has
			# seen nothing, so it merges into an empty base
			$state->{store} = {} if $state->{sets} == ($opt{race_on} // 0);
			$state->{store}{$_} = 1 for map {(split /=/, $_, 2)[0]} @pairs;
			return ('', 0, '');
		}
		if ($cmd eq 'paths') {
			my $path = $args[-1];
			return (join("\n", map {"$path:$_"} sort keys %{$state->{store}}), 0, '');
		}
		return ('', 0, '');
	};

	no warnings 'redefine', 'once';
	*Service::Vault::query = $handler;
	use warnings 'redefine', 'once';

	return $state;
}

sub set_path_racing_at {
	my ($n) = @_;
	my $state = install_racing_vault(race_on => $n);
	my $v = make_vault(name => "race-$n");
	my $data = chunky_data();
	my $err = '';
	eval {$v->set_path("secret/race/$n", $data, flatten => 1); 1} or $err = $@;
	my @lost = grep {!$state->{store}{$_}} keys %$data;
	return ($err, \@lost, $state);
}

subtest 'a stale base is caught wherever it lands' => sub {
	plan tests => 4;

	# An intermediate chunk: the guard works.  This is the fix earning its keep.
	my ($err2, $lost2) = set_path_racing_at(2);
	ok($err2, 'chunk 2 racing its base is reported');
	like($err2 // '', qr/not readable/, 'and named as unreadable keys');

	# The final chunk: same fault, no confirm after it.
	my ($err4, $lost4) = set_path_racing_at(4);
	ok($err4, 'chunk 4 -- the last -- racing its base is reported too');
	ok($err4 || !@$lost4,
		'and either the value is complete or the loss is reported');
};

done_testing;
