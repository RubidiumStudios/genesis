#!/usr/bin/env perl
# Proves T223 and the rest of T239: the acknowledgement --yes cannot suppress,
# what it says, and the ABORTED decline.  These are here rather than beside
# the spawned rows in
# t/integration-tests/genesis_commands_env-deploy_provider_gate.t because
# helper::set_stdin gives a spawned command a pipe, so no spawned run ever
# sees a controlling terminal.  The gate is called directly instead, with the
# terminal read localised, which is how
# t/unit-tests/genesis_commands_pipelines-provider_gate.t proves the same
# three things for the propagate run.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Output;

use Genesis;
use Genesis::Exit qw/ABORTED NOPERM/;

use_ok 'Genesis::CI::Preflight';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# The repository the gate reads.  No vault is wanted, because the gate asks
# the configuration for a provider and nothing else.
my $top = top_for(make_harness(
	envs => ['qa'], provider => 'concourse', vault => 0
));

# The deploy's own words for the gate, as _deploy_preflight passes them.
my %how = (
	owns        => 'deploys of this environment',
	outcome     => 'Nothing was deployed.',
	acknowledge => 'I accept the risk',
);

# refusal_from - what the gate refused with, as the refusal composed it
#
# The message is wrapped for the terminal before it is raised, so reading it
# back off the death would rest on where a line break landed.  The arguments
# are read as the refusal composed them instead, and the exit code is read off
# the options hash, which is the only place a code survives a bail that was
# raised inside an eval.
sub refusal_from {
	my ($code) = @_;

	my @raised;
	my $died;
	{
		# once as well as redefine, because the refusal is the only mention
		# of the glob in this file and Perl reads a single mention as a typo.
		no warnings qw/once redefine/;
		local *Genesis::CI::Preflight::bail =
			sub {push @raised, [@_]; die "refused\n"};
		eval {$code->(); 1} or $died = $@;
	}
	unless (@raised) {
		diag("nothing was refused, and the code died with: $died")
			if defined $died;
		return ('', undef);
	}

	my @args = @{$raised[0]};
	my $opts = ref($args[0]) eq 'HASH' ? shift(@args) : {};
	my ($format, @rest) = @args;

	return (sprintf($format, @rest), $opts->{exitcode});
}

subtest 'the acknowledgement names what to pause and what is not written' => sub {
	plan tests => 4;

	no warnings 'redefine';
	local *Genesis::CI::Preflight::in_controlling_terminal = sub {1};

	my $result;
	set_stdin("I accept the risk\n");
	my ($out, $err) = output_from {
		$result = Genesis::CI::Preflight::assert_provider_gate(
			$top, {force => 1}, %how
		)
	};
	reset_stdin();

	my $said = $out.$err;
	like($said, qr/paus\w+ the pipeline/i, 'it recommends pausing the pipeline');
	like($said, qr/quiescen\w+/i, 'and waiting for quiescence');
	like($said, qr/no shuttle event is written/,
		'and says no shuttle event is written');
	ok($result, 'the typed acknowledgement carries the deploy past the gate');
};

subtest 'anything but the acknowledgement aborts' => sub {
	plan tests => 2;

	no warnings 'redefine';
	local *Genesis::CI::Preflight::in_controlling_terminal = sub {1};

	set_stdin("no\n");
	my ($said, $code);
	output_from {
		($said, $code) = refusal_from(sub {
			Genesis::CI::Preflight::assert_provider_gate(
				$top, {force => 1}, %how
			)
		})
	};
	reset_stdin();

	is($code, ABORTED, 'declining exits ABORTED');
	like($said, qr/Nothing was deployed\./, "in the caller's own closing words");
};

subtest '--yes never answers the acknowledgement' => sub {
	plan tests => 2;

	no warnings 'redefine';
	local *Genesis::CI::Preflight::in_controlling_terminal = sub {1};

	my $result;
	set_stdin("I accept the risk\n");
	my ($out, $err) = output_from {
		$result = Genesis::CI::Preflight::assert_provider_gate(
			$top, {force => 1, yes => 1}, %how
		)
	};
	reset_stdin();

	like($out.$err, qr/I accept the risk/, '-y never answers the gate');
	ok($result, 'and the answer that was typed is the one that carries it');
};

subtest 'outside a terminal the refusal stands even with --force' => sub {
	plan tests => 2;

	no warnings 'redefine';
	local *Genesis::CI::Preflight::in_controlling_terminal = sub {0};

	my ($said, $code) = refusal_from(sub {
		Genesis::CI::Preflight::assert_provider_gate($top, {force => 1}, %how)
	});

	is($code, NOPERM, 'it still exits NOPERM');
	like($said, qr/needs a terminal/, 'saying the acknowledgement needs one');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
