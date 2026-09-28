#!/usr/bin/env perl
# Proves D112's one reader, the half every other D112 row stands on: the
# pipeline's shape (the environment files' genesis.pipeline blocks and the
# pipeline keys that say what the pipeline is) is read from control as R holds
# it, whatever branch the clone stands on and whatever the clone's own control
# carries unpublished, while the keys that say where control is are read from
# the tree in front of the command.  A second read at the same control commit
# reuses the first, because the read writes a scratch tree out of git.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

# three_stage - lab, then qa, then prod following lab, published on control
sub three_stage {
	my (%opts) = @_;
	my $h = make_harness(envs => ['lab', 'qa', 'prod'], vault => 0, %opts);
	write_env_file($h, 'qa',   pipeline => {prior_env => 'lab'});
	write_env_file($h, 'prod', pipeline => {prior_env => 'lab'});
	push_from($h, 'a', $h->control);
	return $h;
}

# set_config_key - one key of .genesis/config, committed where copy A stands
sub set_config_key {
	my ($h, $key, $value) = @_;
	require Genesis::Config;
	my $config = Genesis::Config->new($h->a . '/.genesis/config');
	$config->set($key => $value);
	$config->save;
	run({dir => $h->a}, 'git', 'commit', '-q', '-am', "set $key");
}

sub top_in {
	my ($h) = @_;
	require Genesis::Top;
	local %ENV = %ENV;
	return Genesis::Top->new($h->a);
}

subtest 'a feature branch does not move the shape' => sub {
	plan tests => 3;

	my $h = three_stage();
	local_branch($h, 'feature/reparent', at => $h->control);
	stand_on($h, 'feature/reparent');
	write_env_file($h, 'prod', pipeline => {prior_env => 'qa'});
	set_config_key($h, 'pipeline.enabled', 0);

	my $top = top_in($h);
	is($top->pipeline_topology->{parent_of}{prod}, 'lab',
		"prod follows lab, which is control's answer, not the branch's qa");
	is($top->pipeline_enabled, 1,
		"the pipeline is enabled, which is control's answer, not the branch's");
	is($top->control_branch, $h->control,
		'the name of control itself is read from the tree in front of the command');
};

subtest 'every key that says what the pipeline is comes from control' => sub {
	plan tests => 4;

	my $h = three_stage();
	local_branch($h, 'feature/policy', at => $h->control);
	stand_on($h, 'feature/policy');
	set_config_key($h, 'pipeline.source_control.pr_prefix', 'proposal/');
	set_config_key($h, 'pipeline.recreate_on_deploy', 'always');
	set_config_key($h, 'pipeline.source_control.control_requires_pr', 1);
	set_config_key($h, 'pipeline.name', 'renamed-on-a-branch');

	my $top = top_in($h);
	isnt($top->pr_prefix, 'proposal/', 'the pull request prefix is control\'s');
	isnt($top->recreate_on_deploy, 'always', 'as is the recreate policy');
	is($top->control_requires_pr, 0, 'and the protection control asks for');
	isnt($top->pipeline_name, 'renamed-on-a-branch', 'and the pipeline\'s name');
};

subtest "control's unpublished change is not the shape" => sub {
	plan tests => 1;

	# A re-parent committed on the clone's own control and never pushed is
	# a change nobody has accepted and the pipeline cannot see.
	my $h = three_stage();
	stand_on($h, $h->control);
	write_env_file($h, 'prod', pipeline => {prior_env => 'qa'});

	is(top_in($h)->pipeline_topology->{parent_of}{prod}, 'lab',
		'the shape is the one R holds');
};

subtest 'a clone that never fetched control reads its own' => sub {
	plan tests => 1;

	# An enabled pipeline refuses a clone with no remote at all when its
	# configuration loads, so the case that reaches this reader is a remote
	# whose copy of control this clone does not hold.
	my $h = three_stage();
	run({dir => $h->a}, 'git', 'update-ref', '-d',
		'refs/remotes/origin/'.$h->control);
	local_branch($h, 'feature/elsewhere', at => $h->control);
	stand_on($h, 'feature/elsewhere');
	write_env_file($h, 'prod', pipeline => {prior_env => 'qa'});

	is(top_in($h)->pipeline_topology->{parent_of}{prod}, 'lab',
		'the local control branch stands in for R');
};

subtest 'a deployment root under no git control reads its own files' => sub {
	# Genesis runs a repository with no pipeline outside git, and a pipeline
	# needs one, so such a root can hold no pipeline and there is no control
	# to read.  It is told once, and nothing asks git anything after that.
	plan tests => 2;

	my $dir = helper::workdir('not-under-git');
	put_file("$dir/.genesis/config", join("\n",
		'---', 'deployment_type: thing', 'version: "3"',
		'creator_version: 3.2.0', ''));
	require Genesis::Top;
	my $top = do {local %ENV = %ENV; Genesis::Top->new($dir, no_vault => 1)};

	my $handles = 0;
	no warnings 'redefine';
	my $real = \&Service::Git::new;
	local *Service::Git::new = sub {$handles++; goto &$real};
	is($top->pipeline_enabled, 0, 'it reads no pipeline');
	is($handles, 0, 'and opens no git handle to find that out');
};

subtest "control without this deployment's root has no pipeline for it" => sub {
	# A repository holding several deployment roots, whose control carries
	# no root for this one.  The pipeline for this type does not exist on
	# control, so there is nothing to manage, whatever a branch in front of
	# the command carries.
	plan tests => 2;

	my $h = make_harness(envs => ['lab', 'prod'], root => 'bosh', vault => 0);
	push_from($h, 'a', $h->control);
	local_branch($h, 'feature/keeps-bosh', at => $h->control);
	run({dir => $h->a}, 'git', 'rm', '-q', '-r', 'bosh');
	run({dir => $h->a}, 'git', 'commit', '-q', '-m', 'bosh moves elsewhere');
	push_from($h, 'a', $h->control);
	stand_on($h, 'feature/keeps-bosh');

	my $top = do {local %ENV = %ENV; Genesis::Top->new($h->a . '/bosh')};
	is($top->pipeline_enabled, 0,
		"the branch's root declares a pipeline, and control has no root for it");
	is_deeply($top->pipeline_topology->{order}, [],
		'so there are no environments to act on');
};

subtest "an environment on control's dev kit is in the shape" => sub {
	# An environment file may name the dev kit and no version, which is valid
	# where the root carries a dev kit.  Control carries one, so the
	# environment is in control's shape; the tree the shape is read from has
	# to answer that question the way control does.
	plan tests => 1;

	my $h = make_harness(envs => ['lab', 'qa'], vault => 0,
		kit => 'omega-v2.7.0');
	commit_on_control($h, files => {'qa.yml' =>
		"---\nkit:\n  name: dev\ngenesis:\n  env: qa\n  pipeline:\n".
		"    prior_env: lab\n"}, message => 'qa on the dev kit', push => 1);

	my $top = do {local %ENV = %ENV; Genesis::Top->new($h->a)};
	is_deeply([sort @{$top->pipeline_topology->{order}}], [qw/lab qa/],
		'qa, naming the dev kit and no version, is in the pipeline');
};

subtest 'control is read once per command' => sub {
	# D112 reads control as R holds it when the command starts, so a Top
	# resolves control's ref once and keeps what it found.  Every shape key a
	# command asks after that is answered with no git process at all, where
	# resolving the ref on every call cost four or five of them per call.
	plan tests => 4;

	my $h = three_stage();

	# Counted from before the Top is built, because loading its configuration
	# asks whether the pipeline is enabled, and that is a read of control too.
	my ($top, $reads, $resolves) = (undef, 0, 0);
	{
		no warnings 'redefine';
		my $read    = \&Genesis::Top::_topology_at;
		my $resolve = \&Genesis::Top::_control_ref;
		local *Genesis::Top::_topology_at = sub {$reads++; goto &$read};
		local *Genesis::Top::_control_ref = sub {$resolves++; goto &$resolve};
		$top = top_in($h);
		$top->pipeline_topology for 1 .. 3;
		$top->pipeline_enabled for 1 .. 3;
		$top->pipeline_env_names;
		$top->pr_prefix;
	}
	is($reads, 1, 'the load and every shape key after it take one read of control');
	is($resolves, 1, "and control's ref is resolved once");

	# Control moving on R after the command started is not this command's
	# concern: the publish's leases and control re-check guard every write.
	# The next command reads the new commit.
	commit_on_control($h, files => {'ops/new.yml' => "---\nnew: 1\n"},
		message => 'move control', push => 1);
	my $moved = $h->git('a')->sha('origin/'.$h->control);
	$top->pipeline_topology;
	is($top->{__shape_commit}, $h->git('a')->sha("$moved~1"),
		'the command already running keeps the commit it started with');
	my $next = top_in($h);
	$next->pipeline_topology;
	is($next->{__shape_commit}, $moved, 'and the next command reads the new one');
};

done_testing;
