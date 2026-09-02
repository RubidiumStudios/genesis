#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Deep;

use Genesis;
use Genesis::Config;
provide_rc();

use Genesis::Top;
use Genesis::Env;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# propagation_files consults the kit's blueprint hook to learn which yaml
# files the merge consumes.  Running a hook needs a reachable vault -- the
# hook environment carries SAFE_TARGET and the verify flag -- so these are
# exercised against a real one rather than the no_vault stub.
my $vault_target = vault_ok;

# Build an environment on the ops-blueprint fixture kit, whose blueprint
# returns one kit-internal fragment (manifest.yml) and one that lives in the
# deployment repository ($GENESIS_ROOT/ops/extra.yml).
sub make_ops_env {
	my ($env_name, %opts) = @_;

	my $tmp = workdir();
	my $top = Genesis::Top->create($tmp, 'ops', vault => $VAULT_URL);
	$top->link_dev_kit('t/src/ops-blueprint');

	put_file($top->path('ops/extra.yml'), "---\nextra: fragment\n");
	put_file($top->path('kit-overrides.yml'), "---\ncredentials: {}\n")
		if $opts{kit_overrides};

	put_file($top->path("$env_name.yml"), <<"EOF");
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env: $env_name
EOF

	return $top->load_env($env_name);
}

subtest 'propagation_files - carries repository-side blueprint fragments' => sub {
	# Files the blueprint names from the repository have to reach the
	# environment branch, or that branch cannot render a manifest.
	plan tests => 2;

	my $env = make_ops_env('ops-env');
	my @files = $env->propagation_files;

	ok((grep { $_ eq 'ops/extra.yml' } @files),
		'ops/extra.yml is propagated');
	ok(!(grep { $_ =~ m{(^|/)manifest\.yml$} } @files),
		'the kit-internal fragment is not propagated -- it ships in the kit');
};

subtest 'propagation_files - carries kit-overrides.yml when present' => sub {
	plan tests => 2;

	my $with = make_ops_env('ops-with-overrides', kit_overrides => 1);
	ok((grep { $_ eq 'kit-overrides.yml' } $with->propagation_files),
		'kit-overrides.yml is propagated when it exists');

	my $without = make_ops_env('ops-without-overrides');
	ok(!(grep { $_ eq 'kit-overrides.yml' } $without->propagation_files),
		'kit-overrides.yml is absent when the repository has none');
};

subtest 'propagation_files - still carries the env file and config' => sub {
	plan tests => 2;

	my $env = make_ops_env('ops-baseline');
	my @files = $env->propagation_files;

	ok((grep { $_ eq 'ops-baseline.yml' } @files),
		'the environment file is propagated');
	ok((grep { $_ eq '.genesis/config' } @files),
		'.genesis/config is propagated');
};

teardown_vault();
done_testing;
