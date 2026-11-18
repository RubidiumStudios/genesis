#!/usr/bin/env perl
# An operator can hand a credential to Genesis on the command line, most
# often as an operand passed through to bosh or credhub.  Genesis has not
# seen such a value before, so the scrubber cannot know it, and the
# command line has to be kept out of the logs by construction: the log
# header, the argument traces, the usage error, and the bosh and credhub
# command traces show flags and command names, and every other operand
# only as its length.  The child process still gets every argument whole.
use strict;
use warnings;

BEGIN { *CORE::GLOBAL::exit = sub { die sprintf("EXIT %d\n", $_[0] // 0) } }

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;
use Cwd qw/getcwd/;

use Genesis;
use Genesis::Commands;
use Genesis::Commands::Bosh;
use Service::BOSH;
use Service::Credhub;

my $root = getcwd;
my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/bin";
for my $name (qw/bosh credhub/) {
	put_file("$dir/bin/$name", 0755, <<"EOS");
#!/bin/bash
for a in "\$@"; do printf '%s\\n' "\$a"; done > "$dir/argv-$name"
exit 0
EOS
}
# script(1) on Linux takes `-qef -c 'shell string' FILE`, and on macOS
# `-q FILE cmd...`; Genesis sends the typescript to /dev/null.
put_file("$dir/bin/script", 0755, <<'EOS');
#!/bin/bash
if [[ $1 == -qef ]]; then
	/bin/bash -c "$3"
else
	shift 2
	"$@"
fi
EOS
my $system_path = $ENV{PATH};
$ENV{PATH} = "$dir/bin:$ENV{PATH}";

sub received { my $f = "$dir/argv-$_[0]"; my $got = -f $f ? Genesis::slurp($f) : ''; unlink $f; $got }

# genesis - run bin/genesis with a TRACE file log; returns (log, terminal)
sub genesis {
	my @args = @_;
	my $home = tempdir(CLEANUP => 1);
	mkdir "$home/.genesis";
	put_file("$home/.genesis/config", 0644, "logs:\n- file: $home/trace.log\n  level: TRACE\n");
	my $work = tempdir(CLEANUP => 1);
	my $pid = open(my $fh, '-|') // die "cannot fork: $!";
	unless ($pid) {
		open STDERR, '>&', \*STDOUT;
		chdir $work;
		local $ENV{HOME} = $home;
		local $ENV{PATH} = $system_path;
		delete @ENV{qw/GENESIS_LIB GENESIS_CALLBACK_BIN GENESIS_TRACE GENESIS_DEBUG GENESIS_TESTING/};
		exec $^X, "-I$root/lib", "$root/bin/genesis", @args;
		die "cannot exec: $!";
	}
	my $terminal = do {local $/; <$fh>};
	close $fh;
	my $log = -f "$home/trace.log" ? Genesis::slurp("$home/trace.log") : '';
	return ($log, $terminal);
}

subtest 'bosh passthrough operands stay out of the CLI traces' => sub {
	my ($flag_value, $operand) = map {fake_secret("cli-bosh-$_")} qw/flag operand/;
	my ($log, $terminal) = genesis('bosh', "--client-secret=$flag_value", $operand);
	unlike($log, qr/\Q$flag_value\E|\Q$operand\E/, 'neither value is in the log');
	unlike($terminal, qr/\Q$flag_value\E|\Q$operand\E/, 'nor on the terminal');
	like($log, qr/'<redacted:\d+ bytes>'/, 'each is shown by length');
};

subtest 'a usage error leaves the operands out' => sub {
	my $operand = fake_secret('cli-usage');
	my ($log, $terminal) = genesis('lookup', $operand);
	like($terminal, qr/was\s+called\s+incorrectly/, 'the usage error is reported');
	unlike($log, qr/\Q$operand\E/, 'the operand is absent from the log');
	unlike($terminal, qr/\Q$operand\E/, 'and from the terminal');
	like($log, qr/lookup\s+<redacted:\d+\s+bytes>/, 'the command and the operand\'s place are shown');
};

subtest 'the log header leaves the operands out' => sub {
	my $operand = fake_secret('cli-header');
	my $pid = open(my $fh, '-|') // die "cannot fork: $!";
	unless ($pid) {
		$ENV{HOME} = $dir;
		exec $^X, "-I$root/lib", '-MGenesis::Config', '-MGenesis', '-e', 'Genesis::Init(); print $ENV{GENESIS_FULL_CALL}',
			'credhub', 'fake-env', 'set', '-w', $operand;
		die "cannot exec: $!";
	}
	my $call = do {local $/; <$fh>};
	close $fh;
	unlike($call, qr/\Q$operand\E/, 'the operand is absent from the command line a log header shows');
	# Before the command is known, no word's place is, so every word is
	# shown by length; prepare_command names the command and its options.
	like($call, qr/(?: <redacted:\d+ bytes>){5}$/, 'every word is shown by length');
	my $log = capture_trace { local $ENV{GENESIS_FULL_CALL} = $call; Genesis::info("anything") };
	like($log, qr/^Command: .*(?: <redacted:\d+ bytes>){5}$/m, 'and the header is built from it');
};

subtest 'credhub passthrough reaches credhub whole and the trace redacted' => sub {
	my $value = fake_secret('cli-credhub');
	my $credhub = bless({
		name => 'fake', base => '/fake/', url => 'https://10.0.0.6:8844',
		username => 'credhub-admin', password => 'not-under-test', ca_cert => 'ca',
	}, 'Service::Credhub');
	received('credhub');
	my $log = capture_trace { $credhub->execute('set', '-n', '/fake/x', '-t', 'password', '-w', $value, "--password=$value") };
	is(received('credhub'), join("\n", 'set', '-n', '/fake/x', '-t', 'password', '-w', $value, "--password=$value")."\n",
		'credhub receives every argument whole');
	unlike($log, qr/\Q$value\E/, 'the value is absent from the trace');
	like($log, qr/1: 'set'\s+2: '-n'\s+3: '<redacted:\d+ bytes>'/, 'the command and flags stay in view');
	like($log, qr/--password=<redacted:\d+ bytes>/, 'with a flag\'s own value redacted');
};

subtest 'bosh passthrough reaches bosh whole and the trace redacted' => sub {
	my $value = fake_secret('cli-bosh-dump');
	no warnings qw/redefine once/;
	my $bosh = bless({alias => 'fake'}, 'Service::BOSH');
	Service::BOSH->set_command("$dir/bin/bosh");
	local *Genesis::Top::new = sub { bless({}, 'FakeTop') };
	local *FakeTop::load_env = sub { bless({}, 'FakeEnv') };
	local *FakeEnv::with_vault = sub { $_[0] };
	local *FakeEnv::get_target_bosh = sub { $bosh };
	local $Genesis::Commands::COMMAND_OPTIONS = {};
	received('bosh');
	my $log = capture_trace {
		eval { Genesis::Commands::Bosh::bosh('fake-env', 'update-config', '--type=cloud', $value); 1 }
	};
	is(received('bosh'), join("\n", 'update-config', '--type=cloud', $value)."\n", 'bosh receives every argument whole');
	unlike($log, qr/\Q$value\E/, 'the value is absent from the trace');
	like($log, qr/update-config/, 'the bosh command stays in view');
};

done_testing;
