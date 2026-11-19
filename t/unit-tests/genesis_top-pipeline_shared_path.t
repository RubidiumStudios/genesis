#!perl
# Proves T501: Concourse's shared path defaults to "shared", under the
# store's path prefix (D170).
#
# pipeline.provider.secrets_store.shared_path had no default, so the secret
# check looked at the pipeline scope and the team scope and stopped, and
# reported as missing a secret Concourse would have found at the shared
# path.
#
# The rows read what the store answers for its shared path, and the paths a
# secret is looked for at, in Concourse's order.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;

use Genesis;
provide_rc();
use_ok 'Genesis::Top';
use_ok 'Genesis::Commands::Pipelines';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

# An automated Concourse pipeline whose secrets_store block is the lines
# given, or which has none.
sub store_with {
	my (@store) = @_;
	my @lines = ('pipeline:', '  enabled: true', '  name: doomsday',
		'  provider:', '    type: concourse',
		'    url: https://ci.example.com', '    team: main',
		(@store ? ('    secrets_store:', @store) : ()),
		'  source_control:', '    repository: team/bosh',
		'    auth:', '      type: ssh', '      path: secret/ci/git',
		'    identity:', '      name: Genesis', '      email: ci@example.com',
		automation_block_lines());
	return load_with($h, join("\n", @lines))->pipeline_secrets_store;
}

sub looked_for { [Genesis::Commands::Pipelines::_concourse_secret_paths($_[0], 'management-bucket')] }

subtest 'with nothing said, the shared path is shared, under the prefix' => sub {
	plan tests => 2;
	my $store = store_with();
	is($store->{shared_path}, 'shared', 'the store answers shared');
	is_deeply(looked_for($store), [
		'/concourse/main/doomsday/management-bucket',
		'/concourse/main/management-bucket',
		'/concourse/shared/management-bucket',
	], 'and a secret is looked for at the pipeline scope, the team scope, then /concourse/shared');
};

subtest 'it follows the prefix the store names' => sub {
	plan tests => 1;
	is_deeply(looked_for(store_with('      path_prefix: /ci')), [
		'/ci/main/doomsday/management-bucket',
		'/ci/main/management-bucket',
		'/ci/shared/management-bucket',
	], 'under another prefix it is that prefix\'s shared');
};

subtest 'a shared path the store names is the one used' => sub {
	plan tests => 1;
	is_deeply(looked_for(store_with('      shared_path: common')), [
		'/concourse/main/doomsday/management-bucket',
		'/concourse/main/management-bucket',
		'/concourse/common/management-bucket',
	], 'in place of the default');
};

# A Concourse run with no shared path has to be able to say so, or the
# check reports a secret found where Concourse never reads.
subtest 'an empty shared path says there is none' => sub {
	plan tests => 2;
	my $store = store_with('      shared_path: ""');
	is($store->{shared_path}, '', 'the store answers the empty value it was given');
	is_deeply(looked_for($store), [
		'/concourse/main/doomsday/management-bucket',
		'/concourse/main/management-bucket',
	], 'and a secret is looked for at the two scopes alone');
};

done_testing;
