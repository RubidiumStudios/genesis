#!/usr/bin/env perl
# Proves T52: the staleness query reads the applied commit, a path diff
# over the pipeline-defining paths, and each environment's compiled set
# against its last-read set, and no second copy of it exists.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit;
use Genesis::Top;
use Genesis::Env;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# A stand-in for an environment's own vault, which records the path it was
# asked for and answers whatever the row handed it.  It asserts nothing of
# its own, so it belongs beside the one row that reads through it.
{
	package StandinVault;
	sub new {
		my ($class, $asked, $answer) = @_;
		return bless({asked => $asked, answer => $answer}, $class);
	}
	sub get {
		my ($self, $path) = @_;
		push @{$self->{asked}}, $path;
		return $self->{answer};
	}
}

sub staleness_for {
	my ($h) = @_;
	return Genesis::Top->new($h->a)->pipeline_staleness($h->git('a'));
}

# Every publishing commit below moves ops/shared.yml, because git makes no
# commit out of an unchanged tree.  The rows only need a control sha to put
# in the applied record, and no environment inherits that file, so what it
# holds carries no meaning.

subtest 'an applied pipeline that nothing has changed is not stale' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['lab', 'prod'], type => 'bosh');
	my $control = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'publish', push => 1,
	);
	fixture_applied($h, control => $control, provider => 'manual');
	fixture_pipeline_record($h, $_, dependencies => []) for qw/lab prod/;
	certify($h, $_, control_commit => $control, dependencies_read => [])
		for qw/lab prod/;

	is_deeply(staleness_for($h), [], 'nothing is stale');

	# With no applied record there is nothing to be stale against, and the
	# awaiting pipeline-apply outcome is a different read.
	my $fresh = make_harness(envs => ['lab'], type => 'bosh');
	commit_on_control($fresh,
		files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'publish', push => 1,
	);
	is_deeply(staleness_for($fresh), [],
		'and a pipeline that was never applied reports no staleness');
};

subtest 'a changed pipeline-defining path names its environment' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['lab', 'prod'], type => 'bosh');
	my $applied = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'publish', push => 1,
	);
	fixture_applied($h, control => $applied, provider => 'manual');
	fixture_pipeline_record($h, $_, dependencies => []) for qw/lab prod/;
	certify($h, $_, control_commit => $applied, dependencies_read => [])
		for qw/lab prod/;

	# Any pipeline key the schema declares will move the file, and this one
	# is gated by no capability, so the row stands whatever provider the
	# repository names.
	write_env_file($h, 'prod', pipeline => {require_pr => 'true'});

	my $changes = staleness_for($h);
	is(scalar(@$changes), 1, 'one environment changed');
	is($changes->[0]{env}, 'prod', 'and it is the one whose file moved');
	is($changes->[0]{reason}, 'configuration-changed',
		'with the reason the caller prints');
};

subtest 'the roster comes from control, not from the tree in front of us' => sub {
	plan tests => 3;

	# The deploy asks this query standing on a deployment branch, which the
	# branch class put it on and which carries one environment's hierarchy
	# and no sibling's.  Read out of that tree, the roster is a list of one
	# and an environment that changed only on control is invisible, so the
	# query has to name every environment the applied record knows, read
	# from control rather than from the tree in front of it.
	#
	# bosh is passed for the catch-up alone: a delivery is published from the
	# teammate's copy, so the operator's own branch stands at the commit the
	# apply cut until something brings it forward, and a checkout of that
	# commit is a tree with no deployment root in it at all.
	my $h = ready_harness(envs => ['lab', 'prod'], type => 'bosh', bosh => 1);

	# Any pipeline key the schema declares moves the file, as the row above
	# uses it.  It lands on control alone, and the branch below still carries
	# its own hierarchy as the delivery left it.
	write_env_file($h, 'prod', pipeline => {require_pr => 'true'});
	push_from($h, 'a', $h->control);
	stand_on($h, $h->slug('lab'));

	my $changes = staleness_for($h);
	is(scalar(@$changes), 1, 'one environment changed')
		or diag(explain $changes);
	is($changes->[0]{env}, 'prod',
		'and it is the sibling whose file this branch does not carry');
	is($changes->[0]{reason}, 'configuration-changed',
		'with the reason the caller prints');
};

subtest 'a compiled set that differs from the last-read set is stale' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['lab'], type => 'bosh');
	my $applied = commit_on_control($h,
		files => {'ops/shared.yml' => "---\nshared: 1\n"},
		message => 'publish', push => 1,
	);
	fixture_applied($h, control => $applied, provider => 'manual');
	fixture_pipeline_record($h, 'lab', dependencies => ['ops/bosh']);
	certify($h, 'lab',
		control_commit     => $applied,
		dependencies_read  => ['ops/bosh', 'shared/vault'],
	);

	my $changes = staleness_for($h);
	is($changes->[0]{env}, 'lab', 'the environment is named');
	is($changes->[0]{reason}, 'dependencies-changed',
		'and the reason says which of the two inputs differed');
};

subtest "the last-read set is read through the environment's own vault" => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['lab'], type => 'bosh');
	my $env = Genesis::Env->bare('lab', Genesis::Top->new($h->a));

	# An environment that sets genesis.vault keeps its exodus record in a
	# vault of its own, and pipeline_record already reads through that vault.
	# Were the fact half read through the repository's vault instead, the two
	# halves of one comparison would come from two vaults, the prediction
	# would never match the fact, and that environment would report
	# dependencies-changed on every run with nothing an operator could do.
	# The harness cannot stand a second live vault up beside its own, because
	# spinning one switches the safe target the repository's default vault
	# resolves through, so the environment's own vault is stood in for.
	my @asked;
	my $own = StandinVault->new(\@asked,
		{dependencies_read => 'other/bosh,shared/vault'});
	no warnings 'redefine';
	local *Genesis::Env::vault = sub {$own};

	my $slugs = $env->last_read_dependencies;

	is_deeply(\@asked, [$env->exodus_base],
		"the environment's own vault is the one asked, at its own record");
	is_deeply($slugs, ['other/bosh', 'shared/vault'],
		'and the set that vault holds is the one that comes back');
};

subtest 'a repository with no pipeline is not stale' => sub {
	plan tests => 2;

	# The deploy pre-flight asks this on every deploy, so an ordinary
	# repository has to answer before the applied record's address is
	# composed.  Composing it here would reach the refusal that says the
	# repository has a pipeline and no environment to resolve the mount
	# from, which is a sentence that contradicts the repository in front of
	# the operator.
	my $none = make_harness(envs => ['lab'], pipeline => 'none');
	is_deeply(staleness_for($none), [],
		'a repository with no pipeline section reports no staleness');

	my $off = make_harness(envs => ['lab'], pipeline => 0);
	is_deeply(staleness_for($off), [],
		'and so does one whose pipeline is switched off');
};

subtest 'a diff git cannot take is refused, not called clean' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['lab'], type => 'bosh');
	my $missing = '0' x 40;
	fixture_applied($h, control => $missing, provider => 'manual');

	# git writes its reason where the file names would be, and no reason
	# matches a defining path, so an unchecked read would compare an empty
	# set against the known paths and call the pipeline current.  An applied
	# commit the local repository does not hold is one ordinary way to get
	# there, after a fresh clone or a force-push of control.
	local $ENV{GENESIS_IGNORE_EVAL} = '';
	my $changes = eval {staleness_for($h)};
	my $err = $@;

	is($changes, undef, 'the query does not answer');
	like($err, qr{Cannot diff}, 'and the refusal says the diff could not be taken');
	like($err, qr{Fetch the missing commit or branch},
		'and names the fix');

	# An exit code only exists in a process that exits, and bail dies rather
	# than exiting whenever it is reached from inside an eval, which a test
	# file always is.  So the refusal is provoked in a process of its own and
	# its status is read back from there.
	my $cmd = sprintf(
		q{%s -I%s/lib -MService::Git -e '}.
		q{Service::Git->new($ARGV[0])->diff_names("0" x 40, "control")}.
		q{' %s},
		$^X, $helper::TOPDIR, $h->a
	);
	run_fails($cmd, Genesis::Exit::DATAERR,
		'the refusal exits Genesis::Exit::DATAERR');
};

subtest 'the comparison has one home' => sub {
	plan tests => 2;

	my @composers;
	my @queue = ('lib');
	while (my $dir = shift @queue) {
		opendir(my $dh, $dir) or next;
		for my $entry (sort readdir($dh)) {
			next if $entry eq '.' or $entry eq '..';
			my $path = "$dir/$entry";
			if (-d $path) {
				push @queue, $path;
			} elsif ($path =~ m{\.pm$}) {
				push @composers, $path if slurp($path) =~ m{_pipelines/};
			}
		}
		closedir($dh);
	}

	is_deeply(\@composers, ['lib/Genesis/Top.pm'],
		'the applied record address is composed in one module')
		or diag("a second composition: @composers");
	ok(Genesis::Top->can('pipeline_staleness'),
		'and the comparison is a method its three callers will ask');
};

done_testing;
