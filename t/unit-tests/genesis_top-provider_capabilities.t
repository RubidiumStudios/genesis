#!perl
# Proves T39 and T40: a provider declares its six capabilities, Concourse
# declares the first five true and multi_file_output false, a capability
# that is false refuses the key it gates, naming both the key and the
# capability, and the layout key is declared by the provider that can emit
# several files rather than offered on its behalf.
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
use_ok 'Genesis::CI::ProviderCompiler';
use_ok 'Genesis::CI::Provider';
use_ok 'Genesis::CI::ProviderRegistry';

# The Concourse compiler class comes in by name, because the package it
# declares is the path it lives at now.  Nothing has pulled the file in
# yet, and the rows below ask the class what it declares.
require_ok 'Genesis::CI::ProviderCompiler::Concourse';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

my @NAMES = qw/cross_pipeline_events deployment_locks multi_file_output
               optional_git_triggers per_commit_runs scheduled_jobs/;

# First, because it asks the registry what it holds and every row below
# registers a fixture of its own into it.
#
# Proves that every provider declares its abilities, so the gates read a
# declaration for each of them rather than standing aside for the ones
# that have no compiler class.
subtest 'every provider declares its abilities' => sub {
	# One row per registered provider, counted off the registry rather than
	# written down, because a fourth provider is a fourth row and a written
	# count would fail the file on the plan instead of on anything it
	# proves.  The one beyond them is the manual gate below.
	my @providers = Genesis::CI::ProviderRegistry->known_providers;
	plan tests => 1 + scalar(@providers);

	for my $type (@providers) {
		my $class = Genesis::CI::Provider->provider_class($type);
		lives_ok {
			Genesis::CI::Provider->declared_capabilities($class)
		} "the $type provider answers the capability contract";
	}

	# Manual can do none of the six, and saying so is what makes the gate
	# refuse a key rather than stand aside from it.
	write_env_file($h, 'qa', pipeline => {redeploy_cron => "'0 4 * * *'"});
	throws_ok {load_with($h, automated_config('manual'))}
		qr/genesis\.pipeline\.redeploy_cron.*manual.*scheduled_jobs/s,
		'a manual pipeline refuses a scheduled redeploy, naming the capability';
};

# An assert helper: write the pair of classes a provider takes, with
# capabilities that are the six defaults with the named ones overridden,
# register them, and answer with the type.  The CLI-side class carries
# both halves, the fragment and the capabilities, because one class
# answers for a provider and the compiler-side class reads the declaration
# from it.  That fragment declares group_commits itself, because a key no
# fragment declares is refused as unknown before any gate is read, so a
# gate row needs its key declared to reach the gate at all.
#
# The layout key is declared only where the fixture claims it can emit
# several files, which is how a provider declares it.  A fixture that
# emits one file offers no such key, so an operator who writes it is
# refused by name like anybody writing a key nobody declared.
#
# The defaulted option gives group_commits a default in the fragment, for
# the row that asks what a value the operator never wrote does to a gate.
my $seq = 0;
sub provider_with {
	my (%caps) = @_;
	my $defaulted = delete $caps{defaulted};
	my $type     = 'cap'.++$seq;
	my $pkg      = "Genesis::CI::ProviderCompiler::Cap$seq";
	my $rel      = ($pkg =~ s{::}{/}gr).'.pm';
	my $cli_pkg  = "Genesis::CI::Provider::Cap$seq";
	my $cli_rel  = ($cli_pkg =~ s{::}{/}gr).'.pm';
	my %all  = (map {($_ => 1)} @NAMES);
	$all{$_} = $caps{$_} for keys %caps;
	my $decl = join(', ', map {"$_ => ".($all{$_} ? 1 : 0)} @NAMES);

	# The ability is what decides whether the key is there to write, and
	# the key carries the same default wherever it is declared.
	my $layout = $all{multi_file_output} ? <<'LAYOUT' : '';
		output_layout => {
			type        => 'enum',
			values      => [qw/single multiple/],
			default     => 'single',
			description => 'How many files the provider emits'
		},
LAYOUT

	put_file("t/tmp/lib/$cli_rel", <<"CAPCLI");
package $cli_pkg;
use base 'Genesis::CI::Provider';
# The base's new is the factory's, and it refuses to build a subclass, so
# a CLI-side fixture the load path constructs brings its own.
sub new {my (\$c, %cfg) = \@_; bless {%cfg}, \$c}
sub capabilities {return {$decl}}
sub provider_options_schema {
	return {
		group_commits => {
			type        => 'boolean',
			@{[$defaulted ? "default     => 1,\n\t\t\t" : '']}description => 'Deploy the tip of what arrived rather than each commit'
		},
@{[$layout]}	};
}
1;
CAPCLI
	put_file("t/tmp/lib/$rel", <<"CAP");
package $pkg;
use parent 'Genesis::CI::ProviderCompiler';
sub provider_type {'$type'}
1;
CAP
	Genesis::CI::ProviderRegistry->register_provider($type, {
		class     => $pkg,
		file      => $rel,
		cli_class => $cli_pkg,
		cli_file  => $cli_rel,
	});
	return $type;
}

subtest 'the declaration carries six names' => sub {
	plan tests => 3;

	# Asked of the provider class that declares it.  The compiler side
	# used to answer through a forwarder of its own, and now a compiler
	# asks the provider it holds, so the class that declares the six is
	# the only one to ask.
	my $caps = Genesis::CI::Provider->provider_class('concourse')->capabilities;
	is_deeply [sort keys %$caps], [@NAMES],
		'the six names, and no others';
	is_deeply [grep {$caps->{$_}} sort keys %$caps],
		[qw/cross_pipeline_events deployment_locks optional_git_triggers
		    per_commit_runs scheduled_jobs/],
		'Concourse declares the first five true';
	ok !$caps->{multi_file_output},
		'and multi_file_output false, since it emits one file';
};

# Concourse has a row of its own above and GitHub Actions had none, so
# nothing pinned the declaration, which stays provisional until that
# provider's compiler class is written.  A change to it should be a
# deliberate one that comes here and says so.
subtest 'GitHub Actions declares the file layout and nothing else' => sub {
	plan tests => 3;

	my $class = Genesis::CI::Provider->provider_class('github-actions');
	my $caps  = $class->capabilities;

	ok $caps->{multi_file_output},
		'a workflow directory is several files, so it emits several';
	is_deeply [grep {$caps->{$_}} sort keys %$caps], ['multi_file_output'],
		'and the other five are false until its compiler class is written';

	# Declared here rather than gated centrally, because the provider that
	# can emit several files is the provider that offers the key choosing
	# between the forms.
	is $class->provider_options_schema->{output_layout}{default}, 'single',
		'the layout key it declares defaults to the single form';
};

subtest 'a capability that is false refuses the key it gates' => sub {
	plan tests => 3;

	local @INC = ('t/tmp/lib', @INC);

	# Each pattern reads the key, then the provider, then the capability,
	# in the order the refusal names them, because the refusal is required
	# to name all three and a pattern that read only two would stay green
	# if one of them were dropped.
	my $no_triggers = provider_with(optional_git_triggers => 0);
	write_env_file($h, 'qa', pipeline => {manual => 1});
	throws_ok {load_with($h, automated_config($no_triggers))}
		qr/genesis\.pipeline\.manual.*\Q$no_triggers\E.*optional_git_triggers/s,
		'the manual gate names the key, the provider, and the capability';

	my $no_cron = provider_with(scheduled_jobs => 0);
	write_env_file($h, 'qa', pipeline => {redeploy_cron => "'0 3 * * *'"});
	throws_ok {load_with($h, automated_config($no_cron))}
		qr/genesis\.pipeline\.redeploy_cron.*\Q$no_cron\E.*scheduled_jobs/s,
		'the redeploy cron names the key, the provider, and the capability';

	my $no_per_commit = provider_with(per_commit_runs => 0);
	write_env_file($h, 'qa', pipeline => {});
	throws_ok {load_with($h, automated_config($no_per_commit, 'group_commits: false'))}
		qr/group_commits.*\Q$no_per_commit\E.*per_commit_runs/s,
		'group_commits names the key, the provider, and the capability';
};

subtest 'the layout key is offered by the provider that can use it' => sub {
	plan tests => 3;

	local @INC = ('t/tmp/lib', @INC);

	# A provider that can emit several files declares the key, so the block
	# admits what an operator writes there and fills the fragment's default
	# where nobody wrote anything.  Both reads go through a loaded
	# configuration, because a read of the class's declaration would only
	# be reading back the fixture this file wrote a moment ago.
	my $multi = provider_with(multi_file_output => 1);
	my $top   = load_with($h, automated_config($multi));
	is $top->config->get('pipeline.provider.output_layout'), 'single',
		'the layout key reads back its declared default';
	$top = load_with($h, automated_config($multi, 'output_layout: multiple'));
	is $top->config->get('pipeline.provider.output_layout'), 'multiple',
		'and reads back what an operator wrote over that default';

	# The refusal a provider that emits one file gives is the ordinary
	# undeclared-key refusal, which the Concourse row in
	# t/unit-tests/genesis_ci_compiler-override_file.t states against a
	# real provider.  What is left to say here is that no gate stands
	# between the capability and the key any more.
	ok !exists Genesis::CI::Provider->capability_gates->{multi_file_output},
		"the layout key is nobody's gate any more";
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

	throws_ok {load_with($h, automated_config($no_triggers))}
		qr/genesis\.pipeline\.manual\s+in\s+ocfp-qa:\s+the\s+\Q$no_triggers\E\s+provider/s,
		'the leaf inherits the key, and the refusal names the leaf';
};

subtest 'a capability that is true admits the key it gates' => sub {
	plan tests => 3;

	local @INC = ('t/tmp/lib', @INC);

	# The site file the merged-hierarchy row wrote goes back to saying
	# nothing, so a row below can only refuse over what it wrote itself.
	# That is the one file written here.  The leaf beside it is already
	# silent, and a harness write of a file that is already what it would
	# write has no commit to make, so writing it again would fail.
	write_env_file($h, 'ocfp-qa', site => 'ocfp', pipeline => {});

	my $able = provider_with();
	write_env_file($h, 'qa', pipeline => {manual => 1});
	lives_ok {load_with($h, automated_config($able, 'group_commits: false'))}
		'a provider declaring every capability is refused nothing';

	# A gate is about what the operator chose, and a default the fragment
	# filled is the provider's own answer rather than anybody's choice, so
	# it cannot be the thing a refusal is about.  The one repository-wide
	# gated key here carries a default and its capability is not declared.
	my $defaulted = provider_with(defaulted => 1, per_commit_runs => 0);
	write_env_file($h, 'qa', pipeline => {});
	lives_ok {load_with($h, automated_config($defaulted))}
		'a key nobody wrote, filled from the fragment, trips no gate';

	# The manual provider declares all six false, so every gate has a
	# declaration to read and every one of them fires on a key somebody
	# wrote.  Nobody wrote one here, so the load passes on the strength of
	# what the environment says rather than on the provider being skipped.
	# The source-control block is still named, because the repository
	# cannot be derived from the harness's filesystem remote whatever the
	# provider is.  The qa environment was left silent by the row above and
	# stays that way, so this row stands on the write that row made.
	lives_ok {load_with($h, automated_config('manual'))}
		'and a provider that can do nothing refuses nothing unwritten';
};

subtest 'the capability declaration is checked at load' => sub {
	plan tests => 2;

	local @INC = ('t/tmp/lib', @INC);

	# A provider class with a fragment but no capability declaration,
	# registered for this test alone.  The base makes both abstract, so the
	# omission is a bug at load rather than a discovery at run time.
	put_file('t/tmp/lib/Genesis/CI/Provider/Deaf.pm', <<'DEAF');
package Genesis::CI::Provider::Deaf;
use base 'Genesis::CI::Provider';
sub provider_options_schema {return {}}
1;
DEAF
	Genesis::CI::ProviderRegistry->register_provider('deaf', {
		cli_class => 'Genesis::CI::Provider::Deaf',
		cli_file  => 'Genesis/CI/Provider/Deaf.pm',
	});

	throws_ok {load_with($h, automated_config('deaf'))}
		qr/must implement\s+capabilities/,
		'the omission is a bug at load and not a discovery at run time';

	# A class that answers five of the six names and one of its own.  Left
	# unchecked, the misspelling reads as false and refuses group_commits
	# as though somebody had meant it to, and the ability the name was
	# meant to carry is lost with nothing said about it.
	put_file('t/tmp/lib/Genesis/CI/Provider/Lisp.pm', <<'LISP');
package Genesis::CI::Provider::Lisp;
use base 'Genesis::CI::Provider';
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
	Genesis::CI::ProviderRegistry->register_provider('lisp', {
		cli_class => 'Genesis::CI::Provider::Lisp',
		cli_file  => 'Genesis/CI/Provider/Lisp.pm',
	});

	throws_ok {load_with($h, automated_config('lisp'))}
		qr/Provider::Lisp.*per_commit_run\b.*per_commit_runs/s,
		'a name that is not one of the six is a bug naming the class';
};

done_testing;
