#!perl
use strict;
use warnings;
use utf8;

use Expect;
use lib 't';
use helper;
use Test::Differences;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS}=999;

subtest 'secrets-base' => sub {
	plan skip_all => 'skipping secrets tests because SKIP_SECRETS_TESTS was set'
		if $ENV{SKIP_SECRETS_TESTS};
	plan skip_all => 'secrets-base not selected test'
		if @ARGV && ! grep {$_ eq 'secrets-base'} @ARGV;

	my $vault_target = vault_ok;
	bosh2_cli_ok;
	my @directors = fake_bosh_directors qw/us-east-sandbox west-us-sandbox north-us-sandbox/;
	chdir workdir('redis-deployments') or die;

	reprovision
		init => 'redis',
		kit => 'omega-v2.7.0';

	diag "\rConnecting to the local vault (this may take a while)...";
	expects_ok "new-omega us-east-sandbox";
	system('safe tree');

	my $sec;
	my $v = "secret/us/east/sandbox/omega-v2.7.0";

	my $rotated = [qw[
	  test/random:username
	  test/random:password
	  test/random:limited

	  test/ssh/strong:public
	  test/ssh/strong:private
	  test/ssh/strong:fingerprint

	  test/ssh/meh:public
	  test/ssh/meh:private
	  test/ssh/meh:fingerprint

	  test/ssh/weak:public
	  test/ssh/weak:private
	  test/ssh/weak:fingerprint

	  test/rsa/strong:public
	  test/rsa/strong:private

	  test/rsa/meh:public
	  test/rsa/meh:private

	  test/rsa/weak:public
	  test/rsa/weak:private

	  test/fmt/sha512/default:random
	  test/fmt/sha512/default:random-crypt-sha512

	  test/fmt/sha512/at:random
	  test/fmt/sha512/at:cryptonomicon

	  auth/cf/uaa:shared_secret
	]];

	my $removed = [qw[
	  test/random:username

	  test/rsa/strong:public
	  test/rsa/strong:private

	  test/fixed/ssh:public
	  test/fixed/ssh:private
	  test/fixed/ssh:fingerprint

	  test/fmt/sha512/default:random
	  test/fmt/sha512/default:random-crypt-sha512
	]];

	my $fixed = [qw[
	  test/fixed/random:username

	  test/fixed/ssh:public
	  test/fixed/ssh:private
	  test/fixed/ssh:fingerprint

	  test/fixed/rsa:public
	  test/fixed/rsa:private

	  auth/cf/uaa:fixed
	]];

	my %before;
	for (@$rotated, @$fixed) {
	  have_secret "$v/$_";
	  $before{$_} = secret "$v/$_";
	}
	no_secret "$v/auth/github/oauth:shared_secret",
	  "should not have secrets from inactive subkits";

	is length($before{'test/random:username'}), 32,
	  "random secret is generated with correct length";

	is length($before{'test/random:password'}), 109,
	  "random secret is generated with correct length";

	like secret("$v/test/random:limited"), qr/^[a-z]{16}$/, "It is possible to limit chars used for random credentials";

	runs_ok "genesis rotate-secrets us-east-sandbox --no-prompt";
	my %after;
	for (@$rotated, @$fixed) {
	  have_secret "$v/$_";
	  $after{$_} = secret "$v/$_";
	}

	for (@$rotated) {
	  isnt $before{$_}, $after{$_}, "$_ should be rotated";
	}
	for (@$fixed) {
	  is $before{$_}, $after{$_}, "$_ should not be rotated";
	}

	# Test that nothing is missing
	my ($pass,$rc,$msg) = runs_ok "genesis check-secrets -v --exists us-east-sandbox";
	unlike $msg, qr/\.\.\. missing/, "No secrets should be missing";
	unlike $msg, qr/\.\.\. error/, "No secrets should be errored";
	matches $msg, qr/\.\.\. found/, "Found secrets should be reported";

	# Test only missing secrets are regenerated
	%before = %after;
	for (@$removed) {
	  runs_ok "safe delete -f $v/$_", "removed $v/$_  for testing";
	  no_secret "$v/$_", "$v/$_ should not exist";
	}
	($pass,$rc,$msg) = run_fails "genesis check-secrets -v --exists us-east-sandbox", 1;
	eq_or_diff $msg, <<EOF, "Only deleted secrets are missing";

[us-east-sandbox/omega-v2.7.0] determining manifest fragments for merging...done

[us-east-sandbox/omega-v2.7.0] processing secrets descriptions...
  - using kit Omega/2.0.0 (dev)
  - fetching secret definitions from kit definition file ... found 16
  - processed 16 secret definitions [4 rsa/8 random/4 ssh]

[us-east-sandbox/omega-v2.7.0] checking presence of environment secrets...
  - loading secrets from source...done
  - checking 16 secrets under path '/$v/':
    [ 1/16] auth/cf/uaa:fixed Random - 128 bytes, fixed ... found.
    [ 2/16] auth/cf/uaa:shared_secret Random - 128 bytes ... found.
    [ 3/16] test/fixed/random:username Random - 32 bytes, fixed ... found.
    [ 4/16] test/fixed/rsa RSA public/private keypair - 2048 bits, fixed ... found.
    [ 5/16] test/fixed/ssh SSH public/private keypair - 2048 bits, fixed ... missing!
    [ 6/16] test/fmt/sha512/at:random Random - 8 bytes ... found.
    [ 7/16] test/fmt/sha512/default:random Random - 8 bytes ... missing!
    [ 8/16] test/random:limited Random - 16 bytes ... found.
    [ 9/16] test/random:password Random - 109 bytes ... found.
    [10/16] test/random:username Random - 32 bytes ... missing!
    [11/16] test/rsa/meh RSA public/private keypair - 2048 bits ... found.
    [12/16] test/rsa/strong RSA public/private keypair - 4096 bits ... missing!
    [13/16] test/rsa/weak RSA public/private keypair - 1024 bits ... found.
    [14/16] test/ssh/meh SSH public/private keypair - 2048 bits ... found.
    [15/16] test/ssh/strong SSH public/private keypair - 4096 bits ... found.
    [16/16] test/ssh/weak SSH public/private keypair - 1024 bits ... found.
    failed [12 found/0 skipped/4 errors]

[FATAL] us-east-sandbox/omega-v2.7.0 - missing secrets detected.

EOF

	runs_ok "genesis add-secrets us-east-sandbox";
	for (@$rotated, @$fixed) {
	  have_secret "$v/$_";
	  $after{$_} = secret "$v/$_";
	}
	for my $path (@$rotated, @$fixed) {
	  if (grep {$_ eq $path} @$removed) {
		isnt $before{$path}, $after{$path}, "$path should be recreated with a new value";
	  } else {
		is $before{$path}, $after{$path}, "$path should be left unchanged";
	  }
	}

	reprovision kit => 'asksecrets';
	my $cmd = Expect->new();
	#$ENV{GENESIS_EXPECT_TRACE} = 'y';
	$cmd->log_stdout($ENV{GENESIS_EXPECT_TRACE} ? 1 : 0);
	$cmd->spawn("genesis new east-us-sandbox");
	$v = "secret/east/us/sandbox/asksecrets";
	expect_ok $cmd, ['password .*\[hidden\]:', sub { $_[0]->send("my-password\n");}];
	expect_ok $cmd, ['password .*\[confirm\]:',  sub { $_[0]->send("my-password\n");}];
	expect_ok $cmd, ["\\(Enter <CTRL-D> to end\\)", sub {
		$_[0]->send("this\nis\nmulti\nline\ndata\n\x4");
	}];
	expect_exit $cmd, 0, "New environment with prompted secret succeeded";
	#$ENV{GENESIS_EXPECT_TRACE} = '';
	system('safe tree');
	have_secret "$v/admin:password";
	is secret("$v/admin:password"), "my-password", "Admin password was stored properly";
	have_secret "$v/cert:pem";
	is secret("$v/cert:pem"), <<EOF, "Multi-line secret was stored properly";
this
is
multi
line
data
EOF

	reprovision kit => "certificates";

	$cmd = Expect->new();
	$cmd->log_stdout($ENV{GENESIS_EXPECT_TRACE} ? 1 : 0);
	$cmd->spawn("genesis new west-us-sandbox");
	$v = "secret/west/us/sandbox/certificates";
	expect_ok $cmd, [ "Generate all the certificates?", sub { $_[0]->send("yes\n"); }];
	expect_ok $cmd, [ "What is your base domain?", sub { $_[0]->send("cf.example.com\n"); }];
	expect_exit $cmd, 0, "genesis creates a new environment and auto-generates certificates";

	have_secret "$v/auto-generated-certs-a/ca:certificate";
	my $x509 = qx(safe get $v/auto-generated-certs-a/ca:certificate | openssl x509 -inform pem -text);
	like $x509, qr/Issuer: CN\s*=\s*ca\.n\d+\.auto-generated-certs-a/m, "CA cert is self-signed";
	like $x509, qr/Subject: CN\s*=\s*ca\.n\d+\.auto-generated-certs-a/m, "CA cert is self-signed";

	have_secret "$v/auto-generated-certs-a/server:certificate";
	$x509 = qx(safe get $v/auto-generated-certs-a/server:certificate | openssl x509 -inform pem -text);
	like $x509, qr/Issuer: CN\s*=\s*ca\.n\d+\.auto-generated-certs-a/m, "server cert is signed by the CA";
	like $x509, qr/Subject: CN\s*=\s*server\.example\.com/m, "server cert has correct CN";
	like $x509, qr/DNS:$_/m, "server cert has SAN for $_"
	  for qw/server\.example\.com \*\.server\.example\.com \*\.system\.cf\.example\.com/;
	like $x509, qr/IP Address:10\.10\.10\.10/m, "server cert has an IP SAN for 10.10.10.10";

	have_secret "$v/auto-generated-certs-a/server:key";
	like secret("$v/auto-generated-certs-a/server:key"), qr/----BEGIN RSA PRIVATE KEY----/,
		"server private key looks like an rsa private key";

	have_secret "$v/auto-generated-certs-b/ca:certificate";
	my $ca_a = secret "$v/auto-generated-certs-a/ca:certificate";
	my $ca_b = secret "$v/auto-generated-certs-b/ca:certificate";
	isnt $ca_a, $ca_b, "CA for auto-generated-certs-a is different from that for auto-generated-certs-b";

	have_secret "$v/auto-generated-certs-b/server:certificate";
	$x509 = qx(safe get $v/auto-generated-certs-b/server:certificate | openssl x509 -inform pem -text);
	like $x509, qr/Issuer: CN\s*=\s*ca\.asdf\.com/m, "server B cert is signed by the CA from auto-generated-certs-b";

	$cmd = Expect->new();
	$cmd->log_stdout($ENV{GENESIS_EXPECT_TRACE} ? 1 : 0);
	$cmd->spawn("genesis new north-us-sandbox");
	$v = "secret/north/us/sandbox/certificates";
	expect_ok $cmd, [ "Generate all the certificates?", sub { $_[0]->send("no\n"); }];
	expect_ok $cmd, [ "What is your base domain?", sub { $_[0]->send("cf.example.com\n"); }];
	expect_exit $cmd, 0, "genesis creates a new environment and doesn't create new certificates from ignored submodules";
	no_secret "$v/auto-generated-certs-b/ca";
	no_secret "$v/auto-generated-certs-b/server";

	$v = "secret/west/us/sandbox/certificates";
	runs_ok "safe delete -Rf $v", "clean up certs for rotation testing";
	no_secret "$v/auto-generated-certs-a/ca:certificate";
	($pass,$rc,$msg) = run_fails "genesis check-secrets --exists west-us-sandbox", 1;
	eq_or_diff $msg, <<'EOF', "Removed certs should be missing";

[west-us-sandbox/certificates] determining manifest fragments for merging...done

[west-us-sandbox/certificates] processing secrets descriptions...
  - using kit certificatetest/0.0.1 (dev)
  - fetching secret definitions from kit definition file ... found 6
  - processed 6 secret definitions [6 x509]

[west-us-sandbox/certificates] checking presence of environment secrets...
  - loading secrets from source...
[WARNING] Vault export returned no data for /secret/west/us/sandbox/certificates/
done
  - checking 6 secrets under path '/secret/west/us/sandbox/certificates/':
    [1/6] auto-generated-certs-a/ca X.509 certificate - CA, self-signed ... missing!
    [2/6] auto-generated-certs-a/server X.509 certificate - signed by 'auto-generated-certs-a/ca' ... missing!
    [3/6] auto-generated-certs-b/ca X.509 certificate - CA, self-signed ... missing!
    [4/6] auto-generated-certs-b/server X.509 certificate - signed by 'auto-generated-certs-b/ca' ... missing!
    [5/6] fixed/ca X.509 certificate - CA, self-signed ... missing!
    [6/6] fixed/server X.509 certificate - signed by 'fixed/ca' ... missing!
    failed [0 found/0 skipped/6 errors]

[FATAL] west-us-sandbox/certificates - missing secrets detected.

EOF
	runs_ok "genesis rotate-secrets west-us-sandbox -y", "genesis creates-secrets our certs";
	have_secret "$v/auto-generated-certs-a/server:certificate";
	my $cert = secret "$v/auto-generated-certs-a/server:certificate";
	have_secret "$v/auto-generated-certs-a/ca:certificate";
	my $ca = secret "$v/auto-generated-certs-a/ca:certificate";

	sub get_cert_validity {
		use Time::Piece;
		my ($info) = @_;
		my $pattern = "%b%n%d %H:%M:%S %Y";
		my @i = $info =~ qr/Not Before:\s(.*\s+\d{4})\s+([^\n\r]*)\s+Not After\s+:\s(.*\s+\d{4})\s+([^\n\r]*)/m;
		return undef unless $i[1] eq $i[3]; # ensure timezones are the same
		return (Time::Piece->strptime($i[2], $pattern) - Time::Piece->strptime($i[0], $pattern));
	}

	# Check correct TTL
	my $fixed_ca = qx(safe get $v/fixed/ca:certificate | openssl x509 -inform pem -text);
	is get_cert_validity($fixed_ca), (5*365*24*3600), "CA cert has a 5 year validity period";

	# Check CA alternative names and default TTL
	my $auto_b_ca = qx(safe get $v/auto-generated-certs-b/ca:certificate | openssl x509 -inform pem -text);
	like $auto_b_ca, qr/Issuer: CN\s*=\s*ca\.asdf\.com/m, "CA cert is self-signed";
	like $auto_b_ca, qr/Subject: CN\s*=\s*ca\.asdf\.com/m, "CA cert is self-signed";

	is get_cert_validity($auto_b_ca), (10*365*24*3600), "CA cert has a default 10 year validity period";


	have_secret "$v/fixed/server:certificate";
	my $fixed_cert = secret "$v/fixed/server:certificate";

	runs_ok "genesis rotate-secrets west-us-sandbox -y --regen-x509-keys", "genesis does secrets rotate the CA";
	have_secret "$v/auto-generated-certs-a/ca:certificate";
	my $new_ca = secret "$v/auto-generated-certs-a/ca:certificate";
	isnt $ca, $new_ca, "CA cert does change under normal secret rotation";

	have_secret "$v/fixed/server:certificate";
	my $new_fixed = secret "$v/fixed/server:certificate";
	is $fixed_cert, $new_fixed, "Fixed certificate doesn't change under normal secret rotation";


	$ca = secret "$v/auto-generated-certs-a/ca:certificate";
	$cert = secret "$v/auto-generated-certs-a/server:certificate";
	($pass,$rc,$msg) = runs_ok "genesis add-secrets west-us-sandbox", "genesis add-secrets doesn't rotate the CA";
	eq_or_diff $msg, <<'EOF', "genesis add-secrets reports existing secrets";

[west-us-sandbox/certificates] determining manifest fragments for merging...done

[west-us-sandbox/certificates] processing secrets descriptions...
  - using kit certificatetest/0.0.1 (dev)
  - fetching secret definitions from kit definition file ... found 6
  - processed 6 secret definitions [6 x509]

[west-us-sandbox/certificates] adding missing environment secrets...
  - loading existing secrets from source...done
  - adding 6 secrets under path '/secret/west/us/sandbox/certificates/':
    [1/6] auto-generated-certs-a/ca X.509 certificate - CA, self-signed ... exists!
    [2/6] auto-generated-certs-a/server X.509 certificate - signed by 'auto-generated-certs-a/ca' ... exists!
    [3/6] auto-generated-certs-b/ca X.509 certificate - CA, self-signed ... exists!
    [4/6] auto-generated-certs-b/server X.509 certificate - signed by 'auto-generated-certs-b/ca' ... exists!
    [5/6] fixed/ca X.509 certificate - CA, self-signed ... exists!
    [6/6] fixed/server X.509 certificate - signed by 'fixed/ca' ... exists!
    completed [0 added/6 skipped/0 errors]

[DONE] west-us-sandbox/certificates - all secrets already present, nothing to do!

EOF

	have_secret "$v/auto-generated-certs-a/ca:certificate";
	$new_ca = secret "$v/auto-generated-certs-a/ca:certificate";
	is $ca, $new_ca, "CA cert doesnt change under normal add secrets";

	have_secret "$v/auto-generated-certs-a/server:certificate";
	my $new_cert = secret "$v/auto-generated-certs-a/server:certificate";
	is $cert, $new_cert, "Certificates do not change if existing";

	runs_ok "genesis rotate-secrets -y west-us-sandbox", "genesis rotates-secrets all certs";
	have_secret "$v/auto-generated-certs-a/server:certificate";
	$new_cert = secret "$v/auto-generated-certs-a/server:certificate";
	isnt $cert, $new_cert, "Certificates are rotated normally";

	chdir $TOPDIR;
	$_->stop() for (@directors);
	teardown_vault;
};

# ---------------------------------------------------------------------------
# kit-and-manifest: FromKit and FromManifest parsers combine
#
# Coverage that isn't exercised elsewhere:
#   * Genesis::Env::Secrets::Parser::FromManifest has no unit test file
#     of its own, so this is the primary regression net for its four
#     credhub variable types (password, rsa, ssh, certificate).
#   * When both parsers fire on the same env, the "processing secrets
#     descriptions" block emits one `- fetching secret definitions ...`
#     line per parser and one aggregated `- processed N secret
#     definitions [type-breakdown]` line.  Assert the counts + type
#     mix are correct so a regression in either parser is caught here.
# ---------------------------------------------------------------------------
subtest 'kit-and-manifest' => sub {
	plan skip_all => 'skipping secrets tests because SKIP_SECRETS_TESTS was set'
		if $ENV{SKIP_SECRETS_TESTS};
	plan skip_all => 'kit-and-manifest not selected test'
		if @ARGV && ! grep {$_ eq 'kit-and-manifest'} @ARGV;

	my $vault_target = vault_ok;
	bosh2_cli_ok;
	my @directors = fake_bosh_directors('mixed-env');
	chdir workdir('mixed-secrets-deployments') or die;

	reprovision kit => 'mixed-secrets';

	# Env yml with a bosh-style variables: block hitting each of
	# FromManifest's four supported credhub types.  certificate is
	# covered twice (CA + signed) to exercise the signed_by hookup.
	put_file "mixed-env.yml", <<'EOF';
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env:         mixed-env
  bosh_env:    mixed-env
  min_version: 3.1.0
params: {}
variables:
- name: db_password
  type: password
  options:
    length: 40
- name: uaa_signing_key
  type: rsa
  options:
    key_length: 2048
- name: sshd_host_key
  type: ssh
  options:
    key_length: 2048
- name: internal_ca
  type: certificate
  options:
    is_ca: true
    common_name: ca.internal.example.com
- name: api_server_cert
  type: certificate
  options:
    ca: internal_ca
    common_name: api.internal.example.com
    alternative_names:
    - api.internal.example.com
    - "*.api.internal.example.com"
EOF
	put_file "cpi.yml", "--- {}\n";

	my $configs = "--config cloud=cpi.yml --config cpi=cpi.yml";

	# First check: nothing exists yet, we should see both parsers fire
	# and 9 total definitions produced (4 kit + 5 manifest).
	my ($pass,$rc,$msg) = run_fails "genesis check-secrets --exists mixed-env $configs", 1,
		"check-secrets exits 1 before any secrets are added";
	matches $msg, qr/fetching secret definitions from kit definition file \.\.\. found 4/,
		"FromKit parser reports 4 kit-defined secrets";
	matches $msg, qr/fetching secret definitions from manifest variables block \.\.\. found 5/,
		"FromManifest parser reports 5 manifest-defined secrets";
	matches $msg, qr/processed 9 secret definitions \[[^\]]+\]/,
		"aggregated processed count is 9 with a type-breakdown";
	# Type coverage in the breakdown: exercise each of FromManifest's
	# four types (certificate collapses under x509).  The exact order
	# and pluralisation is intentionally left flexible.
	matches $msg, qr/\[(?=[^\]]*\d+ random)(?=[^\]]*\d+ rsa)(?=[^\]]*\d+ ssh)(?=[^\]]*\d+ x509)[^\]]*\]/,
		"processed breakdown includes random, rsa, ssh, and x509";

	# Add all 9 and confirm the vault ends up populated.
	runs_ok "genesis add-secrets mixed-env $configs",
		"add-secrets generates the missing 9 secrets";
	my $v = "secret/mixed/env/mixed-secrets";
	have_secret "$v/admin:password",
		"kit-declared random secret exists";
	have_secret "$v/admin/rsa:public",
		"kit-declared rsa keypair exists (public half)";
	have_secret "$v/tls/ca:certificate",
		"kit-declared CA cert exists";
	have_secret "$v/tls/server:certificate",
		"kit-declared server cert exists";
	have_secret "$v/db_password:password",
		"manifest-declared password variable exists";
	have_secret "$v/uaa_signing_key:public",
		"manifest-declared rsa variable exists (public half)";
	have_secret "$v/sshd_host_key:public",
		"manifest-declared ssh variable exists (public half)";
	have_secret "$v/internal_ca:certificate",
		"manifest-declared CA cert exists";
	have_secret "$v/api_server_cert:certificate",
		"manifest-declared signed cert exists";

	# Follow-up check-secrets: same 9 counted, none missing.
	($pass,$rc,$msg) = runs_ok "genesis check-secrets --exists mixed-env $configs",
		"check-secrets exits 0 once all 9 are present";
	matches $msg, qr/processed 9 secret definitions/,
		"aggregated count remains 9 after add";
	unlike $msg, qr/\.{3} missing/, "no secret reports as missing after add";

	chdir $TOPDIR;
	$_->stop() for (@directors);
	teardown_vault;
};

# ---------------------------------------------------------------------------
# filter-and-flags: rotate-secrets filter regex + remove-secrets -P
#
# CLI-shaped coverage that unit + integration tests don't hit:
#   * --regen-x509-keys with a path filter (regex-style '/pattern/')
#     rotates only the matching subset.
#   * remove-secrets -P walks the plan and removes only entries in
#     an error state (dangling / half-populated), leaving healthy
#     ones alone.
# Uses the existing certificates kit (already fixtured for x509).
# ---------------------------------------------------------------------------
subtest 'filter-and-flags' => sub {
	plan skip_all => 'skipping secrets tests because SKIP_SECRETS_TESTS was set'
		if $ENV{SKIP_SECRETS_TESTS};
	plan skip_all => 'filter-and-flags not selected test'
		if @ARGV && ! grep {$_ eq 'filter-and-flags'} @ARGV;

	my $vault_target = vault_ok;
	bosh2_cli_ok;
	my @directors = fake_bosh_directors('filter-sandbox');
	chdir workdir('filter-deployments') or die;

	reprovision kit => 'certificates';
	put_file "filter-sandbox.yml", <<'EOF';
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env:      filter-sandbox
  bosh_env: filter-sandbox
params:
  base_domain: filter.example.com
EOF
	put_file "cpi.yml", "--- {}\n";
	my $configs = "--config cloud=cpi.yml --config cpi=cpi.yml";
	my $v = "secret/filter/sandbox/certificates";

	# Seed all certs, capture a stable baseline for CAs and leaf certs.
	runs_ok "genesis rotate-secrets filter-sandbox -y $configs",
		"rotate-secrets seeds all x509 secrets";
	have_secret "$v/auto-generated-certs-a/ca:certificate";
	have_secret "$v/auto-generated-certs-a/server:certificate";
	have_secret "$v/fixed/ca:certificate";
	have_secret "$v/fixed/server:certificate";

	my $ca_a_before     = secret "$v/auto-generated-certs-a/ca:certificate";
	my $server_a_before = secret "$v/auto-generated-certs-a/server:certificate";
	my $fixed_ca_before = secret "$v/fixed/ca:certificate";

	# --regen-x509-keys with a CA-only filter regex should touch the
	# auto-generated CA but leave the same-set leaf server cert and
	# the fixed-CA slot alone (fixed:1 always survives rotation).
	my ($pass, $rc, $msg) = runs_ok
		"genesis rotate-secrets filter-sandbox -y --regen-x509-keys '/ca\$/' $configs",
		"rotate-secrets --regen-x509-keys with CA-only filter";
	matches $msg, qr/rotating environment secrets/,
		"filter-scoped rotate still narrates the phase";

	my $ca_a_after     = secret "$v/auto-generated-certs-a/ca:certificate";
	my $server_a_after = secret "$v/auto-generated-certs-a/server:certificate";
	isnt $ca_a_before, $ca_a_after,
		"filter matched: auto-generated CA rotated";
	# The signed leaf gets regenerated as a side-effect of the CA key
	# rotation, so it will change too -- that's expected behavior, we
	# just don't assert equality on it.

	# Break one cert by removing the private key half, then use
	# remove-secrets -P to clean only the problematic entry.
	runs_ok "safe rm -f $v/auto-generated-certs-a/server:key",
		"remove one half of a keypair to create a problematic state";
	($pass, $rc, $msg) = runs_ok
		"GENESIS_NO_UTF8=1 genesis remove-secrets filter-sandbox -y -P $configs",
		"remove-secrets -P walks the plan and removes broken entries";
	matches $msg, qr/removing/i,
		"remove-secrets -P reports the removal phase";
	# The healthy fixed/ca should still be present; the broken server
	# cert should now be gone entirely.
	have_secret "$v/fixed/ca:certificate",
		"remove-secrets -P leaves healthy secrets alone";

	chdir $TOPDIR;
	$_->stop() for (@directors);
	teardown_vault;
};

done_testing;
