#!perl
# Proves T379: the compile emits each credential component as the reference it
# resolves to (D27, noted 2026-10-16).  `path` gives every component under its
# own name, and a component given as <path>:<key> replaces that one default.
# The compile is the apply's dry run with --output-dir, over the working tree.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/slurp/;
use Genesis::Config;
provide_rc();

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# Compiles the harness's Concourse pipeline with the credential keys given,
# written into the working tree, and answers the emitted pipeline as text.
sub compiled {
	my (%keys) = @_;
	my $h      = make_harness(envs => ['lab', 'qa'], fanned => 'lab', provider => 'concourse');
	my $config = Genesis::Config->new($h->a . '/.genesis/config');
	$config->clear('pipeline.source_control.auth');
	$config->set($_ => $keys{$_}) for sort keys %keys;
	$config->save;

	my $out = workdir('compiled');
	my (undef, $err, $exit) = run_genesis($h, {restore => 0}, 'pipeline-apply',
		'--dry-run', '--skip-vault', '--output-dir', $out);
	is($exit, 0, 'the compile succeeds') or diag($err);
	return -f "$out/pipeline.yml" ? slurp("$out/pipeline.yml") : '';
}

subtest 'approle from a path, with one component given on its own' => sub {
	plan tests => 5;
	my $yml = compiled(
		'pipeline.vault.auth.type'          => 'approle',
		'pipeline.vault.auth.path'          => 'secret/ci/a',
		'pipeline.vault.auth.secret_id'     => 'secret/shared/x:sid',
		'pipeline.source_control.auth.type' => 'ssh',
		'pipeline.source_control.auth.path' => 'secret/ci/git',
	);
	# Concourse resolves a ((...)) from its own vault as ((path.field)); the
	# colon form is Genesis's, for a deployment-vault path a worker reads.
	like($yml, qr{VAULT_ROLE_ID: "?\(\(secret/ci/a\.role_id\)\)}, 'role_id from the path, under its own name');
	like($yml, qr{VAULT_SECRET_ID: "?\(\(secret/shared/x\.sid\)\)}, 'secret_id from its own reference');
	like($yml, qr{private_key: "?\(\(secret/ci/git\.private_key\)\)}, 'the ssh key from its path');
	# The committer is the configured source_control.identity, which the
	# compiler once ignored for a default of its own (T380).
	like($yml, qr{GIT_AUTHOR_NAME: "?Genesis CI}, 'and tasks commit as the configured identity');
};

subtest 'https from a path' => sub {
	plan tests => 3;
	my $yml = compiled(
		'pipeline.source_control.auth.type' => 'https',
		'pipeline.source_control.auth.path' => 'secret/ci/git',
	);
	like($yml, qr{username: "?\(\(secret/ci/git\.username\)\)}, 'the username from the path');
	like($yml, qr{password: "?\(\(secret/ci/git\.password\)\)}, 'and the password');
};

done_testing;
