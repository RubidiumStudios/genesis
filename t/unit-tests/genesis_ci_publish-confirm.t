#!/usr/bin/env perl
# Proves T185's three terminal behaviours, which are that a terminal is shown
# every environment's verified delta and then asked, that -y is shown the same
# delta and never asked, and that a run with no controlling terminal writes the
# delta to the log and goes on without asking.
#
# The sub is called directly rather than through a spawned run, because the
# suite spawns its commands and a spawned command has no controlling terminal
# to be asked at.  That is the same reason the deploy path's own confirmation
# is proved this way, and the showing that does not depend on a terminal is
# proved through a whole run in t/integration-tests/genesis_ci_publish-confirm.t.
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

# One repository for all three subtests, because none of them writes to it.
# The lab branch carries a commit the remote has never seen and the qa branch
# carries none, so every showing below has both a delta with something in it
# and a delta with nothing to compare against.
my $h = make_harness(envs => ['lab', 'qa'], mode => 'direct', vault => 0);
init_branch($h, 'lab');
init_branch($h, 'qa');
local_only_commit($h, 'lab/bosh',
	files   => {'ops/shared.yml' => "---\nops: twelve\n"},
	message => 'share an op with lab',
);

my $git   = $h->git('a');
my @specs = (
	{branch => 'lab/bosh', kind => 'deployment', env => 'lab'},
	{branch => 'qa/bosh',  kind => 'deployment', env => 'qa'},
);

subtest 'at a terminal, the delta is shown and then the ask comes' => sub {
	plan tests => 6;
	no warnings 'redefine';
	local *Genesis::CI::Publish::in_controlling_terminal = sub {1};

	my $go;
	set_stdin("y\n");
	my ($out, $err) = output_from {
		$go = Genesis::CI::Publish::confirm_publish($git, 'origin', \@specs)
	};
	reset_stdin;
	my $said = unfolded($out, $err);

	is($go, 1, 'a yes at the terminal publishes');
	like($said, qr{lab/bosh: 1 commit, 1 file changed, 0 removed},
		"lab's verified delta was shown");
	like($said, qr{share an op with lab},
		'down to the commit the push would carry');
	like($said, qr{qa/bosh: 0 commits, 0 files changed, 0 removed},
		"qa's empty delta was shown beside it");
	like($said, qr{Publish these branches\?}, 'and the operator was asked');

	set_stdin("n\n");
	output_from {
		$go = Genesis::CI::Publish::confirm_publish($git, 'origin', \@specs)
	};
	reset_stdin;
	is($go, 0, 'a no at the terminal publishes nothing');
};

subtest '-y suppresses the ask and never the showing' => sub {
	plan tests => 4;
	no warnings 'redefine';
	# The terminal is never consulted under -y, because the ask is the only
	# thing the flag answers and a flag that also decided the showing would
	# make the delta conditional on how the run was started.
	local *Genesis::CI::Publish::in_controlling_terminal =
		sub {die "must not be consulted\n"};

	my $go;
	my ($out, $err) = output_from {
		$go = Genesis::CI::Publish::confirm_publish($git, 'origin', \@specs,
			yes => 1)
	};
	my $said = unfolded($out, $err);

	is($go, 1, 'the publish goes ahead without being asked');
	like($said, qr{lab/bosh: 1 commit, 1 file changed, 0 removed},
		'the delta was still shown');
	like($said, qr{qa/bosh: 0 commits}, 'for every environment');
	unlike($said, qr{Publish these branches\?}, 'and nothing was asked');
};

subtest 'with no terminal the delta goes to the log and the run proceeds' => sub {
	plan tests => 4;
	no warnings 'redefine';
	local *Genesis::CI::Publish::in_controlling_terminal = sub {0};

	my $go;
	# An answer nobody asked for is left in standard input, so a prompt
	# written into a pipe would be caught here rather than read.
	set_stdin("n\n");
	my ($out, $err) = output_from {
		$go = Genesis::CI::Publish::confirm_publish($git, 'origin', \@specs)
	};
	my $unread = <STDIN>;
	reset_stdin;
	my $said = unfolded($out, $err);

	is($go, 1, 'the publish goes ahead');
	like($said, qr{lab/bosh: 1 commit, 1 file changed, 0 removed},
		'the delta reached the log');
	unlike($said, qr{Publish these branches\?}, 'and nothing was asked');
	is($unread, "n\n", 'and nothing was read from standard input');
};

done_testing;
