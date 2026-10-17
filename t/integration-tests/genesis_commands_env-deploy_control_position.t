#!/usr/bin/env perl
# Proves T377: a deploy under a pipeline says where the local control stands
# against T, and deploys as it would in sync (D112, noted 2026-10-16).  It
# delivers from <env>/<type>, so control's position changes nothing it
# deploys, and a warning rather than a refusal is the whole of the answer.
# Under a pipeline that is off, no such warning prints.
#
# Every message is read through unfolded, because Genesis wraps what it says
# to the terminal width on its way out.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# A deploy has to reach its end for a warning to have been only a warning, so
# each row gets a director, a bosh, and a kit that writes a manifest.
sub deployable {
	my $h = seeded_harness();
	fixture_bosh($h);
	return $h;
}

subtest 'control ahead of T is named, and the deploy goes on' => sub {
	# Two rows, and the run's own restoration assertion.
	plan tests => 3;

	my $h = deployable();
	commit_on_control($h, files => {'ops/local.yml' => "---\nlocal: 1\n"},
		message => 'not pushed yet');

	my (undef, $err, $exit) = run_genesis($h, 'qa', 'deploy', '-y', 'a reason');
	is($exit, 0, 'the deploy went ahead') or diag($err);
	like(unfolded($err), qr/control has 1 commit not on origin\/control/,
		'naming the unpushed commit');
};

subtest 'control behind T is named, and the deploy goes on' => sub {
	# Two rows, and the run's own restoration assertion.
	plan tests => 3;

	my $h = deployable();
	publish_from_b($h, files => {'ops/teammate.yml' => "---\nteammate: 1\n"},
		message => "a teammate's commit");

	my (undef, $err, $exit) = run_genesis($h, 'qa', 'deploy', '-y', 'a reason');
	is($exit, 0, 'the deploy went ahead') or diag($err);
	like(unfolded($err), qr/control lacks 1 commit that origin\/control has/,
		'naming the commit it lacks');
};

subtest 'with the pipeline off, nothing is said of control' => sub {
	# One row, and the run's own restoration assertion.
	plan tests => 2;

	my $h = deployable();
	set_repo_config($h, 'pipeline.enabled', 0);
	commit_on_control($h, files => {'ops/local.yml' => "---\nlocal: 1\n"},
		message => 'not pushed yet');

	my (undef, $err) = run_genesis($h, 'qa', 'deploy', '-y', 'a reason');
	unlike(unfolded($err), qr/not on origin\/control|that origin\/control has/,
		'no word of where control stands');
};

done_testing;
