#!/usr/bin/env perl
# Proves T467 (D137; contract a18, e8): the image registry.  With
# pipeline.registry set, every resource type the compiler emits and the
# default task image are pulled through its uri, each carrying the registry's
# credentials as references.  An image the operator names in full is taken as
# written, and carries the credentials only under the registry's host.
# Without the block nothing is prefixed, and a malformed auth is refused at
# load naming the key.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Harness::Contract;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $ENV_NAME = $Harness::Contract::ENV_NAME;
my $HOST     = 'registry.example.com';
my $URI      = "$HOST/mirror";
my %REGISTRY = (
	'pipeline.registry.uri'       => $URI,
	'pipeline.registry.auth.type' => 'basic',
	'pipeline.registry.auth.path' => 'registry/pull',
);
my %CREDS = (username => '((registry/pull.username))', password => '((registry/pull.password))');

sub deploy_image {
	my ($p) = @_;
	my $task = task_step(pipeline_job($p, "deploy-$ENV_NAME"));
	return $task && $task->{config}{image_resource}{source};
}

subtest 'every image the compiler names comes through the registry' => sub {
	my $h = contract_harness(config => {%REGISTRY});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);

	my @types = @{$p->{resource_types} || []};
	ok(@types, 'a18: the pipeline declares resource types');
	for my $type (@types) {
		like($type->{source}{repository}, qr{^\Q$URI\E/}, "a18: $type->{name} is pulled through the registry");
		is($type->{source}{$_}, $CREDS{$_}, "a18: $type->{name} carries the $_ reference")
			for sort keys %CREDS;
	}

	my $img = deploy_image($p);
	is($img->{repository}, "$URI/genesiscommunity/concourse", 'e8: the default task image is prefixed');
	is($img->{$_}, $CREDS{$_}, "e8: and carries the $_ reference") for sort keys %CREDS;
};

subtest 'a task image named in full is taken as written' => sub {
	my $h = contract_harness(config => {%REGISTRY,
		'pipeline.provider.task.image' => "$HOST/private/genesis-task"});
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	my $img = deploy_image($p);
	is($img->{repository}, "$HOST/private/genesis-task", 'e8: not prefixed');
	is($img->{$_}, $CREDS{$_}, "e8: and under the registry's host it carries the $_ reference")
		for sort keys %CREDS;

	$h = contract_harness(config => {%REGISTRY,
		'pipeline.provider.task.image' => 'elsewhere.example.org/genesis-task'});
	($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	$img = deploy_image($p);
	is($img->{repository}, 'elsewhere.example.org/genesis-task', 'e8: another host is not prefixed');
	ok(!exists $img->{$_}, "e8: and carries no $_") for sort keys %CREDS;
};

subtest 'without a registry nothing is prefixed' => sub {
	my $h = contract_harness();
	my ($p, $why) = dry_pipeline($h);
	ok($p, 'the dry apply prints a pipeline') or return diag($why);
	for my $type (@{$p->{resource_types} || []}) {
		unlike($type->{source}{repository}, qr{^\Q$URI\E}, "a18: $type->{name} is pulled as named");
		ok(!exists $type->{source}{username}, "a18: $type->{name} carries no credentials");
	}
	my $img = deploy_image($p);
	is($img->{repository}, 'genesiscommunity/concourse', 'e8: the default task image as named');
	ok(!exists $img->{username}, 'e8: with no credentials');
};

subtest 'a malformed auth is refused at load' => sub {
	my $h = contract_harness(config => {%REGISTRY, 'pipeline.registry.auth.type' => 'token'});
	my ($p, $why) = dry_pipeline($h);
	ok(!$p, 'an unknown credential type is refused') or return;
	like($why, qr/^exit 78\b/, 'at CONFIG');
	like($why, qr/pipeline\.registry\.auth/, 'naming the key');

	$h = contract_harness(config => {
		'pipeline.registry.uri'           => $URI,
		'pipeline.registry.auth.type'     => 'basic',
		'pipeline.registry.auth.username' => 'registry/pull:username',
	});
	($p, $why) = dry_pipeline($h);
	ok(!$p, 'a missing component is refused') or return;
	like($why, qr/pipeline\.registry\.auth/, 'naming the key');
	like($why, qr/password/, 'and the component it needs');
};

done_testing;
