#!/usr/bin/env perl
# The cloud-config, cpi-config, and runtime-config hooks build configs that
# hold IaaS and director credentials, and the messages a kit writes when
# one fails, or the exception it dies with, can quote them.  The logger
# gets a fixed kind of failure and which config it was, and the kit's own
# words go only to a terminal, as private detail.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Genesis::Kit;
use Genesis::Hook::CpiConfig;
use Genesis::Hook::RuntimeConfig;

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/kit";
mkdir "$dir/kit/hooks";
mkdir "$dir/work";

# Each module hook dies with the value its environment hands it, in the
# step FAKE_DIE_IN names: its initializer, its check for cached results,
# its perform, or its results.  Perform bails, as kit code usually does,
# and the others die as Perl does.
for my $hook (qw/cloud-config cpi-config runtime-config/) {
	my $pkg = join('', map {ucfirst} split(/-/, $hook)) =~ s/Config$/ConfigFake/r;
	put_file("$dir/kit/hooks/$hook.pm", 0644, <<EOF_HOOK);
package Genesis::Hook::$pkg;
use strict;
use warnings;
use Genesis;
sub dies_in { (\$ENV{FAKE_DIE_IN} // 'perform') eq \$_[0] }
sub init {
	my (\$class, \%opts) = \@_;
	die "could not read the api key \$ENV{FAKE_HOOK_VALUE}\\n" if dies_in('init');
	bless({\%opts}, \$class)
}
sub completed { die "could not read the api key \$ENV{FAKE_HOOK_VALUE}\\n" if dies_in('completed'); 0 }
sub perform { bail("could not read the api key %s", \$ENV{FAKE_HOOK_VALUE}) if dies_in('perform'); 1 }
sub results { die "could not read the api key \$ENV{FAKE_HOOK_VALUE}\\n" if dies_in('results'); undef }
1;
EOF_HOOK
}

package FakeEnv {
	sub get_environment_variables { () }
	sub workpath { "$dir/work/$_[1]" }
	sub workdir { "$dir/work" }
	sub name { 'fake-env' }
}

my $note = qr/<\d+ bytes of detail withheld because this output is not a terminal>/;

sub run_module_hook {
	my ($hook, $tty, %opts) = @_;
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
		FAKE_HOOK_VALUE => $value,
	);
	delete $ENV{GENESIS_CLOUD_CONFIG_SUBTYPE};
	delete $ENV{GENESIS_NO_MODULE_HOOKS};
	my $error;
	my ($log, $stderr) = capture_trace {
		eval { bless({}, 'Genesis::Kit')->run_hook($hook, env => bless({}, 'FakeEnv'), %opts); 1 };
		$error = $@;
	};
	return {value => $value, error => $error // '', log => $log, stderr => $stderr};
}

for my $hook (qw/cloud-config cpi-config runtime-config/) {
	subtest "a $hook hook that dies is described by its kind of failure" => sub {
		my $r = run_module_hook($hook, 0);
		isnt($r->{error}, '', 'the hook still fails');
		like($r->{error}, qr/\Q$hook\E/, 'the error names the config hook');
		like($r->{error}, qr/no known kind of failure/, 'and gives its kind of failure');
		unlike($r->{error}, qr/\Q$r->{value}\E/, 'without the kit\'s words');
		unlike($r->{log}, qr/\Q$r->{value}\E/, 'the trace does not get them');
		unlike($r->{stderr}, qr/\Q$r->{value}\E/, 'nor does a redirected stderr');
		like($r->{stderr}, $note, 'which gets a note that detail was withheld');
	};

	subtest "a $hook hook that dies shows why on a terminal" => sub {
		my $r = run_module_hook($hook, 1);
		like($r->{stderr}, qr/could not read the api key \Q$r->{value}\E/, 'the terminal shows the kit\'s words');
		unlike($r->{log}, qr/\Q$r->{value}\E/, 'and the trace still does not');
	};

	for my $step (qw/init completed results/) {
		subtest "a $hook hook that dies in its $step step is described by its kind" => sub {
			local $ENV{FAKE_DIE_IN} = $step;
			my $r = run_module_hook($hook, 0);
			like($r->{error}, qr/Could not synthesize a config with the \S*\Q$hook\E\S* hook/, 'the hook fails with the fixed message');
			unlike($r->{error}.$r->{log}.$r->{stderr}, qr/\Q$r->{value}\E/,
				'and neither the error, the trace, nor a redirected stderr gets the kit\'s words');
			like($r->{stderr}, $note, 'which gets a note that detail was withheld');

			$r = run_module_hook($hook, 1);
			like($r->{stderr}, qr/could not read the api key \Q$r->{value}\E/, 'a terminal shows the kit\'s words');
			unlike($r->{error}.$r->{log}, qr/\Q$r->{value}\E/, 'and the error and the trace still do not');
		};
	}
}

subtest 'a cpi-config error the kit reports is a kind of failure' => sub {
	my $value = fake_secret('cpi-error');
	no warnings qw/redefine once/;
	local *Genesis::Log::_is_terminal = sub { 0 };
	my $hook = bless({env => bless({}, 'FakeEnv')}, 'Genesis::Hook::CpiConfig');
	my ($log, $stderr) = capture_trace { $hook->done(undef, "bad api_key: $value") };
	my $results = $hook->results;
	ok($results->{error}, 'the results still report an error');
	unlike($results->{error}, qr/\Q$value\E/, 'which does not quote the kit\'s words');
	like($results->{error}, qr/no known kind of failure/, 'and gives its kind of failure');
	unlike($log.$stderr, qr/\Q$value\E/, 'and neither the trace nor a redirected stderr gets them');

	local *Genesis::Log::_is_terminal = sub { 1 };
	$hook = bless({env => bless({}, 'FakeEnv')}, 'Genesis::Hook::CpiConfig');
	($log, $stderr) = capture_trace { $hook->done(undef, "bad api_key: $value") };
	like($stderr, qr/bad api_key: \Q$value\E/, 'a terminal shows them');
	unlike($log, qr/\Q$value\E/, 'and the trace still does not');
};

package TestRuntime {
	our @ISA = ('Genesis::Hook::RuntimeConfig');
	sub failing { (undef, 'failed', "could not read $ENV{FAKE_RC_VALUE}") }
	sub skipping { (undef, 'skipped', "nothing at $ENV{FAKE_RC_VALUE}") }
}

for my $case (qw/failed skipped/) {
	subtest "a runtime config that is $case is described without the kit's words" => sub {
		my $value = fake_secret("runtime-$case");
		local $ENV{FAKE_RC_VALUE} = $value;
		no warnings qw/redefine once/;
		local *Genesis::Log::_is_terminal = sub { 0 };
		my $rc = bless({builds => {dns => {
			method => ($case eq 'failed' ? 'failing' : 'skipping'), description => 'DNS'
		}}}, 'TestRuntime');
		my ($log, $stderr) = capture_trace { $rc->build('dns') };
		like($stderr, qr/\bdns\b/, 'the operator learns which config it was');
		unlike($log.$stderr, qr/\Q$value\E/, 'and neither the trace nor a redirected stderr gets the kit\'s words');

		local *Genesis::Log::_is_terminal = sub { 1 };
		($log, $stderr) = capture_trace { $rc->build('dns') };
		like($stderr, qr/\Q$value\E/, 'a terminal shows them');
		unlike($log, qr/\Q$value\E/, 'and the trace still does not');
	};
}

done_testing;
