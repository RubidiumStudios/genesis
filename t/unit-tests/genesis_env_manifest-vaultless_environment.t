#!/usr/bin/env perl
# The vaultless_environment manifest is the shape's merge (D117): the
# environment's own files, merged adaptively with vault unreachable to it.
# Every operator those files resolve is resolved, and a (( vault )) comes back
# as its own text, in its place and in every value built from it, so a reader
# can tell a vault value by the (( it still carries.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Top;
use Genesis::Env;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => [], pipeline => 1, vault => 0);
commit_on_control($h, message => 'a site file and a leaf', files => {
	'us.yml' => <<'EOF',
---
meta:
  site:  us-east
  value: (( vault "secret/value:test" ))
EOF
	'us-east.yml' => <<'EOF',
---
genesis:
  env: us-east
params:
  prior:          (( concat meta.site "-lab" ))
  flag:           (( grab meta.missing || true ))
  through_concat: (( concat "c-" meta.value "-lab" ))
  through_grab:   (( grab meta.value ))
  variable:       ((stemcell_version))
EOF
});

subtest 'what the environment resolves is resolved, and vault is not' => sub {
	plan tests => 6;

	# A vault this process could reach, so a merge that consulted it would
	# fail to connect rather than defer, and the row would show it.
	local $ENV{VAULT_ADDR}  = 'http://127.0.0.1:1';
	local $ENV{VAULT_TOKEN} = 'a-token-the-merge-must-not-use';

	my $top = Genesis::Top->new($h->a, no_vault => 1);
	my $env = Genesis::Env->bare('us-east', $top);
	my $doc = $env->manifest_provider->vaultless_environment->data;

	is($doc->{params}{prior}, 'us-east-lab',
		'a concat over the hierarchy resolves');
	ok($doc->{params}{flag},
		'and a grab falls back to its || default');
	is($doc->{meta}{value}, '(( vault "secret/value:test" ))',
		'a vault value comes back as its own text');
	is($doc->{params}{through_concat}, 'c-(( vault "secret/value:test" ))-lab',
		'and that text carries through a concat');
	is($doc->{params}{through_grab}, '(( vault "secret/value:test" ))',
		'and through a grab');
	is($doc->{params}{variable}, '((stemcell_version))',
		'while a credhub variable is left as written');
};

done_testing;
