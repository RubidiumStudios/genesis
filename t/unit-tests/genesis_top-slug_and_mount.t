#!perl
# Proves T35 and T42: the deployment type and every environment name are
# validated at load as git ref components, a failing value bails naming
# the value and the branch it would have composed, and a pipeline whose
# environments resolve two exodus mounts is refused naming both, at
# Genesis::Exit::CONFIG.
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
use Genesis::Exit;
provide_rc();
use_ok 'Genesis::Top';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 1, vault => 0);

# Two rows in a row can ask for the same deployment type, and the harness's
# commit needs a delta, so each load carries its own count beside the file
# under test.
my $loads = 0;

# The repository is named rather than derived because copy A is cloned from
# a bare repository at a filesystem path, whose URL carries no GitHub
# owner/repo pair, and the derivation's own refusal belongs to the
# source-control rows rather than to these.
sub load_with_type {
	my ($type) = @_;
	commit_on_control($h, files => {
		'.genesis/config' => join("\n",
			'---', "deployment_type: $type", 'version: "3"',
			'creator_version: 3.2.0', 'manifest_store: exodus',
			'pipeline:', '  enabled: true',
			'  source_control:', '    repository: genesis/bosh-deployments', ''),
		'.load-count' => sprintf("%d\n", ++$loads),
	});
	my $top = Genesis::Top->new($h->a, no_vault => 1);
	$top->config;
	return $top;
}

subtest 'the deployment type is a git ref component' => sub {
	plan tests => 5;

	lives_ok {load_with_type('bosh')} 'a plain type passes';
	for my $bad ('bosh.', 'bo..sh', 'bosh.lock', '-bosh') {
		throws_ok {load_with_type($bad)}
			qr/deployment type\s+\Q$bad\E\s+.*is\s+not\s+a\s+git\s+ref\s+component/s,
			"$bad is refused";
	}
};

subtest 'the refusal names the branch it would have composed' => sub {
	plan tests => 1;

	throws_ok {load_with_type('bosh.lock')}
		qr{<env>/bosh\.lock},
		'so the operator can see what the name would have made';
};

subtest 'every environment name is checked too' => sub {
	plan tests => 2;

	# The bad name goes on an environment of its own, written into the
	# working tree and taken out again below, so the row that follows sees
	# a repository whose names are all well formed again.
	my $path = write_env_file($h, 'qa..bad',
		pipeline => {manual => 'false'}, commit => 0);

	throws_ok {load_with_type('bosh')}
		qr{environment name\s+qa\.\.bad\s+.*is\s+not\s+a\s+git\s+ref\s+component}s,
		'a bad environment name is refused by name';
	throws_ok {load_with_type('bosh')}
		qr{qa\.\.bad/bosh},
		'and the branch it would have composed is named with it';

	unlink $h->a . "/$path";
};

subtest 'one exodus mount serves the whole pipeline' => sub {
	# Four explicit rows and one for the run's own restoration assertion,
	# because a command that refuses at configuration load has touched
	# nothing and run_genesis says so for itself.
	plan tests => 5;

	write_env_file($h, 'qa',
		genesis => {exodus_mount => '/secret/exodus/'},
		pipeline => {manual => 'false'});
	write_env_file($h, 'prod',
		genesis => {exodus_mount => '/other/exodus/'},
		pipeline => {manual => 'false'});

	my $refusal = '';
	eval {load_with_type('bosh'); 1} or $refusal = $@;
	like $refusal, qr{/secret/exodus/\s+for\s+qa}s,
		'the load names the mount qa resolved';
	like $refusal, qr{/other/exodus/\s+for\s+prod}s,
		'and the mount prod resolved';

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	is $exit, Genesis::Exit::CONFIG, 'and the refusal exits CONFIG';

	write_env_file($h, 'prod',
		genesis => {exodus_mount => '/secret/exodus/'},
		pipeline => {manual => 'false'});
	lives_ok {load_with_type('bosh')} 'one shared mount passes';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
