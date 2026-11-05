#!/usr/bin/env perl
# Proves T473's compile half (D143; contract a1, a5): pipeline.provider.git
# says how the git resources learn a branch moved.  webhooks: true puts the
# webhook token reference on control-branch and every deployment branch's
# resource; control_check_every and check_every set each one's polling
# interval apart; absent, no resource carries either, as today.  A value that
# is not a Concourse duration nor never is refused at load naming the key.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Harness::Contract;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $ENV_NAME = $Harness::Contract::ENV_NAME;
my $BRANCH   = "$ENV_NAME-branch";

sub git_resources {
	my ($p) = @_;
	return (pipeline_resource($p, 'control-branch'), pipeline_resource($p, $BRANCH));
}

subtest 'webhooks: true puts the token on every git resource' => sub {
	my ($p, $why) = dry_pipeline(contract_harness(config => {'pipeline.provider.git.webhooks' => 'true'}));
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	for my $r (git_resources($p)) {
		is($r->{webhook_token}, '((webhook.token))', "a1/a5: $r->{name} carries the token reference");
	}
};

subtest 'the intervals are set apart' => sub {
	my ($p, $why) = dry_pipeline(contract_harness(config => {
		'pipeline.provider.git.control_check_every' => '2m',
		'pipeline.provider.git.check_every'         => '1h',
	}));
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	my ($control, $branch) = git_resources($p);
	is($control->{check_every}, '2m', 'a5: control-branch at control_check_every');
	is($branch->{check_every},  '1h', 'a1: the deployment branch at check_every');
	ok(!exists $_->{webhook_token}, "and $_->{name} carries no token without webhooks") for ($control, $branch);
};

subtest 'absent, no git resource carries either' => sub {
	my ($p, $why) = dry_pipeline(contract_harness());
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	for my $r (git_resources($p)) {
		ok(!exists $r->{webhook_token}, "$r->{name} carries no token");
		ok(!exists $r->{check_every},   "$r->{name} carries no interval");
	}
};

subtest 'an interval that is not a Concourse duration is refused' => sub {
	for my $bad ('hourly', '5 minutes', '10') {
		my ($p, $why) = dry_pipeline(contract_harness(config => {'pipeline.provider.git.check_every' => $bad}));
		ok(!$p, "'$bad' is refused") or next;
		like($why, qr/^exit 78\b/, 'at CONFIG');
		like($why, qr/pipeline\.provider\.git\.check_every/, 'naming the key');
	}
	my ($p, $why) = dry_pipeline(contract_harness(config => {'pipeline.provider.git.control_check_every' => 'never'}));
	ok($p, 'never is accepted') or diag($why);
};

done_testing;
