#!/usr/bin/env perl
use strict;
use warnings;

# The flags _deploy_to_bosh hands to bosh deploy, driven with a mocked
# director so no bosh CLI runs: a dry run adds -n so bosh never waits on its
# own "Continue?" question, and a real deploy leaves that question to bosh.
# How the deploy ended is decided once, from the exit code and the status
# execute() recorded, and the post-deploy steps follow that outcome.

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis;
use_ok 'Genesis::Config';
provide_rc();
use_ok 'Genesis::Env';

my @deploys;
my ($deploy_out, $deploy_rc, $deploy_status) = ('', 0, undef);
my $director = mock "Mock::DeployToBosh::Director" => {
	deploy => sub {
		my ($self, $manifest, %opts) = @_;
		push @deploys, {manifest => $manifest, %opts};
		return ($deploy_out, $deploy_rc);
	},
	last_interactive_status => sub { $deploy_status },
};

sub make_env {
	return bless {
		name => 'test-env',
		deployment_state => {manifest_path => '/work/manifest.yml', vars_path => '/work/vars.yml'},
	}, 'Genesis::Env';
}

no warnings qw/redefine once/;
local *Genesis::Env::bosh = sub { $director };

subtest 'a dry run tells bosh not to ask' => sub {
	plan tests => 4;
	@deploys = ();
	my $env = make_env();
	ok($env->_deploy_to_bosh('dry-run' => 1, redact => 1), 'the deploy reports success');
	is(scalar(@deploys), 1, 'bosh deploy is called once');
	ok((grep {$_ eq '--dry-run'} @{$deploys[0]{flags}}), 'bosh deploy runs with --dry-run');
	ok((grep {$_ eq '-n'} @{$deploys[0]{flags}}), 'bosh deploy runs with -n, so it never waits on Continue?');
};

subtest 'a real deploy leaves the confirmation to bosh' => sub {
	plan tests => 3;
	@deploys = ();
	my $env = make_env();
	ok($env->_deploy_to_bosh(redact => 1), 'the deploy reports success');
	ok(!(grep {$_ eq '-n'} @{$deploys[0]{flags}}), 'bosh deploy runs without -n');
	ok(!(grep {$_ eq '--dry-run'} @{$deploys[0]{flags}}), 'bosh deploy runs without --dry-run');
};

# bosh can exit zero after Ctrl-C reached Genesis, or with a task it never
# reported the end of; neither is a success, and everything after the
# deploy follows that one outcome.
subtest 'a zero exit after a signal or with a task open is not a success' => sub {
	my $env = make_env();
	($deploy_out, $deploy_rc) = ("Task 4321\r\nTask 4321 | 12:00:00 | Updating instance web/0\r\n", 0);
	$deploy_status = {rc => 0, signal => 'INT', interrupted => 1, tasks => [{id => 4321}]};
	ok(!$env->_deploy_to_bosh(redact => 1), 'an interrupted deploy is not reported as a success');
	is($env->{deployment_state}{outcome}{kind}, 'interrupted', 'its outcome is interrupted');
	is($env->{deployment_state}{outcome}{cleanup_cache}, 0, 'so the deployment cache is kept');
	is_deeply($env->{deployment_state}{outcome}{tasks}, [4321], 'and the open task is named');

	$env = make_env();
	$deploy_status = {rc => 0, signal => undef, interrupted => 0, tasks => [{id => 4321}]};
	ok(!$env->_deploy_to_bosh(redact => 1), 'a deploy with a task left open is not a success');
	is($env->{deployment_state}{outcome}{kind}, 'unfinished', 'its outcome is unfinished');

	$env = make_env();
	$deploy_status = {rc => 0, signal => 'INT', interrupted => 1, tasks => [{id => 4321, state => 'done'}]};
	ok(!$env->_deploy_to_bosh(redact => 1), 'a caught signal is an interrupt even with every task done');

	$env = make_env();
	$deploy_status = {rc => 0, signal => undef, interrupted => 0, tasks => [{id => 4321, state => 'done'}]};
	ok($env->_deploy_to_bosh(redact => 1), 'a zero exit with every task done is a success');
	($deploy_out, $deploy_rc, $deploy_status) = ('', 0, undef);
};

subtest 'the post-deploy steps follow the recorded outcome, not the exit code' => sub {
	my $env = make_env();
	($deploy_out, $deploy_rc) = ("Task 4321\r\n", 0);
	$deploy_status = {rc => 0, signal => 'INT', interrupted => 1, tasks => [{id => 4321}]};
	$env->_deploy_to_bosh(redact => 1);

	my (%hook, %audit, @saved, @notes, $cleaned);
	local *Genesis::Env::top = sub { mock "Mock::DeployToBosh::Top" => {
		config => sub { mock "Mock::DeployToBosh::Config" => {get => sub { 'exodus' }} },
	}};
	local *Genesis::Env::deployment_cache_path_lookup = sub { '/work/deploy.log' };
	local *Genesis::Env::_save_deploy_log = sub { shift; @saved = @_ };
	local *Genesis::Env::notify = sub { shift; push @notes, sprintf(shift, @_) };
	local *Genesis::Env::_reactions = sub { 0 };
	local *Genesis::Env::use_create_env = sub { 0 };
	local *Genesis::Env::has_hook = sub { $_[1] eq 'post-deploy' };
	local *Genesis::Env::run_hook = sub { shift; my $h = shift; %hook = (hook => $h, @_) };
	local *Genesis::Env::deployment_cache_cleanup = sub { $cleaned = 1 };
	local *Genesis::Env::_create_deployment_audit_log = sub { shift; %audit = @_; die "bailed\n" };
	eval { $env->_post_deploy(redact => 1) };
	like($@, qr/\Abailed/, 'the deploy ends as a failure');
	ok(!(grep {/successful/} @notes), 'it is not announced as successful');
	is($hook{rc}, 1, 'the post-deploy hook is told it failed, with a non-zero exit code');
	is($audit{cleanup_cache}, 0, 'the deployment cache is kept for a rejoin');
	like($audit{error}, qr/`genesis test-env bosh task 4321`/, 'and the operator is told how to follow the task');
	is($saved[3], $audit{error}, 'the saved log records the same outcome');
	ok(!$cleaned, 'and nothing cleans the deployment cache up');
	($deploy_out, $deploy_rc, $deploy_status) = ('', 0, undef);
};

done_testing;
