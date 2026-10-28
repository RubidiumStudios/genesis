#!perl
# Proves T372: control's tree is judged by the load's checks wherever it is
# read (D112, noted 2026-10-16).  Control on T holds an rc-era `ci:` block and
# no `pipeline:` section, and the working tree holds the fix, uncommitted,
# which is the state a repository is in part way through its migration.  The
# previews read the fix and name control's failures in their banner; the
# commands that act refuse at CONFIG, naming control and its commit.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/load_yaml to_yaml slurp mkfile_or_fail run/;
use Genesis::Exit;
provide_rc();

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $h    = make_harness(envs => ['lab', 'qa'], fanned => 'lab', provider => 'manual');
my $path = $h->a . '/.genesis/config';
my $good = slurp($path);

my $data = load_yaml($good);
delete $data->{pipeline};
$data->{ci} = {enabled => 1, name => 'bosh', provider => {type => 'manual'}};
my $sha   = commit_on_control($h, files => {'.genesis/config' => to_yaml($data)},
	message => 'the rc-era ci block', push => 1);
my $short = substr($sha, 0, 7);
mkfile_or_fail($path, $good);

# A bullet written as a literal in a file without `use utf8` reaches the
# terminal encoded twice, so its bytes read as "â" and two control characters.
my $MOJIBAKE = qr/\xC3\xA2\xC2\x80\xC2\xA2/;

subtest 'the previews read the fix and name what control fails' => sub {
	# Five rows per preview, and one restoration assertion for each run.
	plan tests => 18;

	for my $argv (['pipeline-describe'], ['pipeline-graph'], ['pipeline-apply', '--dry-run']) {
		my ($out, $err, $exit) = run_genesis($h, @$argv);
		my $said = unfolded($err);

		is($exit, 0, "`genesis @$argv` succeeds over an invalid control") or diag($err);
		# The apply reports its branches on standard error.
		like(unfolded($out, $err), qr/\bqa\b/, "and shows the working tree's pipeline");
		like($said, qr/Control at \Q$short\E fails the configuration checks, so this preview does not read it/,
			'naming control and its commit in the banner');
		like($said, qr/\bci: is no longer read/, 'and the failure, ci retired (T404)');
		unlike($err, $MOJIBAKE, 'in a list whose bullets are not encoded twice');
	}
};

subtest 'the commands that act refuse, naming control' => sub {
	# Six rows per command, and one restoration assertion for each run.
	plan tests => 21;

	for my $argv (['pipeline-apply'], ['propagate'], ['qa', 'deploy']) {
		my (undef, $err, $exit) = run_genesis($h, @$argv);
		my $said = unfolded($err);
		is($exit, Genesis::Exit::CONFIG, "`genesis @$argv` refuses at CONFIG");
		like($said, qr/control at \Q$short\E fails the configuration checks/i,
			'naming control and its commit');
		like($said, qr/\bci: is no longer read/, 'and the failure, ci retired (T404)');
		unlike($err, $MOJIBAKE, 'in a list whose bullets are not encoded twice');

		# The fix is in the working tree, uncommitted, and the refusal says so
		# first, since it is the likeliest reason control still fails.
		like($said, qr/uncommitted changes.*\.genesis\/config/s,
			'naming the uncommitted file');
		ok(index($said, 'uncommitted') >= 0
			&& index($said, 'uncommitted') < index(lc $said, 'fails the configuration checks'),
			'before the failure');
	}
};

subtest 'a fix committed but not pushed is named as unpushed' => sub {
	# Three rows, and the run's restoration assertion.
	plan tests => 4;

	# The fix committed on local control and never pushed, so the shape is
	# still read from control on the remote, at the failing commit.
	run({dir => $h->a, onfailure => 'commit the fix'},
		'git', 'commit', '-q', '-m', 'the fix, not yet pushed', '--', '.genesis/config');
	my (undef, $err, $exit) = run_genesis($h, 'propagate');
	my $said = unfolded($err);
	is($exit, Genesis::Exit::CONFIG, 'it still refuses at CONFIG');
	like($said, qr/local control is 1 commit ahead/i, 'saying local control is ahead');
	like($said, qr/push/i, 'and to push it');
};

done_testing;
