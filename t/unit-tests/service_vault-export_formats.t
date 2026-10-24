#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;

# Safe's export text is decoded by Service::Vault::decode_export_text, which
# turns the v1, v2, and v3 export formats into the flat v1 shape, keeps the
# JSON type of every value, and marks every path holding a value that is not
# a string.  Service::Vault::normalize_export does the same for an export
# already decoded, and refuses any value that is not a string.  The fixtures
# are JSON text, because a JSON number is told from a JSON string by how it
# was decoded.

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

# ---------------------------------------------------------------------------
# Decoding safe's export text
# ---------------------------------------------------------------------------

# Exports in the shape safe 1.26.0 writes.  The values of format 3 are the
# JSON each secret was stored as, verbatim, so a number keeps the digits it
# was written with.  Strings in them are escaped as Go's json.Marshal
# escapes them, so <, &, and > are the six-byte \u003c, \u0026, and \u003e.
my $EXODUS_KV2 = '[{"export_version":3,"data":{"secret/exodus/lab-mgmt/bosh":{"first":7,"versions":[{"value":{"ca_cert":"-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----","url":"https://10.108.16.4:25555"}}]},"secret/exodus/lab-mgmt/bosh/network-claim-lock":{"first":19,"versions":[{"value":{"at":"2026-10-24 12:09:14 +0000","env":"lab-mgmt","hostname":"bastion","pid":3834038,"token":"6f1c2a9e","user":"ubuntu"}}]}},"requires_versioning":{}}]';
my $OCFP_CONFIG = '[{"export_version":3,"data":{"secret/config/ocfp-lab-wayneeseguin/mgmt/bosh/blobstores/bosh":{"first":2,"versions":[{"value":{"bucket":"bosh","endpoint":"https://s3.lab:9000","host":"s3.lab","path_style":true,"port":9000,"region":"us-east-1"}}]},"secret/config/ocfp-lab-wayneeseguin/mgmt/policies":{"versions":[{"value":{"user_provided_bosh_creds":"allow"}}]}},"requires_versioning":{}}]';
my $HUGE = '999999999999999999999999999999999999999999';
my $NUMBERS = '[{"export_version":3,"data":{"secret/fixture/numbers":{"versions":[{"value":{'.
	'"e20":1e20,"e21":1e21,"half":0.5,"huge":'.$HUGE.',"negzero":-0,"quoted":"9000","tiny":1e-7,"u64":12345678901234567890'.
	'}}]},"secret/fixture/strings":{"versions":[{"value":{"n":"9000","t":"true"}}]}},"requires_versioning":{}}]';
my $LOCK = 'secret/exodus/lab-mgmt/bosh/network-claim-lock';

sub value_type { Service::Vault::_export_value_type($_[0]) // 'string' }

subtest 'decode_export_text keeps the JSON type of every value' => sub {
	my $text = versioned(3, '{"secret/a":{"versions":[{"value":{"n":"42"}},{"value":{'.
		'"bool":false,"count":42,"empty":"","list":["p",{"q":1}],"nothing":null,'.
		'"config":{"a":"x","b":[1,2],"tag":"\u003ca\u0026b\u003e"},"ratio":0.5,"tag":"\u003ca\u0026b\u003e"'.
	'}}]}}');
	my ($export, $typed) = Service::Vault::decode_export_text($text);
	my $pairs = $export->{'secret/a'};
	my %want = (bool => 'boolean', count => 'number', empty => 'string', list => 'list',
		nothing => 'null', config => 'object', ratio => 'number', tag => 'string');
	is_deeply({map {($_ => value_type($pairs->{$_}))} keys %$pairs}, \%want,
		'each value of the current version keeps its JSON type');
	ok(!$pairs->{bool} && JSON::PP::is_bool($pairs->{bool}), 'a boolean stays a JSON boolean');
	is(0 + $pairs->{count}, 42, 'a number keeps its value');
	is_deeply($pairs->{config}, {a => 'x', b => [1, 2], tag => '<a&b>'},
		'an object keeps its structure, and its escaped strings decode');
	is($pairs->{tag}, '<a&b>', 'a string escaped by json.Marshal decodes to its text');
	is_deeply($typed, {'secret/a' => [qw/bool config count list nothing ratio/]},
		'and the path is marked with every key that is not a string');

	my $only = Service::Vault::decode_export_text($text);
	is(ref($only), 'HASH', 'in scalar context it returns just the export');
	ok(exists $only->{'secret/a'}, 'with its paths');

	for my $case (['v1', $V1, \%WANT], ['v2', $V2, {%WANT, 'secret/myapp/empty' => {}}], ['v3', $V3, \%WANT]) {
		my ($label, $json, $want) = @$case;
		my ($got, $marks) = Service::Vault::decode_export_text($json);
		is_deeply($got, $want, "$label reads as normalize_export reads it");
		is_deeply($marks, {}, "and with only strings current, no path is marked");
	}
};

subtest 'decode_export_text reads an integer too large for Perl as a number' => sub {
	my $text = versioned(3, '{"secret/a":{"versions":[{"value":{"big":'.$HUGE.'}}]}}');
	is(value_type(load_json($text)->[0]{data}{'secret/a'}{versions}[0]{value}{big}), 'string',
		'decoded without bignums, it reads as a string of digits');
	my ($export, $typed) = Service::Vault::decode_export_text($text);
	is(value_type($export->{'secret/a'}{big}), 'number', 'decoded from the raw text, it is a number');
	is("$export->{'secret/a'}{big}", $HUGE, 'with every digit');
	is_deeply($typed, {'secret/a' => ['big']}, 'and its path is marked');
};

subtest 'decode_export_text marks every path holding a value that is not a string' => sub {
	my ($export, $typed) = Service::Vault::decode_export_text($NUMBERS);
	is_deeply($typed, {'secret/fixture/numbers' => [qw/e20 e21 half huge negzero tiny u64/]},
		'every number shape marks its path, and the strings path and the quoted "9000" are left unmarked');
	is(value_type($export->{'secret/fixture/numbers'}{negzero}), 'number',
		'-0 is a number, though it decodes as zero');
	is($export->{'secret/fixture/numbers'}{quoted}, '9000', 'the quoted "9000" is the string 9000');
	is(value_type($export->{'secret/fixture/numbers'}{quoted}), 'string', 'and stays a string');

	($export, $typed) = Service::Vault::decode_export_text($EXODUS_KV2);
	is_deeply($typed, {$LOCK => ['pid']}, 'a lock with a number pid marks only the lock');
	is($export->{'secret/exodus/lab-mgmt/bosh'}{url}, 'https://10.108.16.4:25555',
		'and the exodus beside it holds its strings');

	($export, $typed) = Service::Vault::decode_export_text($OCFP_CONFIG);
	is_deeply($typed, {'secret/config/ocfp-lab-wayneeseguin/mgmt/bosh/blobstores/bosh' => [qw/path_style port/]},
		'a blobstore with a boolean path_style and a number port marks the blobstore');
	is_deeply($export->{'secret/config/ocfp-lab-wayneeseguin/mgmt/policies'}, {user_provided_bosh_creds => 'allow'},
		'and leaves the policies beside it as they are');

	($export, $typed) = Service::Vault::decode_export_text(versioned(3, '{'.
		'"secret/old":{"versions":[{"value":{"n":1}},{"value":{"n":"1"}}]},'.
		'"secret/gone":{"versions":[{"value":{"n":"1"}},{"value":{"n":2},"deleted":true}]}}'));
	is_deeply([$export, $typed], [{'secret/old' => {n => '1'}}, {}],
		'a typed value in an older or deleted version marks nothing');
};

subtest 'decode_export_text refuses a format it does not know, or text that does not decode' => sub {
	throws_ok { Service::Vault::decode_export_text(versioned(4, '{}')) }
		qr/Cannot\s+use\s+the\s+safe\s+export.*export_version\s+4/s, 'an unknown export_version dies as normalize_export does';
	throws_ok { Service::Vault::decode_export_text('{"secret/a":["x"]}') }
		qr{Cannot\s+use\s+the\s+safe\s+export\s+of\s+secret/a.*not\s+an\s+object\s+of\s+keys}s, 'and so does a path that is not an object';
	throws_ok { Service::Vault::decode_export_text('{"secret/a":') }
		qr/Cannot\s+use\s+the\s+safe\s+export:\s+it\s+is\s+not\s+JSON/s, 'text that does not decode dies';
	throws_ok { Service::Vault::decode_export_text('') }
		qr/Cannot\s+use\s+the\s+safe\s+export:\s+it\s+is\s+not\s+JSON/s, 'and so does no text at all';
};

subtest 'get_path reads a path holding an integer too large for Perl again with safe get' => sub {
	plan tests => 3;
	my $v = Service::Vault->new('https://vault.example.com:8200', 'test-vault', 1, '', undef, '/secret/');
	my $text = versioned(3, '{"secret/myapp/db":{"versions":[{"value":{"host":"localhost","port":'.$HUGE.'}}]}}');
	my @gets;
	no warnings 'redefine';
	local *Service::Vault::query = sub {
		my (undef, undef, $cmd, $path) = @_;
		return ($text, 0, '') if $cmd eq 'export';
		push @gets, $path;
		return (qq{--- # $path\nhost: localhost\nport: "1e+42"\n\n}, 0, '');
	};
	use warnings 'redefine';
	is_deeply($v->get_path('/secret/myapp'), {db => {host => 'localhost', port => '1e+42'}},
		'get_path decodes the raw export text, sees the number, and takes the path from safe get');
	is_deeply($v->get_path_strict('/secret/myapp'), {db => {host => 'localhost', port => '1e+42'}},
		'and so does get_path_strict');
	is_deeply(\@gets, ['secret/myapp/db', 'secret/myapp/db'], 'each reading that one path again');
};

subtest 'normalize_export already refuses 12345678901234567890 as a number' => sub {
	plan tests => 1;
	throws_ok { Service::Vault::normalize_export(load_json(versioned(3,
		'{"secret/a":{"versions":[{"value":{"u64":12345678901234567890}}]}}'))) }
		qr{secret/a.*\bu64\b.*typed.*JSON\s+number}s,
		'an integer that fits an unsigned native type decodes as a number';
};

subtest 'normalize_export reads a released kv v2 lock in format 1 and in format 3' => sub {
	plan tests => 3;
	is_deeply(Service::Vault::normalize_export(load_json(qq({"$LOCK":{}}))), {$LOCK => {}},
		'format 1 gives the released lock no keys');
	is_deeply(Service::Vault::normalize_export(load_json(versioned(3,
		qq({"secret/exodus/lab-mgmt/bosh":{"versions":[{"value":{"url":"https://10.108.16.4:25555"}}]},"$LOCK":{"first":20,"versions":[{}]}})))),
		{'secret/exodus/lab-mgmt/bosh' => {url => 'https://10.108.16.4:25555'}, $LOCK => {}},
		'and so does format 3, where the released version has no value');
	my ($export, $typed) = Service::Vault::decode_export_text(versioned(3,
		qq({"secret/exodus/lab-mgmt/bosh":{"versions":[{"value":{"port":25555}}]},"$LOCK":{"first":20,"versions":[{}]}})));
	is_deeply([$export->{$LOCK}, $typed], [{}, {'secret/exodus/lab-mgmt/bosh' => ['port']}],
		'and a format 3 export forced by a typed value beside it marks only that value\'s path');
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
	local *Service::Vault::query = sub {
		return $_[2] eq 'export' ? ($typed, 0, '') : (qq{--- # $_[3]\nport: "5432"\n\n}, 0, '');
	};
	use warnings 'redefine';
	is_deeply($v->get_path('/secret/myapp'), {db => {port => '5432'}},
		'get_path reads a typed value as the text safe get prints, rather than dying');
	is_deeply($v->get_path_strict('/secret/myapp'), {db => {port => '5432'}},
		'and so does get_path_strict');
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
		service => Mock->new(
			query                => sub { ($typed, 0, '') },
			read_flattened_secret => sub { {ca => '{"pem":"x"}'} },
		),
		mount_override => '/secret/',
		slug_override  => 'myapp',
	);
	is_deeply($store->store_data, {'secret/myapp' => {ca => '{"pem":"x"}'}},
		'store_data reads a typed value as the text safe get prints, rather than dying');
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

# ---------------------------------------------------------------------------
# Typed secrets, read again whole with safe get
# ---------------------------------------------------------------------------

# The same exodus as $EXODUS_KV2 on a kv v1 mount, where no secret has a
# first field.
my $EXODUS_KV1 = $EXODUS_KV2 =~ s/"first":\d+,//gr;
my $EXODUS = 'secret/exodus/lab-mgmt/bosh';
my %EXODUS_STRINGS = (
	ca_cert => "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----",
	url     => 'https://10.108.16.4:25555',
);

# What safe 1.26.0 prints for a safe get of each typed secret below, made by
# safe's own read path and encoder from the v1.26.0 tag, as the files under
# t/src/safe are.
my $LOCK_GET = qq{--- # $LOCK\nat: "2026-10-24 12:09:14 +0000"\nenv: lab-mgmt\nhostname: bastion\npid: "3834038"\ntoken: 6f1c2a9e\nuser: ubuntu\n\n};
my %LOCK_STRINGS = (
	at => '2026-10-24 12:09:14 +0000', env => 'lab-mgmt', hostname => 'bastion',
	pid => '3834038', token => '6f1c2a9e', user => 'ubuntu',
);

# A query that answers safe export with $export and safe get of a path with
# what %gets holds for it, which is safe's output, or [out, rc, stderr] for
# a get that fails.  A path it holds nothing for is absent.  Every command it
# is given is logged to the list it returns.
sub typed_safe {
	my ($export, %gets) = @_;
	my @calls;
	my $query = sub {
		my (undef, $opts, @cmd) = @_;
		push @calls, [@cmd];
		return safe_answers($export, 0, '')->(undef, $opts) if $cmd[0] eq 'export';
		my $got = $gets{$cmd[1]};
		return safe_answers(@$got)->(undef, $opts) if ref($got) eq 'ARRAY';
		return safe_answers($got, 0, '')->(undef, $opts) if defined($got);
		return safe_answers('', 1, absent($cmd[1]))->(undef, $opts);
	};
	return ($query, \@calls);
}

subtest 'get_path takes a typed secret whole from safe get' => sub {
	plan tests => 3;
	my ($query, $calls) = typed_safe($EXODUS_KV2, $LOCK => $LOCK_GET);
	no warnings 'redefine';
	local *Service::Vault::query = $query;
	use warnings 'redefine';
	my $tree = test_vault()->get_path("/$EXODUS");
	is_deeply($tree, {%EXODUS_STRINGS, 'network-claim-lock' => \%LOCK_STRINGS},
		'the lock comes back with its pid as the string 3834038, beside the exodus strings');
	is(value_type($tree->{'network-claim-lock'}{pid}), 'string', 'and the pid is a Perl string');
	is_deeply($calls, [['export', $EXODUS], ['get', $LOCK]],
		'after exactly one safe get, of the lock, and none of the exodus, which holds only strings');
};

subtest 'get_path_strict takes a typed secret whole from safe get' => sub {
	plan tests => 2;
	my ($query, $calls) = typed_safe($EXODUS_KV1, $LOCK => $LOCK_GET);
	no warnings 'redefine';
	local *Service::Vault::query = $query;
	use warnings 'redefine';
	is_deeply(test_vault()->get_path_strict("/$EXODUS"), {%EXODUS_STRINGS, 'network-claim-lock' => \%LOCK_STRINGS},
		'a kv v1 export, with no first fields, reads the lock the same way');
	is_deeply($calls, [['export', $EXODUS], ['get', $LOCK]], 'with one safe get, of the lock');
};

subtest 'store_data takes a typed secret whole from safe get' => sub {
	plan tests => 3;
	my ($query, $calls) = typed_safe($EXODUS_KV2, $LOCK => $LOCK_GET);
	no warnings 'redefine';
	local *Service::Vault::query = $query;
	use warnings 'redefine';
	my $store = Genesis::Env::Secrets::Store::Vault->new(
		ExportMockEnv->new, service => test_vault(), mount_override => '/secret/', slug_override => 'exodus/lab-mgmt/bosh',
	);
	is_deeply($store->store_data, {$EXODUS => \%EXODUS_STRINGS, $LOCK => \%LOCK_STRINGS},
		'the lock is stored with its pid as the string safe get prints');
	is_deeply($calls, [['export', "/$EXODUS/"], ['get', $LOCK]], 'after one safe get, of the lock');
	ok(exists $store->{__data}, 'and the store is cached');
};

subtest 'store_data never writes back a value it only read' => sub {
	# store_data feeds fill, and a secret fill gives a value counts as present,
	# so nothing adds, imports, or saves it.  Only store->write persists a
	# value, and only a secret's save calls it, after a command set the value
	# itself.  So a typed value read as text is never written back as text.
	plan tests => 4;
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;
	require Genesis::Secret::UserProvided;
	my ($query, $calls) = typed_safe($EXODUS_KV2, $LOCK => $LOCK_GET);
	no warnings 'redefine';
	local *Service::Vault::query = $query;
	use warnings 'redefine';
	my $store = Genesis::Env::Secrets::Store::Vault->new(
		ExportMockEnv->new, service => test_vault(), mount_override => '/secret/', slug_override => 'exodus/lab-mgmt/bosh',
	);
	my $pid = Genesis::Secret::UserProvided->new('network-claim-lock:pid', prompt => 'pid');
	$store->fill($pid);
	ok($pid->has_value, 'a typed value read whole fills its secret');
	is($pid->value, '3834038', 'with the text safe get prints');
	is(($store->check($pid))[0], 'ok', 'and checking it reads nothing more');
	is_deeply([map {$_->[0]} @$calls], ['export', 'get'], 'so the only commands run were the export and the safe get');
};

subtest 'a typed object keeps the escaping safe gives it' => sub {
	plan tests => 4;
	my $path = 'secret/fixture/escaping';
	my $captured = 't/src/safe/get-escaping.out';
	# The secret as safe 1.26.0 exports it: json.Marshal escapes <, &, and >
	# in every string, and U+2028 and U+2029 as well.
	my $export = versioned(3, qq({"$path":{"versions":[{"value":{).
		'"config":{"a":"x","b":[1,2],"tag":"\u003ca\u0026b\u003e"},'.
		'"controls":{"bs":"g\bh","line":"a\u2028b","para":"c\u2029d","soh":"e\u0001f"},'.
		'"count":12345678901234567890,"enabled":false,"list":["p",{"q":1}],"nothing":null,'.
		'"password":"old","ratio":0.5,"tag":"\u003ca\u0026b\u003e"'.
	'}}]}}');
	my $dir = workdir('typed-escaping');
	put_file("$dir/export.json", $export);
	my $safe = fake_safe(qq{[ "\$1" = export ] && exec cat '$dir/export.json'; exec cat '}.Cwd::abs_path($captured)."'");
	local $ENV{PATH} = "$safe:$ENV{PATH}";

	my $secret = test_vault()->get_path($path);
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

subtest 'a typed secret read again keeps every byte safe printed' => sub {
	plan tests => 3;
	my $path = 'secret/fixture/fidelity';
	my %strings = (
		a_hex        => '0x10',
		a_tilde      => '~',
		leading      => '   three leading spaces',
		long         => ('abcdefghij ' x 22).'end',
		two_newlines => "ends with two newlines\n\n",
		z_cert       => $CERT,
	);
	# Three keys hold the typed values that safe get prints as the strings in
	# the captured output, so the secret is read again through spruce json.
	my $value = JSON::PP->new->canonical->encode({%strings, a_bool => JSON::PP::true, a_int => 9000, a_null => undef});
	my $dir = workdir('typed-fidelity');
	put_file("$dir/export.json", versioned(3, qq({"$path":{"versions":[{"value":$value}]}})));
	my $safe = fake_safe(qq{[ "\$1" = export ] && exec cat '$dir/export.json'; exec cat '}.Cwd::abs_path($FIDELITY)."'");
	local $ENV{PATH} = "$safe:$ENV{PATH}";

	my $secret = test_vault()->get_path($path);
	is_deeply($secret, {%strings, a_bool => 'true', a_int => '9000', a_null => 'null'},
		'every value comes back byte for byte as the string safe printed');
	is($secret->{z_cert}, $CERT, 'and the certificate ending the output keeps its one final newline');
	is_deeply(calls_of($safe), ["export $path", "get $path"], 'after one export and one safe get of the secret');
};

subtest 'every field of a typed secret comes from one read' => sub {
	plan tests => 4;
	my $export = versioned(3, '{"secret/x":{"versions":[{"value":{"username":"alice","ratio":0.5}}]}}');
	my %cases = (
		'a secret written again between the export and the read' =>
			["--- # secret/x\nratio: \"1.5\"\nusername: bob\n\n", {username => 'bob', ratio => '1.5'}],
		'a secret that went from A to B and back to A' =>
			["--- # secret/x\nratio: \"0.5\"\nusername: alice\n\n", {username => 'alice', ratio => '0.5'}],
	);
	for my $case (sort keys %cases) {
		my ($get, $want) = @{$cases{$case}};
		my ($query, $calls) = typed_safe($export, 'secret/x' => $get);
		no warnings 'redefine';
		local *Service::Vault::query = $query;
		use warnings 'redefine';
		is_deeply(test_vault()->get_path_strict('secret/x'), $want, "$case gives every field as the safe get gave it");
		is_deeply($calls, [['export', 'secret/x'], ['get', 'secret/x']], 'from one whole-secret safe get, and none per key');
	}
};

subtest 'a typed secret that disappears before the second read is an error' => sub {
	plan tests => 3;
	my ($query) = typed_safe($EXODUS_KV2);
	no warnings 'redefine';
	local *Service::Vault::query = $query;
	use warnings 'redefine';
	my $gone = qr{Could not read \Q$LOCK\E from vault.*held\s+nothing\s+when\s+read\s+again.*changed\s+while\s+Genesis\s+was\s+reading\s+it}s;
	throws_ok { test_vault()->get_path("/$EXODUS") } $gone,
		'get_path dies naming the secret, rather than reading it as empty or keeping the export\'s copy';
	throws_ok { test_vault()->get_path_strict("/$EXODUS") } $gone, 'and so does get_path_strict';
	my $store = Genesis::Env::Secrets::Store::Vault->new(
		ExportMockEnv->new, service => test_vault(), mount_override => '/secret/', slug_override => 'exodus/lab-mgmt/bosh',
	);
	throws_ok { $store->store_data } $gone, 'and so does store_data';
};

subtest 'the pipeline readers report a failed second read' => sub {
	plan tests => 2;
	my $deploy = "$PRIOR_DEPLOYS/2026-10-24-120914";
	my ($query) = typed_safe(
		versioned(3, qq({"$deploy":{"versions":[{"value":{"action":"deploy","git.control_commit":"abc123","status":"succeeded","chunks":2}}]}})),
		$deploy => ['', 1, $REFUSED],
	);
	no warnings 'redefine';
	local *Service::Vault::query = $query;
	use warnings 'redefine';
	my $env = pipeline_env(test_vault());
	throws_ok { Genesis::Commands::Env::_assert_prior_env_deployed($env, 'prior-env') }
		qr{Could not read \Q$deploy\E from vault.*Code: 403}s,
		'the prior-env check names the deployment it could not read again, not a missing deploy';
	throws_ok { Genesis::Commands::Env::_get_source_sha_for_pull($env, 'prior-env', Mock->new(sha => 'control-head')) }
		qr{Could not read \Q$deploy\E from vault.*Code: 403}s,
		'and the pull source lookup stops rather than falling back to control HEAD';
};

done_testing;
