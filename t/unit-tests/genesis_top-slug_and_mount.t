#!perl
# Proves T35 and T42: the deployment type and every environment name are
# validated at load as git ref components, a failing value bails naming
# the value and the branch it would have composed, and, for T351, a pipeline
# environment resolving an exodus mount other than pipeline.exodus_mount is
# refused naming the environment, both mounts and the key, at
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

# The environment files below carry genesis.pipeline.require_pr, which is
# there only to put a pipeline block on the file.  It is a key no
# capability gates, so the rows stand on the manual provider the harness
# leaves in place, which declares every ability false.

# The deployment type is the one thing these rows vary, so the load goes
# through the harness loader and names the type in the call, and the block
# below is the configuration every row here shares.
#
# The repository is named rather than derived because copy A is cloned from
# a bare repository at a filesystem path, whose URL carries no GitHub
# owner/repo pair, and the derivation's own refusal belongs to the
# source-control rows rather than to these.
sub load_with_type {
	my ($type, %opts) = @_;
	return load_with($h, join("\n",
		'manifest_store: exodus',
		'pipeline:', '  enabled: true',
		(defined $opts{mount} ? ("  exodus_mount: $opts{mount}") : ()),
		'  source_control:', '    repository: genesis/bosh-deployments'),
		deployment_type => $type);
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

subtest 'a name no environment can carry is no environment' => sub {
	plan tests => 3;

	# The bad name goes on a file of its own, written into the working tree
	# and taken out again below, so the row that follows sees a repository
	# whose names are all well formed again.  The file declares itself, but
	# the environment naming rules refuse the name, so it is left out the
	# way Top::envs leaves it out, and no branch is ever composed from it.
	my $path = write_env_file($h, 'qa..bad',
		pipeline => {require_pr => 'false'}, commit => 0);

	my $top;
	lives_ok {$top = load_with_type('bosh')} 'the load passes over it';
	ok !(grep {$_ eq 'qa..bad'} $top->_env_file_names),
		'it is not among the names the checks walk';
	ok !exists $top->pipeline_topology->{nodes}{'qa..bad'},
		'and the pipeline has no node for it';

	unlink $h->a . "/$path";
};

subtest 'every pipeline environment resolves pipeline.exodus_mount' => sub {
	# T351's load half.  Seven explicit rows and one for the run's own
	# restoration assertion, because a command that refuses at configuration
	# load has touched nothing and run_genesis says so for itself.
	plan tests => 8;

	write_env_file($h, 'qa',
		genesis => {exodus_mount => '/secret/exodus/'},
		pipeline => {require_pr => 'false'});
	write_env_file($h, 'prod',
		genesis => {exodus_mount => '/other/exodus/'},
		pipeline => {require_pr => 'false'});

	# No key, so the pipeline's mount is the default, and prod resolving
	# another is prod out of step with the pipeline.
	my $refusal = '';
	eval {load_with_type('bosh'); 1} or $refusal = $@;
	like $refusal, qr{prod\s+resolves\s+/other/exodus/}s,
		'the load names the environment and the mount it resolved';
	like $refusal, qr{pipeline\.exodus_mount\s+is\s+/secret/exodus/}s,
		"and the pipeline's own mount, defaulted";

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	is $exit, Genesis::Exit::CONFIG, 'and the refusal exits CONFIG';
	# The exit code alone is satisfied by any other CONFIG refusal on the
	# path, so the row reads what the run said as well.
	like $err, qr{Set\s+pipeline\.exodus_mount}s,
		'and names the key to set rather than anything else';

	# The key names the mount prod resolves, and now qa is the one out of
	# step, so the mount is the key's and not whichever environment's.
	my $keyed = '';
	eval {load_with_type('bosh', mount => '/other/exodus/'); 1} or $keyed = $@;
	like $keyed, qr{qa\s+resolves\s+/secret/exodus/}s,
		'the key decides the mount, and the environment off it is named';

	write_env_file($h, 'qa',
		genesis => {exodus_mount => '/other/exodus/'},
		pipeline => {require_pr => 'false'});
	lives_ok {load_with_type('bosh', mount => '/other/exodus')}
		'environments on the key pass, the key normalised like any mount';

	# An environment that names no exodus mount derives one from its secrets
	# mount, with exodus/ under it, and the secrets mount is normalised
	# before anything is appended to it.  So a secrets mount written without
	# its slashes has to land on the key named in full.
	write_env_file($h, 'qa',
		genesis => {secrets_mount => 'foo'},
		pipeline => {require_pr => 'false'});
	write_env_file($h, 'prod',
		genesis => {exodus_mount => '/foo/exodus/'},
		pipeline => {require_pr => 'false'});
	lives_ok {load_with_type('bosh', mount => '/foo/exodus/')}
		'a derived mount meets the key, so the two are one mount';

	write_env_file($h, 'qa',
		genesis => {exodus_mount => '/secret/exodus/'},
		pipeline => {require_pr => 'false'});
	write_env_file($h, 'prod',
		genesis => {exodus_mount => '/secret/exodus/'},
		pipeline => {require_pr => 'false'});
};

subtest 'an empty exodus mount is the mount it names' => sub {
	plan tests => 3;

	# The run time reads genesis.exodus_mount as written and normalises what
	# it finds, so an empty value is a mount of its own rather than a key
	# nobody set.  prod already resolves the default mount from the row
	# above, so only qa changes here and the commit has a delta to carry.
	write_env_file($h, 'qa',
		genesis => {exodus_mount => "''"},
		pipeline => {require_pr => 'false'});

	my $refusal = '';
	eval {load_with_type('bosh'); 1} or $refusal = $@;
	like $refusal, qr{qa\s+resolves\s+//}s,
		'an empty mount normalises the way the run time normalises it';
	unlike $refusal, qr{prod\s+resolves}s,
		'rather than collapsing into the default, which prod resolves';

	write_env_file($h, 'qa',
		genesis => {exodus_mount => '/secret/exodus/'},
		pipeline => {require_pr => 'false'});
	lives_ok {load_with_type('bosh')} 'and one shared mount passes again';
};

subtest 'a block switched off still joins the pipeline' => sub {
	plan tests => 2;

	# The block loop decides membership with exists, so the readers beside
	# it have to agree, or an environment that turns its block off escapes
	# them.  Its mount is off the pipeline's, so the mount check is seen to
	# walk it by refusing it.
	my $path = $h->a . '/qa-off.yml';
	put_file($path, join("\n",
		'---', 'kit:', '  name:    dev', '  version: latest',
		'  features: []', 'genesis:', '  env: qa-off',
		'  exodus_mount: /other/exodus/', '  pipeline: false', ''));

	throws_ok {load_with_type('bosh')}
		qr{qa-off\s+resolves\s+/other/exodus/}s,
		'an environment whose block is off is read like any other';

	unlink $path;
	lives_ok {load_with_type('bosh')} 'and the repository is well formed again';
};

subtest 'a directory named like an environment file is not one' => sub {
	plan tests => 2;

	my $dir = $h->a . '/notes.yml';
	mkdir $dir or die "cannot create $dir: $!";

	my $top = load_with_type('bosh');
	ok !(grep {$_ eq 'notes'} $top->_env_file_names),
		'a directory is left out of the names the checks walk';
	ok scalar(grep {$_ eq 'qa'} $top->_env_file_names),
		'while the environment file beside it is still there';

	rmdir $dir;
};

subtest 'an environment is merged once and the answer kept' => sub {
	plan tests => 2;

	# Three checks walk every environment, and each of them used to pay for
	# its own spruce run, so the read is memoised on the instance.
	my $top    = load_with_type('bosh');
	my $first  = $top->_merged_env_params('qa');
	my $second = $top->_merged_env_params('qa');

	is $second, $first, "the second read answers with the first read's hash";
	is_deeply $second, $first, 'which is the merge the first read built';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
