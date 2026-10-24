#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;

# _entomb_secrets reads every vault path a manifest references with one safe
# export, reads any path the export left out or holds a typed value at again
# on its own, and resolves every reference before it writes anything.  These
# tests run the real mixin in a stand-in manifest class whose environment,
# CredHub, and local vault record every side effect, in order, and whose vault
# is a real Service::Vault that answers safe from a script.  The last one runs
# it in the real VaultifiedEntombed class instead.

use Service::Vault;
use Genesis::Env::Manifest::VaultifiedEntombed;
use Genesis::Env::Secrets::Entombment qw/credhub_var_name/;
use Cwd ();

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Everything the harness and the vault are asked to do, in order.
my @EVENTS;

# The manifest class: the mixin is loaded into it as the manifest classes
# load it, and only what the mixin calls on its own object is stood in for.
package EntombHarness {
	do('Genesis/Env/Manifest/_entombment_mixin.pm') or die($@ || $!);

	no warnings qw/redefine once/;
	*EntombHarness::prime_credhub_cache = sub { push @EVENTS, ['prime_credhub_cache']; $_[0] };
	*EntombHarness::make_local_vault    = sub { push @EVENTS, ['local_vault']; bless({}, 'EntombLocalVault') };
	*EntombHarness::put_secret          = sub { push @EVENTS, ['put_secret', @_[1,2]]; 'new' };

	sub new {
		my ($class, $vault, @references) = @_;
		return bless({vault => $vault, references => {map {($_ => 1)} @references}}, $class);
	}
	sub env             { bless({vault => $_[0]{vault}}, 'EntombEnv') }
	sub builder         { bless({}, 'EntombBuilder') }
	sub get_vault_paths { $_[0]{references} }
}
package EntombEnv {
	sub name         { 'lab-mgmt' }
	sub notify       { }
	sub vault        { $_[0]{vault} }
	sub secrets_base { '/secret/' }
	sub secrets_plan { $_[0]{secrets_plan} }
	sub workpath     { main::workdir('vaultified') }
	sub credhub      { push @EVENTS, ['credhub_target']; bless({}, 'EntombCredhub') }
}
package EntombBuilder {
	sub unevaluated { }
}
package EntombCredhub {
	sub base         { '/lab-mgmt-bosh/lab-mgmt/' }
	sub get          { undef }
	sub preload      { }
	sub is_preloaded { 1 }
}
package EntombLocalVault {
	sub set      { shift; push @EVENTS, ['local_vault_set', @_] }
	sub env      { {} }
	sub shutdown { push @EVENTS, ['local_vault_shutdown'] }
}
package main;

sub test_vault { Service::Vault->new('https://vault.example.com:8200', 'test-vault', 1, '', undef, '/secret/') }

# A query that answers safe export with $export and safe get of a path with
# what %gets holds for it, which is safe's output, or [out, rc, stderr] for an
# export or a get that fails.  A path it holds nothing for is absent, as safe
# says it.  Paths are looked up as safe reads them, without one leading or
# trailing slash and with repeated slashes collapsed.  stderr comes back on
# its own unless the caller sent it to stdout, since query() asks run() to
# keep it separate when the caller does not say.
sub safe_answers {
	my ($export, %gets) = @_;
	return sub {
		my (undef, $opts, @cmd) = @_;
		$opts = {} unless ref($opts) eq 'HASH';
		push @EVENTS, ['safe', @cmd];
		my $path = ($cmd[1] // '') =~ s{^/|/$}{}gr =~ s{/{2,}}{/}gr;
		my ($out, $rc, $err) =
			$cmd[0] eq 'export'          ? (ref($export) eq 'ARRAY' ? @$export : ($export, 0, '')) :
			ref($gets{$path}) eq 'ARRAY' ? @{$gets{$path}} :
			defined($gets{$path})        ? ($gets{$path}, 0, '') :
			                               ('', 1, "!! no secret exists at path `$path`\n");
		return (join('', grep {defined} $out, $err), $rc, undef) if ($opts->{stderr} // 0) eq '&1';
		return ($out, $rc, $err);
	};
}

# Entomb the references with safe answering as given, and return what was
# entombed as {credhub name => value}.  Progress goes to STDERR, so it is
# kept out of the test output.
sub entomb {
	my ($query, @references) = @_;
	@EVENTS = ();
	no warnings 'redefine';
	local *Service::Vault::query = $query;
	open(local *STDERR, '>', \my $progress) or die;
	EntombHarness->new(test_vault(), @references)->_entomb_secrets();
	return {map {($_->[1] => $_->[2])} grep {$_->[0] eq 'put_secret'} @EVENTS};
}

sub entombed_as { my ($path, $key, $value) = @_; (credhub_var_name($path, $key, $value, 'genesis-entombed/') => $value) }
sub safe_calls  { [map {[@{$_}[1..$#$_]]} grep {$_->[0] eq 'safe'} @EVENTS] }

# safe export of secret/a and secret/ab once gave only secret/a, so the
# second path is left out of the export, as that bug left it.
my $EXPORT_A = '{"secret/a":{"password":"apple"}}';
my $GET_AB   = "--- # secret/ab\npassword: banana\n\n";
my $REFUSED  = "Error making API request.\n\nURL: GET https://vault.example.com:8200/v1/secret/data/ab\nCode: 403. Errors:\n\n* 1 error occurred:\n\t* permission denied\n";

subtest 'entombment tells secret/a from secret/ab' => sub {
	plan tests => 1;
	my $entombed = entomb(safe_answers($EXPORT_A, 'secret/ab' => $GET_AB), 'secret/a:password', 'secret/ab:password');
	is_deeply($entombed, {entombed_as('a', 'password', 'apple'), entombed_as('ab', 'password', 'banana')},
		'each path reaches CredHub with its own value, the one the export left out read on its own');
};

subtest 'the fallback reads one secret and needs no list access' => sub {
	plan tests => 2;
	entomb(safe_answers($EXPORT_A, 'secret/ab' => $GET_AB), 'secret/a:password', 'secret/ab:password');
	my @calls = @{safe_calls()};
	is_deeply([sort @{shift(@calls)}], [sort qw{export /secret/a /secret/ab}], 'the export names both paths');
	is_deeply(\@calls, [['get', 'secret/ab']],
		'and the path it left out is read with one safe get of exactly that secret, with no key, and no export');
};

subtest 'the fallback reports a refused read' => sub {
	plan tests => 2;
	throws_ok {
		entomb(safe_answers($EXPORT_A, 'secret/ab' => ['', 1, $REFUSED]), 'secret/a:password', 'secret/ab:password')
	} qr{Could not read secret/ab from vault at https://vault\.example\.com:8200:\s.*Code: 403.*permission denied}s,
		'a refused read stops entombment, naming the path and the reason, rather than reading as an empty secret';
	ok(!grep({$_->[0] eq 'put_secret'} @EVENTS), 'and nothing reaches CredHub');
};

subtest 'the fallback reports a missing secret as having no value' => sub {
	plan tests => 1;
	throws_ok {
		entomb(safe_answers($EXPORT_A), 'secret/a:password', 'secret/ab:password')
	} qr{Manifest\s+references\s+vault\s+path\s+/secret/ab:password\s+which\s+has\s+no\s+value\s+in\s+the\s+vault},
		'a secret safe says does not exist is the reference with no value';
};

# What safe 1.26.0 prints for safe get of a secret holding one key for each
# number shape that safe prints differently from the digits stored, made by
# safe's own read path and encoder from the v1.26.0 tag, as the other files
# under t/src/safe are.
my $NUMBERS = 'secret/fixture/numbers';
my $GET_NUMBERS = get_file(Cwd::abs_path('t/src/safe/get-numbers.out'));
my %PRINTED = (
	big     => '12345678901234567000',
	e20     => '100000000000000000000',
	e21     => '1e+21',
	half    => '0.5',
	huge    => '1e+42',
	negzero => '-0',
	port    => '9000',
	tiny    => '1e-7',
);

subtest 'every number shape reaches CredHub through the fallback as safe get prints it' => sub {
	plan tests => 2;
	my $entombed = entomb(
		safe_answers($EXPORT_A, $NUMBERS => $GET_NUMBERS),
		'secret/a:password', map {"$NUMBERS:$_"} sort keys %PRINTED
	);
	is_deeply($entombed, {
		entombed_as('a', 'password', 'apple'),
		map {entombed_as('fixture/numbers', $_, $PRINTED{$_})} sort keys %PRINTED
	}, 'each number reaches CredHub as the text safe get prints, and the quoted 9000 stays 9000');
	is(scalar(grep {$_->[0] eq 'get'} @{safe_calls()}), 1, 'from one safe get of the secret');
};

# The director's exodus on kv v2 in the shape safe 1.26.0 exports it, beside
# a network lock that an older Genesis left holding a numeric pid, and the
# same exodus on kv v1, where no secret has a first version number.
my $EXODUS    = 'secret/exodus/lab-mgmt/bosh';
my $CA_CERT   = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----";
my $EXODUS_V2 = '[{"export_version":3,"data":{"secret/exodus/lab-mgmt/bosh":{"first":7,"versions":[{"value":{"ca_cert":"-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----","url":"https://10.108.16.4:25555"}}]},"secret/exodus/lab-mgmt/bosh/network-claim-lock":{"first":19,"versions":[{"value":{"at":"2026-10-24 12:09:14 +0000","env":"lab-mgmt","hostname":"bastion","pid":3834038,"token":"6f1c2a9e","user":"ubuntu"}}]}},"requires_versioning":{}}]';
my $EXODUS_V1 = $EXODUS_V2 =~ s/"first":\d+,//gr;

# The ocfp config blobstore in the shape safe 1.26.0 exports it, with a
# boolean path_style and a numeric port, and what safe 1.26.0 prints for a
# safe get of it.
my $BLOBSTORE        = 'secret/config/ocfp-lab-wayneeseguin/mgmt/bosh/blobstores/bosh';
my $EXPORT_BLOBSTORE = qq([{"export_version":3,"data":{"$BLOBSTORE":{"first":2,"versions":[{"value":{"bucket":"bosh","endpoint":"https://s3.lab:9000","host":"s3.lab","path_style":true,"port":9000,"region":"us-east-1"}}]},"secret/config/ocfp-lab-wayneeseguin/mgmt/policies":{"versions":[{"value":{"user_provided_bosh_creds":"allow"}}]}},"requires_versioning":{}}]);
my $GET_BLOBSTORE    = qq(--- # $BLOBSTORE\nbucket: bosh\nendpoint: https://s3.lab:9000\nhost: s3.lab\npath_style: "true"\nport: "9000"\nregion: us-east-1\n\n);

sub gets_of   { [map {$_->[1]} grep {$_->[0] eq 'get'} @{safe_calls()}] }
sub harnessed { [grep {$_->[0] ne 'safe'} @EVENTS] }

subtest 'every number shape reaches CredHub as the same text by every route' => sub {
	plan tests => 4;
	my @refs = map {"$NUMBERS:$_"} sort keys %PRINTED;
	my $expected = {map {entombed_as('fixture/numbers', $_, $PRINTED{$_})} sort keys %PRINTED};

	# safe 1.26.0 exports the numbers as JSON numbers, so the secret is read
	# again with safe get.
	my $typed = qq([{"export_version":3,"data":{"$NUMBERS":{"versions":[{"value":{"big":12345678901234567890,"e20":1e20,"e21":1e21,"half":0.5,"huge":999999999999999999999999999999999999999999,"negzero":-0,"port":"9000","tiny":1e-7}}]}},"requires_versioning":{}}]);
	is_deeply(entomb(safe_answers($typed, $NUMBERS => $GET_NUMBERS), @refs), $expected,
		'a format 3 export read again with safe get gives the text safe get prints');
	is_deeply(gets_of(), [$NUMBERS], 'with one safe get of the secret');

	# safe 1.25.1 and 1.26.1 export the text safe get prints.
	my $flat = '{"'.$NUMBERS.'":{'.join(',', map {qq("$_":"$PRINTED{$_}")} sort keys %PRINTED).'}}';
	is_deeply(entomb(safe_answers($flat), @refs), $expected,
		'a flat format 1 export gives the same text and the same names');

	# An export that left the path out reaches it through the fallback.
	is_deeply(entomb(safe_answers('{}', $NUMBERS => $GET_NUMBERS), @refs), $expected,
		'and so does the fallback');
};

subtest 'entombment ignores a typed value the manifest does not reference' => sub {
	plan tests => 4;
	my $expected = {
		entombed_as('exodus/lab-mgmt/bosh', 'ca_cert', $CA_CERT),
		entombed_as('exodus/lab-mgmt/bosh', 'url', 'https://10.108.16.4:25555'),
	};
	for ([kv2 => $EXODUS_V2], [kv1 => $EXODUS_V1]) {
		my ($kv, $export) = @$_;
		is_deeply(entomb(safe_answers($export), "$EXODUS:url", "$EXODUS:ca_cert"), $expected,
			"on $kv, the exodus reaches CredHub though the lock beside it holds a numeric pid");
		is_deeply(gets_of(), [], 'and nothing is read with safe get, the lock least of all');
	}
};

subtest 'entombment takes a referenced typed value from safe get' => sub {
	plan tests => 4;
	is_deeply(entomb(safe_answers($EXPORT_BLOBSTORE, $BLOBSTORE => $GET_BLOBSTORE), "$BLOBSTORE:port"),
		{entombed_as('config/ocfp-lab-wayneeseguin/mgmt/bosh/blobstores/bosh', 'port', '9000')},
		'a referenced numeric port reaches CredHub as 9000');
	is_deeply(gets_of(), [$BLOBSTORE], 'read again whole with one safe get');
	is_deeply(entomb(safe_answers($EXPORT_BLOBSTORE, $BLOBSTORE => $GET_BLOBSTORE), "$BLOBSTORE:path_style"),
		{entombed_as('config/ocfp-lab-wayneeseguin/mgmt/bosh/blobstores/bosh', 'path_style', 'true')},
		'a referenced boolean path_style reaches CredHub as true');
	is_deeply(gets_of(), [$BLOBSTORE], 'read again whole with one safe get');
};

subtest 'a referenced zero is untouched by an unreferenced -0 elsewhere' => sub {
	plan tests => 4;
	my $export = sub {qq([{"export_version":3,"data":{"secret/app":{"versions":[{"value":{"retries":$_[0]}}]},"secret/app/other":{"versions":[{"value":{"offset":-0}}]}},"requires_versioning":{}}])};
	my $get_app = qq(--- # secret/app\nretries: "0"\n\n);

	is_deeply(entomb(safe_answers($export->('0'), 'secret/app' => $get_app), 'secret/app:retries'),
		{entombed_as('app', 'retries', '0')}, 'a referenced numeric zero reaches CredHub as 0');
	is_deeply(gets_of(), ['secret/app'], 'from a safe get of its own secret, and secret/app/other is never read');
	is_deeply(entomb(safe_answers($export->('"0"'), 'secret/app' => $get_app), 'secret/app:retries'),
		{entombed_as('app', 'retries', '0')}, 'a referenced string zero reaches CredHub as 0');
	is_deeply(gets_of(), [], 'straight from the export, since the -0 marks only the path that holds it');
};

subtest 'entombment reports a missing value before any side effect' => sub {
	plan tests => 2;
	throws_ok {
		entomb(safe_answers($EXPORT_A), 'secret/a:password', 'secret/b:password')
	} qr{Manifest\s+references\s+vault\s+path\s+/secret/b:password\s+which\s+has\s+no\s+value\s+in\s+the\s+vault},
		'the reference with no value stops entombment';
	is_deeply(harnessed(), [],
		'before the local vault starts, the CredHub cache is primed, or secret/a is written anywhere');
};

subtest 'entombment falls back to the strict read when the combined export fails' => sub {
	plan tests => 4;
	my %gets = ('secret/a' => "--- # secret/a\npassword: apple\n\n", 'secret/ab' => $GET_AB);
	my $expected = {entombed_as('a', 'password', 'apple'), entombed_as('ab', 'password', 'banana')};

	is_deeply(entomb(safe_answers(['', 1, ''], %gets), 'secret/a:password', 'secret/ab:password'), $expected,
		'an export that exits nonzero with nothing on stderr reads each path on its own');
	is_deeply([sort @{gets_of()}], ['secret/a', 'secret/ab'], 'with one safe get of each');

	# A token that may read each secret but not list the paths under it.
	my $no_list = "!! Error making API request.\n\nURL: GET https://vault.example.com:8200/v1/secret/metadata/a?list=true\nCode: 403. Errors:\n\n* 1 error occurred:\n\t* permission denied\n";
	is_deeply(entomb(safe_answers(['', 1, $no_list], %gets), 'secret/a:password', 'secret/ab:password'), $expected,
		'and so does an export that is refused');
	is_deeply([sort @{gets_of()}], ['secret/a', 'secret/ab'], 'with one safe get of each');
};

subtest 'entombment keeps the CredHub names it made before for the same spelling' => sub {
	plan tests => 1;
	# The names are the ones Genesis made before every reference was looked
	# up by safe's canonical path: the secrets base is cut from the spelling,
	# and a slash left at its front becomes _/.
	is_deeply(entomb(safe_answers('{"secret/x":{"k":"v"}}', 'secret/x' => "--- # secret/x\nk: v\n\n"),
			'/secret/x:k', 'secret/x:k', 'secret//x:k'),
		{entombed_as('x', 'k', 'v'), entombed_as('_/x', 'k', 'v')},
		'/secret/x and secret/x share one name, and secret//x keeps its own');
};

subtest 'entombment resolves every spelling of one secret, and two spellings together' => sub {
	my %names = (
		'secret/x'   => 'x',           # no slash
		'/secret/x'  => 'x',           # a leading slash
		'secret//x'  => '_/x',         # repeated interior slashes
		'//secret/x' => '_//secret/x', # repeated leading slashes
		'secret/x//' => 'x//',         # repeated trailing slashes
	);
	plan tests => 1 + keys %names;
	my $answers = safe_answers('{"secret/x":{"k":"v"}}', 'secret/x' => "--- # secret/x\nk: v\n\n");
	for my $spelling (sort keys %names) {
		is_deeply(entomb($answers, "$spelling:k"), {entombed_as($names{$spelling}, 'k', 'v')},
			"$spelling resolves to the value at secret/x");
	}
	is_deeply(entomb($answers, '/secret/x:k', 'secret//x:k', '//secret/x:k', 'secret/x//:k'),
		{map {entombed_as($_, 'k', 'v')} qw{x _/x _//secret/x x//}},
		'and spellings referenced together each resolve');
};

subtest 'entombment keeps dots and colons in key names' => sub {
	plan tests => 1;
	is_deeply(entomb(safe_answers('{"secret/app":{"tls.key:v2":"pem"}}'), 'secret/app:tls.key:v2'),
		{entombed_as('app', 'tls.key:v2', 'pem')},
		'the reference splits at its first colon, so the key is tls.key:v2');
};

subtest 'entombment gives the same names for string values whether safe wrote format 1 or format 3' => sub {
	plan tests => 3;
	my @refs = ('secret/a:password', 'secret/b:user');
	my $v1 = entomb(safe_answers('{"secret/a":{"password":"apple"},"secret/b":{"user":"bob"}}'), @refs);
	# safe 1.26.0 writes format 3 only because secret/c holds a number.
	my $v3 = entomb(safe_answers('[{"export_version":3,"data":{"secret/a":{"versions":[{"value":{"password":"apple"}}]},"secret/b":{"first":4,"versions":[{"value":{"user":"bob"}}]},"secret/c":{"versions":[{"value":{"n":1}}]}},"requires_versioning":{}}]'), @refs);
	is_deeply($v1, {entombed_as('a', 'password', 'apple'), entombed_as('b', 'user', 'bob')}, 'format 1 gives these names');
	is_deeply($v3, $v1, 'and format 3 gives the same ones');
	is_deeply(gets_of(), [], 'without reading anything again');
};

subtest 'a CredHub failure after the first write leaves earlier writes in place and fails the run' => sub {
	plan tests => 2;
	my $b_name = (entombed_as('b', 'user', 'bob'))[0];
	no warnings 'redefine';
	local *EntombHarness::put_secret = sub {
		push @EVENTS, ['put_secret', @_[1,2]];
		$_[1] eq $b_name ? 'failed' : 'new'
	};
	throws_ok {
		entomb(safe_answers('{"secret/a":{"password":"apple"},"secret/b":{"user":"bob"}}'), 'secret/a:password', 'secret/b:user')
	} qr{Failed to entomb one or more secrets into Credhub}, 'the failed write fails the run';
	my ($a_name) = entombed_as('a', 'password', 'apple');
	is_deeply(harnessed(), [
		['local_vault'], ['credhub_target'], ['prime_credhub_cache'],
		['put_secret', $a_name, 'apple'], ['local_vault_set', '/secret/a', 'password', "(($a_name))"],
		['put_secret', $b_name, 'bob'],   ['local_vault_set', '/secret/b', 'user', "(($b_name))"],
	], 'after secret/a was written, which stays written, since entombment is not transactional');
};

# A credhub-based kit merges a manifest whose CredHub variables Genesis turns
# into vault references of its own, and entombs those beside the manifest's.
# Its builder answers for the manifest and finds the generated references in
# the file vaultify writes, as spruce finds them there.
sub vaultified_entomb {
	my ($query) = @_;
	@EVENTS = ();
	my $secret = Mock->new(
		from_manifest  => 1,
		var_name       => 'nats_password',
		vault_operator => '(( vault "secret/lab/nats_password:password" ))',
	);
	my $plan = Mock->new(secrets => sub { ($secret) });
	my $env = bless({vault => test_vault(), secrets_plan => $plan}, 'EntombEnv');
	my $unredacted = Mock->new(data => {
		variables       => [{name => 'nats_password', type => 'password'}],
		instance_groups => [{name => 'nats', properties => {password => '((nats_password))', url => 'nats://10.0.0.5:4222'}}],
	});
	my $builder = Mock->new(
		env                => $env,
		initiation_file    => sub { () },
		kit_files          => sub { () },
		cloud_config_files => sub { () },
		environment_files  => sub { () },
		conclusion_file    => sub { () },
		unredacted     => $unredacted,
		unevaluated    => sub {},
		full_merge_env => {},
		merge          => sub { ({name => 'nats'}, undef) },
		vault_paths    => sub {
			my (undef, %opts) = @_;
			return {'secret/lab/nats:url' => []} unless $opts{file};
			return {map {($_ => [])} get_file($opts{file}) =~ /\(\( vault "([^"]+)" \)\)/g};
		},
	);
	no warnings qw/redefine once/;
	local *Genesis::Env::Manifest::VaultifiedEntombed::prime_credhub_cache = sub { push @EVENTS, ['prime_credhub_cache']; $_[0] };
	local *Genesis::Env::Manifest::VaultifiedEntombed::make_local_vault    = sub { push @EVENTS, ['local_vault']; bless({}, 'EntombLocalVault') };
	local *Genesis::Env::Manifest::VaultifiedEntombed::put_secret          = sub { push @EVENTS, ['put_secret', @_[1,2]]; 'new' };
	local *Service::Vault::query = $query;
	open(local *STDERR, '>', \my $progress) or die;
	bless({builder => $builder}, 'Genesis::Env::Manifest::VaultifiedEntombed')->_merge();
	return {map {($_->[1] => $_->[2])} grep {$_->[0] eq 'put_secret'} @EVENTS};
}

subtest 'vaultified entombment resolves generated references before any write' => sub {
	plan tests => 3;
	my $export = '{"secret/lab/nats":{"url":"nats://10.0.0.5:4222"}}';

	throws_ok { vaultified_entomb(safe_answers($export)) }
		qr{Manifest\s+references\s+vault\s+path\s+/secret/lab/nats_password:password\s+which\s+has\s+no\s+value},
		'a generated reference with no value stops entombment';
	is_deeply(harnessed(), [],
		'before the local vault starts or the manifest\'s own reference to secret/lab/nats is written');

	is_deeply(vaultified_entomb(safe_answers($export, 'secret/lab/nats_password' => "--- # secret/lab/nats_password\npassword: s3cr3t\n\n")),
		{entombed_as('lab/nats', 'url', 'nats://10.0.0.5:4222'), entombed_as('lab/nats_password', 'password', 's3cr3t')},
		'and once it has one, the generated reference reaches CredHub beside the manifest\'s own');
};

done_testing;
