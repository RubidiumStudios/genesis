#!perl
# Proves T39 and T40: a provider declares the six capabilities D101 names,
# Concourse declares the first five true and multi_file_output false, and
# a capability that is false refuses the key it gates, naming both the key
# and the capability.
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
use_ok 'Genesis::CI::Compiler::PipelineProvider';

# The Concourse compiler class comes in through the registry's own file
# entry rather than by package name, because nothing has pulled that file
# in yet and the package it declares is named differently from the file it
# lives in.
require_ok Genesis::CI::Compiler::PipelineProvider
	->provider_info('concourse')->{file};

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

my @NAMES = qw/cross_pipeline_events deployment_locks multi_file_output
               optional_git_triggers per_commit_runs scheduled_jobs/;

sub load_with {
	my ($body) = @_;
	commit_on_control($h, files => {'.genesis/config' => join("\n",
		'---', 'deployment_type: bosh', 'version: "3"',
		'creator_version: 3.2.0', $body, '')});
	my $top = Genesis::Top->new($h->a, no_vault => 1);
	$top->config;
	return $top;
}

# The harness clones copy A from a bare repository at a filesystem path, so
# the source-control block names the repository rather than deriving it,
# and every provider here is an automated one, which is the case where the
# clone credential and the committer identity are required beside it.
sub automated_config {
	my ($type, @lines) = @_;
	return join("\n", 'pipeline:', '  enabled: true',
		'  source_control:',
		'    repository: genesis/bosh-deployments',
		'    auth:',
		'      type: ssh',
		'      vault: secret/ci/git',
		'    identity:',
		'      name: Genesis CI',
		'      email: ci@genesis.example.com',
		'  provider:', "    type: $type",
		map {"    $_"} @lines);
}

# An assert helper: write a provider class whose capabilities are the six
# defaults with the named ones overridden, register it, and answer with its
# type.  Its fragment declares both repository-wide gated keys itself, for
# two reasons.  A key no fragment declares is refused as unknown before any
# gate is read, so a gate row needs its key declared to reach the gate at
# all; and output_layout is declared by no real provider's fragment until
# the output-layout work lands, so the multi_file_output row brings its own
# declaration of it and the gate fires today.
my $seq = 0;
sub provider_with {
	my (%caps) = @_;
	my $type = 'cap'.++$seq;
	my $pkg  = "Genesis::CI::Compiler::Providers::Cap$seq";
	my $rel  = ($pkg =~ s{::}{/}gr).'.pm';
	my %all  = (map {($_ => 1)} @NAMES);
	$all{$_} = $caps{$_} for keys %caps;
	my $decl = join(', ', map {"$_ => ".($all{$_} ? 1 : 0)} @NAMES);

	put_file("t/tmp/lib/$rel", <<"CAP");
package $pkg;
use parent 'Genesis::CI::Compiler::PipelineProvider';
sub provider_type {'$type'}
sub provider_options_schema {
	return {
		group_commits => {
			type        => 'boolean',
			description => 'Deploy the tip of what arrived rather than each commit'
		},
		output_layout => {
			type        => 'enum',
			values      => [qw/single multiple/],
			description => 'How many files the provider emits'
		},
	};
}
sub capabilities {return {$decl}}
1;
CAP
	Genesis::CI::Compiler::PipelineProvider->register_provider($type, {
		class     => $pkg,
		file      => $rel,
		cli_class => 'Genesis::CI::Provider::Manual',
		cli_file  => 'Genesis/CI/Provider/Manual.pm',
	});
	return $type;
}

subtest 'the declaration carries six names' => sub {
	plan tests => 3;

	my $caps = Genesis::CI::Concourse->capabilities;
	is_deeply [sort keys %$caps], [@NAMES],
		'the six names D101 fixes, and no others';
	is_deeply [grep {$caps->{$_}} sort keys %$caps],
		[qw/cross_pipeline_events deployment_locks optional_git_triggers
		    per_commit_runs scheduled_jobs/],
		'Concourse declares the first five true';
	ok !$caps->{multi_file_output},
		'and multi_file_output false, since it emits one file';
};

subtest 'a capability that is false refuses the key it gates' => sub {
	plan tests => 4;

	local @INC = ('t/tmp/lib', @INC);

	my $no_triggers = provider_with(optional_git_triggers => 0);
	write_env_file($h, 'qa', pipeline => {manual => 1});
	throws_ok {load_with(automated_config($no_triggers))}
		qr/genesis\.pipeline\.manual.*optional_git_triggers/s,
		'the manual gate names the key and the capability';

	my $no_cron = provider_with(scheduled_jobs => 0);
	write_env_file($h, 'qa', pipeline => {redeploy_cron => "'0 3 * * *'"});
	throws_ok {load_with(automated_config($no_cron))}
		qr/genesis\.pipeline\.redeploy_cron.*scheduled_jobs/s,
		'the redeploy cron names the key and the capability';

	my $no_per_commit = provider_with(per_commit_runs => 0);
	write_env_file($h, 'qa', pipeline => {});
	throws_ok {load_with(automated_config($no_per_commit, 'group_commits: false'))}
		qr/group_commits.*per_commit_runs/s,
		'group_commits names the key and the capability';

	my $no_multi_file = provider_with(multi_file_output => 0);
	throws_ok {load_with(automated_config($no_multi_file, 'output_layout: multiple'))}
		qr/output_layout.*multi_file_output/s,
		'output_layout names the key and the capability';
};

subtest 'a capability that is true admits the key it gates' => sub {
	plan tests => 2;

	local @INC = ('t/tmp/lib', @INC);

	my $able = provider_with();
	write_env_file($h, 'qa', pipeline => {manual => 1});
	lives_ok {load_with(automated_config($able, 'group_commits: false'))}
		'a provider declaring every capability is refused nothing';

	# A provider with no compiler class declares no capabilities at all, so
	# there is nothing to gate against and nothing to refuse.  The
	# source-control block is still named, because the repository cannot be
	# derived from the harness's filesystem remote whatever the provider is.
	write_env_file($h, 'qa', pipeline => {});
	lives_ok {load_with(automated_config('manual'))}
		'and a provider with no class is left alone';
};

subtest 'a provider that omits its capabilities fails at load' => sub {
	plan tests => 1;

	# A provider class with a fragment but no capability declaration,
	# registered for this test alone.  The base makes both abstract, so the
	# omission is a bug at load rather than a discovery at run time.
	put_file('t/tmp/lib/Genesis/CI/Compiler/Providers/Deaf.pm', <<'DEAF');
package Genesis::CI::Compiler::Providers::Deaf;
use parent 'Genesis::CI::Compiler::PipelineProvider';
sub provider_type {'deaf'}
sub provider_options_schema {return {}}
1;
DEAF
	local @INC = ('t/tmp/lib', @INC);
	Genesis::CI::Compiler::PipelineProvider->register_provider('deaf', {
		class     => 'Genesis::CI::Compiler::Providers::Deaf',
		file      => 'Genesis/CI/Compiler/Providers/Deaf.pm',
		cli_class => 'Genesis::CI::Provider::Manual',
		cli_file  => 'Genesis/CI/Provider/Manual.pm',
	});

	throws_ok {load_with(automated_config('deaf'))}
		qr/must implement\s+capabilities/,
		'the omission is a bug at load and not a discovery at run time';
};

done_testing;
