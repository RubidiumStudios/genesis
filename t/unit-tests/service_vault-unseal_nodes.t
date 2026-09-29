#!/usr/bin/env perl
# Unsealing a Raft cluster one node at a time, and keeping the keys quiet.
#
# `safe unseal` reaches only the address it targets unless Strongbox is on,
# and a Raft node that forwards every request to the active node is no use
# on its own, since one unsealed member of a three-node cluster cannot elect a
# leader.  unseal_nodes talks to each node's own sys/unseal instead, and
# wait_for_active_node polls each node's sys/health until one is active or
# the time runs out.
#
# Seal keys go to curl over stdin, never as an argument, and never reach a
# trace, a log line, or a returned message.  The same holds for the older
# single-target unseal, which used to dump every key into the trace log when
# it failed.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;

use_ok 'Service::Vault';
use Genesis::Log;
use JSON::PP qw/encode_json decode_json/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 200;
$ENV{NOCOLOR} = 1;

my @KEYS = qw/c2VhbC1vbmU= c2VhbC10d28= c2VhbC10aHJlZQ== c2VhbC1mb3Vy c2VhbC1maXZl/;

sub vault_at {
	my ($url, %args) = @_;
	my $v = Service::Vault->new($url, 'ops', $args{verify} // 0, '', 0, '/secret/');
	$v->{unseal_keys} = [@{$args{keys} // \@KEYS}];
	return $v;
}

# A fake Raft cluster behind curl.  Each node has a threshold, a set of keys
# it has accepted this round, and a flag for whether it is active once open.
# Every curl invocation is recorded with its arguments, its stdin, and the
# run() options, so a test can check where the keys travelled.
sub fake_cluster {
	my (%nodes) = @_;
	my @calls;
	my $run = sub {
		my $opts = ref($_[0]) eq 'HASH' ? shift : {};
		my ($prog, @args) = @_;
		my $stdin = $opts->{stdin};
		push @calls, {opts => {%$opts}, args => [@args], stdin => $stdin};
		my ($url) = grep {m{^https?://}} @args;
		my ($method) = map {$args[$_+1]} grep {$args[$_] eq '-X'} 0..$#args;
		my ($resolve) = map {$args[$_+1]} grep {$args[$_] eq '--resolve'} 0..$#args;
		my ($host, $path) = $url =~ m{^https?://([^:/]+)(?::\d+)?/v1/(.*)$};
		my $ip = $resolve ? (split(/:/, $resolve))[2] : $host;
		my $node = $nodes{$ip};
		return ('', 7, '') unless $node && !$node->{down};

		if ($path eq 'sys/seal-status') {
			return (encode_json({
				sealed => $node->{sealed} ? JSON::PP::true : JSON::PP::false,
				t => $node->{threshold}, progress => scalar(@{$node->{given} //= []}),
			}), 0, '');
		}
		if ($path eq 'sys/unseal') {
			my $body = decode_json($stdin);
			if ($body->{reset}) {
				$node->{given} = [];
			} elsif (!grep {$_ eq $body->{key}} @{$node->{accepts} // \@KEYS}) {
				return (encode_json({errors => ['invalid key']}), 0, '');
			} else {
				push @{$node->{given} //= []}, $body->{key};
				$node->{sealed} = 0 if @{$node->{given}} >= $node->{threshold};
			}
			return (encode_json({
				sealed => $node->{sealed} ? JSON::PP::true : JSON::PP::false,
				progress => scalar(@{$node->{given}}),
			}), 0, '');
		}
		if ($path eq 'sys/health') {
			my $polls = ++$node->{health_polls};
			my $active = !$node->{sealed} && $node->{active_after}
				&& $polls >= $node->{active_after};
			return (encode_json({
				sealed  => $node->{sealed} ? JSON::PP::true : JSON::PP::false,
				standby => $active ? JSON::PP::false : JSON::PP::true,
			}), 0, '');
		}
		return ('', 22, '');
	};
	return ($run, \@calls);
}

# Run a block with curl faked, trace logging on, and stderr captured.
sub with_cluster {
	my ($nodes, $block) = @_;
	my ($run, $calls) = fake_cluster(%$nodes);
	my $stderr = '';
	my @result;
	{
		no warnings 'redefine';
		local *Service::Vault::run = $run;
		local *Service::Vault::_pause = sub { };
		local $ENV{GENESIS_TRACE} = 'y';
		local $Genesis::Log::Logger = undef;
		local *STDERR;
		open STDERR, '>', \$stderr or die "cannot capture stderr: $!";
		@result = $block->();
	}
	$Genesis::Log::Logger = undef;
	return (\@result, $calls, $stderr);
}

sub mentions_a_key {
	my ($text) = @_;
	return scalar grep {index($text // '', $_) >= 0} @KEYS;
}

sub sealed_node { return {sealed => 1, threshold => 3, @_} }

subtest 'every sealed node is unsealed through its own address' => sub {
	my %nodes = map {$_ => sealed_node()} qw/10.0.0.5 10.0.0.6 10.0.0.7/;
	my $vault = vault_at('https://10.0.0.5');
	my ($results, $calls, $stderr) = with_cluster(\%nodes, sub {
		$vault->unseal_nodes(qw/10.0.0.5 10.0.0.6 10.0.0.7/)
	});

	is(scalar(@$results), 3, 'one result per node');
	is_deeply([map {$_->{address}} @$results], [qw/10.0.0.5 10.0.0.6 10.0.0.7/],
		'results come back in the order the nodes were given');
	ok(!(grep {!$_->{unsealed}} @$results), 'every node reports unsealed');
	ok(!(grep {$_->{sealed}} values %nodes), 'and every node really is unsealed');

	my @unseal_calls = grep {defined $_->{stdin} && $_->{stdin} =~ /"key"/} @$calls;
	is(scalar(@unseal_calls), 9, 'three keys per node, and no more once the node opens');
	ok(!(grep {mentions_a_key(join ' ', @{$_->{args}})} @$calls),
		'no key ever appears in a curl argument');
	ok(!(grep {!$_->{opts}{redact_output}} @$calls),
		'every node call redacts its output from the trace');
	ok(!mentions_a_key($stderr), 'no key reaches the trace or stderr');
	ok(!(grep {mentions_a_key($_->{message})} @$results), 'no key in any result message');
};

subtest 'an IP target talks to each node by IP and skips TLS checks when the target does' => sub {
	my %nodes = map {$_ => sealed_node()} qw/10.0.0.5 10.0.0.6/;
	my ($results, $calls) = with_cluster(\%nodes, sub {
		vault_at('https://10.0.0.5:8200')->unseal_nodes(qw/10.0.0.5 10.0.0.6/)
	});
	my ($first_to_6) = grep {grep {m{^https://10\.0\.0\.6:8200/v1/}} @{$_->{args}}} @$calls;
	ok($first_to_6, "the second node is reached at its own address on the target's port");
	ok((grep {$_ eq '-k'} @{$first_to_6->{args}}), '-k is passed for a target that does not verify');
};

subtest 'a named target keeps its hostname and pins each node with --resolve' => sub {
	my %nodes = map {$_ => sealed_node()} qw/10.0.0.5 10.0.0.6/;
	my ($results, $calls) = with_cluster(\%nodes, sub {
		vault_at('https://vault.example.com', verify => 1)->unseal_nodes(qw/10.0.0.5 10.0.0.6/)
	});
	ok(!(grep {!$_->{unsealed}} @$results), 'both nodes unsealed');
	my @args = map {@{$_->{args}}} @$calls;
	ok((grep {$_ eq 'vault.example.com:443:10.0.0.6'} @args),
		'the hostname is resolved to each node in turn, so the certificate still matches');
	ok(!(grep {$_ eq '-k'} @args), 'and TLS verification stays on when the target verifies');
};

subtest 'nodes that are already open, unreachable, or refuse every key' => sub {
	my %nodes = (
		'10.0.0.5' => sealed_node(sealed => 0),
		'10.0.0.6' => sealed_node(down => 1),
		'10.0.0.7' => sealed_node(accepts => []),
	);
	my ($results, $calls, $stderr) = with_cluster(\%nodes, sub {
		vault_at('https://10.0.0.5')->unseal_nodes(qw/10.0.0.5 10.0.0.6 10.0.0.7/)
	});
	my %by = map {$_->{address} => $_} @$results;
	ok($by{'10.0.0.5'}{unsealed}, 'an open node counts as unsealed');
	like($by{'10.0.0.5'}{message}, qr/already unsealed/, 'and says it was already open');
	ok(!(grep {($_->{stdin}//'') =~ /"key"/ && grep {m{//10\.0\.0\.5/}} @{$_->{args}}} @$calls),
		'no key is sent to a node that is already open');
	ok(!$by{'10.0.0.6'}{unsealed}, 'an unreachable node is not unsealed');
	like($by{'10.0.0.6'}{message}, qr/unreachable/, 'and says why');
	ok(!$by{'10.0.0.7'}{unsealed}, 'a node that rejects every key stays sealed');
	like($by{'10.0.0.7'}{message}, qr/still sealed/, 'and says so');
	ok(!mentions_a_key($stderr), 'no key in the trace, even on failure');
	ok(!(grep {mentions_a_key($_->{message})} @$results), 'no key in any result message');
};

subtest 'a half-finished unseal from an earlier attempt is reset first' => sub {
	my %nodes = ('10.0.0.5' => sealed_node(given => ['stale-share']));
	my ($results, $calls) = with_cluster(\%nodes, sub {
		vault_at('https://10.0.0.5')->unseal_nodes('10.0.0.5')
	});
	ok($results->[0]{unsealed}, 'the node unseals');
	my @bodies = map {decode_json($_->{stdin})} grep {defined $_->{stdin}} @$calls;
	ok($bodies[0]{reset}, 'the first thing sent is a reset of the stale progress');
};

subtest 'without fetched keys a sealed node is reported, not attempted' => sub {
	my %nodes = ('10.0.0.5' => sealed_node());
	my ($results, $calls) = with_cluster(\%nodes, sub {
		vault_at('https://10.0.0.5', keys => [])->unseal_nodes('10.0.0.5')
	});
	ok(!$results->[0]{unsealed}, 'the node stays sealed');
	like($results->[0]{message}, qr/no unseal keys/i, 'and the message says why');
	ok(!(grep {defined $_->{stdin}} @$calls), 'nothing is posted to the node');
};

subtest 'wait_for_active_node returns the active node once one is elected' => sub {
	my %nodes = (
		'10.0.0.5' => sealed_node(sealed => 0),
		'10.0.0.6' => sealed_node(sealed => 0, active_after => 3),
		'10.0.0.7' => sealed_node(),
	);
	my ($result, $calls) = with_cluster(\%nodes, sub {
		vault_at('https://10.0.0.5')->wait_for_active_node(30, qw/10.0.0.5 10.0.0.6 10.0.0.7/)
	});
	is($result->[0], '10.0.0.6', 'the node that became active is returned');
};

subtest 'wait_for_active_node gives up at its bound' => sub {
	my %nodes = map {$_ => sealed_node(sealed => 0)} qw/10.0.0.5 10.0.0.6/;
	my $pauses = 0;
	my ($result) = with_cluster(\%nodes, sub {
		no warnings 'redefine';
		local *Service::Vault::_pause = sub { $pauses++ };
		vault_at('https://10.0.0.5')->wait_for_active_node(9, qw/10.0.0.5 10.0.0.6/)
	});
	ok(!defined($result->[0]), 'no active node means undef');
	is($pauses, 3, 'after pausing only as long as the bound allows');
};

subtest 'a failed single-target unseal keeps the keys out of the trace and the error' => sub {
	my $vault = vault_at('https://10.0.0.5');
	my @result;
	my $stderr = '';
	{
		no warnings 'redefine';
		local *Service::Vault::query = sub {
			return ("Key #1: $KEYS[0]\nunseal failed", 1, "bad key $KEYS[1]");
		};
		local *Service::Vault::_pause = sub { };
		local $ENV{GENESIS_TRACE} = 'y';
		local $Genesis::Log::Logger = undef;
		local *STDERR;
		open STDERR, '>', \$stderr or die "cannot capture stderr: $!";
		@result = $vault->unseal;
	}
	$Genesis::Log::Logger = undef;
	ok($result[1], 'the unseal still fails');
	ok(!mentions_a_key($stderr), 'no key reaches the trace or stderr');
	ok(!mentions_a_key(join("\n", grep {defined} @result)), 'no key in the returned output or error');
	like($result[2], qr/<redacted>/, 'a key that safe echoed is replaced, not dropped silently');
};

done_testing;
