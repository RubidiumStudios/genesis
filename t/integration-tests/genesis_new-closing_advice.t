#!/usr/bin/env perl
# Proves T394: genesis new closes, under a pipeline, with advice that names
# the deployment branch pipeline-apply creates, <env>/<type>, and how the
# environment is deployed under the provider.  It used to say
# `git checkout '<env>'` and `genesis deploy` whatever the provider.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

sub new_env {
	my ($h, $name) = @_;
	my $git = $h->git('a');
	$git->create_branch("add-$name", 'refs/remotes/origin/' . $h->control);
	stand_on($h, "add-$name");
	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'new', $name);
	return (unfolded($out, $err), $exit);
}

subtest 'under the manual provider, the deployment branch and propagate' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], type => 'bosh', kit => 'omega-v2.7.0', provider => 'manual');
	init_branch($h, 'qa');
	refresh($h, 'a');
	my ($said, $exit) = new_env($h, 'prod');

	is($exit, 0, 'genesis new succeeds') or diag($said);
	like($said, qr/git checkout 'prod\/bosh'/, 'naming the deployment branch, <env>/<type>');
	like($said, qr/genesis propagate/, 'after propagate delivers the environment');
	unlike($said, qr/git checkout 'prod'/, 'and never the bare environment name');
};

subtest 'under an automated provider, the pipeline deploys it' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], type => 'bosh', kit => 'omega-v2.7.0', provider => 'concourse');
	init_branch($h, 'qa');
	refresh($h, 'a');
	# A name the harness vault holds no secrets for, so new asks nothing.
	my ($said, $exit) = new_env($h, 'uat');

	is($exit, 0, 'genesis new succeeds') or diag("exit $exit: $said");
	like($said, qr/pipeline deploys uat once genesis propagate/, 'saying the pipeline deploys it');
	unlike($said, qr/git checkout/, 'and offering no deploy by hand');
};

done_testing;
