#!/usr/bin/env perl
# The shape's merge never reaches vault, with a vault standing by that would
# answer (T352, D117).  The secret is written to the harness's vault and the
# process carries that vault's address and token, so a merge that consulted
# them would read the secret; the row first shows spruce reading it that way,
# then that the shape's read refuses the key without ever holding the value.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $SECRET = 'the-value-the-shape-must-never-see';

subtest 'the shape read reaches no vault, though one would answer' => sub {
	plan tests => 5;

	my $h = make_harness(envs => [], pipeline => 1, vault => 1);
	$h->_write_record('secret/shape/test', value => $SECRET);

	my ($json) = run({env => {SAFE_TARGET => $h->fixture_vault}, stderr => 0},
		Harness::Propagation::real_tool('safe'), 'env', '--json');
	my $vault = Genesis::load_json($json);
	local $ENV{VAULT_ADDR}  = $vault->{VAULT_ADDR};
	local $ENV{VAULT_TOKEN} = $vault->{VAULT_TOKEN};
	local $ENV{VAULT_SKIP_VERIFY} = 1;

	my $probe = workdir() . '/probe.yml';
	put_file($probe, "---\nvalue: (( vault \"secret/shape/test:value\" ))\n");
	my ($read) = run({stderr => 0}, 'spruce', 'merge', $probe);
	like($read, qr/\Q$SECRET\E/, 'spruce reads the secret with what this process carries');

	commit_on_control($h, message => 'a shape key from vault', files => {
		'us.yml'      => "---\nmeta:\n  value: (( vault \"secret/shape/test:value\" ))\n",
		'us-east.yml' => "---\ngenesis:\n  env: us-east\n  pipeline:\n"
			. "    prior_env: (( concat \"c-\" meta.value \"-lab\" ))\n",
	});
	my $refusal = '';
	eval {Genesis::Top->new($h->a)->config; 1} or $refusal = $@;
	like($refusal, qr/genesis\.pipeline\.prior_env in us-east/,
		'the shape key built from the vault value is refused');
	like($refusal, qr/\(\( vault "secret\/shape\/test:value" \)\)/,
		'naming it as the vault operator it is');
	unlike($refusal, qr/\Q$SECRET\E/, 'and never the value the vault holds');

	# The same reference outside the shape, so the repository loads and the
	# merge itself can be read.
	commit_on_control($h, message => 'the vault value in content only', files => {
		'us-east.yml' => "---\ngenesis:\n  env: us-east\n"
			. "params:\n  copy: (( concat \"c-\" meta.value \"-lab\" ))\n",
	});
	my $doc = Genesis::Env->bare('us-east', Genesis::Top->new($h->a, no_vault => 1))
		->manifest_provider->vaultless_environment->data;
	unlike(join("\n", $doc->{meta}{value} // '', $doc->{params}{copy} // ''),
		qr/\Q$SECRET\E/, 'nor does the merge itself hold it anywhere');
};

done_testing;
