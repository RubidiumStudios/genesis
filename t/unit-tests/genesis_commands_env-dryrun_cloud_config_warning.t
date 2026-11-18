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
use TraceCapture;
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

subtest 'a deploy shows cloud config changes on the terminal only' => sub {
	# A kit can put a credential into a cloud config, and the deploy's diff
	# would show the old and new ones, so the log gets how many paths
	# differ, and the diff and a new config's body reach only the terminal.
	my ($old, $new, $said) = map {fake_secret($_)} qw(old new said);
	my $dir = workdir();
	put_file("$dir/old.yml", "azs:\n- name: z1\n  key: $old\n");
	put_file("$dir/new.yml", "azs:\n- name: z1\n  key: $new\n");

	my ($log, $stderr) = capture_trace {
		Genesis::Commands::Env::_deploy_show_cloud_config_diff("$dir/old.yml", "$dir/new.yml", "azs.z1.key\n  - $old\n  + $new\n");
	} tty => 1;
	like($log, qr/found differences \(1 path changed\)/, 'the log says how many paths changed');
	unlike($log, qr/\Q$_\E/, 'and holds no value from the diff') for ($old, $new);
	like($stderr, qr/\Q$new\E/, 'the terminal shows the diff');

	($log, $stderr) = capture_trace {
		Genesis::Commands::Env::_deploy_show_missing_cloud_config('lab.cf', "$dir/new.yml");
	} tty => 1;
	like($log, qr/Cloud config lab\.cf missing\..*with 1 path added/s, 'a dry run logs a missing config by its size');
	unlike($log, qr/\Q$new\E/, 'and not by its body');
	like($stderr, qr/\Q$new\E/, 'which the terminal shows');

	no warnings 'redefine';
	local *Genesis::Commands::Env::spruce_diff = sub { return ("unable to parse data from new: yaml: $said", 2, undef) };
	my $error;
	($log, $stderr) = capture_trace {
		eval {Genesis::Commands::Env::_deploy_cloud_config_diff("$dir/old.yml", "$dir/new.yml")}; $error = $@;
	};
	like($error, qr/Error comparing cloud configs: spruce diff exited 2 \(could not parse its input\)/,
		'a failed comparison says how spruce ended');
	unlike($error.$log.$stderr, qr/\Q$said\E/, 'and not what it said');
};

done_testing;
