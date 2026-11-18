#!/usr/bin/env perl
# An operator can hand a bash addon a credential as an argument, and an
# addon's help can print expanded configuration values.  The addon gets
# its arguments exactly, but the trace shows each one by its size; help
# text reaches the terminal and never a log file; and an addon whose help
# fails, or whose Perl module dies, is described by how it ended or where
# it died, never by what it said.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Genesis::Helpers;
use Genesis::Kit;
use Genesis::Hook::Addon;

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/$_" for qw/kit kit\/hooks work root/;
Genesis::Helpers->write("$dir/kit/.helper");

# The bash addon writes the arguments it was given, NUL-terminated.
put_file("$dir/kit/hooks/addon", 0755, <<'SH');
#!/bin/bash
printf '%s\0' "$GENESIS_ADDON_SCRIPT" "$@" > "$FAKE_DIR/addon-argv"
exit 0
SH
put_file("$dir/kit/hooks/addon-fake", 0755, <<'SH');
#!/bin/bash
[[ "$1" == help ]] && { echo "Fake help: password is $FAKE_HELP_VALUE"; exit 0; }
SH
put_file("$dir/kit/hooks/addon-failing", 0755, <<'SH');
#!/bin/bash
echo "out: $FAKE_HELP_VALUE"; echo >&2 "err: $FAKE_HELP_VALUE"; exit 4
SH
put_file("$dir/kit/hooks/addon-broken.pm", 0644, <<'PM');
package Genesis::Hook::Addon::Broken;
die "could not use password $ENV{FAKE_HELP_VALUE}";
1;
PM

package FakeEnv {
	sub get_environment_variables { () }
	sub workpath { "$dir/work/$_[1]" }
	sub name { 'fake-env' }
	sub kit { $_[0]->{kit} }
}

sub with_fake_kit (&;%) {
	my ($code, %env) = @_;
	no warnings qw/redefine once/;
	local *Genesis::Kit::id = sub { "fake/1.0.0" };
	local *Genesis::Kit::name = sub { "fake" };
	local *Genesis::Kit::version = sub { "1.0.0" };
	local *Genesis::Kit::path = sub { my $p = $_[1]; $p ? "$dir/kit/$p" : "$dir/kit" };
	local %ENV = (%ENV,
		GENESIS_LIB => "$ENV{GENESIS_TOPDIR}/lib",
		GENESIS_ROOT => "$dir/root", GENESIS_ENVIRONMENT => 'fake-env',
		FAKE_DIR => $dir, %env,
	);
	# Perl will not retry a file that failed to compile, so each attempt
	# starts as the first.
	delete $INC{"$dir/kit/hooks/addon-broken.pm"};
	my $kit = bless({}, 'Genesis::Kit');
	my $env = bless({kit => $kit}, 'FakeEnv');
	return $code->($kit, $env);
}

subtest 'a bash addon gets its arguments exactly, and the trace only their sizes' => sub {
	my $secret = fake_secret('addon-arg');
	my @args = ($secret, '--password', "$secret-2", 'a b', "it's", '$HOME', '');
	my $error;
	my ($log, $stderr) = capture_trace {
		with_fake_kit {
			my ($kit, $env) = @_;
			eval {$kit->run_hook('addon', env => $env, script => 'fake', args => [@args])};
			$error = $@;
		} GENESIS_NO_MODULE_HOOKS => 1;
	};
	is($error, '', 'the addon runs');
	my @got = split(/\0/, slurp("$dir/addon-argv"), -1); pop @got;
	is_deeply(\@got, ['fake', @args], 'the addon gets every argument exactly');
	unlike($log.$stderr, qr/\Q$secret\E/, 'no argument is in the trace');
	like($log, qr/<redacted:\d+ bytes>/, 'which shows each by its size');
};

subtest 'addon help reaches the terminal, never a log' => sub {
	my $value = fake_secret('addon-help');
	my ($log, $stderr) = capture_trace {
		with_fake_kit {
			my ($kit, $env) = @_;
			bless({env => $env, label => 'list'}, 'Genesis::Hook::Addon')->help;
		} FAKE_HELP_VALUE => $value;
	};
	like($stderr, qr/Fake help: password is \Q$value\E/, 'the operator sees the help text');
	unlike($log, qr/\Q$value\E/, 'the log does not hold it');
	like($log, qr/bytes of output withheld from this log/, 'only that it was withheld');
	like($log, qr/fake/, 'and the addon is still named');
};

subtest 'a failing help or a broken module is described, not quoted' => sub {
	my $value = fake_secret('addon-fail');
	my ($log, $stderr) = capture_trace {
		with_fake_kit {
			my ($kit, $env) = @_;
			bless({env => $env, label => 'list'}, 'Genesis::Hook::Addon')->help;
		} FAKE_HELP_VALUE => $value;
	};
	unlike($log, qr/\Q$value\E/, 'neither what the scripts said nor the die is in the log');
	unlike($stderr, qr/(?:out|err): \Q$value\E|could not use password/, 'nor on stderr, where only the working help shows');
	like($log, qr/addon-failing gave no help: its help command exited 4/, 'the failed help is described by its exit');
	like($log, qr{Failed to load hook module\s+\S*addon-broken\.pm:\s+it died at\s+\S*addon-broken\.pm\s+line 2}, 'the broken module by where it died');
	like($log, qr{addon-broken\.pm gave no help: it could not be loaded}, 'and the listing goes on without it');
};

subtest 'a Perl addon that dies while loading is described by where it died' => sub {
	my $value = fake_secret('addon-load');
	my $error;
	my ($log, $stderr) = capture_trace {
		with_fake_kit {
			my ($kit, $env) = @_;
			eval {$kit->run_hook('addon', env => $env, script => 'broken', args => [])};
			$error = $@;
		} FAKE_HELP_VALUE => $value;
	};
	like($error, qr{Could not load Perl module .*addon-broken\.pm.*it died at\s+\S*addon-broken\.pm line 2}s, 'the error says where it died');
	unlike($error.$log.$stderr, qr/\Q$value\E/, 'and not what it said');
};

done_testing;
