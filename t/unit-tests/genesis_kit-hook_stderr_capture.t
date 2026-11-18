#!/usr/bin/env perl
# The blueprint, features, cloud-config, and cpi-config hooks run with no
# terminal, and Genesis parses their stdout.  What they print on stderr can
# quote the values they handled, so it is kept in memory and shown as
# private detail: a terminal shows it as printed, and a redirected stderr,
# such as a CI log, gets a note that it was withheld.  A failed hook is
# described by its kind of failure there.
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

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/kit";
mkdir "$dir/kit/hooks";
mkdir "$dir/work";
Genesis::Helpers->write("$dir/kit/.helper");

my @hooks = qw/blueprint features cloud-config cpi-config/;
for my $hook (@hooks) {
	put_file("$dir/kit/hooks/$hook", 0755, <<'EOF_HOOK');
#!/bin/bash
echo "manifests/base.yml"
echo "warning: using $FAKE_HOOK_VALUE" >&2
[[ "${FAKE_HOOK_END:-}" == "fail" ]] && exit 3
exit 0
EOF_HOOK
}

package FakeEnv {
	sub get_environment_variables { () }
	sub workpath { "$dir/work/$_[1]" }
	sub name { 'fake-env' }
}

sub run_fake_hook {
	my ($hook, $end, $tty) = @_;
	my $value = fake_secret("hook-$hook");
	no warnings qw/redefine once/;
	local *Genesis::Kit::has_hook = sub { 1 };
	local *Genesis::Kit::id = sub { "fake/1.0.0" };
	local *Genesis::Kit::name = sub { "fake" };
	local *Genesis::Kit::version = sub { "1.0.0" };
	local *Genesis::Kit::path = sub { my $p = $_[1]; $p ? "$dir/kit/$p" : "$dir/kit" };
	local *Genesis::Log::_is_terminal = sub { $tty ? 1 : 0 };
	local %ENV = (%ENV,
		GENESIS_LIB => "$ENV{GENESIS_TOPDIR}/lib",
		GENESIS_ROOT => "$dir/root",
		GENESIS_ENVIRONMENT => 'fake-env',
		GENESIS_NO_MODULE_HOOKS => 1,
		FAKE_HOOK_VALUE => $value,
		FAKE_HOOK_END => $end,
	);
	my %opts = $hook eq 'features' ? (features => ['base']) : ();
	my $error;
	my ($log, $stderr) = capture_trace {
		eval { bless({}, 'Genesis::Kit')->run_hook($hook, env => bless({}, 'FakeEnv'), %opts) };
		$error = $@;
	};
	return {value => $value, error => $error // '', log => $log, stderr => $stderr};
}

my $note = qr/<\d+ bytes of detail withheld because this output is not a terminal>/;
for my $hook (@hooks) {
	subtest "a $hook hook's stderr is withheld off a terminal" => sub {
		my $r = run_fake_hook($hook, '', 0);
		is($r->{error}, '', 'the hook succeeds');
		unlike($r->{stderr}, qr/\Q$r->{value}\E/, 'what it printed on stderr does not reach a redirected stderr');
		like($r->{stderr}, $note, 'a note says it was withheld');
		unlike($r->{log}, qr/\Q$r->{value}\E/, 'and the log does not hold it');
	};

	subtest "a failed $hook hook is summarized off a terminal" => sub {
		my $r = run_fake_hook($hook, 'fail', 0);
		isnt($r->{error}, '', 'the hook fails');
		like($r->{error}, qr/exited 3/, 'the error gives its exit code');
		like($r->{error}, qr/no known kind of failure/, 'and its kind of failure');
		unlike($r->{error}.$r->{stderr}.$r->{log}, qr/\Q$r->{value}\E/, 'and nothing quotes what it printed');
	};

	subtest "a $hook hook's stderr is shown on a terminal" => sub {
		my $r = run_fake_hook($hook, 'fail', 1);
		like($r->{stderr}, qr/warning: using \Q$r->{value}\E/, 'the terminal shows what it printed');
		unlike($r->{log}, qr/\Q$r->{value}\E/, 'and the log still does not hold it');
	};
}

done_testing;
