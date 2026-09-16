#!/usr/bin/env perl
# Proves T147: the withdrawn flags are refused at exit 2, and --dry-run
# names, per environment and per control commit, the files that would land
# and whether each commit would be delivered or held and why.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# The files one report names beneath one control commit, which is every
# written or removed path between that commit's own line and whatever line
# ends its block.  It reads the output and builds nothing, so it stays beside
# the rows that use it.
sub files_under {
	my ($report, $sha) = @_;
	my $short = substr($sha, 0, 7);

	my ($in, @files) = (0);
	for my $line (split /\n/, ($report // '')) {
		if ($line =~ /^\s+control\@([0-9a-f]{7})\b/) {
			$in = ($1 eq $short) ? 1 : 0;
			next;
		}
		# An environment's own line ends whatever block stood above it.
		$in = 0 if $line =~ /^\s{0,3}\S+:\s/;
		push @files, $2 if $in && $line =~ /^\s+([MD])\s+(\S+)$/;
	}
	return [sort @files];
}

# Every path one report says a delivery would take off the branch, read
# whole, so a line carrying something that is not a path at all is caught
# rather than passed over by a pattern that only matches one.
sub removed_in {
	my ($report) = @_;
	my @gone = ($report // '') =~ /^\s+D (.+?)\s*$/mg;
	return [sort @gone];
}

subtest 'the withdrawn flags are usage errors' => sub {
	# Two rows, and one more for each run's own restoration assertion.
	plan tests => 4;

	my $h = make_harness(envs => ['qa']);
	fixture_applied($h, control => $h->git('a')->sha($h->control));

	my (undef, undef, $push_exit) = run_genesis($h, 'propagate', '--no-push');
	is($push_exit, 2, '--no-push is refused');

	my (undef, undef, $commit_exit) =
		run_genesis($h, 'propagate', '--commit', 'deadbeef');
	is($commit_exit, 2, '--commit is refused');
};

subtest 'the preview names each commit, its files, and its verdict' => sub {
	# Eleven rows, and one more for the run's own restoration assertion.
	plan tests => 12;

	my $h = ready_harness(envs => ['lab', 'qa'], kit => 'omega-v2.7.0',
		chained => 1, tracked => ['ops/shared.yml']);

	# The environment file as the harness laid it down, with one key added,
	# so the commit below changes a file qa's set holds and this file keeps
	# no second copy of the harness's own body.
	my $qa_yml = blob_at($h->a, $h->control, 'qa.yml');

	my $first = commit_on_control($h,
		files   => {'qa.yml' => $qa_yml . "leaf: 1\n"},
		message => 'Tune qa', push => 1);
	certify($h, 'lab', control_commit => $first);
	my $second = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nshared: 3\n"},
		message => 'Bump shared ops', push => 1);

	my $tip_before = harness_marker($h, $h->slug('qa'));
	my $w = snapshot_w($h);

	# Both streams are read from the second value, because the run speaks
	# through info and everything Genesis says about itself goes to standard
	# error.
	my (undef, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');

	is($exit, 0, 'the preview succeeded');
	like($err,
		qr/This is a preview\.\s+Nothing will be written\.[\s\S]*?^\s*lab: /m,
		'it says it is a preview above the first line of the report');
	like($err, qr/^\s*qa\b/m, 'it names the environment');
	like($err, qr/^\s*qa:\s*would propagate/m,
		'an environment with commits due reads would propagate');
	like($err, qr/\Q@{[substr($first, 0, 7)]}\E.*would deliver/,
		'the first commit reads would deliver');
	like($err, qr/\Q@{[substr($first, 0, 7)]}\E[\s\S]*?\Qqa.yml\E/,
		'the files that would land are named');
	unlike($err, qr{^\s+M dev/kit\.yml$}m,
		'and not a file the fast-forward this preview assumes would bring');
	unlike($err, qr{^\s+D init$}m,
		'nor one that fast-forward would take off');
	like($err,
		qr/\Q@{[substr($second, 0, 7)]}\E[^\n]*held\n\s+H held by lab\b/,
		'the second reads held with its reason beneath it');
	is(harness_marker($h, $h->slug('qa')), $tip_before,
		'the preview wrote nothing');
	assert_w_restored($w, 'propagate --dry-run');
};

subtest 'two commits due are two file lists, not one union' => sub {
	# Three rows, and one more for each of the two runs.
	plan tests => 5;

	my $h = ready_harness(envs => ['qa'], kit => 'omega-v2.7.0',
		tracked => ['ops/shared.yml']);

	my $qa_yml = blob_at($h->a, $h->control, 'qa.yml');
	my $one = commit_on_control($h,
		files   => {'qa.yml' => $qa_yml . "leaf: 2\n"},
		message => 'Tune qa', push => 1);
	my $two = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nshared: 5\n"},
		message => 'Bump shared ops', push => 1);

	my (undef, $preview) = run_genesis($h, 'propagate', '--dry-run');
	my (undef, $real) = run_genesis($h, {answers => ['y']}, 'propagate');

	is_deeply(files_under($preview, $one), ['qa.yml'],
		'the first commit names the file it changed and nothing else');
	is_deeply(files_under($preview, $two), ['ops/shared.yml'],
		'and the second names its own rather than both');
	is_deeply([files_under($preview, $one), files_under($preview, $two)],
		[files_under($real, $one), files_under($real, $two)],
		'which is what the run then delivers, commit for commit');
};

subtest 'the preview reads the branch it is previewing against' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h = ready_harness(envs => ['qa'], kit => 'omega-v2.7.0',
		tracked => ['ops/shared.yml', 'ops/extra.yml']);

	# A hand edit the branch is carrying, on a path the commit below does
	# not itself change, which is what makes the mirror's overwrite of it an
	# overwrite rather than a delivery.
	hand_commit($h, $h->slug('qa'),
		files   => {'dev/kit.yml' => "---\nname: edited by hand\n"},
		message => 'Patch the kit in place');

	# The set narrows, so one path the branch holds falls out of it and the
	# delivery has a real removal to report.
	my $file = write_env_file($h, 'qa', commit => 0,
		genesis => {pipeline => {track_additional_files => ['ops/shared.yml']}});
	my $due = commit_on_control($h,
		files   => {'qa.yml' => slurp($h->a . '/' . $file)},
		message => 'Stop tracking the extra ops file', push => 1);

	my (undef, $preview) = run_genesis($h, 'propagate', '--dry-run');

	like($preview, qr{^\s+D ops/extra\.yml$}m,
		'the preview names the path that would leave the branch');
	ok(scalar(grep {$_ eq 'ops/extra.yml'} @{files_under($preview, $due)}),
		'beneath the commit that narrowed the set rather than loose in the '.
		'report');
	like($preview, qr{^\s+overwrote-hand-edit dev/kit\.yml$}m,
		'and the hand edit the mirror would take back off it');
	is_deeply(removed_in($preview), ['ops/extra.yml'],
		'and names nothing that is not a path on the branch');
};

done_testing;
