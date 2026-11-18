#!/usr/bin/env perl
# An interactive bosh command runs under `script` so that bosh sees a
# terminal, and on Linux `script -c` takes the whole command as one shell
# string.  A credential wrapped as {redact => $value} must reach bosh as
# the value itself, in its own argument, and stay out of the trace.  Each
# test checks the argv a fake bosh actually receives.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Service::BOSH;

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/bin";

# The fake bosh writes each argument it receives on its own line.
put_file("$dir/bin/bosh", 0755, <<"EOS");
#!/bin/bash
for a in "\$@"; do printf '%s\\n' "\$a"; done > "$dir/argv"
exit 0
EOS

# The fake script follows the real one's calling conventions on each OS:
# Linux takes `-qef -c 'shell string' FILE`, macOS takes `-q FILE cmd...`.
put_file("$dir/bin/script", 0755, <<'EOS');
#!/bin/bash
if [[ $1 == -qef ]]; then
	/bin/bash -c "$3"
else
	shift 2
	"$@"
fi
EOS
$ENV{PATH} = "$dir/bin:$ENV{PATH}";
Service::BOSH->set_command("$dir/bin/bosh");

for my $os (qw/linux darwin/) {
	subtest "interactive bosh on $os gets the exact arguments" => sub {
		my $value = fake_secret("bosh-$os");
		unlink "$dir/argv";
		my $log = capture_trace {
			local $^O = $os;
			bless({}, 'Service::BOSH')->execute(
				{interactive => 1},
				'update-config', '--name', "it's spaced", {redact => $value}
			);
		};
		is(Genesis::slurp("$dir/argv"), join("\n", 'update-config', '--name', "it's spaced", $value)."\n",
			'bosh receives each argument whole, with the wrapped value unwrapped');
		unlike($log, qr/\Q$value\E/, 'the value is absent from the trace');
		like($log, qr/<redacted:\d+ bytes>/, 'the trace marks where it was');
	};
}

subtest "pty_command on linux carries a wrapped argument as its value" => sub {
	my $value = fake_secret("pty");
	local $^O = "linux";
	my @cmd = pty_command("spruce", "diff", {redact => $value});
	is(ref($cmd[3]), "HASH", "the -c command is wrapped");
	is($cmd[3]{redact}, "'spruce' 'diff' '$value'", "its value is the real command");
	unlike($cmd[3]{display}, qr/\Q$value\E/, "its display form leaves the value out");
	is($cmd[4], '/dev/null', 'and no typescript is written');
};

subtest "fake_tty on linux carries a wrapped argument as its value" => sub {
	my $value = fake_secret("tty");
	local $^O = "linux";
	my @cmd = fake_tty("$dir/out", "spruce", "diff", {redact => $value});
	is(ref($cmd[-1]), "HASH", "the -c command is wrapped");
	is($cmd[-1]{redact}, "'spruce' 'diff' '$value'", "its value is the real command");
	unlike($cmd[-1]{display}, qr/\Q$value\E/, "its display form leaves the value out");
};

done_testing;
