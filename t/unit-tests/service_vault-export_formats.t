#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;

# How Genesis reads safe's export and its whole-secret get: the one form of
# export it reads and the refusal of every other, by get_path and by the
# secrets store; what a read that did not finish does in each; and what the
# strict whole-secret reader keeps of the bytes safe prints.  The export
# fixtures are JSON text, because a JSON number is told from a JSON string
# by how it was decoded.

use_ok 'Service::Vault';
use_ok 'Genesis::Env::Secrets::Store::Vault';
use_ok 'Genesis::Commands::Env';
use Genesis qw/load_json/;
use Test::Output;
use Cwd ();

# The versioned and typed exports wrap one export object in an array; the
# values of the typed one keep the JSON type they were stored with.
sub versioned {
	my ($version, $data) = @_;
	return sprintf('[{"export_version":%s,"data":%s,"requires_versioning":{}}]', $version, $data);
}

my $V1 = '{"secret/myapp":{"password":"hunter2","port":"8443"},"secret/myapp/db":{"host":"localhost"}}';
my $V2 = versioned(2, '{'.
	'"secret/myapp":{"first":3,"versions":['.
		'{"value":{"password":"old"}},'.
		'{"value":{"password":"older-deleted"},"deleted":true},'.
		'{"value":{"password":"hunter2","port":"8443"}}]},'.
	'"secret/myapp/db":{"versions":[{"value":{"host":"localhost"}}]},'.
	'"secret/myapp/gone":{"versions":[{"value":{"x":"y"}},{"value":{"x":"z"},"deleted":true}]},'.
	'"secret/myapp/burnt":{"versions":[{"value":{"x":"y"}},{"destroyed":true}]},'.
	'"secret/myapp/empty":{"versions":[{}]},'.
	'"secret/myapp/none":{"versions":[]}'.
'}') =~ s/"requires_versioning":\{\}/"requires_versioning":{"secret":true}/r;
my $V3 = versioned(3, '{'.
	'"secret/myapp":{"versions":[{"value":{"count":42,"flag":true}},{"value":{"password":"hunter2","port":"8443"}}]},'.
	'"secret/myapp/db":{"versions":[{"value":{"host":"localhost"}}]},'.
	'"secret/myapp/gone":{"versions":[{"value":{"x":"y"},"deleted":true}]}'.
'}');
my %WANT = (
	'secret/myapp'       => {password => 'hunter2', port => '8443'},
	'secret/myapp/db'    => {host => 'localhost'},
);

# ---------------------------------------------------------------------------
# The export Genesis reads
#
# safe writes one form of export when it is asked for nothing more: an
# object of paths, each holding keys whose values are strings.  It writes a
# versioned form only when given -a and a typed form only when given
# --typed, neither of which Genesis passes; safe 1.26.0 alone wrote the
# typed form unasked.  Genesis reads the first form and refuses the others
# with one message that says so.
# ---------------------------------------------------------------------------

my $REFUSAL = qr/safe\s+1\.26\.0.*-a.*--typed.*safe\s+1\.26\.1\s+or\s+later/s;

subtest 'plain_export reads the export safe writes unasked' => sub {
	is_deeply(Service::Vault::plain_export(load_json($V1), 'secret/myapp'), \%WANT,
		'every path comes back with its keys');
	is_deeply(Service::Vault::plain_export({}, 'secret/myapp'), {}, 'an empty export is empty');
	is_deeply(Service::Vault::plain_export(undef, 'secret/myapp'), {}, 'and so is no export at all');
	is_deeply(Service::Vault::plain_export(load_json('{"secret/myapp":null,"secret/b":{"k":"v"}}'), 'secret'),
		{'secret/b' => {k => 'v'}}, 'a path with no value is left out');
	is_deeply(Service::Vault::plain_export(load_json('{"secret/a":{}}'), 'secret/a'), {'secret/a' => {}},
		'a secret with no keys is a path with no keys');
	is_deeply(Service::Vault::plain_export(load_json('{"secret/a":{"n":"42","b":"true","z":"null","o":"{}","e":""}}'), 'secret/a'),
		{'secret/a' => {n => '42', b => 'true', z => 'null', o => '{}', e => ''}},
		'strings come through whatever they spell');

	my $data = load_json($V1);
	my $read = Service::Vault::plain_export($data, 'secret/myapp');
	$read->{'secret/myapp'}{password} = 'changed';
	is($data->{'secret/myapp'}{password}, 'hunter2', 'and what comes back is a copy');
};

subtest 'plain_export refuses every other form with one message' => sub {
	my %bad = (
		'a versioned export (format 2)'    => [$V2,                                    qr/an\s+array/],
		'a typed export (format 3)'        => [$V3,                                    qr/an\s+array/],
		'an export_version it never saw'   => [versioned(4, '{}'),                     qr/an\s+array/],
		'a bare string'                    => ['"nope"',                               qr/a\s+string/],
		'a path that is a list'            => ['{"secret/myapp":["x"]}',               qr{secret/myapp.*not\s+an\s+object\s+of\s+keys}s],
		'a path that is a string'          => ['{"secret/myapp":"x"}',                 qr{secret/myapp.*not\s+an\s+object\s+of\s+keys}s],
		'a number value'                   => ['{"secret/myapp/db":{"port":8443}}',    qr{\bport\b.*secret/myapp/db.*JSON\s+number}s],
		'a float value'                    => ['{"secret/myapp/db":{"port":1.5}}',     qr{\bport\b.*secret/myapp/db.*JSON\s+number}s],
		'a boolean value'                  => ['{"secret/myapp/db":{"port":true}}',    qr{\bport\b.*secret/myapp/db.*JSON\s+boolean}s],
		'a null value'                     => ['{"secret/myapp/db":{"port":null}}',    qr{\bport\b.*secret/myapp/db.*JSON\s+null}s],
		'an object value'                  => ['{"secret/myapp/db":{"port":{"a":"b"}}}', qr{\bport\b.*secret/myapp/db.*JSON\s+object}s],
		'a list value'                     => ['{"secret/myapp/db":{"port":["a"]}}',   qr{\bport\b.*secret/myapp/db.*JSON\s+list}s],
	);
	plan tests => 2 * scalar keys %bad;
	for my $case (sort keys %bad) {
		my ($json, $detail) = @{$bad{$case}};
		my $data = load_json($json);
		throws_ok { Service::Vault::plain_export($data, 'secret/myapp') }
			qr{Cannot\s+use\s+the\s+safe\s+export\s+of\s+secret/myapp.*$detail}s,
			"$case is refused, naming what was exported and what is wrong with it";
		throws_ok { Service::Vault::plain_export($data, 'secret/myapp') } $REFUSAL,
			"$case: and which safe, or which flags, write such an export";
	}
};

subtest 'get_path and get_path_strict read a plain export, and refuse any other' => sub {
	my $v = Service::Vault->new('https://vault.example.com:8200', 'test-vault', 1, '', undef, '/secret/');
	my @commands;
	my $answer;
	no warnings 'redefine';
	local *Service::Vault::query = sub { my (undef, undef, @cmd) = @_; push @commands, $cmd[0]; return ($answer, 0, '') };
	use warnings 'redefine';

	$answer = $V1;
	my %tree = (password => 'hunter2', port => '8443', db => {host => 'localhost'});
	is_deeply($v->get_path('/secret/myapp'), \%tree, 'get_path reads the plain export as a tree');
	is_deeply($v->get_path_strict('/secret/myapp'), \%tree, 'and so does get_path_strict');

	my %other = (
		'a versioned export'           => $V2,
		'a typed export'               => $V3,
		'a plain export with a number' => '{"secret/myapp/db":{"port":5432}}',
	);
	for my $case (sort keys %other) {
		$answer = $other{$case};
		@commands = ();
		throws_ok { $v->get_path('/secret/myapp') } qr{Cannot\s+use\s+the\s+safe\s+export\s+of\s+secret/myapp.*$REFUSAL}s,
			"get_path refuses $case, naming the path and the cause";
		throws_ok { $v->get_path_strict('/secret/myapp') } qr{Cannot\s+use\s+the\s+safe\s+export\s+of\s+secret/myapp}s,
			"get_path_strict refuses $case";
		is_deeply(\@commands, [qw/export export/], "$case: and neither reads the path again another way");
	}
};

{
	package ExportMockEnv;
	sub new    { bless {}, shift }
	sub name   { 'my-org-my-env' }
	sub type   { 'bosh' }
	sub lookup { undef }
	sub exists { 0 }
}

subtest 'store_data reads a plain export, and refuses any other' => sub {
	my $store_for = sub {
		my ($json, $commands) = @_;
		return Genesis::Env::Secrets::Store::Vault->new(
			ExportMockEnv->new,
			service => Mock->new(
				query => sub { my (undef, undef, @cmd) = @_; push @$commands, $cmd[0]; ($json, 0, '') },
				url   => sub { 'https://vault.example.com:8200' },
			),
			mount_override => '/secret/',
			slug_override  => 'myapp',
		);
	};

	my $store = $store_for->($V1, []);
	is_deeply($store->store_data, \%WANT, 'store_data reads the plain export');
	is_deeply([sort $store->store_paths], [sort keys %WANT], 'and store_paths lists its paths');

	my %other = (
		'a versioned export'               => $V2,
		'a typed export'                   => $V3,
		'a plain export holding an object' => '{"secret/myapp":{"ca":{"pem":"x"}}}',
	);
	for my $case (sort keys %other) {
		my @commands;
		$store = $store_for->($other{$case}, \@commands);
		throws_ok { $store->store_data } qr{Cannot\s+use\s+the\s+safe\s+export\s+of\s+secret/myapp.*$REFUSAL}s,
			"store_data refuses $case, naming the path and the cause";
		is_deeply(\@commands, ['export'], "$case: after the one export, and no other read");
		ok(!exists $store->{__data}, "$case: and it caches nothing");
	}
};

# ---------------------------------------------------------------------------
# Reads safe could not finish
# ---------------------------------------------------------------------------

# What safe prints on stderr for each way a read can end without data.  The
# absent-secret and deleted-version lines are safe's own wording
# (pkg/vault/errors.go); the others are what the vault and the network say.
my $REFUSED    = "Error making API request.\n\nURL: GET https://vault.example.com:8200/v1/secret/data/myapp\nCode: 403. Errors:\n\n* 1 error occurred:\n\t* permission denied\n";
my $UNREACHED  = "!! Get \"https://10.0.0.1:8200/v1/sys/health\": dial tcp 10.0.0.1:8200: connect: connection refused\n";
sub absent     { "!! no secret exists at path `$_[0]`\n" }

sub test_vault { Service::Vault->new('https://vault.example.com:8200', 'test-vault', 1, '', undef, '/secret/') }

# A query that answers as safe would, honouring where the caller sent
# stderr: merged into the output for '&1', or apart from it for 0.
sub safe_answers {
	my ($out, $rc, $err) = @_;
	return sub {
		my (undef, $opts) = @_;
		$opts = {} unless ref($opts) eq 'HASH';
		return (join('', grep {defined} $out, $err), $rc, undef) if ($opts->{stderr} // '&1') eq '&1';
		return ($out, $rc, $err);
	};
}

# A stand-in for the safe binary itself, so run() and the reader see a real
# child process exactly as they would with safe, but with no vault behind it.
# Each one logs its last arguments, one per line, to the file args, and every
# call it was given, one per line, to the file calls.
my $FAKE_SAFE = 0;
sub fake_safe {
	my ($body) = @_;
	my $dir = workdir('fake-safe-'.++$FAKE_SAFE);
	put_file("$dir/safe", "#!/bin/bash\nprintf '%s\\n' \"\$@\" > '$dir/args'\necho \"\$*\" >> '$dir/calls'\n$body\n");
	chmod(0755, "$dir/safe");
	return $dir;
}
sub args_of { my $args = get_file("$_[0]/args"); [split /\n/, $args] }
sub calls_of { [split /\n/, get_file("$_[0]/calls")] }

subtest 'get_path dies when the export exits nonzero' => sub {
	plan tests => 2;
	my $v = test_vault();
	no warnings 'redefine';
	local *Service::Vault::query = safe_answers('', 2, $REFUSED);
	use warnings 'redefine';
	throws_ok { $v->get_path('/secret/myapp') } qr{Could not read secret/myapp from vault at https://vault\.example\.com:8200: .*Code: 403}s,
		'a refused export dies naming the path and the reason, rather than reading as empty';

	local *Service::Vault::query = safe_answers('', 1, $UNREACHED);
	throws_ok { $v->get_path('/secret/myapp') } qr{Could not read secret/myapp .*connection refused}s,
		'and so does an unreachable vault';
};

subtest 'get_path returns an empty tree for a path with nothing stored' => sub {
	plan tests => 1;
	my $v = test_vault();
	no warnings 'redefine';
	local *Service::Vault::query = safe_answers('', 1, absent('secret/myapp'));
	use warnings 'redefine';
	is_deeply($v->get_path('/secret/myapp'), {}, 'nothing stored reads as an empty tree');
};


{
	package ExportMockExistingEnv;
	our @ISA = ('ExportMockEnv');
	sub exists { 1 }
}

sub vault_store {
	my ($query, %opts) = @_;
	my $env = delete($opts{env}) // ExportMockEnv->new;
	return Genesis::Env::Secrets::Store::Vault->new(
		$env,
		service        => Mock->new(query => $query),
		mount_override => '/secret/',
		slug_override  => 'myapp',
		%opts,
	);
}

subtest 'store_data dies on a refused export and stays quiet for a fresh env' => sub {
	plan tests => 7;
	my $store = vault_store(safe_answers('', 1, $REFUSED), env => ExportMockExistingEnv->new);
	my $out = combined_from {
		throws_ok { $store->store_data } qr{Could not read secret/myapp from vault.*Code: 403}s,
			'a refused export dies naming the path, rather than reading as no secrets';
	};
	ok(!exists $store->{__data}, 'and caches nothing');

	$store = vault_store(safe_answers('', 1, $UNREACHED));
	throws_ok { $store->store_data } qr{Could not read secret/myapp from vault.*connection refused}s,
		'an unreachable vault dies even for a fresh env';

	my $data;
	$store = vault_store(safe_answers('', 1, absent('secret/myapp')));
	$out = combined_from { $data = $store->store_data };
	is_deeply($data, {}, 'a fresh env with nothing stored reads as no secrets');
	is($out, '', 'without a warning');
	ok(!exists $store->{__data}, 'and is read again next time, once secrets may have been added');

	$store = vault_store(safe_answers('', 1, absent('secret/myapp')), env => ExportMockExistingEnv->new);
	$out = combined_from { $data = $store->store_data };
	like($out, qr/Vault export returned no data for \/secret\/myapp\//, 'an existing env with nothing stored is still warned about');
};

subtest 'store_data reads the paths that exist when safe reports one of them missing' => sub {
	# safe exports its paths one after the other and stops at the first it
	# cannot read, naming only that one.  An absent root CA path must not
	# hide the env's own secrets, so the store reads the rest without it.
	plan tests => 4;
	my @calls;
	my $query = sub {
		my (undef, $opts, @cmd) = @_;
		push @calls, [@cmd];
		return safe_answers('', 1, absent('secret/root-ca'))->(undef, $opts) if grep {$_ eq '/secret/root-ca'} @cmd;
		return safe_answers($V1, 0, '')->(undef, $opts);
	};
	my $store = vault_store($query, root_ca_override => '/secret/root-ca');
	is_deeply($store->store_data, \%WANT, 'the env secrets are read');
	is_deeply(\@calls, [['export', '/secret/myapp/', '/secret/root-ca'], ['export', '/secret/myapp/']],
		'by exporting again without the path safe said was missing');

	@calls = ();
	$query = sub {
		my (undef, $opts, @cmd) = @_;
		push @calls, [@cmd];
		return safe_answers('', 1, absent($cmd[1] =~ s{^/|/$}{}gr))->(undef, $opts);
	};
	$store = vault_store($query, root_ca_override => '/secret/root-ca');
	is_deeply($store->store_data, {}, 'with neither path stored, the store is empty');
	is(scalar(@calls), 2, 'after one export for each path');
};

subtest 'read_flattened_secret tells a missing secret from a refused read' => sub {
	my $v = test_vault();
	my %absent = (
		'no secret exists'           => absent('secret/myapp'),
		'a deleted latest version'   => "!! version 3 of secret `secret/myapp` has been deleted\n",
		'a destroyed latest version' => "!! version 3 of secret `secret/myapp` has been destroyed\n",
	);
	my %failed = (
		'a 403'                => [$REFUSED,   qr{Could not read secret/myapp from vault at https://vault\.example\.com:8200: .*Code: 403}s],
		'an unreachable vault' => [$UNREACHED, qr{Could not read secret/myapp from vault.*connection refused}s],
		'a refusal ahead of the absent line' => ["!! permission denied\n".absent('secret/myapp'), qr{Could not read secret/myapp.*permission denied}s],
	);
	plan tests => 1 + keys(%absent) + keys(%failed);

	for my $case (sort keys %absent) {
		local $ENV{PATH} = fake_safe("printf '%s' '$absent{$case}' >&2; exit 1").":$ENV{PATH}";
		is($v->read_flattened_secret('secret/myapp'), undef, "$case reads as nothing stored");
	}
	for my $case (sort keys %failed) {
		my ($stderr, $error) = @{$failed{$case}};
		local $ENV{PATH} = fake_safe("printf '%s' '$stderr' >&2; exit 1").":$ENV{PATH}";
		throws_ok { $v->read_flattened_secret('secret/myapp') } $error, "$case dies naming the path";
	}
	local $ENV{PATH} = fake_safe("printf -- '--- # secret/myapp\\npassword: hunter2\\nport: \"8443\"\\n\\n'").":$ENV{PATH}";
	is_deeply($v->read_flattened_secret('secret/myapp'), {password => 'hunter2', port => '8443'}, 'a good read comes back as its keys');
};

subtest 'read_flattened_secret treats a child killed by a signal as a failed read' => sub {
	plan tests => 2;
	my $v = test_vault();
	# safe prints part of a secret, then the shell running it is killed, so
	# the exit status holds a signal and no exit code.  The guard keeps the
	# kill off this test process should the shell ever exec safe directly.
	local $ENV{FAKE_SAFE_TEST_PID} = $$;
	local $ENV{PATH} = fake_safe(join("\n",
		"printf -- '--- # secret/myapp\\npassword: hunter2\\n'",
		'[ "$PPID" != "$FAKE_SAFE_TEST_PID" ] && kill -KILL "$PPID"',
		'sleep 1',
	)).":$ENV{PATH}";
	throws_ok { $v->read_flattened_secret('secret/myapp') } qr{Could not read secret/myapp from vault.*signal 9}s,
		'a killed read dies naming the path and the signal, rather than returning what it printed';

	# run() itself reports the signal only to a caller that opts in.
	my ($out, $rc, $err) = Genesis::run({stderr => 0, exact => 1}, 'safe', 'get', 'secret/myapp');
	is($rc, 128 + 9, 'run reports the signal as 128 plus its number');
};

subtest 'a child killed by a signal after naming an absent secret is a failed read, not nothing stored' => sub {
	plan tests => 3;
	my ($reason, @absent) = Service::Vault::read_failure(137, absent('secret/x')."killed by signal 9");
	like($reason, qr/killed by signal 9/, 'read_failure gives the signal as the reason');
	is_deeply(\@absent, [], 'and names no path as holding nothing');

	my $v = test_vault();
	local $ENV{FAKE_SAFE_TEST_PID} = $$;
	local $ENV{PATH} = fake_safe(join("\n",
		"printf '%s' '".absent('secret/myapp')."' >&2",
		'[ "$PPID" != "$FAKE_SAFE_TEST_PID" ] && kill -KILL "$PPID"',
		'sleep 1',
	)).":$ENV{PATH}";
	throws_ok { $v->read_flattened_secret('secret/myapp') } qr{Could not read secret/myapp from vault.*signal 9}s,
		'a killed read dies naming the signal, though safe had said the secret was absent';
};

subtest 'a safe killed by a signal after naming an absent secret is a failed read, not nothing stored' => sub {
	plan tests => 4;
	# When safe itself is killed, the shell that ran it exits 137 and says
	# Killed, so run has no signal to note.  safe exits 1 for every error it
	# reports, absence included, so only that status can mean nothing stored.
	my ($reason, @absent) = Service::Vault::read_failure(137, absent('secret/x')."Killed");
	like($reason, qr/no secret exists/, 'read_failure gives what safe said as the reason for a status of 137');
	is_deeply(\@absent, [], 'and names no path as holding nothing');
	is_deeply([Service::Vault::read_failure(1, absent('secret/x'))], [undef, 'secret/x'],
		'while the same line with safe\'s own error status names the path');

	my $v = test_vault();
	local $ENV{PATH} = fake_safe(join("\n",
		"printf '%s' '".absent('secret/myapp')."' >&2",
		'kill -KILL $$',
	)).":$ENV{PATH}";
	throws_ok { $v->read_flattened_secret('secret/myapp') } qr{Could not read secret/myapp from vault.*no secret exists}s,
		'a safe killed after it said the secret was absent dies rather than reading as nothing stored';
};

subtest 'read_flattened_secret escapes backslashes, colons, and carets, and leaves an ordinary path unchanged' => sub {
	plan tests => 4;
	my $v = test_vault();
	my $dir = fake_safe("printf -- '--- # x\\nk: v\\n\\n'");
	local $ENV{PATH} = "$dir:$ENV{PATH}";

	$v->read_flattened_secret('secret/exodus/lab-mgmt/bosh');
	is_deeply(args_of($dir), ['get', 'secret/exodus/lab-mgmt/bosh'], 'an ordinary path reaches safe byte for byte');

	$v->read_flattened_secret('secret/a\\b:c^1');
	is_deeply(args_of($dir), ['get', 'secret/a\\\\b\\:c\\^1'],
		'a backslash, a colon, and a caret are each escaped, so safe reads them as part of the path');

	$v->read_flattened_secret('secret/key:like');
	is_deeply(args_of($dir), ['get', 'secret/key\\:like'], 'a colon is not read as a key');

	$v->read_flattened_secret('secret/v^2');
	is_deeply(args_of($dir), ['get', 'secret/v\\^2'], 'and a caret is not read as a version');
};

# What `safe get secret/fixture/fidelity` prints with safe 1.26.0, made by
# safe's own encoder from the v1.26.0 tag (pkg/yamlenc.Marshal, printed with
# the format string at internal/cli/secrets.go:193), not written by hand.
my $FIDELITY = 't/src/safe/get-byte-fidelity.out';
my $CERT = "-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIUJ8v\nAQIDBAUGBwgJCgsMDQ4PEA==\n-----END CERTIFICATE-----\n";

subtest 'read_flattened_secret keeps the final newline of the literal block that ends the output' => sub {
	plan tests => 3;
	my $captured = get_file($FIDELITY);
	like($captured, qr/\nz_cert: \|\n  -----BEGIN CERTIFICATE-----\n(?:  .*\n)+  -----END CERTIFICATE-----\n\n\z/,
		'the captured output ends with the certificate as a literal block');

	my $v = test_vault();
	local $ENV{PATH} = fake_safe("cat '".Cwd::abs_path($FIDELITY)."'").":$ENV{PATH}";
	my $secret = $v->read_flattened_secret('secret/fixture/fidelity');
	is($secret->{z_cert}, $CERT, 'the certificate keeps its one final newline');
	is_deeply($secret, {
		a_bool       => 'true',
		a_hex        => '0x10',
		a_int        => '9000',
		a_null       => 'null',
		a_tilde      => '~',
		leading      => '   three leading spaces',
		long         => ('abcdefghij ' x 22).'end',
		two_newlines => "ends with two newlines\n\n",
		z_cert       => $CERT,
	}, 'and every other value comes back as the string safe printed');
};

subtest 'read_flattened_secret keeps a value ending in two newlines' => sub {
	plan tests => 2;
	my $v = test_vault();
	local $ENV{PATH} = fake_safe("cat '".Cwd::abs_path($FIDELITY)."'").":$ENV{PATH}";
	is($v->read_flattened_secret('secret/fixture/fidelity')->{two_newlines}, "ends with two newlines\n\n",
		'safe quotes it, so both newlines survive');
	is($v->get('secret/fixture/fidelity')->{two_newlines}, "ends with two newlines\n\n",
		'as they always have through get');
};

subtest 'get reads a whole secret through read_flattened_secret, and still reads a failure as empty' => sub {
	plan tests => 3;
	my $v = test_vault();
	{
		local $ENV{PATH} = fake_safe("cat '".Cwd::abs_path($FIDELITY)."'").":$ENV{PATH}";
		is_deeply($v->get('secret/fixture/fidelity'), $v->read_flattened_secret('secret/fixture/fidelity'),
			'get gives the same keys and values');
		is($v->get('secret/fixture/fidelity')->{z_cert}, $CERT,
			'so the certificate that ends the output keeps its final newline');
	}
	local $ENV{PATH} = fake_safe("printf '%s' '$REFUSED' >&2; exit 1").":$ENV{PATH}";
	is_deeply($v->get('secret/myapp'), {}, 'a refused read still comes back empty to the callers that take it so');
};

subtest 'get still stops on a successful read that prints something other than a map of keys' => sub {
	plan tests => 3;
	my $v = test_vault();
	{
		local $ENV{PATH} = fake_safe("printf -- '- a\\n- b\\n'").":$ENV{PATH}";
		throws_ok { $v->get('secret/myapp') } qr{Could not read secret/myapp from vault}s,
			'a list is an error, not an empty secret';
	}
	local $ENV{PATH} = fake_safe("printf -- 'just a string\\n'").":$ENV{PATH}";
	throws_ok { $v->get('secret/myapp') } qr{Could not read secret/myapp from vault}s,
		'and so is a string';

	# A clear is confirmed by reading the path back until no keys remain, so
	# an answer that is not a map must never pass for an empty secret.
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '1';
	local $ENV{GENESIS_VAULT_CONFIRM_TIMEOUT} = '1';
	throws_ok { $v->_confirm_cleared('secret/myapp') } qr{Could not read secret/myapp from vault}s,
		'so _confirm_cleared stops instead of taking it as a cleared path';
};

subtest 'get reads a trailing ^N as a version, and the strict read takes it as part of the path' => sub {
	plan tests => 4;
	my $v = test_vault();
	my $dir = fake_safe("printf -- '--- # x\\nk: v\\n\\n'");
	local $ENV{PATH} = "$dir:$ENV{PATH}";

	$v->get('secret/app^2');
	is_deeply(args_of($dir), ['get', 'secret/app^2'], 'get hands the version selector to safe as it is');
	$v->get('secret/app\\^2');
	is_deeply(args_of($dir), ['get', 'secret/app\\^2'], 'and a caret the caller escaped stays escaped, naming the literal path');
	$v->read_flattened_secret('secret/app^2');
	is_deeply(args_of($dir), ['get', 'secret/app\\^2'], 'read_flattened_secret escapes the caret, so it names the literal path');
	$v->read_flattened_secret('secret/app^2', versioned => 1);
	is_deeply(args_of($dir), ['get', 'secret/app^2'], 'unless it is asked to read versions as get does');
};

# ---------------------------------------------------------------------------
# What the store does with a value it read
# ---------------------------------------------------------------------------

subtest 'store_data never writes back a value it only read' => sub {
	# store_data feeds fill, and a secret fill gives a value counts as present,
	# so nothing adds, imports, or saves it.  Only store->write persists a
	# value, and only a secret's save calls it, after a command set the value
	# itself.  So a value stored as a number, which safe exports as its text,
	# is never written back as that text.
	plan tests => 4;
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;
	require Genesis::Secret::UserProvided;
	my $exodus = 'secret/exodus/lab-mgmt/bosh';
	my $export = qq({"$exodus":{"url":"https://10.108.16.4:25555"},"$exodus/network-claim-lock":{"pid":"3834038","user":"ubuntu"}});
	my @commands;
	no warnings 'redefine';
	local *Service::Vault::query = sub {
		my (undef, $opts, @cmd) = @_;
		push @commands, $cmd[0];
		return safe_answers($export, 0, '')->(undef, $opts);
	};
	use warnings 'redefine';
	my $store = Genesis::Env::Secrets::Store::Vault->new(
		ExportMockEnv->new, service => test_vault(), mount_override => '/secret/', slug_override => 'exodus/lab-mgmt/bosh',
	);
	my $pid = Genesis::Secret::UserProvided->new('network-claim-lock:pid', prompt => 'pid');
	$store->fill($pid);
	ok($pid->has_value, 'a value the export gave as text fills its secret');
	is($pid->value, '3834038', 'with that text');
	is(($store->check($pid))[0], 'ok', 'and checking it reads nothing more');
	is_deeply(\@commands, ['export'], 'so the only command run was the export');
};

subtest 'read_flattened_secret keeps the escaping safe gives a value that is not a string' => sub {
	plan tests => 4;
	my $path = 'secret/fixture/escaping';
	# What safe get prints for a secret holding an object, a list, numbers,
	# a boolean and a null beside its strings: each as text, an object with
	# the escapes json.Marshal gives it.
	my $captured = 't/src/safe/get-escaping.out';
	local $ENV{PATH} = fake_safe("exec cat '".Cwd::abs_path($captured)."'").":$ENV{PATH}";

	my $secret = test_vault()->read_flattened_secret($path);
	is($secret->{config}, '{"a":"x","b":[1,2],"tag":"\u003ca\u0026b\u003e"}',
		'the object is the compact, sorted JSON safe prints, with <, &, and > as six-byte escapes');
	is($secret->{tag}, '<a&b>', 'a string at the top of the secret keeps its <, &, and > unescaped');
	is($secret->{controls}, '{"bs":"g\bh","line":"a\u2028b","para":"c\u2029d","soh":"e\u0001f"}',
		'U+2028, U+2029, and the control characters keep the escapes safe gives them');
	is_deeply({map {($_ => $secret->{$_})} qw/count enabled list nothing password ratio/}, {
		count => '12345678901234567000', enabled => 'false', list => '["p",{"q":1}]',
		nothing => 'null', password => 'old', ratio => '0.5',
	}, 'and every other value is the text safe prints');
};

done_testing;
