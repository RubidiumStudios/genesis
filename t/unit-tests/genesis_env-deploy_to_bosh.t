#!/usr/bin/env perl
use strict;
use warnings;

# The flags _deploy_to_bosh hands to bosh deploy, driven with a mocked
# director so no bosh CLI runs: a dry run adds -n so bosh never waits on its
# own "Continue?" question, and a real deploy leaves that question to bosh.

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis;
use_ok 'Genesis::Config';
provide_rc();
use_ok 'Genesis::Env';

my @deploys;
my $director = mock "Mock::DeployToBosh::Director" => {
	deploy => sub {
		my ($self, $manifest, %opts) = @_;
		push @deploys, {manifest => $manifest, %opts};
		return ('', 0);
	},
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

done_testing;
