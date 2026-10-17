#!perl
# Proves T378 on Genesis::Top: a credential block names a type and every
# component's vault path, and nothing less loads (D27, noted 2026-10-16).
# `path` names one secret holding every component under its default key;
# any component may instead be given as <path>:<key>.  A block missing a
# component is refused by the load and before a save, so the compiler never
# meets half a credential.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Output;
use Test::Exit;

# Explicit import: Genesis also exports workdir(), which would shadow the
# helper's and break every fixture below.
use Genesis qw/mkfile_or_fail mkdir_or_fail run/;
use Genesis::Exit;

use_ok 'Genesis::Config';
provide_rc();
use_ok 'Genesis::Top';

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# A version 3 repository with a manual pipeline, and the lines given written
# into its pipeline block as they stand.
sub repo {
	my ($name, @pipeline) = @_;
	scrub_git_env();
	my $dir = workdir($name);
	mkdir_or_fail("$dir/.genesis");
	my $extra = join('', map {"  $_\n"} @pipeline);
	mkfile_or_fail("$dir/.genesis/config", <<EOF);
---
creator_version: 3.2.0
deployment_type: test-kit
manifest_store: exodus
pipeline:
  enabled: true
  provider:
    type: manual
$extra  source_control:
    repository: genesis/test-kit-deployments
version: 3
EOF
	run({dir => $dir}, 'git', 'init', '-q');
	return $dir;
}

# Runs a block that may refuse, and reports how it ended and what it said.
sub refused (&) {
	my ($block) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = 1;
	my ($code, $err);
	$err = stderr_from { $code = exit_code { $block->() } };
	$err =~ s/\s+/ /g;
	return ($code, $err);
}

my @vault = ('vault:', '  url: https://vault.example.com');

subtest 'a vault credential with no type is refused' => sub {
	plan tests => 2;
	my $dir = repo('no-type', @vault, '  auth:', '    path: secret/ci/a');
	my ($code, $err) = refused {Genesis::Top->new($dir)};
	is($code, Genesis::Exit::CONFIG, 'at CONFIG');
	like($err, qr/pipeline\.vault\.auth: missing required key type/, 'naming the type');
};

subtest 'a type with a component neither path nor its own reference gives is refused' => sub {
	plan tests => 2;
	my $dir = repo('no-component', @vault, '  auth:', '    type: approle',
		'    role_id: secret/ci/a:role');
	my ($code, $err) = refused {Genesis::Top->new($dir)};
	is($code, Genesis::Exit::CONFIG, 'at CONFIG');
	like($err, qr/pipeline\.vault\.auth: the approle credential needs secret_id/,
		'naming the missing component');
};

subtest 'path alone, or every component explicitly, loads' => sub {
	plan tests => 2;
	my $by_path = repo('by-path', @vault, '  auth:', '    type: approle',
		'    path: secret/ci/a');
	ok(eval {Genesis::Top->new($by_path); 1}, 'type and path load') or diag($@);

	my $explicit = repo('explicit', @vault, '  auth:', '    type: approle',
		'    role_id: secret/ci/a:role', '    secret_id: secret/ci/b:sid');
	ok(eval {Genesis::Top->new($explicit); 1}, 'type and both components load') or diag($@);
};

subtest "a component the type does not take is refused" => sub {
	plan tests => 2;
	my $dir = repo('foreign', @vault, '  auth:', '    type: token',
		'    path: secret/ci/a', '    role_id: secret/ci/a:role');
	my ($code, $err) = refused {Genesis::Top->new($dir)};
	is($code, Genesis::Exit::CONFIG, 'at CONFIG');
	like($err, qr/role_id is not a component of the token credential/,
		'naming the stray component and the type');
};

subtest "the source-control credential's retired vault key names path" => sub {
	plan tests => 2;
	# The source_control block is the fixture's own, so it is written whole.
	my $dir = repo('retired');
	mkfile_or_fail("$dir/.genesis/config", <<EOF);
---
creator_version: 3.2.0
deployment_type: test-kit
manifest_store: exodus
pipeline:
  enabled: true
  provider:
    type: manual
  source_control:
    repository: genesis/test-kit-deployments
    auth:
      type: ssh
      vault: secret/ci/git
version: 3
EOF

	my ($code, $err) = refused {Genesis::Top->new($dir)};
	is($code, Genesis::Exit::CONFIG, 'at CONFIG');
	like($err, qr/pipeline\.source_control\.auth\.vault: retired.*\bpath\b/,
		'naming path as what replaces it');
};

subtest 'a save that would leave a component out is refused' => sub {
	plan tests => 2;
	my $dir = repo('save', @vault, '  auth:', '    type: approle',
		'    path: secret/ci/a');
	my $top = Genesis::Top->new($dir, repair_config => 1);
	# set merges into a hash it finds, so the block is cleared first.
	$top->config->clear('pipeline.vault.auth');
	$top->config->set('pipeline.vault.auth.type', 'approle');
	my ($code, $err) = refused {$top->_validate_config_to_save};
	is($code, Genesis::Exit::CONFIG, 'at CONFIG');
	like($err, qr/the approle credential needs role_id, secret_id/,
		'naming both components the save would lose');
};

done_testing;
