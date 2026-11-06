#!perl
# Proves T477 (D147): genesis.pipeline.track_bosh_configs on an OCFP
# environment, one whose merged kit.features include ocfp with
# genesis.manage-cloud-configs not false, is refused at load naming the key,
# the environment and the file that sets it, since its deploy generates and
# uploads its own configs.  The same environment managing no configs, and a
# Classic one, load.
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

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $CONCOURSE = automated_config('concourse', 'url: https://ci.example.com', 'team: main');

# An environment file with the given features and extra genesis lines.
sub env_file {
	my ($env, $features, @genesis) = @_;
	return join("\n", '---', 'kit:', '  name:    dev', '  version: latest',
		"  features: $features", 'genesis:', "  env: $env", @genesis, '');
}

my @TRACKED = ('  pipeline:', '    track_bosh_configs: [cloud]');

subtest 'an OCFP environment tracking its configs is refused' => sub {
	plan tests => 2;
	my $h = make_harness(envs => ['qa'], pipeline => 1, vault => 0);
	$h->commit_on_control(files => {'qa.yml' => env_file('qa', '[ocfp]', @TRACKED)});
	throws_ok {load_with($h, $CONCOURSE)}
		qr/genesis\.pipeline\.track_bosh_configs.* in qa.*set in qa\.yml.*OCFP.*generates.*nothing to watch/s,
		'naming the key, the environment and its file';
	throws_ok {load_with($h, $CONCOURSE)}
		qr/genesis\.manage-cloud-configs/s,
		'and the key that would make it Classic';
};

subtest 'the file named is the one that sets the key' => sub {
	plan tests => 1;
	my $h = make_harness(envs => ['site-qa'], pipeline => 1, vault => 0);
	$h->commit_on_control(files => {
		'site.yml'    => join("\n", '---', 'genesis:', @TRACKED, ''),
		'site-qa.yml' => env_file('site-qa', '[ocfp]'),
	});
	throws_ok {load_with($h, $CONCOURSE)}
		qr/track_bosh_configs.* in site-qa.*set in site\.yml/s,
		'the shared file';
};

subtest 'an OCFP environment not managing its configs loads' => sub {
	plan tests => 2;
	my $h = make_harness(envs => ['qa'], pipeline => 1, vault => 0);
	$h->commit_on_control(files => {'qa.yml' =>
		env_file('qa', '[ocfp]', '  manage-cloud-configs: false', @TRACKED)});
	lives_ok {load_with($h, $CONCOURSE)} 'with genesis.manage-cloud-configs: false';
	$h->commit_on_control(files => {'qa.yml' =>
		env_file('qa', '[ocfp]', '  pipeline:', '    track_bosh_configs: false')});
	lives_ok {load_with($h, $CONCOURSE)} 'and one tracking nothing';
};

subtest 'a Classic environment tracking its configs loads' => sub {
	plan tests => 1;
	my $h = make_harness(envs => ['qa'], pipeline => 1, vault => 0);
	$h->commit_on_control(files => {'qa.yml' => env_file('qa', '[]', @TRACKED)});
	lives_ok {load_with($h, $CONCOURSE)} 'its key is accepted';
};

done_testing;
