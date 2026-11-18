#!/usr/bin/env perl
# A Bash hook runs with the environment Genesis gives it, credentials
# included, and with the values it reads from vault.  Tracing a command
# at TRACE level must not write any of those into the hook's stderr or a
# log file: the helper names the variables without their values, the
# hook is not run under `set -x`, and the bosh helper does not echo its
# arguments.  An operator who wants a hook's xtrace sets
# GENESIS_HOOK_XTRACE, which warns each time and sends the trace only to
# the controlling terminal.  The hook's stdout still reaches the caller,
# and the commands it runs still get their exact arguments.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Genesis::Log;
use Genesis::Helpers;
use Genesis::Kit;

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/bin";
mkdir "$dir/kit";
mkdir "$dir/kit/hooks";
put_file("$dir/bin/bosh", 0755, join("\n",
	'#!/bin/bash',
	qq(for a in "\$@"; do printf '%s\\n' "\$a"; done >> "$dir/argv-bosh"),
	'exit 0', ''));
# The fake CredHub says the name does not exist until it has been written,
# and then answers the read-back the move makes before it deletes
# anything, with its one version when asked for versions.  It records
# only the arguments of the write.
put_file("$dir/bin/credhub", 0755, join("\n",
	'#!/bin/bash',
	qq([[ \$1 == get && ! -f "$dir/argv-credhub" ]] && { echo >&2 'The request could not be completed because the credential does not exist or you do not have sufficient authorization.'; exit 1; }),
	q([[ $1 == get ]] && exec perl -MJSON::PP -e 'my $v = {type => "value", value => $ENV{FAKE_VAULT_VALUE}}; print encode_json((grep {/^--versions=/} @ARGV) ? {versions => [$v]} : $v)' -- "$@"),
	qq(for a in "\$@"; do printf '%s\\n' "\$a"; done >> "$dir/argv-credhub"),
	'exit 0', ''));
put_file("$dir/bin/safe", 0755, join("\n",
	'#!/bin/bash',
	qq(for a in "\$@"; do printf '%s\\n' "\$a"; done >> "$dir/argv-safe"),
	'[[ $1 == get && -n "${FAKE_SAFE_GET_FAILS:-}" ]] && exit 1',
	'[[ $1 == get ]] && printf "%s\n" "$FAKE_VAULT_VALUE"',
	'exit 0', ''));
put_file("$dir/kit/hooks/info", 0755, <<'EOF_HOOK');
#!/bin/bash
set -eu
[[ -n "${FAKE_NO_ERREXIT:-}" ]] && set +e
echo "hook-stdout-marker"
move_secrets_to_credhub "fake/path:password" "fake/password"
bosh -d fake update-config --var "password=$FAKE_HOOK_TOKEN"
echo "hook-finished-marker"
EOF_HOOK
Genesis::Helpers->write("$dir/kit/.helper");

sub received {
	my ($name) = @_;
	my $file = "$dir/argv-$name";
	return '' unless -f $file;
	my $got = slurp($file);
	unlink $file;
	return $got;
}

# Runs the hook with fd 1 and 2 sent to files, so the hook's own streams
# are what the test reads, and with a TRACE file log.
sub run_info_hook {
	my (%env) = @_;
	my ($vault_value, $token) = (fake_secret('hook-vault-value'), fake_secret('hook-env-token'));
	my ($out_file, $err_file, $log_file) = map {"$dir/$_"} qw/stdout stderr trace.log/;
	unlink $_ for ($out_file, $err_file, $log_file, "$dir/kit/hooks/info-trace");
	no warnings qw/redefine once/;
	local *Genesis::Kit::has_hook = sub { 1 };
	local *Genesis::Kit::id = sub { "fake/1.0.0" };
	local *Genesis::Kit::name = sub { "fake" };
	local *Genesis::Kit::version = sub { "1.0.0" };
	local *Genesis::Kit::path = sub { my $p = $_[1]; $p ? "$dir/kit/$p" : "$dir/kit" };
	local *FakeEnv::get_environment_variables = sub { (FAKE_HOOK_TOKEN => $token) };
	local %ENV = (%ENV,
		PATH => "$dir/bin:$ENV{PATH}",
		GENESIS_LIB => "$ENV{GENESIS_TOPDIR}/lib",
		GENESIS_SECRETS_BASE => '/secret/fake/',
		GENESIS_CREDHUB_ROOT => 'fake-bosh/fake',
		BOSH_ENVIRONMENT => 'https://10.0.0.4:25555',
		BOSH_CA_CERT => 'fake-ca',
		BOSH_ALIAS => 'fake-bosh',
		GENESIS_BOSH_VERIFIED => 'fake-bosh',
		GENESIS_BOSH_COMMAND => "$dir/bin/bosh",
		GENESIS_ROOT => "$dir/root",
		GENESIS_ENVIRONMENT => 'fake-env',
		SAFE_TARGET => 'fake-vault',
		GENESIS_TARGET_VAULT => 'fake-vault',
		FAKE_VAULT_VALUE => $vault_value,
		GENESIS_TRACE => 'y',
		HOME => $dir,
		%env,
	);
	delete $ENV{$_} for grep {!defined $ENV{$_}} keys %ENV;
	local $Genesis::Log::Logger = undef;
	local %Genesis::Log::SECRETS = ();
	local $Genesis::Log::SECRET_PATTERN = undef;
	my $logger = Genesis::Log->new;
	$logger->configure_log(level => 'TRACE');
	$logger->configure_log($log_file, level => 'TRACE');

	open my $saved_out, '>&', \*STDOUT or die "cannot save stdout: $!";
	open my $saved_err, '>&', \*STDERR or die "cannot save stderr: $!";
	open STDOUT, '>', $out_file or die "cannot redirect stdout: $!";
	open STDERR, '>', $err_file or die "cannot redirect stderr: $!";
	my $ok = eval { bless({}, 'Genesis::Kit')->run_hook('info', env => bless({}, 'FakeEnv')); 1 };
	my $error = $@;
	open STDOUT, '>&', $saved_out or die "cannot restore stdout: $!";
	open STDERR, '>&', $saved_err or die "cannot restore stderr: $!";
	$logger->_flush_buffer if $logger->can('_flush_buffer');
	undef $logger;
	return {
		ok => $ok, error => $error, vault_value => $vault_value, token => $token,
		stdout => slurp($out_file), stderr => slurp($err_file),
		log => (-f $log_file ? slurp($log_file) : ''),
		traced_hook => (-f "$dir/kit/hooks/info-trace" ? slurp("$dir/kit/hooks/info-trace") : undef),
		credhub => received('credhub'), bosh => received('bosh'), safe => received('safe'),
	};
}

sub no_values_anywhere {
	my ($r) = @_;
	for my $value (@{$r}{qw/vault_value token/}) {
		unlike($r->{stderr}, qr/\Q$value\E/, 'the hook\'s stderr holds no credential value');
		unlike($r->{log}, qr/\Q$value\E/, 'the log file holds no credential value');
		unlike($r->{stdout}, qr/\Q$value\E/, 'the hook\'s stdout holds no credential value');
	}
}

subtest 'a hook traced at TRACE level keeps its values to itself' => sub {
	my $r = run_info_hook();
	ok($r->{ok}, 'the hook succeeds') or diag $r->{error};
	no_values_anywhere($r);
	like($r->{stderr}, qr/^\s*FAKE_HOOK_TOKEN$/m, 'the helper still names the variables it was given');
	unlike($r->{stderr}, qr/^\+ /m, 'the hook does not run under set -x');
	like($r->{stdout}, qr/hook-stdout-marker.*hook-finished-marker/s, 'the hook\'s stdout still reaches the caller');
	is($r->{credhub}, "set\n--name=/fake-bosh/fake/fake/password\n--type=value\n--value=$r->{vault_value}\n",
		'credhub gets the exact arguments');
	is($r->{bosh}, "-d\nfake\nupdate-config\n--var\npassword=$r->{token}\n", 'bosh gets the exact arguments');
	ok(!defined($r->{traced_hook}), 'no xtrace copy of the hook is written');
};

subtest 'GENESIS_SHOW_BOSH_CMD no longer echoes the bosh arguments' => sub {
	my $r = run_info_hook(GENESIS_SHOW_BOSH_CMD => 'true');
	ok($r->{ok}, 'the hook succeeds') or diag $r->{error};
	no_values_anywhere($r);
	is($r->{bosh}, "-d\nfake\nupdate-config\n--var\npassword=$r->{token}\n", 'bosh gets the exact arguments');
};

subtest 'GENESIS_HOOK_XTRACE warns and traces only to the terminal' => sub {
	my $r = run_info_hook(GENESIS_HOOK_XTRACE => 'true');
	ok($r->{ok}, 'the hook succeeds') or diag $r->{error};
	no_values_anywhere($r);
	like($r->{stderr}, qr/GENESIS_HOOK_XTRACE is set/, 'the operator is warned on the terminal');
	like($r->{stdout}, qr/hook-stdout-marker.*hook-finished-marker/s, 'the hook\'s stdout still reaches the caller');
	ok(defined($r->{traced_hook}), 'an xtrace copy of the hook is written');
	like($r->{traced_hook} // '', qr{BASH_XTRACEFD=.*/dev/tty|/dev/tty.*BASH_XTRACEFD}s,
		'its trace goes to the controlling terminal, not to stderr');
	like($r->{traced_hook} // '', qr/\A#!\/bin\/bash\n/, 'and the copy keeps the hook\'s interpreter line');
};

subtest 'a failed vault read moves nothing and deletes nothing' => sub {
	my $r = run_info_hook(FAKE_NO_ERREXIT => 1, FAKE_SAFE_GET_FAILS => 1);
	ok(!$r->{ok}, 'the hook fails');
	is($r->{credhub}, '', 'credhub is not given an empty value');
	unlike($r->{safe}, qr/^rm$/m, 'the vault secret is not removed');
	like($r->{stderr}, qr/Failed to read secret.*fake\/path:password/s, 'the failed read is reported');
};

subtest 'a failed credhub set does not echo what credhub printed' => sub {
	my $marker = fake_secret('credhub-output');
	put_file("$dir/bin/credhub", 0755, "#!/bin/bash\n"
		. "[[ \$1 == get ]] && { echo >&2 'The request could not be completed because the credential does not exist or you do not have sufficient authorization.'; exit 1; }\n"
		. "echo 'stdout $marker'; echo >&2 'stderr $marker'; exit 3\n");
	my $r = run_info_hook();
	ok(!$r->{ok}, 'the hook fails');
	no_values_anywhere($r);
	unlike($r->{stderr}.$r->{log}, qr/\Q$marker\E/, 'credhub\'s output is kept out of the message and the log');
	like($r->{stderr}, qr/credhub exited 3/, 'the exit status is reported');
};

done_testing;
