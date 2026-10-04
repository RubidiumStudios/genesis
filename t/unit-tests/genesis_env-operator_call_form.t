#!/usr/bin/env perl
# Spruce accepts an operator written as a call, (( op(args) )), as well as the
# (( op args )) form Genesis supports.  Every place Genesis reads or rewrites an
# operator assumes the supported form, the adaptive merge's deferral and the
# vaultinfo sanitiser among them, so an environment file using the call form
# is refused before any merge, naming the file and line and the form to write.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Exception;

use Genesis;
use Genesis::Top;
use Genesis::Env;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

sub env_with {
	my (%files) = @_;
	my $h = make_harness(envs => [], pipeline => 0, vault => 0);
	commit_on_control($h, message => 'environment files', files => {
		'us-east.yml' => "---\ngenesis:\n  env: us-east\n", %files,
	});
	return Genesis::Env->bare('us-east', Genesis::Top->new($h->a, no_vault => 1));
}

subtest 'the call form is refused before any merge' => sub {
	plan tests => 6;

	my $env = env_with('us.yml' => "---\nmeta:\n  notes: (( static_ips(0) ))\n");
	my $refusal = '';
	eval {$env->manifest_provider->partial_environment->data; 1} or $refusal = $@;
	like($refusal, qr/\(\( static_ips\(0\) \)\)/, 'naming the operator as written');
	like($refusal, qr/\bus\.yml\b.*\bline 3\b/s, 'and the file and line it is on');
	like($refusal, qr/\(\( static_ips 0 \)\)/, 'and the form to write instead');

	$refusal = '';
	eval {$env->manifest_provider->unevaluated_environment->data; 1} or $refusal = $@;
	like($refusal, qr/\(\( static_ips\(0\) \)\)/,
		'an unevaluated merge refuses it the same way');

	$refusal = '';
	eval {env_with('us-east.yml' => "---\ngenesis:\n  env: us-east\n"
		. "params:\n  x: (( concat(\"a\", \"b\") ))\n")
		->manifest_provider->partial_environment->data; 1} or $refusal = $@;
	like($refusal, qr/\(\( concat "a", "b" \)\)/,
		'and the rewrite keeps the arguments as written');

	$refusal = '';
	eval {env_with(
		'shared.yml'  => "---\nmeta:\n  notes: (( static_ips(0) ))\n",
		'us-east.yml' => "---\ngenesis:\n  env: us-east\n  inherits: [shared]\n",
	)->manifest_provider->partial_environment->data; 1} or $refusal = $@;
	like($refusal, qr/\bshared\.yml\b.*\bline 3\b/s,
		'a file the environment inherits explicitly is read too');
};

subtest 'the supported forms are not refused' => sub {
	plan tests => 1;

	my $env = env_with('us.yml' => "---\n"
		. "# an old note: (( static_ips(0) )) is the call form\n"
		. "meta:\n  site: us-east\n  stemcell: ((stemcell_version))\n"
		. "  prior: (( concat meta.site \"-lab\" ))\n");
	lives_ok {$env->manifest_provider->partial_environment->data}
		'the space form, a credhub variable, and a comment all merge';
};

done_testing;
