#!perl
# Proves T33 and T34: the manifest store is refused at configuration load
# under a pipeline, a fresh repository is initialised with exodus, and an
# environment whose effective Genesis floor is below 3.1.0 is refused by
# name with the remedy of raising it.
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

# What a row here varies is the store, the repository's own floor, and
# whether there is a pipeline at all, so this composes those three into the
# configuration text and hands it to the harness loader, which builds the
# repository round it.  It builds no state itself.
#
# Every row here leaves the provider at manual, so the shuttle, the vault,
# and the locker are not required beside it.
#
# The repository is named rather than derived because copy A is cloned from
# a bare repository at a filesystem path, whose URL carries no GitHub
# owner/repo pair, and the derivation's own refusal belongs to the
# source-control rows rather than to these.
# The floor goes to the harness rather than into the body, because the
# harness writes it for every repository it assembles and a row that says
# nothing about the floor should get the one a real repository has.  A row
# that is about the floor names its own, and undef asks for none.
sub load_store {
	my ($store, %opts) = @_;
	my @lines;
	push @lines, "manifest_store: $store" if $store;
	push @lines, 'pipeline:', '  enabled: true',
		'  source_control:', '    repository: genesis/bosh-deployments'
		unless $opts{no_pipeline};
	return load_with($h, join("\n", @lines),
		exists $opts{minimum_version}
			? (minimum_version => $opts{minimum_version})
			: ());
}

subtest 'the store must be exodus under a pipeline' => sub {
	plan tests => 4;

	for my $store (qw/repository hybrid/) {
		throws_ok {load_store($store)}
			qr/manifest_store:\s+$store.*cannot\s+be\s+used\s+under\s+a\s+pipeline/s,
			"$store is refused naming the value";
	}
	lives_ok {load_store('exodus')} 'exodus passes';
	lives_ok {load_store('repository', no_pipeline => 1)}
		'and a repository with no pipeline is left alone';
};

subtest 'a fresh repository is initialised with exodus' => sub {
	plan tests => 1;

	my $top = load_store(undef);
	is $top->config->get('manifest_store'), 'exodus',
		'the 3.2.0 default is exodus';
};

subtest 'an old kit floor cannot reach the repository store' => sub {
	plan tests => 5;

	# The old floor goes on an environment of its own, written into the
	# working tree and taken out again below, so no other row ever sees it
	# and this one passes wherever it is run.  The harness's own qa.yml is
	# left exactly as it was.
	my $path = write_env_file($h, 'legacy',
		genesis => {min_version => '3.0.0'}, commit => 0);

	throws_ok {load_store('exodus', minimum_version => undef)}
		qr/environment legacy has\s+a\s+Genesis\s+floor\s+below\s+3\.1\.0/i,
		'the floor case is refused by name';
	throws_ok {load_store('exodus', minimum_version => undef)}
		qr/Raise\s+the\s+kit's\s+floor\s+to\s+3\.1\.0/,
		'and the refusal carries the remedy';
	throws_ok {load_store('exodus', minimum_version => undef)}
		qr/genesis\.min_version/,
		'and names the key too, for a floor somebody set by hand';

	# The floor that matters is the effective one, which is the higher of
	# the repository's own minimum and the environment's, so a repository
	# that declares nothing better is refused and one that already declares
	# 3.1.0 is not refused over a line the run time would never honour.
	throws_ok {load_store('exodus', minimum_version => '3.0.0')}
		qr/environment legacy has\s+a\s+Genesis\s+floor\s+below\s+3\.1\.0/i,
		'a repository floor below 3.1.0 leaves the refusal standing';
	lives_ok {load_store('exodus', minimum_version => '3.1.0')}
		'and a repository floor of 3.1.0 lifts the environment that declares less';

	unlink $h->a . "/$path";
};

subtest 'the schema supplies the store where nobody named one' => sub {
	plan tests => 2;

	# The gate reads the key with no fallback of its own, so the schema's
	# default is the only thing standing between an unwritten key and a
	# refusal, and this row is what says so.
	my $top = load_store(undef);
	is $top->config->get('manifest_store'), 'exodus',
		'an unnamed store resolves to exodus out of the schema alone';
	lives_ok {load_store(undef)} 'and the gate is satisfied by it';
};

subtest 'an environment that declares no floor is refused' => sub {
	plan tests => 3;

	# An environment declaring no minimum version resolves to 0.0.0, which
	# is below 3.1.0, so the run time serves it out of the repository store
	# and the deploy commits manifests onto the deployment branch that the
	# propagation writer also advances.  That is the two-writer case the
	# gate exists to refuse, and a declaration it cannot read is not a
	# reason to pass it.  A newly written environment file omits the
	# minimum version whenever Genesis is a development build, so this is
	# reached rather than theoretical.
	my $path = write_env_file($h, 'floorless', genesis => {}, commit => 0);

	throws_ok {load_store('exodus', minimum_version => undef)}
		qr/environment floorless/i,
		'the environment is refused by name';
	throws_ok {load_store('exodus', minimum_version => undef)}
		qr/declares\s+no\s+minimum\s+Genesis\s+version/i,
		'and the refusal says it declared none';
	lives_ok {load_store('exodus', minimum_version => '3.1.0')}
		'while a repository floor of 3.1.0 lifts it as it lifts any other';

	unlink $h->a . "/$path";
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
