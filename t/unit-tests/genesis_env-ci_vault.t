#!perl
# Proves T471 (D141): pipeline.provider.secrets_store names the store
# Concourse resolves its references from.  Env::ci_vault attaches to that
# store, else to the environment's own vault; ci_mount, ci_pipeline_base and
# ci_base follow Concourse's lookup order under it, and the per-environment
# overrides still win.  Without the block the CI paths are as they were, and
# a key the block does not declare is refused at load.
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
provide_rc();
use_ok 'Genesis::Top';
use_ok 'Genesis::Env';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 1, vault => 0, kit => 't/src/simple');

sub load_qa {
	my (%opts) = @_;
	# Staged, not committed, so an unchanged file is no failed commit; the
	# configuration's commit below carries it.
	write_env_file($h, 'qa', genesis => $opts{genesis} || {}, commit => 0);
	Genesis::run({dir => $h->a}, 'git', 'add', '--', 'qa.yml');
	my $top = load_with($h, join("\n",
		automated_config('concourse', 'url: https://ci.example.com', 'team: main',
			@{$opts{store} || []}),
		'  name: p'), deployment_type => 'bosh');
	return $top->load_env('qa');
}

my @STORE = ('secrets_store:', '  url: https://ci-vault.example.com', '  namespace: ops');

subtest 'the store names the vault the CI paths are read from' => sub {
	plan tests => 4;

	my $env = load_qa(store => \@STORE);
	my %attached;
	{
		no warnings 'redefine';
		local *Service::Vault::Remote::attach = sub {shift; %attached = @_; return bless {}, 'Service::Vault::Remote'};
		$env->ci_vault;
	}
	is $attached{url}, 'https://ci-vault.example.com', 'ci_vault attaches to the store by its URL';
	is $attached{namespace}, 'ops', 'in its namespace';
	ok !exists $attached{alias}, 'and names no target, each operator resolving their own';

	my $plain = load_qa();
	is $plain->ci_vault, $plain->vault, "without a store it is the environment's own vault";
};

subtest 'the CI paths follow Concourse lookup order' => sub {
	plan tests => 6;

	my $env = load_qa(store => \@STORE);
	is $env->ci_mount,         '/concourse/main/',      'ci_mount is the team scope';
	is $env->ci_pipeline_base, '/concourse/main/p/',    'ci_pipeline_base the pipeline scope';
	is $env->ci_base,          '/concourse/main/p/qa/', 'ci_base the environment under it';

	$env = load_qa(store => [@STORE, '  path_prefix: /ci']);
	is $env->ci_mount, '/ci/main/', 'a path_prefix moves the team scope';
	is $env->ci_base,  '/ci/main/p/qa/', 'and everything beneath it';

	$env = load_qa(store => \@STORE, genesis => {ci_mount => '/elsewhere/', ci_base => '/mine/'});
	is_deeply [$env->ci_mount, $env->ci_base], ['/elsewhere/', '/mine/'],
		'the per-environment overrides still win';
};

subtest 'without a store the CI paths are as they were' => sub {
	plan tests => 2;

	my $env = load_qa();
	is $env->ci_mount, '/secret/ci/', 'ci_mount under the secrets mount';
	is $env->ci_base,  '/secret/ci/bosh/qa/', 'ci_base under it by type and name';
};

subtest 'the block is declared, and only for Concourse' => sub {
	plan tests => 1;

	throws_ok {load_qa(store => [@STORE, '  mount: /x'])}
		qr/pipeline\.provider\.secrets_store\.mount: unknown configuration key/,
		'an undeclared key is refused by name';
};

done_testing;
