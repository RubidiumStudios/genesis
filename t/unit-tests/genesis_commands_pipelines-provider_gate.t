#!/usr/bin/env perl
use strict;
use warnings;

# Proves T170 and T171: the three behaviours of the propagate provider gate
# that only appear at a controlling terminal.  With --force the gate warns
# and asks, a yes carries the run past it, a no exits ABORTED, and -y never
# answers the question, because -y answers the publish confirmation alone.
#
# These are here rather than beside the spawned rows in
# t/integration-tests/genesis_ci_walk-provider_gate.t because nothing the
# suite spawns has a controlling terminal, so a spawned run can only ever
# meet the refusal.  The gate is called directly instead, with the terminal
# read localised, which is how the deploy's own confirmation rows prove the
# same three things in t/unit-tests/genesis_commands_env-deploy_confirm.t.

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Output;

use Genesis;
use Genesis::Exit qw/ABORTED/;

use_ok 'Genesis::Commands::Pipelines';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# The repository the gate reads.  No vault is wanted, because the gate asks
# the configuration for a provider and nothing else.
my $top = top_for(make_harness(
	envs => ['lab', 'qa'], provider => 'concourse', vault => 0
));

# refusal_from - what the gate refused with, as the refusal composed it
#
# The message is wrapped for the terminal before it is raised, so reading it
# back off the death would rest on where a line break landed.  The arguments
# are read as the refusal composed them instead, and the exit code is read
# off the options hash, which is the only place a code survives a bail that
# was raised inside an eval.
sub refusal_from {
	my ($code) = @_;

	my @raised;
	my $died;
	{
		# once as well as redefine, because the refusal is the only mention
		# of the glob in this file and Perl reads a single mention as a typo.
		no warnings qw/once redefine/;
		local *Genesis::Commands::Pipelines::bail =
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

subtest 'force at a terminal warns and asks' => sub {
	plan tests => 3;

	no warnings 'redefine';
	local *Genesis::Commands::Pipelines::in_controlling_terminal = sub {1};

	my $result;
	set_stdin("y\n");
	my ($out, $err) = output_from {
		$result = Genesis::Commands::Pipelines::assert_provider_gate(
			$top, {force => 1}
		)
	};
	reset_stdin();

	my $said = $out.$err;
	like($said, qr/Proceed anyway\?/, 'it asks');
	like($said, qr/by hand/, "it warns that this is the pipeline's work");
	ok($result, 'a yes proceeds past the gate');
};

subtest 'a no at the terminal aborts' => sub {
	plan tests => 2;

	no warnings 'redefine';
	local *Genesis::Commands::Pipelines::in_controlling_terminal = sub {1};

	set_stdin("n\n");
	my ($said, $code);
	output_from {
		($said, $code) = refusal_from(sub {
			Genesis::Commands::Pipelines::assert_provider_gate(
				$top, {force => 1}
			)
		})
	};
	reset_stdin();

	is($code, ABORTED, 'a no exits ABORTED');
	like($said, qr/Nothing was written/,
		'and it says the run wrote nothing on its way out');
};

subtest '-y never answers the gate' => sub {
	plan tests => 2;

	no warnings 'redefine';
	local *Genesis::Commands::Pipelines::in_controlling_terminal = sub {1};

	my $result;
	set_stdin("y\n");
	my ($out, $err) = output_from {
		$result = Genesis::Commands::Pipelines::assert_provider_gate(
			$top, {force => 1, yes => 1}
		)
	};
	reset_stdin();

	like($out.$err, qr/Proceed anyway\?/, '-y never answers the gate');
	ok($result, 'and the answer that was given is the one that carries it');
};

done_testing;
