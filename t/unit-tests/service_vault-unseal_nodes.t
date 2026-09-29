#!/usr/bin/env perl
# Unsealing a Raft cluster one node at a time, and keeping the keys quiet.
#
# `safe unseal` reaches only the address it targets unless Strongbox is on,
# and a Raft node that forwards every request to the active node is no use
# on its own, since one unsealed member of a three-node cluster cannot elect a
# leader.  unseal_nodes talks to each node's own sys/unseal instead,
# wait_for_active_node polls each node's sys/health until one is active or
# the time runs out, and unseal_cluster puts the two together.
#
# Seal keys go to curl over stdin, never as an argument, and never reach a
# trace, a log line, a curl config file's trace, or a returned message.  The
# same holds for the older single-target unseal, which used to dump every key
# into the trace log when it failed.
use strict;
use warnings;
no warnings 'once';

use lib 't';
use lib 'lib';
use helper;
use Test::More;

use_ok 'Service::Vault';
use Genesis::Log;
use JSON::PP qw/encode_json decode_json/;
use File::Temp qw/tempdir/;
use IO::Socket::INET;

$ENV{GENESIS_OUTPUT_COLUMNS} = 200;
$ENV{NOCOLOR} = 1;

my @KEYS = qw/c2VhbC1vbmU= c2VhbC10d28= c2VhbC10aHJlZQ== c2VhbC1mb3Vy c2VhbC1maXZl/;

sub vault_at {
	my ($url, %args) = @_;
	my $v = Service::Vault->new($url, 'ops', $args{verify} // 0, '', $args{strongbox} // 0, '/secret/');
	$v->{unseal_keys} = [@{$args{keys} // \@KEYS}];
	return $v;
}

# A fake Raft cluster behind curl, with a fake clock.
#
# Each node behaves the way OpenBao does.  A malformed key is refused on its
# own and leaves the progress alone.  A well-formed key is counted whether or
# not it is right, and only when the threshold is reached does the node check
# the round: a good round unseals it, and a bad one is thrown away with an
# error.  A node can be down (refused at once), blackholed (it eats the whole
# -m allowance), start answering only after some number of calls, or become
# active some number of health polls after it opens.
#
# Every curl invocation is recorded with its arguments, stdin, run() options,
# and the environment it would run with.
our $CLOCK = 1000;
sub fake_cluster {
	my (%nodes) = @_;
	my @calls;
	my $run = sub {
		my $opts = ref($_[0]) eq 'HASH' ? shift : {};
		my ($prog, @args) = @_;
		my $stdin = $opts->{stdin};
		push @calls, {opts => {%$opts}, args => [@args], stdin => $stdin, env => {%{$opts->{env} // {}}}};
		my ($url) = grep {m{^https?://}} @args;
		my %flag = map {$args[$_] => $args[$_+1]} grep {$args[$_] =~ /^-/ && $args[$_] ne '-q' && $args[$_] ne '-s' && $args[$_] ne '-k'} 0..$#args-1;
		my ($path) = $url =~ m{/v1/(.*)$};
		my ($ip) = $flag{'--connect-to'} =~ /^(?:\[[^\]]+\]|[^:]+):[0-9]+:(\[[^\]]+\]|[^:]+):[0-9]+$/;
		my $node = $nodes{$ip};
		$CLOCK += $node && $node->{latency} ? $node->{latency} : 0.01;
		return ('', 7, '') unless $node && !$node->{down};
		if ($node->{blackhole}) {
			$CLOCK += $flag{'-m'};
			return ('', 28, '');
		}
		if ($node->{answers_after} && ++$node->{calls_seen} <= $node->{answers_after}) {
			return ('', 7, '');
		}

		my $body = defined($stdin) ? decode_json($stdin) : {};
		my $state = sub {
			encode_json({
				sealed   => $node->{sealed} ? JSON::PP::true : JSON::PP::false,
				t        => $node->{threshold},
				progress => scalar(@{$node->{given} //= []}),
				@_,
			});
		};
		if ($path eq 'sys/seal-status') {
			return ($state->(), 0, '');
		}
		if ($path eq 'sys/unseal') {
			if ($body->{reset}) {
				$node->{given} = [];
				$node->{resets}++;
				return ($state->(), 0, '');
			}
			return (encode_json({errors => ['invalid key']}), 0, '')
				unless $body->{key} =~ /^[A-Za-z0-9+\/]+=*$/;
			push @{$node->{given} //= []}, $body->{key};
			if (@{$node->{given}} >= $node->{threshold}) {
				my %good = map {$_ => 1} @{$node->{accepts} // \@KEYS};
				my $round_ok = !grep {!$good{$_}} @{$node->{given}};
				$node->{given} = [];
				return (encode_json({errors => ['unseal failed, invalid key']}), 0, '')
					unless $round_ok;
				$node->{sealed} = 0;
			}
			return ($state->(), 0, '');
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

# Run a block with curl and the clock faked, tracing on, and stderr captured.
sub with_cluster {
	my ($nodes, $block) = @_;
	my ($run, $calls) = fake_cluster(%$nodes);
	my $stderr = '';
	my @result;
	my $pauses = 0;
	{
		no warnings 'redefine';
		local *Service::Vault::run = $run;
		local *Service::Vault::_now = sub { $CLOCK };
		local *Service::Vault::_pause = sub { $pauses++; $CLOCK += $_[1] };
		local $ENV{GENESIS_TRACE} = 'y';
		local $Genesis::Log::Logger = undef;
		local *STDERR;
		open STDERR, '>', \$stderr or die "cannot capture stderr: $!";
		@result = $block->();
	}
	$Genesis::Log::Logger = undef;
	return (\@result, $calls, $stderr, $pauses);
}

sub mentions_a_key {
	my ($text) = @_;
	return scalar grep {index($text // '', $_) >= 0} @KEYS;
}

sub sealed_node { return {sealed => 1, threshold => 3, @_} }
sub key_calls { grep {($_->{stdin} // '') =~ /"key"/} @{$_[0]} }
sub calls_to { my ($calls, $ip) = @_; grep {grep {/:\Q$ip\E:[0-9]+$/} @{$_->{args}}} @$calls }

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
	is(scalar(key_calls($calls)), 9, "three keys per node, one threshold's worth");
	ok(!(grep {mentions_a_key(join ' ', @{$_->{args}})} @$calls),
		'no key ever appears in a curl argument');
	ok(!(grep {$_->{args}[0] ne '-q'} @$calls),
		'-q comes first on every call, so no curlrc is read');
	ok(!(grep {!exists($_->{env}{CURL_HOME}) || defined($_->{env}{CURL_HOME})} @$calls),
		'and CURL_HOME is cleared');
	ok(!(grep {!exists($_->{env}{SSLKEYLOGFILE}) || defined($_->{env}{SSLKEYLOGFILE})} @$calls),
		'as is SSLKEYLOGFILE');
	ok(!(grep {!$_->{opts}{redact_output}} @$calls),
		'every node call redacts its output from the trace');
	ok(!mentions_a_key($stderr), 'no key reaches the trace or stderr');
	ok(!(grep {mentions_a_key($_->{message})} @$results), 'no key in any result message');
};

subtest "an IP target is asked for by its own address, and each node's port is kept" => sub {
	my %nodes = map {$_ => sealed_node()} qw/10.0.0.5 10.0.0.6/;
	my ($results, $calls) = with_cluster(\%nodes, sub {
		vault_at('https://10.0.0.5')->unseal_nodes(qw/10.0.0.5:8200 10.0.0.6:8200/)
	});
	ok(!(grep {!$_->{unsealed}} @$results), 'both nodes unsealed');
	my ($to_6) = calls_to($calls, '10.0.0.6');
	ok((grep {$_ eq '10.0.0.5:443:10.0.0.6:8200'} @{$to_6->{args}}),
		"the target's address and port are sent to the node's own address and port");
	ok((grep {m{^https://10\.0\.0\.5:443/v1/}} @{$to_6->{args}}),
		'while the URL stays the one safe uses');
	ok((grep {$_ eq '-k'} @{$to_6->{args}}), '-k is passed for a target that does not verify');
};

subtest 'a named target keeps its hostname, so the certificate still matches' => sub {
	my %nodes = map {$_ => sealed_node()} qw/10.0.0.5 10.0.0.6/;
	my ($results, $calls) = with_cluster(\%nodes, sub {
		vault_at('https://vault.example.com', verify => 1)->unseal_nodes(qw/10.0.0.5 10.0.0.6/)
	});
	ok(!(grep {!$_->{unsealed}} @$results), 'both nodes unsealed');
	my @args = map {@{$_->{args}}} @$calls;
	ok((grep {$_ eq 'vault.example.com:443:10.0.0.6:443'} @args),
		'the hostname is connected to each node in turn');
	ok(!(grep {$_ eq '-k'} @args), 'and TLS verification stays on when the target verifies');
};

subtest 'IPv6 targets and nodes keep their brackets' => sub {
	my %nodes = map {$_ => sealed_node()} qw/[fd00::5] [fd00::6]/;
	my ($results, $calls) = with_cluster(\%nodes, sub {
		vault_at('https://[fd00::5]:8200')->unseal_nodes(qw/[fd00::5]:8200 [fd00::6]:8200/)
	});
	ok(!(grep {!$_->{unsealed}} @$results), 'both nodes unsealed');
	my @args = map {@{$_->{args}}} @$calls;
	ok((grep {$_ eq '[fd00::5]:8200:[fd00::6]:8200'} @args), 'the IPv6 node is reached on its own port');
	ok((grep {m{^https://\[fd00::5\]:8200/v1/}} @args), 'and the URL keeps the bracketed target');
};

subtest 'a stale key cannot wedge a node' => sub {
	# A well-formed key from before a rekey is counted like any other, and the
	# node only throws the round away when the threshold is reached.
	my $stale = 'c3RhbGUta2V5';
	my %nodes = ('10.0.0.5' => sealed_node(accepts => [@KEYS[1..4]]));
	my ($results, $calls) = with_cluster(\%nodes, sub {
		vault_at('https://10.0.0.5', keys => [$stale, @KEYS[1..4]])->unseal_nodes('10.0.0.5')
	});
	ok($results->[0]{unsealed}, 'the node unseals with the four good keys');
	ok($nodes{'10.0.0.5'}{resets} >= 2, 'after a fresh round replaced the one the stale key spoiled');

	%nodes = ('10.0.0.5' => sealed_node());
	($results) = with_cluster(\%nodes, sub {
		vault_at('https://10.0.0.5', keys => ['not a key!', @KEYS[0..2]])->unseal_nodes('10.0.0.5')
	});
	ok($results->[0]{unsealed}, 'a malformed key is passed over as well');

	%nodes = ('10.0.0.5' => sealed_node(accepts => []));
	($results) = with_cluster(\%nodes, sub {
		vault_at('https://10.0.0.5')->unseal_nodes('10.0.0.5')
	});
	ok(!$results->[0]{unsealed}, 'with no good combination the node stays sealed');
	like($results->[0]{message}, qr/every combination/, 'and says every combination was tried');
};

subtest 'a half-finished unseal from an earlier attempt is reset first' => sub {
	my %nodes = ('10.0.0.5' => sealed_node(given => ['c3RhbGUtc2hhcmU=']));
	my ($results, $calls) = with_cluster(\%nodes, sub {
		vault_at('https://10.0.0.5')->unseal_nodes('10.0.0.5')
	});
	ok($results->[0]{unsealed}, 'the node unseals');
	my @bodies = map {decode_json($_->{stdin})} grep {defined $_->{stdin}} @$calls;
	ok($bodies[0]{reset}, 'the first thing sent is a reset of the stale progress');
};

subtest 'nodes that are already open, unreachable, or short of keys' => sub {
	my %nodes = (
		'10.0.0.5' => sealed_node(sealed => 0),
		'10.0.0.6' => sealed_node(down => 1),
		'10.0.0.7' => sealed_node(threshold => 4),
	);
	my ($results, $calls, $stderr) = with_cluster(\%nodes, sub {
		vault_at('https://10.0.0.5', keys => [@KEYS[0..2]])->unseal_nodes(qw/10.0.0.5 10.0.0.6 10.0.0.7/)
	});
	my %by = map {$_->{address} => $_} @$results;
	ok($by{'10.0.0.5'}{unsealed}, 'an open node counts as unsealed');
	like($by{'10.0.0.5'}{message}, qr/already unsealed/, 'and says it was already open');
	ok(!(grep {($_->{stdin}//'') =~ /"key"/} calls_to($calls, '10.0.0.5')),
		'no key is sent to a node that is already open');
	ok(!$by{'10.0.0.6'}{unsealed}, 'an unreachable node is not unsealed');
	like($by{'10.0.0.6'}{message}, qr/unreachable/, 'and says why');
	ok(!$by{'10.0.0.7'}{unsealed}, 'a node whose threshold exceeds the keys stays sealed');
	like($by{'10.0.0.7'}{message}, qr/needs 4 unseal keys where only 3/, 'and says so');
	ok(!(grep {defined $_->{stdin}} calls_to($calls, '10.0.0.7')), 'without being sent anything');
	ok(!mentions_a_key($stderr), 'no key in the trace, even on failure');
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
	my ($result) = with_cluster(\%nodes, sub {
		vault_at('https://10.0.0.5')->wait_for_active_node(30, qw/10.0.0.5 10.0.0.6 10.0.0.7/)
	});
	is($result->[0], '10.0.0.6', 'the node that became active is returned');
};

subtest 'wait_for_active_node stops at its bound in wall-clock time' => sub {
	# One node drops every packet, so each request to it lasts as long as curl
	# allows.  Counting only the pauses let the default 90 seconds run for
	# minutes; the bound is now elapsed time.
	my %nodes = (
		'10.0.0.5' => sealed_node(sealed => 0),
		'10.0.0.6' => sealed_node(sealed => 0),
		'10.0.0.7' => sealed_node(blackhole => 1),
	);
	my $start = $CLOCK;
	my ($result, $calls) = with_cluster(\%nodes, sub {
		vault_at('https://10.0.0.5')->wait_for_active_node(30, qw/10.0.0.5 10.0.0.6 10.0.0.7/)
	});
	ok(!defined($result->[0]), 'no active node means undef');
	cmp_ok($CLOCK - $start, '<=', 31, 'and the wait ended within its 30-second bound');
	my ($m_first) = map {my @a = @{$_->{args}}; map {$a[$_+1]} grep {$a[$_] eq '-m'} 0..$#a} $calls->[0];
	my ($m_last) = map {my @a = @{$_->{args}}; map {$a[$_+1]} grep {$a[$_] eq '-m'} 0..$#a} $calls->[-1];
	cmp_ok($m_last, '<', $m_first, 'because each request is capped at the time that remains');
};

subtest 'unseal_cluster retries late nodes, waits for a leader, and finishes the rest' => sub {
	my %nodes = (
		'10.0.0.5' => sealed_node(active_after => 1),
		'10.0.0.6' => sealed_node(answers_after => 4),
		'10.0.0.7' => sealed_node(answers_after => 40),
	);
	my ($result) = with_cluster(\%nodes, sub {
		vault_at('https://10.0.0.5')->unseal_cluster(90, qw/10.0.0.5 10.0.0.6 10.0.0.7/)
	});
	my $out = $result->[0];
	is($out->{quorum}, 2, 'a three-node cluster needs two');
	is($out->{active}, '10.0.0.5', 'a leader is found once a quorum is open');
	ok($out->{nodes}[1]{unsealed}, 'the node that answered late was retried and unsealed');
	ok(!$out->{nodes}[2]{unsealed}, 'a node still not answering at the end is reported');
	is($out->{open}, 2, 'and the open count says two of three');
};

subtest 'unseal_cluster does not wait for a leader without a quorum' => sub {
	my %nodes = (
		'10.0.0.5' => sealed_node(),
		'10.0.0.6' => sealed_node(down => 1),
		'10.0.0.7' => sealed_node(down => 1),
	);
	my $waited = 0;
	my $start = $CLOCK;
	my ($result) = with_cluster(\%nodes, sub {
		no warnings 'redefine';
		local *Service::Vault::wait_for_active_node = sub { $waited++; undef };
		vault_at('https://10.0.0.5')->unseal_cluster(20, qw/10.0.0.5 10.0.0.6 10.0.0.7/)
	});
	is($result->[0]{open}, 1, 'one of three open');
	is($waited, 0, 'no leader wait');
	cmp_ok($CLOCK - $start, '<=', 21, 'and the retries for the missing nodes stop at the bound');
};

subtest 'fetch_unseal_keys orders the keys the same way every time' => sub {
	my $vault = vault_at('https://10.0.0.5', keys => []);
	my $env = bless {}, 'Test::KeysEnv';
	{ package Test::KeysEnv; sub secrets_mount { '/secret/' } }
	no warnings 'redefine';
	local *Service::Vault::get = sub {
		return {map {("key$_" => "v$_")} 1..11};
	};
	my ($ok) = $vault->fetch_unseal_keys($env);
	ok($ok, 'keys fetched');
	is_deeply($vault->{unseal_keys}, [map {"v$_"} 1..11], 'key1 to key11 in numeric order');
};

subtest "a failed single-target unseal keeps safe's words about keys out of the trace" => sub {
	# A stand-in safe that echoes the first key it reads on both stdout and
	# stderr, and fails.  It runs through the real query and run, so this
	# covers what run() writes to the trace, not just what unseal returns.
	my $dir = tempdir(CLEANUP => 1);
	open my $fh, '>', "$dir/safe" or die $!;
	print $fh "#!/bin/sh\nread k\necho \"Key #1: \$k\"\necho \"unseal failed for key \$k\" >&2\nexit 1\n";
	close $fh;
	chmod 0755, "$dir/safe";

	my $vault = vault_at('https://10.0.0.5');
	my @result;
	my $stderr = '';
	{
		no warnings 'redefine';
		local $ENV{PATH} = "$dir:$ENV{PATH}";
		local *Service::Vault::_pause = sub { };
		local *Service::Vault::_strongbox_unseal_caveat = sub { () };
		local $ENV{GENESIS_TRACE} = 'y';
		local $Genesis::Log::Logger = undef;
		local *STDERR;
		open STDERR, '>', \$stderr or die "cannot capture stderr: $!";
		@result = $vault->unseal;
	}
	$Genesis::Log::Logger = undef;
	ok($result[1], 'the unseal still fails');
	like($stderr, qr/redacted stderr omitted/, 'the trace notes the stderr it withheld');
	ok(!mentions_a_key($stderr), 'no key reaches the trace or stderr');
	ok(!mentions_a_key(join("\n", grep {defined} @result)), 'no key in the returned output or error');
	like($result[2], qr/unseal failed for key <redacted>/, 'a key that safe echoed is replaced, not dropped');
};

subtest 'a curlrc cannot make curl write the keys to disk' => sub {
	# A real curl against a local stand-in node.  The curlrc asks curl to
	# write a full trace of every request, which would include the key in
	# the body.  The control run shows the curlrc is live; the unseal run
	# shows curl never read it.
	my $home = tempdir(CLEANUP => 1);
	my $trace = "$home/curl-trace.txt";
	open my $rc, '>', "$home/.curlrc" or die $!;
	print $rc "trace-ascii = \"$trace\"\n";
	close $rc;

	my $server = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
		or plan skip_all => "cannot listen on 127.0.0.1: $!";
	my $port = $server->sockport;
	my $pid = fork();
	if (!$pid) {
		my $sealed = 1;
		while (my $client = $server->accept) {
			local $/ = "\r\n";
			my $request = <$client> // '';
			my $length = 0;
			while (my $line = <$client>) {
				last if $line eq "\r\n";
				$length = $1 if $line =~ /^Content-Length:\s*([0-9]+)/i;
			}
			my $body = '';
			read($client, $body, $length) if $length;
			$sealed = 0 if $body =~ /"key"/;
			my $reply = encode_json({sealed => $sealed ? JSON::PP::true : JSON::PP::false, t => 1, progress => 0});
			print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ".length($reply)."\r\nConnection: close\r\n\r\n$reply";
			close $client;
		}
		exit 0;
	}
	close $server;

	local $ENV{HOME} = $home;
	local $ENV{CURL_HOME} = $home;
	local $ENV{XDG_CONFIG_HOME} = $home;
	system('curl', '-s', '-o', '/dev/null', "http://127.0.0.1:$port/v1/sys/seal-status");
	ok(-s $trace, 'control: a plain curl call obeys the curlrc and writes a trace');
	unlink $trace;

	my $vault = vault_at("http://127.0.0.1:$port", keys => [$KEYS[0]]);
	my @results = $vault->unseal_nodes("127.0.0.1:$port");
	kill 'TERM', $pid;
	waitpid($pid, 0);

	ok($results[0]{unsealed}, 'the stand-in node was unsealed over real curl');
	ok(!-e $trace, 'and curl wrote no trace, so the key never reached the disk');
};

done_testing;
