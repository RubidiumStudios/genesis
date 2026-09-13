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

# Assert helpers live beside the test that uses them, so these two are
# here rather than in the harness: they build no state, they only drive a
# load and report what it said.
sub config_yaml {
	my ($body) = @_;
	return join("\n",
		'---',
		'deployment_type: bosh',
		'version: "3"',
		'creator_version: 3.2.0',
		$body,
		''
	);
}

sub load_with {
	my ($body) = @_;
	commit_on_control($h, files => {'.genesis/config' => config_yaml($body)});
	my $top = Genesis::Top->new($h->a, no_vault => 1);
	$top->config;
	return $top;
}

subtest 'the pipeline section loads and the ci section does not' => sub {
	plan tests => 3;

	my $top;
	lives_ok {$top = load_with("pipeline:\n  enabled: true")}
		'pipeline.enabled validates';
	is $top->config->get('pipeline.enabled'), 1,
		'the gate reads back through the new name';

	throws_ok {load_with("ci:\n  enabled: true")}
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

	throws_ok {load_with("pipeline:\n  enabled: true\n  repo:\n    root: .")}
		qr/pipeline\.repo: unknown configuration key/,
		'pipeline.repo.root is refused by name';

	my $top = load_with("pipeline:\n  enabled: true");
	Genesis::Commands::Repo::_create_pipeline_scaffold($top);
	ok !$top->config->has('pipeline.repo.root'),
		'the scaffold writes no repository-root key';
};

subtest 'there are no compatibility aliases' => sub {
	plan tests => 4;

	# One renamed key per decision that renamed one.  Each is refused
	# under its old spelling rather than accepted and moved.
	my %old = (
		'ci.enabled'            => "ci:\n  enabled: true",
		'pipeline.repo.root'    => "pipeline:\n  enabled: true\n  repo:\n    root: .",
		'ci.control_branch'     => "ci:\n  control_branch: control",
		'ci.name'               => "ci:\n  name: bosh",
	);
	for my $key (sort keys %old) {
		throws_ok {load_with($old{$key})}
			qr/unknown configuration key/,
			"$key is refused rather than translated";
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
