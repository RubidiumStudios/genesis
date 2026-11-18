#!perl
# Proves T500: pipeline.vault says how a pipeline task logs in to the
# deployment vault, and where that vault is comes from the repository's own
# secrets_provider, in the same file (D169).
#
# pipeline.vault.url was required, so a repository named its vault twice,
# once for its operators and once for its tasks, and nothing checked that
# the two agreed.  A block holding auth alone was refused.
#
# The rows read three things: that such a block loads, what the block is
# once the repository's vault is read into it, and that the compiler is
# handed that and not the block as written.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
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
		'    identity:', '      name: Genesis', '      email: ci@example.com',
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

subtest 'the rest of the connection comes from the repository\'s vault too' => sub {
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

subtest 'what the block does say wins' => sub {
	plan tests => 4;

	my $vault = vault_of(
		vault      => [@AUTH, '    url: https://vault.internal:8200', '    namespace: tasks',
			'    options:', '      tls_verify: true', '      no_strongbox: false'],
		repository => ['  url: https://vault.example.com:8200',
			'  namespace: ops', '  insecure: true', '  strongbox: false']);
	is($vault->{url}, 'https://vault.internal:8200', 'its own url');
	is($vault->{namespace}, 'tasks', 'its own namespace');
	ok($vault->{options}{tls_verify}, 'its own answer on TLS');
	ok(!$vault->{options}{no_strongbox}, 'and its own answer on strongbox');
};

# An options block written for strongbox alone turned TLS verification off,
# since an unset tls_verify under a written block read as false.
subtest 'an options block that says nothing of TLS takes the repository\'s answer' => sub {
	plan tests => 2;

	my @strongbox_only = (@AUTH, '    options:', '      no_strongbox: true');
	my $vault = vault_of(
		vault      => \@strongbox_only,
		repository => ['  url: https://vault.example.com:8200']);
	ok($vault->{options}{tls_verify}, 'which is to verify, where the repository does not say insecure');

	$vault = vault_of(
		vault      => \@strongbox_only,
		repository => ['  url: https://vault.example.com:8200', '  insecure: true']);
	ok(defined $vault->{options}{tls_verify} && !$vault->{options}{tls_verify},
		'and not to, where it does');
};

subtest 'where neither names a url the load refuses' => sub {
	plan tests => 2;

	throws_ok {load_with($h, config_with(vault => \@AUTH))}
		qr/pipeline\.vault: missing required key url/,
		'a block with no url and no repository vault is refused by name';
	lives_ok {load_with($h, config_with(vault => [@AUTH, '    url: https://vault.internal:8200']))}
		'and a block naming its own url needs no repository vault';
};

subtest 'the compiler is handed the block with the repository\'s vault read into it' => sub {
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

done_testing;
