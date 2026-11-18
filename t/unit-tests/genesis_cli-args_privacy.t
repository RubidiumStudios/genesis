#!/usr/bin/env perl
# An operator can type a credential as the value of any option, and a
# credential can begin with a hyphen.  The command header, the traced
# arguments, and the arguments handed through to bosh or credhub show a
# flag only where it cannot be an option's value, so a hyphenated value
# after a flag, or a value attached to a short flag, shows only its length.
# When Genesis cannot parse its own options, what Getopt::Long said can
# quote the value, so the log and the usage message say what kind of
# problem it was and name only options Genesis knows.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use Test::Exit;

use Genesis;
use Genesis::Commands;

# The helper points HOME at the test's own directory, so this reads no
# operator configuration.
$ENV{NOCOLOR} = 1;
require Genesis::Config;
Genesis::Init();

my $secret = fake_secret('cli');

subtest 'a hyphenated value after a flag shows only its length' => sub {
	my @shown = Genesis::traced_cli_args('--client-secret', "-$secret", 'vms');
	is($shown[0], '--client-secret', 'the flag is shown');
	like($shown[1], qr/^<redacted:\d+ bytes>$/, 'its value, though it looks like a flag, is not');
	unlike(join(' ', @shown), qr/\Q$secret\E/, 'and appears nowhere');
};

subtest 'a value attached to a short flag shows only its length' => sub {
	my @shown = Genesis::traced_cli_args("-p$secret", '-n');
	like($shown[0], qr/^-p<redacted:\d+ bytes>$/, 'the flag letter stays in view');
	is($shown[1], '-n', 'and a lone short flag is shown');
	unlike(join(' ', @shown), qr/\Q$secret\E/, 'the value appears nowhere');
};

subtest 'flags the caller lists as taking no value keep the next flag in view' => sub {
	my @shown = Genesis::traced_cli_args(['vms', '--json', '--tty'], '--json', '--tty', 'vms', '--details');
	is_deeply(\@shown, ['--json', '--tty', 'vms', '--details'], 'every flag is shown');
	@shown = Genesis::traced_cli_args(['vms'], '--column', '--name', 'vms');
	like($shown[1], qr/^<redacted:\d+ bytes>$/, 'while a flag after an unlisted one may be its value');
};

subtest 'bosh and credhub flags that take no value keep the next flag in view' => sub {
	require Genesis::Commands::Bosh;
	require Service::Credhub;
	my @shown = Genesis::traced_cli_args(\@Genesis::Commands::Bosh::BOSH_COMMANDS,
		'-n', '--json', 'deploy', '--fix', '--recreate', '--dry-run', '-d', "-$secret");
	is_deeply([@shown[0..6]], ['-n', '--json', 'deploy', '--fix', '--recreate', '--dry-run', '-d'], 'bosh flags are shown');
	like($shown[7], qr/^<redacted:\d+ bytes>$/, 'and the value of -d is not');
	@shown = Genesis::traced_cli_args(\@Service::Credhub::CREDHUB_COMMANDS,
		'find', '-j', '-n', "-$secret");
	is_deeply([@shown[0..2]], ['find', '-j', '-n'], 'credhub flags are shown');
	like($shown[3], qr/^<redacted:\d+ bytes>$/, 'and the value of -n is not');
};

subtest 'every operand after a bare -- shows only its length' => sub {
	my @shown = Genesis::traced_cli_args(['set'], 'set', '--', "--$secret", '-n');
	is_deeply([@shown[0,1]], ['set', '--'], 'the command and the end of options are shown');
	like($shown[$_], qr/^<redacted:\d+ bytes>$/, "operand $_ is not") for (2,3);
};

subtest 'run hands the child the exact arguments' => sub {
	my @args = Genesis::passthrough_args(['vms'], '--client-secret', "-$secret", "-p$secret", 'vms');
	my ($out) = Genesis::run({public_output => 1}, 'printf "%s\n" "$@"', @args);
	is($out, join("\n", '--client-secret', "-$secret", "-p$secret", 'vms'), 'every argument arrives whole');
};

subtest 'an option Genesis cannot parse is described without its value' => sub {
	Genesis::Commands::define_command('cli-privacy-test', {
		options => ['count=i' => 'A number', 'name=s' => 'A word'],
	});
	my ($log, $stderr, $stdout) = capture_trace {
		exit_code { Genesis::Commands::prepare_command('cli-privacy-test', '--count', $secret) };
	};
	unlike($log.$stderr.$stdout, qr/\Q$secret\E/, 'the log and the usage message hold no part of the value');
	like($log, qr/option --count was given a value of the wrong type/, 'and say what was wrong with which option');
};

subtest 'parser warnings are summarised by kind' => sub {
	my %known = map {($_ => 1)} qw/count c name/;
	is_deeply(
		[Genesis::Commands::_option_warnings(\%known,
			"Value \"$secret\" invalid for option count (number expected)\n",
			"Option name requires an argument\n",
			"Unknown option: $secret\n",
			"Option c does not take an argument\n",
			"Value \"$secret\" invalid for option $secret (number expected)\n",
			"$secret\n",
		)],
		[
			'option --count was given a value of the wrong type',
			'option --name needs a value',
			'an unknown option was given',
			'option -c takes no value',
			'an option was given a value of the wrong type',
			'the options could not be parsed',
		],
		'each warning becomes a fixed phrase, naming only options Genesis knows'
	);
};

done_testing;
