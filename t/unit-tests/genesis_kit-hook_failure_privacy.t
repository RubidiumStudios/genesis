#!/usr/bin/env perl
# A Bash hook's stdout goes back to Genesis to be parsed, and it can carry
# credential values, such as the vault values a hook reads.  It stays out
# of the trace, and a hook that fails is described by how it ended, never
# by what it printed.  A hook killed by a signal fails, and says so.
#
# GENESIS_HOOK_XTRACE is deliberately left as it is: an operator who sets
# it is warned every time, and the trace goes to the terminal only (see
# genesis_kit-hook_tracing.t).
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

# Each hook prints the made-up value from its environment, which run()
# does not trace, and then ends the way the test asks.
for my $hook (qw/blueprint features info pre-deploy/) {
	put_file("$dir/kit/hooks/$hook", 0755, <<'EOF_HOOK');
#!/bin/bash
echo "manifests/base.yml"
echo "password: $FAKE_HOOK_VALUE"
case "${FAKE_HOOK_END:-}" in
	fail)   exit 3 ;;
	signal) kill -TERM $$ ;;
	parent) kill -TERM $PPID; sleep 1; exit 0 ;;
esac
exit 0
EOF_HOOK
}

package FakeEnv {
	sub get_environment_variables { () }
	sub workpath { "$dir/work/$_[1]" }
	sub name { 'fake-env' }
}

sub run_fake_hook {
	my ($hook, $end, %opts) = @_;
	my $value = fake_secret("hook-$hook");
	no warnings qw/redefine once/;
	local *Genesis::Kit::has_hook = sub { 1 };
	local *Genesis::Kit::id = sub { "fake/1.0.0" };
	local *Genesis::Kit::name = sub { "fake" };
	local *Genesis::Kit::version = sub { "1.0.0" };
	local *Genesis::Kit::path = sub { my $p = $_[1]; $p ? "$dir/kit/$p" : "$dir/kit" };
	local %ENV = (%ENV,
		GENESIS_LIB => "$ENV{GENESIS_TOPDIR}/lib",
		GENESIS_ROOT => "$dir/root",
		GENESIS_ENVIRONMENT => 'fake-env',
		GENESIS_NO_MODULE_HOOKS => 1,
		FAKE_HOOK_VALUE => $value,
		FAKE_HOOK_END => $end,
	);
	my (@result, $error);
	my ($log, $stderr, $stdout) = capture_trace {
		@result = eval { bless({}, 'Genesis::Kit')->run_hook($hook, env => bless({}, 'FakeEnv'), %opts) };
		$error = $@;
	};
	return {value => $value, result => \@result, error => $error // '', log => $log, stderr => $stderr};
}

for my $hook (qw/blueprint features info pre-deploy/) {
	my %opts = $hook eq 'features' ? (features => ['base']) : ();
	subtest "a $hook hook's stdout stays out of the trace" => sub {
		my $r = run_fake_hook($hook, '', %opts);
		is($r->{error}, '', 'the hook succeeds');
		unlike($r->{log}, qr/\Q$r->{value}\E/, 'the trace does not hold what it printed');
		# An interactive hook prints straight to the terminal, so there is
		# nothing captured to measure.
		like($r->{log}, qr/\[\d+b of redacted data omitted from debug\]/, 'only its size')
			if $hook =~ /^(blueprint|features)$/;
	};

	subtest "a failed $hook hook is described without its output" => sub {
		my $r = run_fake_hook($hook, 'fail', %opts);
		isnt($r->{error}, '', 'the hook fails');
		unlike($r->{error}, qr/\Q$r->{value}\E|manifests\/base\.yml/, 'the error does not quote its output');
		like($r->{error}, qr/exited 3/, 'and gives its exit code');
		unlike($r->{log}.$r->{stderr}, qr/\Q$r->{value}\E/, 'nor do the trace or stderr');
	};
}

my @deploy_files = (manifest => "$dir/manifest.yml", vars_file => "$dir/vars.yml");
subtest 'a pre-deploy hook killed by a signal stops the deployment' => sub {
	my $r = run_fake_hook('pre-deploy', 'signal', @deploy_files);
	isnt($r->{error}, '', 'the hook fails');
	like($r->{error}, qr/ended with status 143, as it does when killed by signal 15/, 'and the error names the signal');
	unlike($r->{error}.$r->{log}, qr/\Q$r->{value}\E/, 'without quoting its output');
};

subtest 'a pre-deploy hook whose shell is killed stops the deployment' => sub {
	# The hook itself exits 0, but the shell Genesis ran it in is killed,
	# which once read as success.
	my $r = run_fake_hook('pre-deploy', 'parent', @deploy_files);
	isnt($r->{error}, '', 'the hook fails');
	like($r->{error}, qr/killed by signal 15/, 'and the error names the signal');
};

done_testing;
