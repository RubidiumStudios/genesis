#!perl
# Proves T371: the previews, pipeline-describe, pipeline-graph and
# pipeline-apply --dry-run, read their deployment root's working tree and name
# every gap between it and control on T, in D44's "This preview assumes"
# shape (D112, noted 2026-10-16).  The harness's root is bosh/, and a second
# directory, vault/, stands beside it so a change there can be shown not to
# reach the banner.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
provide_rc();

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# The manual provider keeps fly out of the apply's dry run.  Copy B is brought
# up to the second root's commit, so a teammate's later publish fast-forwards.
sub harness {
	my $h = make_harness(envs => ['lab', 'qa', 'prod'], fanned => 'lab',
		provider => 'manual', root => 'bosh');
	commit_on_control($h, files => {'vault/notes.yml' => "--- {}\n"},
		message => 'a second root beside bosh', push => 1);
	run({dir => $h->b}, 'git', 'pull', '-q', '--ff-only');
	return $h;
}

# Every preview prints what it shows (T375), so the run's own restoration
# assertion is the proof it wrote nothing in the tree.
sub preview {
	my ($h, @argv) = @_;
	my ($out, $err, $exit) = run_genesis($h, {dir => 'bosh'}, @argv);
	return ($out, unfolded($err), $exit);
}

my @PREVIEWS = (
	['pipeline-describe'],
	['pipeline-graph'],
	['pipeline-apply', '--dry-run'],
);

subtest '(a) in sync, no preview prints a banner' => sub {
	# Two rows per preview, and one restoration assertion for each run.
	plan tests => 9;

	my $h = harness();
	for my $argv (@PREVIEWS) {
		my (undef, $err, $exit) = preview($h, @$argv);
		is($exit, 0, "`genesis @$argv` succeeds in sync") or diag($err);
		unlike($err, qr/This preview/, 'and prints no banner');
	}
};

subtest '(b) an uncommitted change in the root is previewed and named' => sub {
	# Four rows per preview, one shape row for each of the two that draw it,
	# and one restoration assertion for each run.
	plan tests => 17;

	my $h = harness();
	write_env_file($h, 'prod', pipeline => {prior_env => 'qa'}, commit => 0);
	mkfile_or_fail($h->a . '/vault/notes.yml', "--- {changed: true}\n");

	for my $argv (@PREVIEWS) {
		my ($out, $err, $exit) = preview($h, @$argv);
		is($exit, 0, "`genesis @$argv` succeeds over the change") or diag($err);
		like($err, qr/This preview assumes the uncommitted changes to prod\.yml are committed/,
			'naming the uncommitted file as assumed committed');
		unlike($err, qr/notes\.yml/, "and nothing of vault/'s change");
		like($err, qr{origin/\S+ at [0-9a-f]{7}, as last fetched},
			'naming T as last fetched');

		like($out, qr{^\s*qa --> prod$}m, 'drawing prod following qa, the tree in front of it')
			if $argv->[0] eq 'pipeline-graph';
		like($out, qr{^ {6}prod$}m, 'showing prod under qa, the tree in front of it')
			if $argv->[0] eq 'pipeline-describe';
	}
};

subtest '(c) a commit not pushed is assumed pushed' => sub {
	# Two rows per preview, and one restoration assertion for each run.
	plan tests => 9;

	my $h = harness();
	write_env_file($h, 'prod', pipeline => {prior_env => 'qa'});

	for my $argv (@PREVIEWS) {
		my (undef, $err) = preview($h, @$argv);
		like($err, qr/This preview assumes the commit on \S+ is pushed/,
			"`genesis @$argv` names the unpushed commit as assumed pushed");
		unlike($err, qr/uncommitted/, 'and no uncommitted change');
	}
};

subtest '(d) a commit on T the tree lacks is named as not included' => sub {
	# One row per preview, and one restoration assertion for each run.
	plan tests => 6;

	my $h = harness();
	publish_from_b($h, files => {'bosh/README.md' => "a teammate's note\n"},
		message => "a teammate's commit");
	run({dir => $h->a}, 'git', 'fetch', '-q', 'origin');

	for my $argv (@PREVIEWS) {
		my (undef, $err) = preview($h, @$argv);
		like($err, qr{This preview does not include the commit on origin/\S+ that this tree lacks},
			"`genesis @$argv` names the commit it does not include");
	}
};

done_testing;
