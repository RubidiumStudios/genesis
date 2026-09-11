#!/usr/bin/env perl
use strict;
use warnings;

# A dry-run deploy never uploads a cloud config, so the director validates the
# manifest against the copy it already holds.  These are the warnings that say
# so: one for a director whose copy is out of date, one for a director that
# holds no copy at all.

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Output;

use Genesis;
use_ok 'Genesis::Commands::Env';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

sub make_env {
	my $director = mock "Mock::DryrunWarning::Director" => {
		alias => 'parent',
	};
	$director->{alias} = 'parent';
	return mock "Mock::DryrunWarning::Env" => {
		name => 'test-env',
		bosh => $director,
	};
}

sub warning_for {
	my (@args) = @_;
	my ($out, $err) = output_from {
		Genesis::Commands::Env::_deploy_dryrun_cloud_config_warning(make_env(), @args)
	};
	return ($out, $err);
}

subtest 'an outdated cloud config on the director is explained' => sub {
	plan tests => 5;
	my ($out, $err) = warning_for('lab.cf', 'outdated');
	my $text = $out.$err;
	like($text, qr/never uploads cloud configs/, 'says a dry run uploads nothing');
	like($text, qr/current copy of cloud config lab\.cf/, 'names the cloud config the director will validate against');
	like($text, qr/parent/, 'names the director');
	like($text, qr/do not indicate a manifest problem/, 'says the errors that follow are expected');
	like($text, qr/Deploy without --dry-run to upload the updated cloud config/, 'says how to validate against the new cloud config');
};

subtest 'a missing cloud config on the director is explained' => sub {
	plan tests => 5;
	my ($out, $err) = warning_for('lab.cf', 'missing');
	my $text = $out.$err;
	like($text, qr/never uploads cloud configs/, 'says a dry run uploads nothing');
	like($text, qr/does not hold a cloud config named lab\.cf/, 'says the director holds no such cloud config');
	like($text, qr/parent/, 'names the director');
	like($text, qr/do not indicate a manifest problem/, 'says the errors that follow are expected');
	like($text, qr/Deploy without --dry-run to create and upload the cloud config/, 'says how to get the cloud config onto the director');
};

subtest 'the warnings stay off standard output' => sub {
	plan tests => 2;
	for my $state (qw(outdated missing)) {
		my ($out) = warning_for('lab.cf', $state);
		is($out, '', "the $state warning writes nothing to standard output");
	}
};

subtest 'an unknown state is a bug, not a silent warning' => sub {
	plan tests => 1;
	throws_ok {
		output_from { Genesis::Commands::Env::_deploy_dryrun_cloud_config_warning(make_env(), 'lab.cf', 'sideways') }
	} qr/Unknown cloud config state 'sideways'/, 'an unrecognized state is reported as a bug';
};

done_testing;
