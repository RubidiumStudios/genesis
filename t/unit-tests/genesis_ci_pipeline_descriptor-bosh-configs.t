#!/usr/bin/env perl
# The descriptor's half of T476 and T478 (D146, D148; contract a16, c10): a
# director's configs are checked once per director and config type, shared by
# every environment on it that tracks the type, read with the director's
# published credentials, and heard by one notify job per director that no
# deploy or redeploy shares.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use Test::More;
use Test::Deep;
use Test::Exception;

$ENV{GENESIS_TESTING} = 'yes';
$ENV{GENESIS_LIB}   ||= 'lib';
$ENV{NOCOLOR}         = 1;

use_ok 'Genesis::CI::Compiler::AST';
use_ok 'Genesis::CI::Compiler::PipelineDescriptor';

# =========================================================================
# Helpers
# =========================================================================

# Environments as name => {bosh_env, track, tags, auto}; a global
# track_bosh_configs as the legacy ci.yml set it.
sub _ast_for {
	my (%o) = @_;
	my %envs = %{$o{envs} || {sandbox => {}}};

	my %integrations = (
		source_control => { provider => 'github', repository => 'org/repo' },
		vault          => { url => 'https://vault.example.com' },
	);
	$integrations{slack} = $o{slack} if $o{slack};

	my %config = (
		task     => { image => 'genesiscommunity/concourse', version => 'latest' },
		registry => {},
	);
	$config{track_bosh_configs} = $o{track_bosh_configs}
		if exists $o{track_bosh_configs};

	my %nodes = map {
		my $e = $envs{$_};
		($_ => {
			alias       => $_, stage_name => $_, genesis_env => $_,
			auto        => $e->{auto} // 0,
			type        => 'deployment',
			deployment_name => "$_-deployment",
			(exists $e->{bosh_env} ? (bosh_env => $e->{bosh_env}) : ()),
			(exists $e->{track} ? (track_bosh_configs => $e->{track}) : ()),
			worker_tags => $e->{tags} || [],
		})
	} keys %envs;

	return Genesis::CI::Compiler::AST->new(
		metadata     => { name => 'test-pipeline', deployment_type => 'deployment' },
		branches     => { control => 'main' },
		integrations => \%integrations,
		targets      => {},
		workflows    => {
			default => {
				name  => 'default',
				type  => 'deployment',
				graph => { nodes => \%nodes, edges => [] },
			},
		},
		configuration => \%config,
	);
}

sub _describe {
	my ($ast) = @_;
	Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast)->describe();
}

sub _resource {
	my ($p, $name) = @_;
	return (grep {$_->{name} eq $name} @{$p->{resources}})[0];
}

sub _job {
	my ($p, $name) = @_;
	return (grep {$_->{name} eq $name} @{$p->{jobs}})[0];
}

sub _config_resources {
	my ($p) = @_;
	return sort map {$_->{name}} grep {$_->{type} eq 'bosh-config'} @{$p->{resources}};
}

# Every get and put of a job, however its plan nests them.
sub _steps {
	my ($node) = @_;
	return () unless ref $node;
	return map {_steps($_)} @$node if ref $node eq 'ARRAY';
	return () unless ref $node eq 'HASH';   # a boolean is blessed
	my @inner = map {_steps($node->{$_})} grep {ref $node->{$_}} keys %$node;
	return ((grep {exists $node->{$_}} qw/get put task/) ? $node : (), @inner);
}

my $SLACK = { channel => '#deploys', webhook => '((slack-webhook))' };

my %TWO_ON_MGMT = (
	qa   => { bosh_env => 'mgmt', track => ['cloud', 'runtime'] },
	prod => { bosh_env => 'mgmt', track => ['cloud'] },
);

# =========================================================================
# T476: one check per director and type
# =========================================================================
subtest 'nothing tracked makes no check and no job' => sub {
	for my $track (undef, 0, 'false', []) {
		my $p = _describe(_ast_for(envs => {sandbox => {bosh_env => 'mgmt',
			(defined $track ? (track => $track) : ())}}));
		my $what = defined $track ? (ref $track ? '[]' : "'$track'") : 'unset';
		is_deeply([_config_resources($p)], [], "no bosh-config resource with $what");
		ok(!_job($p, 'notify-mgmt-bosh-configs'), "and no notify job with $what");
	}
};

subtest 'two environments on one director share its checks' => sub {
	my $p = _describe(_ast_for(envs => \%TWO_ON_MGMT));
	is_deeply([_config_resources($p)], ['mgmt-bosh-cloud-config', 'mgmt-bosh-runtime-config'],
		'a16: one resource per director and type, none per environment');

	my $cloud = _resource($p, 'mgmt-bosh-cloud-config');
	is($cloud->{source}{config}, 'cloud', 'the cloud check reads the cloud type');
	ok($cloud->{source}{all}, 'with all: true, so every named config is covered');
	ok(!exists $cloud->{source}{name}, 'and no single config name');
	is(_resource($p, 'mgmt-bosh-runtime-config')->{source}{config}, 'runtime',
		'the runtime check reads the runtime type');
};

subtest 'true tracks cloud and runtime, and a list exactly its types' => sub {
	my $p = _describe(_ast_for(envs => {sandbox => {bosh_env => 'mgmt', track => 1}}));
	is_deeply([_config_resources($p)], ['mgmt-bosh-cloud-config', 'mgmt-bosh-runtime-config'],
		'true gives cloud and runtime');
	$p = _describe(_ast_for(envs => {sandbox => {bosh_env => 'mgmt', track => ['cpi']}}));
	is_deeply([_config_resources($p)], ['mgmt-bosh-cpi-config'], 'a list gives its own types');
};

subtest 'each director has its own checks' => sub {
	my $p = _describe(_ast_for(envs => {
		qa   => { bosh_env => 'east', track => ['cloud'] },
		prod => { bosh_env => 'west', track => ['cloud'] },
	}));
	is_deeply([_config_resources($p)], ['east-bosh-cloud-config', 'west-bosh-cloud-config'],
		'one cloud check per director');
	ok(_job($p, "notify-$_-bosh-configs"), "and a notify job for $_") for qw/east west/;
};

subtest 'without a director named, the environment is its own' => sub {
	# Env::bosh_env falls back to the environment's own name likewise.
	my $p = _describe(_ast_for(envs => {sandbox => {track => ['cloud']}}));
	is_deeply([_config_resources($p)], ['sandbox-bosh-cloud-config'], 'named for the environment');
};

subtest 'a create-env environment has no director to check' => sub {
	my $p = _describe(_ast_for(envs => {sandbox => {bosh_env => '', track => ['cloud']}}));
	is_deeply([_config_resources($p)], [], 'no check');
};

subtest 'the legacy global key still asks for the checks' => sub {
	my $p = _describe(_ast_for(track_bosh_configs => ['cloud'],
		envs => {sandbox => {bosh_env => 'mgmt'}}));
	is_deeply([_config_resources($p)], ['mgmt-bosh-cloud-config'], 'from the configuration');
};

# =========================================================================
# T478: the director's published credentials
# =========================================================================
subtest 'the check reads the director with its published credentials' => sub {
	my $p = _describe(_ast_for(envs => \%TWO_ON_MGMT));
	my $src = _resource($p, 'mgmt-bosh-cloud-config')->{source};
	is($src->{target},        '((bosh/mgmt.url))',           'D148: target');
	is($src->{ca_cert},       '((bosh/mgmt.ca_cert))',       'D148: ca_cert');
	is($src->{client},        '((bosh/mgmt.client))',        'D148: client');
	is($src->{client_secret}, '((bosh/mgmt.client_secret))', 'D148: client_secret');
};

# =========================================================================
# T476: the notify job
# =========================================================================
subtest 'one job per director hears its checks' => sub {
	my $p = _describe(_ast_for(envs => \%TWO_ON_MGMT, slack => $SLACK));
	my $job = _job($p, 'notify-mgmt-bosh-configs');
	ok($job, 'c10: notify-mgmt-bosh-configs is emitted') or return;

	my @gets = grep {exists $_->{get}} _steps($job->{plan});
	is_deeply([sort map {$_->{get}} @gets], ['mgmt-bosh-cloud-config', 'mgmt-bosh-runtime-config'],
		'it gets both checks');
	ok((!grep {!$_->{trigger}} @gets), 'each with trigger: true');

	my ($put) = grep {($_->{put} // '') eq 'slack'} _steps($job->{plan});
	ok($put, 'and puts one Slack message') or return;
	my $text = $put->{params}{text};
	like($text, qr/^:gear: /, 'D131: led by its kind');
	like($text, qr/\bmgmt\b/, 'naming the director');
	like($text, qr/cloud config[^\n]*\bprod\b[^\n]*\bqa\b/, 'the cloud config with both environments');
	like($text, qr/runtime config[^\n]*\bqa\b/, 'the runtime config with its one');
	like($text, qr/redeploy/i, 'and that a redeploy picks it up');
};

subtest 'no deploy or redeploy gets a check' => sub {
	my $p = _describe(_ast_for(envs => \%TWO_ON_MGMT, slack => $SLACK));
	for my $job (grep {$_->{name} !~ /-bosh-configs$/} @{$p->{jobs}}) {
		my @got = grep {($_->{get} // '') =~ /-bosh-\w+-config$/} _steps($job->{plan});
		ok(!@got, "c10: $job->{name} gets none");
	}
};

subtest 'without Slack the job still hears the checks' => sub {
	my $p = _describe(_ast_for(envs => \%TWO_ON_MGMT));
	my $job = _job($p, 'notify-mgmt-bosh-configs');
	ok($job, 'the job is emitted') or return;
	ok(!(grep {exists $_->{put}} _steps($job->{plan})), 'with nothing to put');
};

subtest 'the job sits in the deployments group' => sub {
	my $p = _describe(_ast_for(envs => \%TWO_ON_MGMT, slack => $SLACK));
	my @in = grep {grep {$_ eq 'notify-mgmt-bosh-configs'} @{$_->{jobs}}} @{$p->{groups}};
	is(scalar(@in), 1, 'in exactly one group');
};

# =========================================================================
# T476: the worker tag (D139)
# =========================================================================
subtest 'one shared tag goes on the check and its get' => sub {
	my %envs = map {$_ => {%{$TWO_ON_MGMT{$_}}, tags => ['net-a']}} keys %TWO_ON_MGMT;
	my $p = _describe(_ast_for(envs => \%envs));
	is_deeply(_resource($p, $_)->{tags}, ['net-a'], "b5: $_ carries the tag")
		for _config_resources($p);
	my @gets = grep {exists $_->{get}} _steps(_job($p, 'notify-mgmt-bosh-configs')->{plan});
	is_deeply($_->{tags}, ['net-a'], "b5: and so does the get of $_->{get}") for @gets;
};

subtest 'with no tag nothing is tagged' => sub {
	my $p = _describe(_ast_for(envs => \%TWO_ON_MGMT));
	ok(!exists _resource($p, $_)->{tags}, "$_ carries none") for _config_resources($p);
};

subtest 'environments disagreeing on the tag are refused' => sub {
	my %envs = (
		qa   => {%{$TWO_ON_MGMT{qa}},   tags => ['net-a']},
		prod => {%{$TWO_ON_MGMT{prod}}, tags => ['net-b']},
	);
	throws_ok {_describe(_ast_for(envs => \%envs))}
		qr/mgmt.*prod.*net-b.*qa.*net-a/s,
		'naming the director, each environment and its tag';
};

subtest 'an environment tracking nothing does not take part in the tag' => sub {
	my %envs = (
		qa   => {%{$TWO_ON_MGMT{qa}}, tags => ['net-a']},
		prod => {bosh_env => 'mgmt', tags => ['net-b']},
	);
	lives_ok {_describe(_ast_for(envs => \%envs))} 'the compile goes on';
};

done_testing;
