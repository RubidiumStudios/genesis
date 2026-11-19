#!perl
# Proves T500 and T504: pipeline.vault says how a pipeline task logs in to
# the deployment vault and nothing else, and where that vault is, is the
# repository's own to say (D169, D173).
#
# pipeline.vault.url was required, so a repository named its vault twice,
# once for its operators in secrets_provider and once for its tasks, though
# the two reach one endpoint, and nothing checked that they agreed.  A block
# holding auth alone was refused.
#
# The rows read four things: that such a block loads, that the keys which
# named the vault are refused by name, what a task is sent to, and that the
# compiler is handed that.
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
use_ok 'Genesis::CI::Compiler::Parser';

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

my @AUTH = ('    auth:', '      type: approle', '      path: genesis-ci-approle');

# An automated pipeline whose vault block and whose repository vault are the
# lines given.  Everything else an automated provider needs is there.
sub config_with {
	my (%opts) = @_;
	my @lines = ('pipeline:', '  enabled: true',
		'  provider:', '    type: concourse',
		'    url: https://ci.example.com', '    team: main',
		'  source_control:', '    repository: team/bosh',
		'    auth:', '      type: ssh', '      path: secret/ci/git',
		automation_block_lines(without => ['vault']),
		'  vault:', @{$opts{vault}});
	push @lines, 'secrets_provider:', @{$opts{repository}} if $opts{repository};
	return join("\n", @lines);
}

sub vault_of { load_with($h, config_with(@_))->pipeline_vault }

subtest 'a block holding auth alone is a complete one' => sub {
	plan tests => 4;

	my $top;
	lives_ok {
		$top = load_with($h, config_with(
			vault      => \@AUTH,
			repository => ['  url: https://vault.example.com:8200']))
	} 'it loads, where the repository names its vault';

	my $vault = $top ? $top->pipeline_vault : {};
	is($vault->{url}, 'https://vault.example.com:8200', 'the task is sent to the repository\'s vault');
	is_deeply($vault->{auth}, {type => 'approle', path => 'genesis-ci-approle'},
		'with the credential the block names');
	ok(!exists $vault->{options}, 'and nothing said about TLS or strongbox where the repository says nothing');
};

subtest 'the rest of the connection is the repository\'s vault\'s too' => sub {
	plan tests => 3;

	my $vault = vault_of(
		vault      => \@AUTH,
		repository => ['  url: https://vault.example.com:8200',
			'  namespace: ops', '  insecure: true', '  strongbox: false']);
	is($vault->{namespace}, 'ops', 'its namespace');
	ok(defined $vault->{options}{tls_verify} && !$vault->{options}{tls_verify},
		'TLS left unverified, where the repository says insecure');
	ok($vault->{options}{no_strongbox}, 'and no strongbox, where the repository says it runs without');
};

# A task and an operator reach one endpoint, so the block has nothing to
# say of where it is, and a key that says it is refused with where that is
# said now.
subtest 'a key that names the vault is refused, with where that is said' => sub {
	plan tests => 4;

	my @repository = ('  url: https://vault.example.com:8200');
	my %retired = (
		'url'       => [['    url: https://vault.internal:8200'], qr/secrets_provider\.url/],
		'namespace' => [['    namespace: tasks'],                 qr/secrets_provider\.namespace/],
		'options'   => [['    options:', '      tls_verify: false'],
		                qr/secrets_provider\.insecure.*secrets_provider\.strongbox/s],
	);
	for my $key (sort keys %retired) {
		my ($lines, $said_by) = @{$retired{$key}};
		throws_ok {load_with($h, config_with(vault => [@AUTH, @$lines], repository => \@repository))}
			qr/pipeline\.vault\.$key: is no longer read\..*$said_by/s,
			"$key is refused by name, naming the key that says it";
	}
	throws_ok {load_with($h, config_with(vault => [@AUTH, '    url: https://vault.internal:8200'],
			repository => \@repository))}
		qr/pipeline\.vault holds auth alone/,
		'and each refusal says what the block holds';
};

# T504 (D173): the credential is the one thing the block says, and a task
# cannot log in to the vault without it.
subtest 'the credential is required under an automated provider' => sub {
	plan tests => 2;

	throws_ok {load_with($h, join("\n", 'pipeline:', '  enabled: true',
			'  provider:', '    type: concourse',
			'    url: https://ci.example.com', '    team: main',
			'  source_control:', '    repository: team/bosh',
			'    auth:', '      type: ssh', '      path: secret/ci/git',
			automation_block_lines(without => ['vault']),
			'  vault: {}',
			'secrets_provider:', '  url: https://vault.example.com:8200'))}
		qr/pipeline\.vault: missing required key auth/,
		'a block that names no auth is refused by name';

	lives_ok {load_with($h, join("\n", 'pipeline:', '  enabled: true',
		'  provider:', '    type: manual',
		'  vault: {}'))}
		'and tolerated under the manual provider, where no task logs in';
};

subtest 'the compiler is handed the repository\'s vault' => sub {
	plan tests => 2;

	my $top = load_with($h, config_with(
		vault      => \@AUTH,
		repository => ['  url: https://vault.example.com:8200', '  insecure: true']));
	my $parsed = Genesis::CI::Compiler::Parser->new(top => $top)->parse;
	is($parsed->{integrations}{vault}{url}, 'https://vault.example.com:8200',
		'so a task\'s VAULT_ADDR is the repository\'s vault');
	ok(defined $parsed->{integrations}{vault}{options}{tls_verify}
			&& !$parsed->{integrations}{vault}{options}{tls_verify},
		'and its TLS setting the repository\'s');
};

# T505 (D174): a repository that names no vault reads whichever one safe
# targets on the machine a command runs on, which a pipeline's records and
# its tasks cannot rest on, so a pipeline is refused there at load.
subtest 'a pipeline whose repository names no vault is refused at load' => sub {
	plan tests => 5;

	throws_ok {load_with($h, config_with(vault => \@AUTH), repository_vault => 0)}
		qr/secrets_provider: .*names none/s,
		'under an automated provider, naming the key';
	throws_ok {load_with($h, config_with(vault => \@AUTH), repository_vault => 0)}
		qr/genesis secrets-provider <target>/,
		'and the command that records it';

	throws_ok {load_with($h, join("\n", 'pipeline:', '  enabled: true',
			'  provider:', '    type: manual'), repository_vault => 0)}
		qr/secrets_provider: .*names none/s,
		'under the manual provider too, whose records live in the same vault';

	throws_ok {load_with($h, join("\n", 'pipeline:', '  enabled: true',
			'  provider:', '    type: manual',
			'secrets_provider:', '  alias: somewhere'))}
		qr/secrets_provider: .*names none|secrets_provider: missing required key url/s,
		'a block that names no url names no vault';

	lives_ok {load_with($h, join("\n", 'pipeline:', '  enabled: false'), repository_vault => 0)}
		'and a repository with no pipeline loads in legacy mode, as it did';
};

done_testing;
