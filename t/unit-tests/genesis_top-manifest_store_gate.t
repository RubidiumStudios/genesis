#!perl
# Proves T33 and T34: the manifest store is refused at configuration load
# under a pipeline, a fresh repository is initialised with exodus, and an
# environment whose kit floor is below 3.1.0 is refused by name with the
# remedy of raising it.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

# Two rows in a row can ask for the same configuration, and the harness's
# commit needs a delta, so each load carries its own count beside the file
# under test.
my $loads = 0;

# Every row here leaves the provider at manual, so the shuttle, the vault,
# and the locker are not required beside it.
#
# The repository is named rather than derived because copy A is cloned from
# a bare repository at a filesystem path, whose URL carries no GitHub
# owner/repo pair, and the derivation's own refusal belongs to the
# source-control rows rather than to these.
sub load_with {
	my ($store, %opts) = @_;
	my @lines = ('---', 'deployment_type: bosh', 'version: "3"',
		'creator_version: 3.2.0');
	push @lines, "manifest_store: $store" if $store;
	push @lines, 'pipeline:', '  enabled: true',
		'  source_control:', '    repository: genesis/bosh-deployments'
		unless $opts{no_pipeline};
	commit_on_control($h, files => {
		'.genesis/config' => join("\n", @lines, ''),
		'.load-count'     => sprintf("%d\n", ++$loads),
	});
	my $top = Genesis::Top->new($h->a, no_vault => 1);
	$top->config;
	return $top;
}

subtest 'the store must be exodus under a pipeline' => sub {
	plan tests => 4;

	for my $store (qw/repository hybrid/) {
		throws_ok {load_with($store)}
			qr/manifest_store:\s+$store.*cannot\s+be\s+used\s+under\s+a\s+pipeline/s,
			"$store is refused naming the value";
	}
	lives_ok {load_with('exodus')} 'exodus passes';
	lives_ok {load_with('repository', no_pipeline => 1)}
		'and a repository with no pipeline is left alone';
};

subtest 'a fresh repository is initialised with exodus' => sub {
	plan tests => 1;

	my $top = load_with(undef);
	is $top->config->get('manifest_store'), 'exodus',
		'the 3.2.0 default is exodus';
};

subtest 'an old kit floor cannot reach the repository store' => sub {
	plan tests => 2;

	write_env_file($h, 'qa', genesis => {min_version => '3.0.0'},
		pipeline => {});
	throws_ok {load_with('exodus')}
		qr/environment qa uses\s+a\s+kit\s+whose\s+Genesis\s+floor\s+is\s+below\s+3\.1\.0/i,
		'the floor case is refused by name';
	throws_ok {load_with('exodus')}
		qr/Raise\s+the\s+kit's\s+floor\s+to\s+3\.1\.0/,
		'and the refusal carries the remedy';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
