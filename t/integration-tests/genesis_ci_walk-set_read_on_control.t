#!/usr/bin/env perl
# Proves T453: a writing propagate never reads a set while a deployment
# branch is checked out.  The delivery used to read its set again after the
# switch, so the kit's blueprint ran with the working tree on the branch,
# and on a branch carrying only its init commit a hook calling back into the
# repository's embedded Genesis found none (the lmelt PoC's lab, 2026-10-30).
#
# The hook records the branch the clone stands on each time it runs, so the
# rows ask the one thing directly, rather than through whatever a missing
# callback happens to break.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use File::Temp ();

use Genesis qw/run/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $BLUEPRINT =
	qq{git -C "\$HARNESS_CLONE" rev-parse --abbrev-ref HEAD >> "\$HARNESS_BRANCH_LOG"\n}.
	qq{cat > manifest.yml <<'MANIFEST'\n---\nname: qa-bosh\nMANIFEST\n}.
	qq{echo manifest.yml\n};

subtest 'a first delivery reads its set on control' => sub {
	my $h = make_harness(envs => ['qa'], type => 'bosh');
	fixture_kit($h, hooks => {blueprint => $BLUEPRINT}, commit => 1);
	fixture_vault($h);
	fixture_applied($h, control => $h->git('a')->sha($h->control));
	fixture_pipeline_record($h, 'qa');
	init_branch($h, 'qa');
	commit_on_control($h, files => {'qa.yml' => <<'YAML'}, message => 'qa', push => 1);
---
kit:
  name:     dev
  version:  latest
  features: []
genesis:
  env:      qa
YAML
	refresh($h, 'a');
	stand_on($h, $h->control);

	my $tmp = File::Temp->newdir();
	local $ENV{HARNESS_CLONE}      = $h->a;
	local $ENV{HARNESS_BRANCH_LOG} = "$tmp/branches";
	helper::put_file("$tmp/branches", '');

	my ($out, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($out, $err);
	is($exit, 0, 'the run delivers') or diag($said);

	my @branches = grep {/\S/} split /\n/, helper::get_file("$tmp/branches");
	ok(scalar(@branches), 'the blueprint was read') or diag($said);
	is_deeply([grep {$_ ne $h->control} @branches], [],
		'and never with a deployment branch checked out') or diag(join("\n", @branches));

	my ($log) = run({dir => $h->a}, 'git', 'log', '-1', '--format=%s', 'refs/remotes/origin/'.$h->slug('qa'));
	like($log // '', qr/^\[pipeline\] control\@/, 'and the branch holds the delivery');
};

done_testing;
