#!/usr/bin/env perl
# What the propagate child's /dev/null redirect actually buys, proved by
# driving the confirmation directly.  The suite spawns its commands and a
# spawned command has no controlling terminal to be asked at, which is why
# the terminal half of T251 and T331 cannot be shown through a whole run.
# The same split is the one t/unit-tests/genesis_ci_publish-confirm.t makes
# for the propagate run's own confirmation.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Output;

use Genesis;
use Genesis::CI::Publish;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['prod'], mode => 'direct', vault => 0);
init_branch($h, 'prod');
local_only_commit($h, $h->slug('prod'),
	files   => {'ops/shared.yml' => "---\nops: twelve\n"},
	message => 'carry an op to prod',
);

my $git   = $h->git('a');
my @specs = ({branch => $h->slug('prod'), kind => 'deployment', env => 'prod'});

subtest 'the redirect is what keeps the publish from asking' => sub {
	plan tests => 6;

	# Standard input on /dev/null, which is the state _spawn_propagate_child
	# puts the child in.  The redirect is made here with a localised glob
	# rather than the spawn's save and restore, because this row calls the
	# confirmation in process and in_controlling_terminal reads the Perl
	# handle, where a child inherits the descriptor instead.
	#
	# The first row is the one that carries the discrimination, because
	# in_controlling_terminal asks about standard output as well and
	# output_from has made that a capture, so the three rows under it stay
	# green whatever standard input is doing.
	my ($go, $said);
	{
		local *STDIN;
		open(STDIN, '<', '/dev/null') or die "cannot open /dev/null: $!\n";
		ok(!Genesis::Term::in_controlling_terminal(),
			'with stdin on /dev/null there is no controlling terminal');
		my ($out, $err) = output_from {
			$go = Genesis::CI::Publish::confirm_publish($git, 'origin', \@specs)
		};
		$said = unfolded($out, $err);
	}

	is($go, 1, 'the publish goes ahead without being asked');
	like($said, qr{@{[$h->slug('prod')]}: 1 commit},
		'and the delta the operator would have been shown went to the log');
	unlike($said, qr{Publish these branches\?},
		'the confirmation step was never put');

	# The other arm, so the row above discriminates.  With a terminal the
	# same call does ask, which is what the redirect is there to prevent.
	no warnings 'redefine';
	local *Genesis::CI::Publish::in_controlling_terminal = sub {1};
	my ($answered, $asked);
	set_stdin("y\n");
	my ($out2, $err2) = output_from {
		$answered = Genesis::CI::Publish::confirm_publish($git, 'origin', \@specs)
	};
	reset_stdin;
	$asked = unfolded($out2, $err2);

	like($asked, qr{Publish these branches\?},
		'at a terminal the same call asks');
	is($answered, 1, 'and the answer that was typed is the one that carries it');
};

done_testing;
