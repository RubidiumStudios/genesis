#!perl
# Proves T365 through the commands an operator types: a pipeline can be
# enabled and rehearsed before its remote exists, and only the commands
# that act on the remote refuse for want of one (D118, noted 2026-10-15).
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;

use Genesis qw/run slurp/;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], provider => 'manual');

# An enabled manual pipeline, with the repository written or not.
sub pipeline_config {
	my (%opts) = @_;
	return join("\n",
		'---', 'deployment_type: bosh', 'version: "3"',
		'creator_version: 3.2.0', 'minimum_version: 3.2.0',
		'pipeline:', '  enabled: true',
		'  provider:', '    type: manual',
		($opts{repository}
			? ('  source_control:', "    repository: $opts{repository}")
			: ()),
		'');
}

# Committed while the remote is still there, then the remote is taken away,
# which is a clone that has not been pushed anywhere yet.  Every commit after
# this one is local, because commit_on_control pushes only when asked to.
commit_on_control($h, files => {
	'.genesis/config' => pipeline_config(repository => 'genesis/bosh-deployments'),
});
run({dir => $h->a}, 'git', 'remote', 'remove', 'origin');

subtest 'with no remote, a dry run is not refused for it' => sub {
	# Two explicit rows and one for the run's own restoration assertion.
	plan tests => 3;

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply', '--dry-run');
	is $exit, 0, 'the dry run goes through';
	(my $flat = $err) =~ s/\s+/ /g;
	like $flat, qr/No remote is used by this dry run/,
		'and warns what the real apply will need, rather than refusing';
};

subtest 'with no remote, the commands that act on it refuse' => sub {
	# Two explicit rows per command, and one for each run's restoration
	# assertion.
	plan tests => 12;

	for my $argv (['pipeline-apply'], ['propagate'], ['pipeline-status'], ['qa', 'deploy']) {
		my ($out, $err, $exit) = run_genesis($h, @$argv);
		my $what = join(' ', 'genesis', @$argv);
		is $exit, Genesis::Exit::CONFIG, "$what refuses at the configuration exit";
		(my $flat = $err) =~ s/\s+/ /g;
		like $flat, qr/This clone has no git remote/, "$what says the clone has no remote";
	}
};

subtest 'with no remote and no repository written, the dry run needs one only to use it' => sub {
	# Three explicit rows and one for each run's restoration assertion.
	plan tests => 5;

	# Under the manual provider with no token, nothing the dry run reports
	# names the repository, so it has nothing to refuse for.
	commit_on_control($h, files => {'.genesis/config' => pipeline_config()});
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply', '--dry-run');
	is $exit, 0, 'a dry run that needs no repository goes through without one';

	# With a token the dry run names the protection it would apply, which is
	# set on a repository, so here it does need one.
	my $gh = make_harness(envs => ['qa'], provider => 'manual', github => 1);
	commit_on_control($gh, files => {'.genesis/config' => pipeline_config()});
	run({dir => $gh->a}, 'git', 'remote', 'remove', 'origin');

	($out, $err, $exit) = run_genesis($gh, 'pipeline-apply', '--dry-run');
	is $exit, Genesis::Exit::CONFIG,
		'a dry run that needs the repository refuses without one';
	like $err, qr/pipeline\.source_control\.repository/, 'naming the key that gives one';
};

subtest 'a new repository can be rehearsed straight after init' => sub {
	plan tests => 3;

	# Run outside the harness, because the point is a repository that has
	# never had a remote at all.
	my $parent = workdir('init-then-dry-run');
	my %env = (GENESIS_TOPDIR => $helper::TOPDIR, NOCOLOR => 1);
	my $genesis = "$helper::TOPDIR/bin/genesis";

	my (undef, $rc) = run({dir => $parent, env => \%env, stderr => 0, passfail => 0},
		$genesis, 'init', '--with-ci', '--skip-vault', 'rehearsal');
	is $rc, 0, 'genesis init --with-ci makes a repository with the pipeline on';

	my ($dir) = grep {-d} map {"$parent/$_"} ('rehearsal-deployments', 'rehearsal');
	my ($out, $err);
	($out, $rc, $err) = run({dir => $dir, env => \%env, stderr => 0, passfail => 0},
		$genesis, 'config', '--set', 'pipeline.source_control.repository', 'org/repo');
	is $rc, 0, 'the repository is named with no remote to check it against'
		or diag $err;

	# --skip-vault, because init was given it and the vault is not this row's
	# subject.
	($out, $rc, $err) = run({dir => $dir, env => \%env, stderr => 0, passfail => 0},
		$genesis, 'pipeline-apply', '--dry-run', '--skip-vault');
	is $rc, 0, 'and the dry run goes through, with no remote ever added'
		or diag $err;
};

done_testing;
