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

require Genesis::Commands::Bosh;
require Service::Credhub;
my $bosh    = $Genesis::Commands::Bosh::BOSH_ARGS;
my $credhub = $Service::Credhub::CREDHUB_ARGS;
my $R = qr/^<redacted:\d+ bytes>$/;

subtest 'with nothing known, every word shows only its length' => sub {
	my @shown = Genesis::traced_cli_args({}, '--client-secret', "-$secret", 'vms', '-n');
	like($shown[$_], $R, "word $_ is hidden") for 0..3;
};

subtest 'a hyphenated value after a known option shows only its length' => sub {
	my @shown = Genesis::traced_cli_args($bosh, '--client-secret', "-$secret", 'vms');
	is($shown[0], '--client-secret', 'the option is shown');
	like($shown[1], $R, 'its value, though it looks like a flag, is not');
	is($shown[2], 'vms', 'and the command after it is');
	unlike(join(' ', @shown), qr/\Q$secret\E/, 'the value appears nowhere');
};

subtest 'a value attached to a known short option shows only its length' => sub {
	my @shown = Genesis::traced_cli_args($credhub, 'set', "-w$secret", '-j');
	like($shown[1], qr/^-w<redacted:\d+ bytes>$/, 'the option letter stays in view');
	is($shown[2], '-j', 'and a known flag after it is shown');
	unlike(join(' ', @shown), qr/\Q$secret\E/, 'the value appears nowhere');
};

subtest 'a known word out of its place shows only its length' => sub {
	# A credential can be spelled like a command or a flag, so only its
	# place decides whether a word is shown.
	my @shown = Genesis::traced_cli_args($bosh, '-d', 'deploy', 'vms', 'deploy', '-e', '--json');
	like($shown[1], $R, 'a command name as an option\'s value is hidden');
	is($shown[2], 'vms', 'the first operand is the command');
	like($shown[3], $R, 'a command name as a later operand is hidden');
	is($shown[4], '-e', 'a known option is shown');
	like($shown[5], $R, 'and a flag as its value is hidden');
	@shown = Genesis::traced_cli_args($credhub, 'get', '-n', '-j');
	like($shown[2], $R, 'a credhub flag as the value of -n is hidden');
};

subtest 'an unknown option hides itself and everything after it' => sub {
	my @shown = Genesis::traced_cli_args($bosh, 'vms', '--made-up', '--json', '-n');
	is($shown[0], 'vms', 'the command before it is shown');
	like($shown[$_], $R, "word $_ is hidden") for 1..3;
	@shown = Genesis::traced_cli_args($bosh, "-nX$secret", '--json');
	like($shown[$_], $R, "a bundle with an unknown letter hides word $_") for 0..1;
};

subtest 'an unknown option with its value attached is hidden alone' => sub {
	# Its value is attached, so the next word cannot be its value.
	my @shown = Genesis::traced_cli_args($bosh, "--made-up=$secret", 'vms', '--json');
	like($shown[0], $R, 'the option is hidden whole');
	is_deeply([@shown[1,2]], ['vms', '--json'], 'and the words after it stay placed');
	@shown = Genesis::traced_cli_args($bosh, "--deployment=$secret", 'vms');
	like($shown[0], qr/^--deployment=<redacted:\d+ bytes>$/, 'a known option keeps its name');
};

subtest 'a list in place of a spec names commands and flags' => sub {
	my @shown = Genesis::traced_cli_args(['vms', '--json'], '--json', 'vms', '--details');
	is_deeply([@shown[0,1]], ['--json', 'vms'], 'listed words are shown in their places');
	like($shown[2], $R, 'and an unlisted flag is not');
};

subtest 'bosh and credhub options keep their values hidden' => sub {
	my @shown = Genesis::traced_cli_args($bosh,
		'-n', '--json', 'deploy', '--fix', '--recreate', '--dry-run', '-d', "-$secret");
	is_deeply([@shown[0..6]], ['-n', '--json', 'deploy', '--fix', '--recreate', '--dry-run', '-d'], 'bosh flags are shown');
	like($shown[7], $R, 'and the value of -d is not');
	@shown = Genesis::traced_cli_args($credhub, 'find', '-j', '-n', "-$secret");
	is_deeply([@shown[0..2]], ['find', '-j', '-n'], 'credhub flags are shown');
	like($shown[3], $R, 'and the value of -n is not');
};

subtest 'every operand after a bare -- shows only its length' => sub {
	my @shown = Genesis::traced_cli_args(['set'], 'set', '--', "--$secret", '-n');
	is_deeply([@shown[0,1]], ['set', '--'], 'the command and the end of options are shown');
	like($shown[$_], $R, "operand $_ is not") for (2,3);
};

subtest 'Getopt::Long specs give the flags and the options that take values' => sub {
	my $words = Genesis::getopt_spec_words('name|n=s', 'force|f', 'color!', 'count:i', 'v+');
	is_deeply([sort @{$words->{options}}], [sort qw/--name -n --count/], 'options with = or : take a value');
	is_deeply([sort @{$words->{flags}}], [sort qw/--force -f --color --no-color --nocolor -v/], 'and the rest do not');
};

subtest 'run hands the child the exact arguments' => sub {
	my @args = Genesis::passthrough_args($bosh, '--client-secret', "-$secret", "-p$secret", 'vms');
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

subtest 'the log header shows the command\'s own options in their places' => sub {
	Genesis::Commands::define_command('cli-header-test', {
		options => ['name|N=s' => 'A word', 'force' => 'A flag'],
	});
	capture_trace { Genesis::Commands::prepare_command('cli-header-test', '--name', '--force', '--force', 'force', "-N$secret") };
	my $call = $ENV{GENESIS_FULL_CALL};
	unlike($call, qr/\Q$secret\E/, 'no value is in the header');
	like($call, qr/cli-header-test --name <redacted:7 bytes> --force <redacted:5 bytes> -N<redacted:\d+ bytes>$/,
		'options show where they stand, and values and operands by length');
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
