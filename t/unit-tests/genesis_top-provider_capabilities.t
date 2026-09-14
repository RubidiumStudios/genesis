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
		(map {"    $_"} @lines),
		# The shuttle, the vault, and the locker are required of an
		# automation for the same reason the credential is, so every row
		# that names one carries them too.
		'  shuttle:', '    backend: s3', '    bucket: pipes',
		'  vault:', '    url: https://vault.example.com',
		'  locker:', '    url: https://locker.example.com');
}

# An assert helper: write a provider class whose capabilities are the six
# defaults with the named ones overridden, register it, and answer with its
# type.  Its fragment declares both repository-wide gated keys itself, for
# two reasons.  A key no fragment declares is refused as unknown before any
# gate is read, so a gate row needs its key declared to reach the gate at
# all; and output_layout is declared by no real provider's fragment until
# the output-layout work lands, so the multi_file_output row brings its own
# declaration of it and the gate fires today.
#
# The defaulted option gives both of those keys a default in the fragment,
# for the row that asks what a value the operator never wrote does to a
# gate.
my $seq = 0;
sub provider_with {
	my (%caps) = @_;
	my $defaulted = delete $caps{defaulted};
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
			@{[$defaulted ? "default     => 1,\n\t\t\t" : '']}description => 'Deploy the tip of what arrived rather than each commit'
		},
		output_layout => {
			type        => 'enum',
			values      => [qw/single multiple/],
			@{[$defaulted ? "default     => 'single',\n\t\t\t" : '']}description => 'How many files the provider emits'
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

	# Each pattern reads the key, then the provider, then the capability,
	# in the order the refusal names them, because the refusal is required
	# to name all three and a pattern that read only two would stay green
	# if one of them were dropped.
	my $no_triggers = provider_with(optional_git_triggers => 0);
	write_env_file($h, 'qa', pipeline => {manual => 1});
	throws_ok {load_with(automated_config($no_triggers))}
		qr/genesis\.pipeline\.manual.*\Q$no_triggers\E.*optional_git_triggers/s,
		'the manual gate names the key, the provider, and the capability';

	my $no_cron = provider_with(scheduled_jobs => 0);
	write_env_file($h, 'qa', pipeline => {redeploy_cron => "'0 3 * * *'"});
	throws_ok {load_with(automated_config($no_cron))}
		qr/genesis\.pipeline\.redeploy_cron.*\Q$no_cron\E.*scheduled_jobs/s,
		'the redeploy cron names the key, the provider, and the capability';

	my $no_per_commit = provider_with(per_commit_runs => 0);
	write_env_file($h, 'qa', pipeline => {});
	throws_ok {load_with(automated_config($no_per_commit, 'group_commits: false'))}
		qr/group_commits.*\Q$no_per_commit\E.*per_commit_runs/s,
		'group_commits names the key, the provider, and the capability';

	my $no_multi_file = provider_with(multi_file_output => 0);
	throws_ok {load_with(automated_config($no_multi_file, 'output_layout: multiple'))}
		qr/output_layout.*\Q$no_multi_file\E.*multi_file_output/s,
		'output_layout names the key, the provider, and the capability';
};

subtest 'the gated key is read out of the merged hierarchy' => sub {
	plan tests => 1;

	local @INC = ('t/tmp/lib', @INC);

	# The leaf says nothing, and the site file above it carries the gated
	# key, which is where a key like this usually lives.  A check that read
	# the leaf file alone would find the key absent and let the load pass.
	# The qa environment was left silent by the row above and stays that
	# way, because a harness write of a file that is already what it would
	# write has no commit to make.
	my $no_triggers = provider_with(optional_git_triggers => 0);
	write_env_file($h, 'ocfp-qa', pipeline => {});
	write_env_file($h, 'ocfp-qa', site => 'ocfp', pipeline => {manual => 1});

	throws_ok {load_with(automated_config($no_triggers))}
		qr/genesis\.pipeline\.manual\s+in\s+ocfp-qa:\s+the\s+\Q$no_triggers\E\s+provider/s,
		'the leaf inherits the key, and the refusal names the leaf';
};

subtest 'a capability that is true admits the key it gates' => sub {
	plan tests => 3;

	local @INC = ('t/tmp/lib', @INC);

	# The two files the merged-hierarchy row left behind go back to saying
	# nothing, so a row below can only refuse over what it wrote itself.
	write_env_file($h, 'ocfp-qa', site => 'ocfp', pipeline => {});

	my $able = provider_with();
	write_env_file($h, 'qa', pipeline => {manual => 1});
	lives_ok {load_with(automated_config($able, 'group_commits: false'))}
		'a provider declaring every capability is refused nothing';

	# A gate is about what the operator chose, and a default the fragment
	# filled is the provider's own answer rather than anybody's choice, so
	# it cannot be the thing a refusal is about.  Both repository-wide keys
	# here carry a default and neither capability is declared.
	my $defaulted = provider_with(defaulted => 1,
		per_commit_runs => 0, multi_file_output => 0);
	write_env_file($h, 'qa', pipeline => {});
	lives_ok {load_with(automated_config($defaulted))}
		'a key nobody wrote, filled from the fragment, trips no gate';

	# A provider with no compiler class declares no capabilities at all, so
	# there is nothing to gate against and nothing to refuse.  The
	# source-control block is still named, because the repository cannot be
	# derived from the harness's filesystem remote whatever the provider is.
	lives_ok {load_with(automated_config('manual'))}
		'and a provider with no class is left alone';
};

subtest 'the capability declaration is checked at load' => sub {
	plan tests => 2;

	local @INC = ('t/tmp/lib', @INC);

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
	Genesis::CI::Compiler::PipelineProvider->register_provider('deaf', {
		class     => 'Genesis::CI::Compiler::Providers::Deaf',
		file      => 'Genesis/CI/Compiler/Providers/Deaf.pm',
		cli_class => 'Genesis::CI::Provider::Manual',
		cli_file  => 'Genesis/CI/Provider/Manual.pm',
	});

	throws_ok {load_with(automated_config('deaf'))}
		qr/must implement\s+capabilities/,
		'the omission is a bug at load and not a discovery at run time';

	# A class that answers five of the six names and one of its own.  Left
	# unchecked, the misspelling reads as false and refuses group_commits
	# as though somebody had meant it to, and the ability the name was
	# meant to carry is lost with nothing said about it.
	put_file('t/tmp/lib/Genesis/CI/Compiler/Providers/Lisp.pm', <<'LISP');
package Genesis::CI::Compiler::Providers::Lisp;
use parent 'Genesis::CI::Compiler::PipelineProvider';
sub provider_type {'lisp'}
sub provider_options_schema {return {}}
sub capabilities {
	return {
		cross_pipeline_events => 1,
		deployment_locks      => 1,
		multi_file_output     => 1,
		optional_git_triggers => 1,
		per_commit_run        => 1,
		scheduled_jobs        => 1,
	};
}
1;
LISP
	Genesis::CI::Compiler::PipelineProvider->register_provider('lisp', {
		class     => 'Genesis::CI::Compiler::Providers::Lisp',
		file      => 'Genesis/CI/Compiler/Providers/Lisp.pm',
		cli_class => 'Genesis::CI::Provider::Manual',
		cli_file  => 'Genesis/CI/Provider/Manual.pm',
	});

	throws_ok {load_with(automated_config('lisp'))}
		qr/Providers::Lisp.*per_commit_run\b.*per_commit_runs/s,
		'a name that is not one of the six is a bug naming the class';
};

done_testing;
