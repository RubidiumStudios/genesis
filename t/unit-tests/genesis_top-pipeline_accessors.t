#!/usr/bin/env perl
# Proves T44, the three pipeline accessors answering three questions, and
# T45, the old guards being gone with no call site open-coding the check.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Top;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# The sources a sweep reads: every module under lib, and the command script,
# because a call site left on a removed accessor is just as broken there.
sub scanned_sources {
	my @found;
	my @queue = ('lib');
	while (my $dir = shift @queue) {
		opendir(my $dh, $dir) or next;
		for my $entry (sort readdir($dh)) {
			next if $entry eq '.' or $entry eq '..';
			my $path = "$dir/$entry";
			if (-d $path) {
				push @queue, $path;
			} elsif ($path =~ m{\.pm$}) {
				push @found, $path;
			}
		}
		closedir($dh);
	}
	return (sort @found), 'bin/genesis';
}

# The file's lines with the text that only names a key stripped out, so a
# sweep for a read does not trip over a comment or over an error message
# that tells the operator which key to edit.  The double-quoted strings go
# first, because an operator message is written in one and the key it names
# is not a read.  What is left goes through the shared comment stripper,
# which finds where a comment opens by reading the quoting rather than by
# cutting at the first '#', so a colour code inside a single-quoted string
# no longer takes the rest of the line with it and a read that follows one
# stays visible.  The single-quoted strings themselves stay, because that
# is how every key is spelled at the call.
sub code_lines_of {
	my ($file) = @_;
	my @lines;
	for my $line (split /\n/, (slurp($file) // '')) {
		(my $code = $line) =~ s{"(?:\\.|[^"\\])*"}{""}g;
		push @lines, strip_comment($code);
	}
	return @lines;
}

# Every place the pattern is read, as "<file> <sub>" so a failure names the
# sub that has to move rather than only the file it sits in.
sub readers_of {
	my ($pattern) = @_;
	my (@found, %seen);
	for my $file (scanned_sources()) {
		my $sub = '<file scope>';
		for my $code (code_lines_of($file)) {
			$sub = $1 if $code =~ m{^\s*sub\s+(\w+)};
			my $where = "$file $sub";
			push @found, $where if $code =~ $pattern && !$seen{$where}++;
		}
	}
	return sort @found;
}

# How many times one sub in one file reads the pattern.  readers_of dedupes
# on the file and the sub, which is what makes its answer readable, so a
# second read inside the accessor itself would be deduped away and this is
# the reader that can still see it.
sub reads_in {
	my ($file, $sub, $pattern) = @_;
	my ($in, $count) = ('<file scope>', 0);
	for my $code (code_lines_of($file)) {
		$in = $1 if $code =~ m{^\s*sub\s+(\w+)};
		$count++ if $in eq $sub && $code =~ $pattern;
	}
	return $count;
}

sub files_matching {
	my ($pattern) = @_;
	my @hits;
	for my $file (scanned_sources()) {
		push @hits, $file if grep {$_ =~ $pattern} code_lines_of($file);
	}
	return @hits;
}

subtest 'a repository with no pipeline block has no pipeline' => sub {
	plan tests => 3;

	my $top = top_for(make_harness(envs => ['qa'], vault => 0, pipeline => 'none'));

	ok(!$top->pipeline_enabled, 'pipeline_enabled is false');
	is($top->pipeline_provider_type, undef,
		'pipeline_provider_type is undef where there is no pipeline');
	ok(!$top->manual_pipeline, 'manual_pipeline is false');
};

subtest 'enabled with no provider key is a manual pipeline' => sub {
	plan tests => 3;

	my $top = top_for(make_harness(envs => ['qa'], vault => 0), config => {
		'creator_version'                    => '3.2.0',
		'version'                            => 3,
		'deployment_type'                    => 'bosh',
		'pipeline.enabled'                   => 1,
		'pipeline.source_control.repository' => 'genesis/bosh-deployments',
	});

	ok($top->pipeline_enabled, 'pipeline_enabled reads pipeline.enabled alone');
	is($top->pipeline_provider_type, 'manual',
		'pipeline_provider_type defaults to manual');
	ok($top->manual_pipeline, 'manual_pipeline is true');
};

subtest 'enabled with concourse is an automated pipeline' => sub {
	plan tests => 3;

	my $top = top_for(make_harness(envs => ['qa'], vault => 0), config => {
		'creator_version'                    => '3.2.0',
		'version'                            => 3,
		'deployment_type'                    => 'bosh',
		'pipeline.enabled'                   => 1,
		'pipeline.provider.type'             => 'concourse',
		'pipeline.provider.target'           => 'pipes/lab',
		'pipeline.provider.url'              => 'https://pipes.example.com',
		'pipeline.provider.team'             => 'lab',
		'pipeline.shuttle.backend'           => 's3',
		'pipeline.shuttle.bucket'            => 'pipes',
		'pipeline.vault.url'                 => 'https://vault.example.com',
		'pipeline.locker.url'                => 'https://locker.example.com',
		'pipeline.source_control.repository'     => 'genesis/bosh-deployments',
		'pipeline.source_control.auth.vault'     => 'secret/ci/git',
		'pipeline.source_control.identity.name'  => 'Genesis Bot',
		'pipeline.source_control.identity.email' => 'bot@genesis.example.com',
	});

	ok($top->pipeline_enabled, 'pipeline_enabled is true');
	is($top->pipeline_provider_type, 'concourse',
		'pipeline_provider_type returns the configured type');
	ok(!$top->manual_pipeline, 'manual_pipeline is false for concourse');
};

subtest 'the two source-control readers answer the configuration' => sub {
	plan tests => 4;

	# The harness writes both keys from the options it was declared with,
	# so a row that wants the defaults takes them away by name.
	my $default = top_for(make_harness(
		envs => ['qa'], vault => 0,
		source_control => {control_branch => undef, pr_prefix => undef},
	));

	is($default->control_branch, 'control',
		'control_branch falls back to DEFAULT_CONTROL_BRANCH');
	is($default->pr_prefix, 'pr/',
		'pr_prefix falls back to DEFAULT_PR_PREFIX');

	my $configured = top_for(make_harness(
		envs => ['qa'], vault => 0, control => 'trunk', pr_prefix => 'review/',
	));

	is($configured->control_branch, 'trunk',
		'control_branch returns the configured branch');
	is($configured->pr_prefix, 'review/',
		'pr_prefix returns the configured prefix');
};

subtest 'the old guards are gone' => sub {
	plan tests => 6;

	ok(!Genesis::Top->can('ci_configured'), 'ci_configured no longer exists');
	ok(!Genesis::Top->can('ci_enabled'),    'ci_enabled no longer exists');
	ok(!Genesis::Top->can('ci_control_branch'),
		'ci_control_branch no longer exists');

	my @callers = files_matching(qr{\bci_(?:configured|enabled|control_branch)\b});
	is_deeply(\@callers, [], 'no module calls any of the three')
		or diag("still calling a removed accessor: @callers");

	my @control_readers = grep { $_ ne 'lib/Genesis/Top.pm' }
		files_matching(qr{pipeline\.source_control\.control_branch});
	is_deeply(\@control_readers, [],
		'control_branch is read in one place')
		or diag("open-coded control branch read: @control_readers");

	my @prefix_readers = grep { $_ ne 'lib/Genesis/Top.pm' }
		files_matching(qr{pipeline\.source_control\.pr_prefix});
	is_deeply(\@prefix_readers, [],
		'pr_prefix is read in one place')
		or diag("open-coded prefix read: @prefix_readers");
};

subtest 'no call site pairs a provider read with a separate guard' => sub {
	plan tests => 2;

	# The readers the design allows, and why each one may read the key
	# rather than ask the accessor.  Under D105 the schema builder is no
	# longer among them: the block declares the field that decides its
	# shape, so nothing reads the value raw to build a schema out of it.
	my @allowed = (
		# It is the accessor, and every caller outside the load-time
		# validation below reads the provider through it.
		'lib/Genesis/Top.pm pipeline_provider_type',

		# A schema predicate, which the schema hands the raw config rather
		# than the Genesis::Top, so there is no object to ask.
		'lib/Genesis/Top.pm _automated_provider_configured',

		# It refuses a key whose provider declares no capability behind it,
		# so it reads the type the operator declared, which is the very
		# thing it is deciding about.
		'lib/Genesis/Top.pm _validate_capability_gates',
	);

	my @readers = readers_of(qr{pipeline\.provider\.type});
	is_deeply(\@readers, [sort @allowed],
		'pipeline.provider.type is read only where the design allows')
		or diag("open-coded provider read: @readers");

	# The row above dedupes on the file and the sub, so a second read of the
	# key inside the accessor itself would hide behind the first one.  The
	# accessor answers the whole tree's question about the provider, and it
	# needs to ask the configuration exactly once to do it.
	is(reads_in('lib/Genesis/Top.pm', 'pipeline_provider_type',
			qr{pipeline\.provider\.type}), 1,
		'and the accessor reads its own key once');
};

subtest 'the provider block declares what decides its shape' => sub {
	plan tests => 5;

	require Genesis::CI::Compiler::PipelineProvider;

	# Any repository at all will do here, and that is as much the row's
	# point as the declaration is.  The block's schema used to be built
	# out of whatever this configuration said the provider was, so which
	# repository it was read from decided what came back.
	my $top = top_for(make_harness(envs => ['qa'], vault => 0,
		pipeline => 'none'));
	my $schema = $top->_repo_config_schema->{pipeline}{schema}{provider};

	is $schema->{type}, 'custom_struct',
		'the block is declared as one whose own value decides it';
	is $schema->{discriminator}, 'type',
		'and it names the field that decides';
	is $schema->{discriminator_default}, 'manual',
		"and D15's default sits on the declaration";
	is_deeply $schema->{default}, {},
		'beside the empty block that lets that default be reached';
	is_deeply [sort keys %{$schema->{modules}}],
		[Genesis::CI::Compiler::PipelineProvider->known_providers],
		'with a module for every registered provider, so the map is total';
};

done_testing;
