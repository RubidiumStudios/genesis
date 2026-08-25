#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::Output;

use_ok 'Service::Vault';
use_ok 'Service::Vault::None';
use Service::Vault::Remote;
use Service::Vault::Local;
use Genesis;

# -------------------------------------------------------------------------
# Helper: build a raw Service::Vault object without calling external tools
# -------------------------------------------------------------------------
sub make_vault {
	my (%args) = @_;
	my $url       = $args{url}       // 'https://vault.example.com:8200';
	my $name      = $args{name}      // 'test-vault';
	my $verify    = $args{verify}    // 1;
	my $namespace = $args{namespace} // '';
	my $strongbox = $args{strongbox};   # undef means "use default (true)"
	my $mount     = $args{mount}     // '/secret/';
	return Service::Vault->new($url, $name, $verify, $namespace, $strongbox, $mount);
}

# -------------------------------------------------------------------------
# new() constructor
# -------------------------------------------------------------------------
subtest 'new() constructor' => sub {
	plan tests => 10;

	my $v = make_vault();

	is($v->url,       'https://vault.example.com:8200', 'url stored correctly');
	is($v->name,      'test-vault',                     'name stored correctly');
	is($v->verify,    1,                                'verify coerced to 1');
	is($v->namespace, '',                               'namespace defaults to empty string');
	is($v->strongbox, 1,                                'strongbox defaults to 1');

	# mount normalisation: must be /xxx/ with leading and trailing slash
	my $v2 = make_vault(mount => 'secret');
	is($v2->{mount}, '/secret/', 'mount normalised: no slashes -> /secret/');

	my $v3 = make_vault(mount => 'secret/');
	is($v3->{mount}, '/secret/', 'mount normalised: trailing slash only -> /secret/');

	my $v4 = make_vault(mount => '/secret');
	is($v4->{mount}, '/secret/', 'mount normalised: leading slash only -> /secret/');

	# strongbox: explicit 0 yields 0
	my $v5 = make_vault(strongbox => 0);
	is($v5->strongbox, 0, 'strongbox=0 stored as 0');

	# id is generated and matches pattern name-NNNNNN
	like($v->{id}, qr/^test-vault-\d{6}$/, 'id is generated with name prefix and 6-digit suffix');
};

# -------------------------------------------------------------------------
# Accessor methods
# -------------------------------------------------------------------------
subtest 'accessor methods' => sub {
	plan tests => 8;

	my $v = make_vault(
		url       => 'https://10.0.0.1:8200',
		name      => 'my-vault',
		verify    => 0,
		namespace => 'admin',
		strongbox => 1,
		mount     => '/ops/',
	);

	is($v->url,       'https://10.0.0.1:8200', 'url()');
	is($v->name,      'my-vault',              'name()');
	is($v->verify,    0,                       'verify()');
	is($v->namespace, 'admin',                 'namespace()');
	is($v->strongbox, 1,                       'strongbox()');
	ok($v->tls,                                'tls() true for https URL');

	my $v_http = make_vault(url => 'http://10.0.0.1:8200');
	ok(!$v_http->tls, 'tls() false for http URL');

	# ref() defaults to url; ref_by_name() switches to name
	is($v->ref, 'https://10.0.0.1:8200', 'ref() returns url by default');
};

subtest 'ref_by_name() switches ref mode' => sub {
	plan tests => 3;

	my $v = make_vault(name => 'named-vault', url => 'https://vault.local:8200');
	is($v->ref, 'https://vault.local:8200', 'ref() starts as url');
	my $ret = $v->ref_by_name();
	is($ret, $v,               'ref_by_name() returns self for chaining');
	is($v->ref, 'named-vault', 'ref() returns name after ref_by_name()');
};

# -------------------------------------------------------------------------
# parse_vault_descriptor
# -------------------------------------------------------------------------
subtest 'parse_vault_descriptor() - scalar context' => sub {
	plan tests => 8;

	my $r = Service::Vault->parse_vault_descriptor('https://vault.example.com:8200');
	is(ref($r), 'HASH', 'scalar context returns hash ref');
	is($r->{url},       'https://vault.example.com:8200', 'url parsed');
	ok($r->{tls},                                          'tls true for https');
	is($r->{domain},    'vault.example.com',               'domain extracted');
	is($r->{port},      '8200',                            'port extracted');
	is($r->{strongbox}, 1,                                 'strongbox defaults to 1');
	# verify defaults to tls when not explicitly set
	ok($r->{verify},    'verify defaults to tls value (true for https)');
	ok(!defined($r->{alias}), 'alias undef when not specified');
};

subtest 'parse_vault_descriptor() - list context' => sub {
	plan tests => 5;

	my ($url, $verify, $ns, $alias, $sb) = Service::Vault->parse_vault_descriptor(
		'https://10.0.0.1:8200/ns1 as local verify no-strongbox'
	);
	is($url,    'https://10.0.0.1:8200', 'url in list context');
	is($verify, 1,                       'verify=1 in list context');
	is($ns,     'ns1',                   'namespace in list context');
	is($alias,  'local',                 'alias in list context');
	is($sb,     0,                       'no-strongbox -> 0');
};

subtest 'parse_vault_descriptor() - clauses' => sub {
	plan tests => 6;

	# no-verify with https
	my $r = Service::Vault->parse_vault_descriptor('https://vault.local:8200 no-verify');
	is($r->{verify}, 0, 'no-verify sets verify=0');
	ok($r->{tls},       'tls still true for https');

	# strongbox explicit
	my $r2 = Service::Vault->parse_vault_descriptor('https://v.local:8200 strongbox');
	is($r2->{strongbox}, 1, 'explicit strongbox=1');

	# http URL -> tls=false, verify defaults to false
	my $r3 = Service::Vault->parse_vault_descriptor('http://10.0.0.1:8200');
	ok(!$r3->{tls},    'tls false for http');
	ok(!$r3->{verify}, 'verify defaults to false for http');

	# alias via "as" - the regex requires a trailing space after the alias token,
	# so the alias must be followed by another clause (not at end of string)
	my $r4 = Service::Vault->parse_vault_descriptor('https://v.local:8200 as my-alias no-verify');
	is($r4->{alias}, 'my-alias', 'alias parsed from "as" clause');
};

subtest 'parse_vault_descriptor() - error cases' => sub {
	plan tests => 2;

	quietly {
		throws_ok {
			Service::Vault->parse_vault_descriptor('no-strongbox')
		} qr/Missing connect clause/i,
			'dies with "Missing connect clause" when no URL given';
	};

	quietly {
		throws_ok {
			Service::Vault->parse_vault_descriptor('https://v.local:8200 badclause')
		} qr/Unknown clause/i,
			'dies with "Unknown clause" for unrecognised token';
	};
};

# -------------------------------------------------------------------------
# build_descriptor
# -------------------------------------------------------------------------
subtest 'build_descriptor() contains url and alias' => sub {
	plan tests => 4;

	my $v = make_vault(
		url       => 'https://vault.example.com:8200',
		name      => 'prod',
		verify    => 1,
		strongbox => 1,
	);
	my $desc = $v->build_descriptor();
	like($desc, qr{https://vault\.example\.com:8200}, 'descriptor contains url');
	like($desc, qr/as prod/,                           'descriptor contains alias');
	unlike($desc, qr/no-verify/,                       'no "no-verify" when verify=1');
	unlike($desc, qr/no-strongbox/,                    'no "no-strongbox" when strongbox=1');
};

subtest 'build_descriptor() with no-verify and no-strongbox' => sub {
	plan tests => 2;

	my $v = make_vault(
		url       => 'https://vault.example.com:8200',
		name      => 'prod',
		verify    => 0,
		strongbox => 0,
	);
	my $desc = $v->build_descriptor();
	like($desc, qr/no-verify/,    'descriptor contains "no-verify" when verify=0');
	like($desc, qr/no-strongbox/, 'descriptor contains "no-strongbox" when strongbox=0');
};

# -------------------------------------------------------------------------
# set_as_current / is_current / current()
# -------------------------------------------------------------------------
subtest 'set_as_current / is_current / current()' => sub {
	plan tests => 5;

	Service::Vault->clear_all();

	my $v1 = make_vault(name => 'vault-a');
	my $v2 = make_vault(name => 'vault-b');

	ok(!$v1->is_current, 'vault-a is not current before set_as_current');
	ok(!Service::Vault->current, 'current() is undef initially');

	$v1->set_as_current();
	ok($v1->is_current,              'vault-a is_current after set_as_current');
	is(Service::Vault->current, $v1, 'current() returns vault-a');

	$v2->set_as_current();
	ok(!$v1->is_current, 'vault-a is no longer current after vault-b set_as_current');

	Service::Vault->clear_all();
};

# -------------------------------------------------------------------------
# clear_all()
# -------------------------------------------------------------------------
subtest 'clear_all()' => sub {
	plan tests => 3;

	my $v = make_vault(name => 'cleared-vault');
	$v->set_as_current();
	ok(Service::Vault->current, 'current set before clear_all');

	my $ret = Service::Vault->clear_all();
	ok(!Service::Vault->current, 'current is undef after clear_all');

	# Returns the invocant (the class string when called on class)
	ok($ret, 'clear_all() returns a truthy value (the invocant)');
};

# -------------------------------------------------------------------------
# query() - monkey-patch run() to verify env setup
# -------------------------------------------------------------------------
subtest 'query() sets SAFE_TARGET and DEBUG env vars' => sub {
	plan tests => 3;

	my $v = make_vault(name => 'q-vault', url => 'https://q.vault.local:8200');

	my $run_called   = 0;
	my %captured_env;

	no warnings 'redefine';
	local *Service::Vault::run = sub {
		my $opts = ref($_[0]) eq 'HASH' ? shift : {};
		$run_called = 1;
		%captured_env = %{$opts->{env} || {}};
		return ('output', 0, '');
	};
	use warnings 'redefine';

	$v->query('get', '/secret/test:key');

	ok($run_called, 'query() calls run()');
	is($captured_env{SAFE_TARGET}, $v->ref,
		'query() sets SAFE_TARGET to vault ref');
	is($captured_env{DEBUG}, '',
		'query() clears DEBUG env var');
};

subtest 'query() prepends "safe" to command' => sub {
	plan tests => 2;

	my $v = make_vault();

	my @run_cmd;
	no warnings 'redefine';
	local *Service::Vault::run = sub {
		my $opts = ref($_[0]) eq 'HASH' ? shift : {};
		@run_cmd = @_;
		return ('', 0, '');
	};
	use warnings 'redefine';

	$v->query('get', '/secret/test:key');
	is($run_cmd[0], 'safe', 'query() prepends "safe" when first arg is not "safe"');

	@run_cmd = ();
	$v->query('safe', 'get', '/secret/test:key');
	is($run_cmd[0], 'safe', 'query() does not double-prepend "safe"');
};

# -------------------------------------------------------------------------
# get($path, $key) - with key
# Monkey-patch query() at the package level so internal $self->query() calls
# are intercepted (MockWrapper only intercepts calls FROM OUTSIDE the object)
# -------------------------------------------------------------------------
subtest 'get($path, $key) returns value on success' => sub {
	plan tests => 2;

	my $v = make_vault();
	my @query_args;

	no warnings 'redefine';
	local *Service::Vault::query = sub {
		my ($self, @args) = @_;
		@query_args = @args;
		return ('secret-value', 0, '');
	};
	use warnings 'redefine';

	my $result = $v->get('/secret/myapp', 'password');
	is($result, 'secret-value', 'get() returns output from query on success');
	like($query_args[-1], qr{/secret/myapp:password}, 'get() constructs path:key arg');
};

subtest 'get($path, $key) returns undef on failure' => sub {
	plan tests => 1;

	my $v = make_vault();

	no warnings 'redefine';
	local *Service::Vault::query = sub { return ('error output', 1, 'err') };
	use warnings 'redefine';

	my $result = $v->get('/secret/myapp', 'password');
	ok(!defined($result), 'get() returns undef on non-zero rc');
};

subtest 'get($path) without key returns hash ref' => sub {
	plan tests => 2;

	my $v = make_vault();
	my $yaml = "password: hunter2\nuser: admin\n";

	no warnings 'redefine';
	local *Service::Vault::query = sub { return ($yaml, 0, '') };
	use warnings 'redefine';

	my $result = $v->get('/secret/myapp');
	is(ref($result), 'HASH', 'get() without key returns hash ref');
	is($result->{password}, 'hunter2', 'get() hash contains parsed YAML value');
};

subtest 'get($path) without key returns empty hash on error' => sub {
	plan tests => 2;

	my $v = make_vault();

	no warnings 'redefine';
	local *Service::Vault::query = sub { return ('', 1, 'error') };
	use warnings 'redefine';

	my $result = $v->get('/secret/myapp');
	is(ref($result), 'HASH', 'get() returns hash ref even on error');
	is(scalar(keys %$result), 0, 'get() returns empty hash on error');
};

subtest 'get() splits combined path:key from single arg' => sub {
	plan tests => 2;

	my $v = make_vault();
	my @query_args;

	no warnings 'redefine';
	local *Service::Vault::query = sub {
		my ($self, @args) = @_;
		@query_args = @args;
		return ('value', 0, '');
	};
	use warnings 'redefine';

	# When path contains a colon, get() splits into path and key
	$v->get('/secret/myapp:password');
	# The last arg should be path:key
	like($query_args[-1], qr{/secret/myapp:password},
		'path:key form passed through correctly');
	# The first arg should be an opts hash (redact_output)
	is(ref($query_args[0]), 'HASH', 'first arg is options hash');
};

# -------------------------------------------------------------------------
# set()
# -------------------------------------------------------------------------
subtest 'set($path, $key, $value) writes and returns value' => sub {
	plan tests => 2;

	# These are about what reaches safe.  Reading it back is
	# service_vault-write_confirmation.t's subject.
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';
	my $v = make_vault();
	my @query_args;

	no warnings 'redefine';
	local *Service::Vault::query = sub {
		my ($self, @args) = @_;
		@query_args = @args;
		return ('', 0, '');
	};
	use warnings 'redefine';

	my $result = $v->set('/secret/myapp', 'password', 'hunter2');
	is($result, 'hunter2', 'set() returns the value written');
	like(join(' ', grep { !ref($_) } @query_args), qr/password=hunter2/,
		'set() passes key=value to query');
};

subtest 'set() dies on failure' => sub {
	plan tests => 1;

	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';
	my $v = make_vault();

	no warnings 'redefine';
	local *Service::Vault::query = sub { return ('error', 1, '') };
	use warnings 'redefine';

	quietly {
		throws_ok {
			$v->set('/secret/myapp', 'password', 'hunter2');
		} qr/Could not write/i,
			'set() throws on non-zero rc from query';
	};
};

# -------------------------------------------------------------------------
# clear()
# -------------------------------------------------------------------------
subtest 'clear($path) non-recursive: skips if path absent' => sub {
	plan tests => 1;

	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';
	my $v = make_vault();
	my $query_called = 0;

	no warnings 'redefine';
	local *Service::Vault::query = sub { $query_called = 1; return ('', 0, '') };
	local *Service::Vault::has   = sub { 0 };  # path does not exist
	use warnings 'redefine';

	$v->clear('/secret/gone');
	ok(!$query_called, 'clear() does not call query when path does not exist');
};

subtest 'clear($path) non-recursive: runs rm -f when path exists' => sub {
	plan tests => 2;

	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';
	my $v = make_vault();
	my @query_args;

	no warnings 'redefine';
	local *Service::Vault::has   = sub { 1 };
	local *Service::Vault::query = sub {
		my ($self, @args) = @_;
		@query_args = @args;
		return ('', 0, '');
	};
	use warnings 'redefine';

	my $result = $v->clear('/secret/mypath');
	ok($result, 'clear() returns true on success');
	like(join(' ', grep { !ref($_) } @query_args), qr/rm.*-f/,
		'clear() uses "rm -f" for non-recursive');
};

subtest 'clear($path, 1) recursive: runs rm -rf' => sub {
	plan tests => 1;

	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';
	my $v = make_vault();
	my @query_args;

	no warnings 'redefine';
	local *Service::Vault::query = sub {
		my ($self, @args) = @_;
		@query_args = @args;
		return ('', 0, '');
	};
	use warnings 'redefine';

	$v->clear('/secret/mypath', 1);
	like(join(' ', grep { !ref($_) } @query_args), qr/rm.*-rf/,
		'clear() uses "rm -rf" for recursive');
};

# -------------------------------------------------------------------------
# has()
# -------------------------------------------------------------------------
subtest 'has() returns true when path exists' => sub {
	plan tests => 2;

	my $v = make_vault();
	my @query_args;

	no warnings 'redefine';
	local *Service::Vault::query = sub {
		my ($self, @args) = @_;
		@query_args = @args;
		# has() uses passfail=>1 so query() returns a single boolean;
		# simulate rc=0 (path exists) by returning 1
		return 1;
	};
	use warnings 'redefine';

	my $result = $v->has('/secret/myapp');
	ok($result, 'has() returns true when path exists (query returns 1)');
	like(join(' ', grep { !ref($_) } @query_args), qr/exists/,
		'has() uses "exists" subcommand');
};

subtest 'has() returns false when path absent' => sub {
	plan tests => 1;

	my $v = make_vault();

	no warnings 'redefine';
	# has() uses passfail=>1 so query() returns a single boolean;
	# simulate rc=1 (path absent) by returning 0
	local *Service::Vault::query = sub { return 0 };
	use warnings 'redefine';

	my $result = $v->has('/secret/missing');
	ok(!$result, 'has() returns false when path absent (query returns 0)');
};

subtest 'has($path, $key) appends key to path' => sub {
	plan tests => 1;

	my $v = make_vault();
	my @query_args;

	no warnings 'redefine';
	local *Service::Vault::query = sub {
		my ($self, @args) = @_;
		@query_args = @args;
		return 1;  # passfail mode returns a single boolean
	};
	use warnings 'redefine';

	$v->has('/secret/myapp', 'password');
	like(join(' ', grep { !ref($_) } @query_args), qr{/secret/myapp:password},
		'has() appends :key when key arg given');
};

# -------------------------------------------------------------------------
# paths()
# -------------------------------------------------------------------------
subtest 'paths() with no prefix returns all paths' => sub {
	plan tests => 2;

	my $v = make_vault();

	no warnings 'redefine';
	local *Service::Vault::query = sub { return ("/secret/a\n/secret/b\n/secret/c", 0, '') };
	use warnings 'redefine';

	my @paths = $v->paths();
	is(scalar(@paths), 3, 'paths() returns all 3 paths');
	is($paths[0], '/secret/a', 'paths() first entry correct');
};

subtest 'paths() with prefix passes prefix to query' => sub {
	plan tests => 2;

	my $v = make_vault();
	my @query_args;

	no warnings 'redefine';
	local *Service::Vault::has   = sub { 1 };
	local *Service::Vault::query = sub {
		my ($self, @args) = @_;
		@query_args = @args;
		return ("/secret/app/pass\n/secret/app/user", 0, '');
	};
	use warnings 'redefine';

	my @paths = $v->paths('/secret/app');
	is(scalar(@paths), 2, 'paths() returns 2 paths under prefix');
	ok((grep { $_ eq '/secret/app' } @query_args), 'paths() passes prefix to query');
};

# -------------------------------------------------------------------------
# keys()
# -------------------------------------------------------------------------
subtest 'keys() with no prefix returns all path:key pairs' => sub {
	plan tests => 2;

	my $v = make_vault();

	no warnings 'redefine';
	local *Service::Vault::query = sub { return ("/secret/a:pass\n/secret/b:user", 0, '') };
	use warnings 'redefine';

	my @keys = $v->keys();
	is(scalar(@keys), 2, 'keys() returns 2 path:key pairs');
	is($keys[0], '/secret/a:pass', 'keys() first entry correct');
};

subtest 'keys() passes --keys flag to safe paths' => sub {
	plan tests => 1;

	my $v = make_vault();
	my @query_args;

	no warnings 'redefine';
	local *Service::Vault::query = sub {
		my ($self, @args) = @_;
		@query_args = @args;
		return ('', 0, '');
	};
	use warnings 'redefine';

	$v->keys();
	ok((grep { $_ eq '--keys' } @query_args), 'keys() passes --keys to query');
};

# -------------------------------------------------------------------------
# status()
# Monkey-patch tcp_listening (imported into Service::Vault namespace)
# and query/authenticated/initialized on the instance via package override
# -------------------------------------------------------------------------
subtest 'status() returns "unreachable" when tcp not listening' => sub {
	plan tests => 1;

	my $v = make_vault(url => 'https://192.0.2.1:8200');

	no warnings 'redefine';
	local *Service::Vault::tcp_listening = sub { return 'failed' };
	use warnings 'redefine';

	my $status = $v->status();
	like($status, qr/unreachable/, 'status() is unreachable when tcp_listening fails');
};

subtest 'status() returns "sealed" when vault status exit code is 2' => sub {
	plan tests => 1;

	my $v = make_vault(url => 'https://192.0.2.1:8200');

	no warnings 'redefine';
	local *Service::Vault::tcp_listening = sub { return 'ok' };
	local *Service::Vault::query = sub { return ("exit status 2", 1, '') };
	use warnings 'redefine';

	my $status = $v->status();
	is($status, 'sealed', 'status() returns "sealed" when vault exits with code 2');
};

subtest 'status() returns "unreachable" when exit code is 0 (not 2)' => sub {
	plan tests => 1;

	my $v = make_vault(url => 'https://192.0.2.1:8200');

	# status() code: $out =~ /exit status ([0-9])/; return "sealed" if $1//0 == 2;
	# Due to Perl operator precedence, $1//0 == 2 parses as ($1 // (0==2)) = ($1 // "").
	# Any defined non-"0" value of $1 is truthy and triggers "sealed".
	# "unreachable" requires $1 to be falsy: use "exit status 0" so $1 = "0" (falsy in Perl).
	no warnings 'redefine';
	local *Service::Vault::tcp_listening = sub { return 'ok' };
	local *Service::Vault::query = sub { return ("exit status 0", 1, '') };
	use warnings 'redefine';

	my $status = $v->status();
	is($status, 'unreachable', 'status() returns "unreachable" when exit status is 0');
};

subtest 'status() returns "unauthenticated" when not authenticated' => sub {
	plan tests => 1;

	my $v = make_vault(url => 'https://192.0.2.1:8200');

	no warnings 'redefine';
	local *Service::Vault::tcp_listening  = sub { return 'ok' };
	local *Service::Vault::query          = sub { return ('', 0, '') };
	local *Service::Vault::authenticated  = sub { 0 };
	use warnings 'redefine';

	my $status = $v->status();
	is($status, 'unauthenticated', 'status() returns "unauthenticated" when not authed');
};

subtest 'status() returns "uninitialized" when not initialized' => sub {
	plan tests => 1;

	my $v = make_vault(url => 'https://192.0.2.1:8200');

	no warnings 'redefine';
	local *Service::Vault::tcp_listening  = sub { return 'ok' };
	local *Service::Vault::query          = sub { return ('', 0, '') };
	local *Service::Vault::authenticated  = sub { 1 };
	local *Service::Vault::initialized    = sub { 0 };
	use warnings 'redefine';

	my $status = $v->status();
	is($status, 'uninitialized', 'status() returns "uninitialized" when no handshake');
};

subtest 'status() returns "ok" when reachable, authenticated, and initialized' => sub {
	plan tests => 1;

	my $v = make_vault(url => 'https://192.0.2.1:8200');

	no warnings 'redefine';
	local *Service::Vault::tcp_listening  = sub { return 'ok' };
	local *Service::Vault::query          = sub { return ('', 0, '') };
	local *Service::Vault::authenticated  = sub { 1 };
	local *Service::Vault::initialized    = sub { 1 };
	use warnings 'redefine';

	my $status = $v->status();
	is($status, 'ok', 'status() returns "ok" when all conditions met');
};

# -------------------------------------------------------------------------
# initialized()
# -------------------------------------------------------------------------
subtest 'initialized() checks for handshake at secrets mount' => sub {
	plan tests => 2;

	my $v = make_vault();
	my @checked;

	no warnings 'redefine';
	local *Service::Vault::has = sub {
		my ($self, $path) = @_;
		push @checked, $path;
		return $path =~ /handshake/ ? 1 : 0;
	};
	use warnings 'redefine';

	my $result = $v->initialized();
	ok($result, 'initialized() returns true when handshake exists');
	ok((grep { /handshake/ } @checked), 'initialized() checked a path containing "handshake"');
};

subtest 'initialized() returns false when no handshake found' => sub {
	plan tests => 1;

	my $v = make_vault();

	no warnings 'redefine';
	local *Service::Vault::has = sub { 0 };
	use warnings 'redefine';

	my $result = $v->initialized();
	ok(!$result, 'initialized() returns false when handshake not found');
};

# -------------------------------------------------------------------------
# Service::Vault::None
# -------------------------------------------------------------------------
subtest 'Service::Vault::None - construction' => sub {
	plan tests => 2;

	my $none = Service::Vault::None->new();
	ok($none, 'Service::Vault::None->new() returns an object');
	is(ref($none), 'Service::Vault::None', 'object is a Service::Vault::None');
};

subtest 'Service::Vault::None - name() returns empty string' => sub {
	plan tests => 1;

	my $none = Service::Vault::None->new();
	is($none->name(), '', 'name() returns empty string');
};

subtest 'Service::Vault::None - status() returns "absent"' => sub {
	plan tests => 1;

	my $none = Service::Vault::None->new();
	is($none->status(), 'absent', 'status() returns "absent"');
};

subtest 'Service::Vault::None - new() ignores arguments' => sub {
	plan tests => 2;

	my $none = Service::Vault::None->new('ignored', key => 'also-ignored');
	ok($none, 'new() with arguments still constructs object');
	is(ref($none), 'Service::Vault::None', 'result is still a Service::Vault::None');
};

subtest 'Service::Vault::None - AUTOLOAD dies on other methods' => sub {
	plan tests => 3;

	local $ENV{GENESIS_COMMAND} = 'test-cmd';

	my $none = Service::Vault::None->new();

	throws_ok { $none->get('/secret/x') }
		qr/bug|should not need a vault/i,
		'get() triggers AUTOLOAD and dies';

	throws_ok { $none->set('/secret/x', 'k', 'v') }
		qr/bug|should not need a vault/i,
		'set() triggers AUTOLOAD and dies';

	throws_ok { $none->has('/secret/x') }
		qr/bug|should not need a vault/i,
		'has() triggers AUTOLOAD and dies';
};

subtest 'Service::Vault::None - sentinel detection patterns' => sub {
	plan tests => 2;

	my $none = Service::Vault::None->new();

	is(ref($none), 'Service::Vault::None',
		'ref() check works for class-based detection');
	is($none->status(), 'absent',
		'status() check works for value-based detection');
};

# -------------------------------------------------------------------------
# rebind() - class-agnostic, callback-context lookup by URL from
# $ENV{GENESIS_TARGET_VAULT}.  Returns whatever kind of vault sits at
# the target URL (Remote OR Local) -- callers in bash-hook subprocess
# contexts must not need to know or care.  Regression prevention for a
# prior design where rebind() lived on Remote and class-filtered its
# find(), which silently excluded Local vaults and bailed on any
# kit-test / dev-loop that used `safe local -m` -- see kit-validator's
# HOME-sandbox setup.
# -------------------------------------------------------------------------
subtest 'rebind() - missing GENESIS_TARGET_VAULT throws' => sub {
	plan tests => 1;

	delete local $ENV{GENESIS_TARGET_VAULT};

	quietly {
		throws_ok { Service::Vault->rebind() }
			qr/Cannot rebind to vault in callback due to missing environment variables/i,
			'rebind() throws when GENESIS_TARGET_VAULT is not set';
	};
};

subtest 'rebind() returns the vault at the URL regardless of subclass' => sub {
	plan tests => 4;

	local $ENV{GENESIS_TARGET_VAULT} = 'http://127.0.0.1:8201';

	# Case 1: URL resolves to a Remote vault.
	Service::Vault->clear_all();
	{
		my $r = bless {
			url => 'http://127.0.0.1:8201', name => 'remote-vault',
			verify => 0, namespace => '', strongbox => 0,
		}, 'Service::Vault::Remote';

		no warnings 'redefine';
		local *Service::Vault::find = sub { ($r) };
		use warnings 'redefine';

		my $ret = Service::Vault->rebind();
		is(ref($ret), 'Service::Vault::Remote', 'Remote at URL is returned as Remote');
		is($ret->{name}, 'remote-vault', 'correct Remote instance returned');
	}

	# Case 2: URL resolves to a Local vault -- the case that used to bail.
	Service::Vault->clear_all();
	{
		my $l = bless {
			url => 'http://127.0.0.1:8201', name => 'local_vault_test_1234',
			verify => 0, namespace => '', strongbox => 0,
		}, 'Service::Vault::Local';

		no warnings 'redefine';
		local *Service::Vault::find = sub { ($l) };
		use warnings 'redefine';

		my $ret = Service::Vault->rebind();
		is(ref($ret), 'Service::Vault::Local', 'Local at URL is returned as Local');
		is($ret->{name}, 'local_vault_test_1234', 'correct Local instance returned');
	}

	Service::Vault->clear_all();
};

subtest 'rebind() throws when URL is not found in .saferc' => sub {
	plan tests => 1;

	local $ENV{GENESIS_TARGET_VAULT} = 'http://nowhere.invalid:8200';

	no warnings 'redefine';
	local *Service::Vault::find = sub { () };
	use warnings 'redefine';

	quietly {
		throws_ok { Service::Vault->rebind() }
			qr/Cannot rebind to vault at address/i,
			'rebind() throws when URL is unknown';
	};
};

# -------------------------------------------------------------------------
# set() - key/value pairs, and the chunking that writing them requires
#
# Confirmation is suppressed throughout: what a write reads back is
# service_vault-write_confirmation.t's subject, and these are about the
# shape of the write itself.
# -------------------------------------------------------------------------

# Capture what set() hands to safe, one entry per `safe set` call.
sub capture_sets {
	my ($v) = @_;
	my $calls = [];
	$v->{__sets} = $calls;
	return $calls;
}

# Named so each subtest can install it with `local`, as the rest of this
# file does -- a file-scoped override would outlive them.
sub mock_capture_query {
	my $self = shift;
	shift if ref($_[0]) eq 'HASH';
	my ($cmd, @args) = @_;
	push(@{$self->{__sets}}, [@args]) if $cmd eq 'set' && $self->{__sets};
	return ('', 0, '');
}

subtest 'set() still takes a single key and value' => sub {
	plan tests => 3;
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';

	no warnings 'redefine';
	local *Service::Vault::query = \&mock_capture_query;
	use warnings 'redefine';

	my $v = make_vault(name => 'single');
	my $calls = capture_sets($v);
	my $got = $v->set('secret/one', 'password', 'hunter2');

	is scalar(@$calls), 1, 'one write';
	eq_or_diff $calls->[0], ['secret/one', 'password=hunter2'],
		'sent as a single key=value pair';
	is $got, 'hunter2', 'and returns the value, as it always did';
};

subtest 'set() takes a list of key/value pairs' => sub {
	plan tests => 3;
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';

	no warnings 'redefine';
	local *Service::Vault::query = \&mock_capture_query;
	use warnings 'redefine';

	my $v = make_vault(name => 'multi');
	my $calls = capture_sets($v);
	my $got = $v->set('secret/many', alpha => 1, beta => 2, gamma => 3);

	is scalar(@$calls), 1, 'small enough to go in one write';
	my ($path, @pairs) = @{$calls->[0]};
	is $path, 'secret/many', 'written to the given path';
	eq_or_diff [sort @pairs], ['alpha=1', 'beta=2', 'gamma=3'],
		'every pair present';
};

subtest 'set() refuses an odd number of arguments' => sub {
	plan tests => 1;
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';
	local $ENV{GENESIS_IGNORE_EVAL} = '';

	no warnings 'redefine';
	local *Service::Vault::query = \&mock_capture_query;
	use warnings 'redefine';

	my $v = make_vault(name => 'odd');
	capture_sets($v);
	# Three trailing args cannot be pairs, and treating the last as a
	# value would silently drop one -- exactly the class of bug this
	# ticket exists for.
	quietly {
		throws_ok { $v->set('secret/odd', 'a', 1, 'b') }
			qr/pairs|odd number/i,
			'an unpaired argument is an error, not a silent drop';
	};
};

subtest 'set() still prompts when no value is given' => sub {
	plan tests => 2;
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';
	local $ENV{GENESIS_IGNORE_EVAL} = '';

	no warnings 'redefine';
	local *Service::Vault::query = \&mock_capture_query;
	use warnings 'redefine';

	my $v = make_vault(name => 'prompt');
	capture_sets($v);

	# A lone key means "ask me for it".
	quietly {
		throws_ok { $v->set('secret/p', 'password') }
			qr/controlling terminal/i,
			'a bare key takes the interactive path';
	};

	# And so does an explicit undef value: that reached the interactive
	# branch before pair lists existed, and a 2-element list must not
	# quietly turn it into a write of the empty string.
	quietly {
		throws_ok { $v->set('secret/p', 'password', undef) }
			qr/controlling terminal/i,
			'an explicit undef value does too';
	};
};

subtest 'set() accepts a joined path:key' => sub {
	plan tests => 4;
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';
	local $ENV{GENESIS_IGNORE_EVAL} = '';

	# get() already splits this form, so set() matching it is consistency
	# rather than new syntax.  The key comes from the path, which makes
	# the argument after it a value.
	no warnings 'redefine';
	local *Service::Vault::query = \&mock_capture_query;
	use warnings 'redefine';

	my $v = make_vault(name => 'joined');
	my $calls = capture_sets($v);
	$v->set('secret/foo:password', 'hunter2');
	eq_or_diff $calls->[0], ['secret/foo', 'password=hunter2'],
		'the key is taken from the path and the argument is its value';

	# With nothing after it, there is still a key but no value.
	quietly {
		throws_ok { $v->set('secret/foo:password') }
			qr/controlling terminal/i,
			'a joined path with no value prompts for it';
	};

	# A joined path names one key, so pairs after it would name a second
	# and contradict it.
	quietly {
		throws_ok { $v->set('secret/foo:password', 'a', 'b') }
			qr/one value|one key/i,
			'more than one value after a joined path is an error';
	};

	quietly {
		throws_ok { $v->set('secret/foo:password', a => 1, b => 2) }
			qr/one value|one key/i,
			'and so are pairs';
	};
};

subtest 'set() refuses a path with no key at all' => sub {
	plan tests => 1;
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';
	local $ENV{GENESIS_IGNORE_EVAL} = '';

	no warnings 'redefine';
	local *Service::Vault::query = \&mock_capture_query;
	use warnings 'redefine';

	my $v = make_vault(name => 'keyless');
	my $calls = capture_sets($v);
	# An empty pair list would otherwise write nothing and report success.
	quietly {
		throws_ok { $v->set('secret/nokey') }
			qr/no key|key.*given/i,
			'a bare path is an error rather than a silent no-op';
	};
};

subtest 'set() chunks a payload too large for one command' => sub {
	plan tests => 3;
	local $ENV{GENESIS_VAULT_CONFIRM_WRITES} = '0';

	no warnings 'redefine';
	local *Service::Vault::query = \&mock_capture_query;
	use warnings 'redefine';

	my $v = make_vault(name => 'chunky');
	my $calls = capture_sets($v);

	# 900 characters is where safe was empirically found to corrupt a
	# write; this is comfortably past it.
	my %data = map {("key-with-a-reasonably-long-name-$_" => "value-$_" x 4)} (1..45);
	$v->set('secret/chunky', %data);

	cmp_ok scalar(@$calls), '>', 1, 'the payload was split across writes';

	my $longest = 0;
	for my $call (@$calls) {
		my (undef, @pairs) = @$call;
		my $len = length(join(' ', @pairs));
		$longest = $len if $len > $longest;
	}
	cmp_ok $longest, '<=', 900, 'no single write exceeds the guard';

	my %seen;
	for my $call (@$calls) {
		my (undef, @pairs) = @$call;
		$seen{(split /=/, $_, 2)[0]} = 1 for @pairs;
	}
	eq_or_diff [sort keys %seen], [sort keys %data],
		'and every key was written exactly once across the chunks';
};

done_testing;
