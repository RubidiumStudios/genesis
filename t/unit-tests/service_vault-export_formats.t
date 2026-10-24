#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;

# Every reader of `safe export` output goes through
# Service::Vault::normalize_export, which turns the v1, v2, and v3 export
# formats into the flat v1 shape and refuses any value that is not a
# string.  The fixtures are JSON text decoded the way the readers decode it,
# because a JSON number is told from a JSON string by how it was decoded.

use_ok 'Service::Vault';
use_ok 'Genesis::Env::Secrets::Store::Vault';
use_ok 'Genesis::Commands::Env';
use Genesis qw/load_json/;
use Test::Output;
use Cwd ();

# v2 and v3 wrap one export object in an array; the values of v3 keep the
# JSON type they were stored with.
sub versioned {
	my ($version, $data) = @_;
	return sprintf('[{"export_version":%s,"data":%s,"requires_versioning":{}}]', $version, $data);
}

my $V1 = '{"secret/myapp":{"password":"hunter2","port":"8443"},"secret/myapp/db":{"host":"localhost"}}';
my $V2 = versioned(2, '{'.
	'"secret/myapp":{"first":3,"requires_versioning":true,"versions":['.
		'{"value":{"password":"old"}},'.
		'{"value":{"password":"older-deleted"},"deleted":true},'.
		'{"value":{"password":"hunter2","port":"8443"}}]},'.
	'"secret/myapp/db":{"versions":[{"value":{"host":"localhost"}}]},'.
	'"secret/myapp/gone":{"versions":[{"value":{"x":"y"}},{"value":{"x":"z"},"deleted":true}]},'.
	'"secret/myapp/burnt":{"versions":[{"value":{"x":"y"}},{"destroyed":true}]},'.
	'"secret/myapp/empty":{"versions":[{}]},'.
	'"secret/myapp/none":{"versions":[]}'.
'}');
my $V3 = versioned(3, '{'.
	'"secret/myapp":{"versions":[{"value":{"count":42,"flag":true}},{"value":{"password":"hunter2","port":"8443"}}]},'.
	'"secret/myapp/db":{"versions":[{"value":{"host":"localhost"}}]},'.
	'"secret/myapp/gone":{"versions":[{"value":{"x":"y"},"deleted":true}]}'.
'}');
my %WANT = (
	'secret/myapp'       => {password => 'hunter2', port => '8443'},
	'secret/myapp/db'    => {host => 'localhost'},
);

subtest 'normalize_export reads every export version as v1' => sub {
	is_deeply(Service::Vault::normalize_export(load_json($V1)), \%WANT,
		'v1 comes back as it was');
	is_deeply(Service::Vault::normalize_export(load_json($V2)), {%WANT, 'secret/myapp/empty' => {}},
		'v2 gives the newest version of each path, and an empty live version as no keys');
	is_deeply(Service::Vault::normalize_export(load_json($V3)), \%WANT,
		'v3 gives the newest version, and a typed value in an older version does not matter');
	is_deeply(Service::Vault::normalize_export({}), {}, 'an empty export is empty');
	is(Service::Vault::normalize_export(undef), undef, 'no export at all stays undef');
	is_deeply(Service::Vault::normalize_export(load_json('{"secret/myapp":null,"secret/b":{"k":"v"}}')),
		{'secret/b' => {k => 'v'}}, 'a v1 path with no value is left out');
};

subtest 'normalize_export keeps strings that look like other types' => sub {
	my $data = load_json(versioned(3,
		'{"secret/a":{"versions":[{"value":{"n":"42","b":"true","z":"null","o":"{}","e":""}}]}}'));
	is_deeply(Service::Vault::normalize_export($data),
		{'secret/a' => {n => '42', b => 'true', z => 'null', o => '{}', e => ''}},
		'v3 strings come through whatever they spell');
};

subtest 'normalize_export refuses a typed value, naming its path and key' => sub {
	my %typed = (
		'a number'  => ['42',          'number'],
		'a float'   => ['1.5',         'number'],
		'a boolean' => ['true',        'boolean'],
		'a null'    => ['null',        'null'],
		'an object' => ['{"a":"b"}',   'object'],
		'a list'    => ['["a","b"]',   'list'],
	);
	plan tests => keys(%typed) + 2;
	for my $case (sort keys %typed) {
		my ($json, $type) = @{$typed{$case}};
		my $data = load_json(versioned(3,
			qq({"secret/myapp/db":{"versions":[{"value":{"host":"localhost","port":$json}}]}})));
		throws_ok { Service::Vault::normalize_export($data) }
			qr{secret/myapp/db.*\bport\b.*typed.*JSON\s+$type.*not\s+a\s+string.*Genesis}s,
			"v3 with $case dies naming the path, the key, and the type";
	}
	throws_ok { Service::Vault::normalize_export(load_json('{"secret/myapp":{"port":8443}}')) }
		qr{secret/myapp.*\bport\b.*typed.*JSON\s+number}s,
		'a typed value in v1 dies as well';
	throws_ok { Service::Vault::normalize_export(load_json(versioned(2,
		'{"secret/myapp":{"versions":[{"value":{"port":8443}}]}}'))) }
		qr{secret/myapp.*\bport\b.*typed.*JSON\s+number}s,
		'and in v2';
};

subtest 'normalize_export refuses a format it does not know' => sub {
	my %bad = (
		'an unknown export_version' => [versioned(4, '{}'),                      qr/export_version\s+4.*1,\s+2,\s+and\s+3/s],
		'no export_version'         => ['[{"data":{}}]',                          qr/export_version\s+\(none\)/s],
		'two exports in the array'  => ['['.versioned(2,'{}').','.versioned(2,'{}').']', qr/one\s+export.*holds\s+2/s],
		'an array of a string'      => ['["nope"]',                               qr/one\s+export/s],
		'a bare string'             => ['"nope"',                                 qr/not\s+an\s+object\s+or\s+an\s+array/s],
		'a v1 path that is a list'  => ['{"secret/a":["x"]}',                     qr{secret/a.*not\s+an\s+object\s+of\s+keys}s],
		'versions that are not a list' => [versioned(2, '{"secret/a":{"versions":{}}}'), qr{secret/a.*versions.*not\s+a\s+list}s],
		'a value that is not an object' => [versioned(3, '{"secret/a":{"versions":[{"value":"x"}]}}'), qr{secret/a.*not\s+an\s+object\s+of\s+keys}s],
	);
	plan tests => scalar keys %bad;
	for my $case (sort keys %bad) {
		my ($json, $error) = @{$bad{$case}};
		my $data = load_json($json);
		throws_ok { Service::Vault::normalize_export($data) } qr/Cannot\s+use\s+the\s+safe\s+export.*$error/s,
			"$case dies clearly";
	}
};

subtest 'get_path and get_path_strict read every export version' => sub {
	my $v = Service::Vault->new('https://vault.example.com:8200', 'test-vault', 1, '', undef, '/secret/');
	my %tree = (password => 'hunter2', port => '8443', db => {host => 'localhost'});
	for my $case (['v1', $V1, \%tree], ['v2', $V2, {%tree, empty => {}}], ['v3', $V3, \%tree]) {
		my ($label, $json, $want) = @$case;
		no warnings 'redefine';
		local *Service::Vault::query = sub { return ($json, 0, '') };
		use warnings 'redefine';
		is_deeply($v->get_path('/secret/myapp'), $want, "get_path reads $label");
		is_deeply($v->get_path_strict('/secret/myapp'), $want, "get_path_strict reads $label");
	}

	my $typed = versioned(3, '{"secret/myapp/db":{"versions":[{"value":{"port":5432}}]}}');
	no warnings 'redefine';
	local *Service::Vault::query = sub { return ($typed, 0, '') };
	use warnings 'redefine';
	throws_ok { $v->get_path('/secret/myapp') } qr{secret/myapp/db.*\bport\b.*typed}s,
		'get_path dies on a typed value rather than returning it';
	throws_ok { $v->get_path_strict('/secret/myapp') } qr{secret/myapp/db.*\bport\b.*typed}s,
		'and so does get_path_strict';
};

{
	package ExportMockEnv;
	sub new    { bless {}, shift }
	sub name   { 'my-org-my-env' }
	sub type   { 'bosh' }
	sub lookup { undef }
	sub exists { 0 }
}

subtest 'store_data reads every export version' => sub {
	for my $case (['v1', $V1, \%WANT], ['v2', $V2, {%WANT, 'secret/myapp/empty' => {}}], ['v3', $V3, \%WANT]) {
		my ($label, $json, $want) = @$case;
		my $store = Genesis::Env::Secrets::Store::Vault->new(
			ExportMockEnv->new,
			service => Mock->new(query => sub { ($json, 0, '') }),
			mount_override => '/secret/',
			slug_override  => 'myapp',
		);
		is_deeply($store->store_data, $want, "store_data reads $label");
		is_deeply([sort $store->store_paths], [sort keys %$want], "and store_paths lists its live paths");
	}

	my $typed = versioned(3, '{"secret/myapp":{"versions":[{"value":{"ca":{"pem":"x"}}}]}}');
	my $store = Genesis::Env::Secrets::Store::Vault->new(
		ExportMockEnv->new,
		service => Mock->new(query => sub { ($typed, 0, '') }),
		mount_override => '/secret/',
			slug_override  => 'myapp',
	);
	throws_ok { $store->store_data } qr{secret/myapp.*\bca\b.*typed.*JSON\s+object}s,
		'store_data dies on a typed value';
	ok(!exists $store->{__data}, 'and caches nothing');
};

subtest 'pipeline callers of get_path surface an export error' => sub {
	my $error = do { local $@; eval { Service::Vault::normalize_export({'secret/x' => {k => 1}}) }; $@ };
	like($error, qr/^\s*(?:\[FATAL\]\s*)?Cannot use the safe export/, 'the fixture error is an export error, whose message starts with what normalize_export says');

	my $vault = Mock->new(get_path => sub { die $error });
	my $env = Mock->new(
		exodus_mount => '/secret/exodus/',
		type         => 'bosh',
		name         => 'my-env',
		vault        => $vault,
	);
	throws_ok { Genesis::Commands::Env::_assert_prior_env_deployed($env, 'prior-env') }
		qr{secret/x.*\bk\b.*typed}s,
		'the prior-env check reports the export error, not a missing deploy';
	throws_ok { Genesis::Commands::Env::_get_source_sha_for_pull($env, 'prior-env', Mock->new(sha => 'abc123')) }
		qr{secret/x.*\bk\b.*typed}s,
		'the pull source lookup reports it rather than falling back to control HEAD';
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
# Each one logs its arguments, one per line, to the file named by args_file.
my $FAKE_SAFE = 0;
sub fake_safe {
	my ($body) = @_;
	my $dir = workdir('fake-safe-'.++$FAKE_SAFE);
	put_file("$dir/safe", "#!/bin/bash\nprintf '%s\\n' \"\$@\" > '$dir/args'\n$body\n");
	chmod(0755, "$dir/safe");
	return $dir;
}
sub args_of { my $args = get_file("$_[0]/args"); [split /\n/, $args] }

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

my $PRIOR_DEPLOYS = 'secret/exodus/prior-env/bosh/deployments';
sub pipeline_env {
	my ($vault) = @_;
	return Mock->new(
		exodus_mount => '/secret/exodus/',
		type         => 'bosh',
		name         => 'my-env',
		vault        => $vault,
	);
}

subtest 'the pipeline readers stop on a nonzero export exit instead of falling back' => sub {
	plan tests => 2;
	my $env = pipeline_env(test_vault());
	no warnings 'redefine';
	local *Service::Vault::query = safe_answers('', 2, $REFUSED);
	use warnings 'redefine';
	throws_ok { Genesis::Commands::Env::_assert_prior_env_deployed($env, 'prior-env') }
		qr{Could not read \Q$PRIOR_DEPLOYS\E from vault.*Code: 403}s,
		'the prior-env check names the unreadable path, not a missing deploy';
	throws_ok { Genesis::Commands::Env::_get_source_sha_for_pull($env, 'prior-env', Mock->new(sha => 'control-head')) }
		qr{Could not read \Q$PRIOR_DEPLOYS\E from vault.*Code: 403}s,
		'the pull source lookup stops rather than falling back to control HEAD';
};

subtest 'the pipeline readers treat a predecessor with no deployments record as never deployed' => sub {
	plan tests => 3;
	my $env = pipeline_env(test_vault());
	no warnings 'redefine';
	local *Service::Vault::query = safe_answers('', 1, absent($PRIOR_DEPLOYS));
	use warnings 'redefine';
	throws_ok { Genesis::Commands::Env::_assert_prior_env_deployed($env, 'prior-env') }
		qr{prior-env.*never been successfully deployed}s,
		'the prior-env check reports a predecessor that never deployed';
	my $sha;
	my $out = combined_from {
		$sha = Genesis::Commands::Env::_get_source_sha_for_pull($env, 'prior-env', Mock->new(sha => 'control-head'));
	};
	is($sha, 'control-head', 'the pull source lookup falls back to control HEAD');
	like($out, qr/Falling back to control HEAD/, 'and says so');
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

done_testing;
