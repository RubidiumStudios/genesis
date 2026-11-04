#!perl
# Proves T469's load half (D139): genesis.pipeline.provider.tag is a string
# or a list of strings, declared by the configured provider, so the manual
# provider refuses it as it refuses any provider key; and the boolean
# pipeline.provider.tagged it replaces is refused as retired, naming it.
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

my $h = make_harness(envs => ['qa'], pipeline => 1, vault => 0);

my $CONCOURSE = automated_config('concourse', 'url: https://ci.example.com', 'team: main');
my $MANUAL    = join("\n", 'pipeline:', '  enabled: true', '  provider:', '    type: manual');

# The tag is given as the YAML that follows "tag:", since write_env_file
# nests no deeper than one key under the pipeline block.
sub load_tagged {
	my ($tag_yaml, $config) = @_;
	$h->commit_on_control(files => {'qa.yml' => join("\n",
		'---', 'kit:', '  name:    dev', '  version: latest', '  features: []',
		'genesis:', '  env: qa', '  pipeline:', '    provider:', "      tag: $tag_yaml", '')});
	return load_with($h, $config // $CONCOURSE);
}

subtest 'a tag is a string or a list of strings' => sub {
	plan tests => 5;

	lives_ok {load_tagged('net-a')} 'a string validates';
	lives_ok {load_tagged('[net-a, dmz]')} 'a list validates';
	throws_ok {load_tagged('{name: net-a}')}
		qr/genesis\.pipeline\.provider\.tag.*a worker tag or a list of them/s,
		'a mapping is refused by name';
	throws_ok {load_tagged('[net-a, {x: 1}]')}
		qr/genesis\.pipeline\.provider\.tag.*a worker tag or a list of them/s,
		'so is a list holding something other than a tag';
	throws_ok {load_tagged('""')}
		qr/genesis\.pipeline\.provider\.tag.*a worker tag or a list of them/s,
		'and an empty one';
};

subtest 'the manual provider declares no tag' => sub {
	plan tests => 1;

	throws_ok {load_tagged('net-a', $MANUAL)}
		qr/genesis\.pipeline\.provider\.tag.*unknown/s,
		'it is refused as any provider key is';
};

subtest 'the boolean it replaces is refused as retired' => sub {
	plan tests => 1;

	write_env_file($h, 'qa', pipeline => {});
	throws_ok {load_with($h, automated_config('concourse',
		'url: https://ci.example.com', 'team: main', 'tagged: true'))}
		qr/pipeline\.provider\.tagged: is no longer read.*genesis\.pipeline\.provider\.tag/s,
		'naming the key that replaced it';
};

done_testing;
