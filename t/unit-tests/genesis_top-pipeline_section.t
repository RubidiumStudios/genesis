#!perl
# Proves T12, T15, and T31: the .genesis/config section is called pipeline,
# the ci spelling is refused by name, the Genesis::CI package names are
# untouched, pipeline.repo.root is gone from the schema and from the
# scaffold, and no renamed key is translated onto its replacement.
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

# The scaffold sits in the repo command module, which nothing else here
# pulls in, so the subtest that calls it would otherwise find no sub.
require Genesis::Commands::Repo;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

# A row's own configuration text lives beside the row rather than in the
# harness, because it builds no state: it says what the load is handed and
# the harness loader builds the repository round it.
#
# The harness clones copy A from a bare repository at a filesystem path, so
# the origin URL carries no GitHub owner/repo pair for the source-control
# block to derive one from, and a row that enables a pipeline names the
# repository itself.
sub enabled_pipeline {
	return join("\n", 'pipeline:', '  enabled: true',
		'  source_control:', '    repository: genesis/bosh-deployments');
}

subtest 'the pipeline section loads and the ci section does not' => sub {
	plan tests => 3;

	my $top;
	lives_ok {$top = load_with($h, enabled_pipeline())}
		'pipeline.enabled validates';
	is $top->config->get('pipeline.enabled'), 1,
		'the gate reads back through the new name';

	throws_ok {load_with($h, "ci:\n  enabled: true")}
		qr/\bci\b.*unknown configuration key/s,
		'the ci section is refused by name';
};

subtest 'the code namespace is unchanged' => sub {
	plan tests => 3;

	for my $module (qw/Genesis::CI::Compiler Genesis::CI::Propagation
	                   Genesis::CI::Compiler::PipelineProvider/) {
		(my $path = "$module.pm") =~ s{::}{/}g;
		ok -f "lib/$path", "$module still lives where it did";
	}
};

subtest 'the repository-root key is gone' => sub {
	plan tests => 2;

	throws_ok {load_with($h, "pipeline:\n  enabled: true\n  repo:\n    root: .")}
		qr/pipeline\.repo: unknown configuration key/,
		'pipeline.repo.root is refused by name';

	my $top = load_with($h, enabled_pipeline());
	Genesis::Commands::Repo::_create_pipeline_scaffold($top);
	ok !$top->config->has('pipeline.repo.root'),
		'the scaffold writes no repository-root key';
};

subtest 'there are no compatibility aliases' => sub {
	plan tests => 4;

	# One renamed key per decision that renamed one.  Each is refused
	# under its old spelling rather than accepted and moved, and each row
	# reads the key the refusal names as well, because a refusal over some
	# other key would otherwise satisfy every one of them.
	#
	# The name a refusal carries is the outermost key the schema does not
	# know, so all three ci. spellings are refused as ci, and the one under
	# an enabled pipeline is refused as pipeline.repo.
	my %old = (
		'ci.enabled'         => ["ci:\n  enabled: true", 'ci'],
		'pipeline.repo.root' => ["pipeline:\n  enabled: true\n  repo:\n    root: .",
		                         'pipeline.repo'],
		'ci.control_branch'  => ["ci:\n  control_branch: control", 'ci'],
		'ci.name'            => ["ci:\n  name: bosh", 'ci'],
	);
	for my $key (sort keys %old) {
		my ($body, $refused) = @{$old{$key}};
		throws_ok {load_with($h, $body)}
			qr/\Q$refused\E:\s+unknown\s+configuration\s+key/,
			"$key is refused as $refused rather than translated";
	}
};

subtest 'no code path maps an old key onto a new one' => sub {
	plan tests => 1;

	my @offenders;
	for my $pm (qx{find lib -name '*.pm'}) {
		chomp $pm;
		open my $fh, '<', $pm or next;
		my $body = do {local $/; <$fh>};
		close $fh;
		push @offenders, $pm if $body =~ m{['"]ci\.(?:enabled|provider|name|repo|control_branch)};
	}
	is_deeply \@offenders, [],
		'nothing under lib/ still reads a ci. key';
};

done_testing;
