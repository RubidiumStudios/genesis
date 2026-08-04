#!/usr/bin/env perl
# Genesis::Hook::CpiConfig::gather_properties -- the interaction between a
# property's `>path` and the trailing manual-override pass.
#
# gather_properties files each mapped value under its output path, but the
# override pass -- the one that lets an environment set CPI properties the
# kit does not model -- decides what to copy by looking for the *source*
# key. Those two agree only while every property leaves `>path` unset. As
# soon as a kit uses `>path`, the source key is absent from the config hash,
# so the operator's own setting is copied back in at the top level beside
# the correctly-placed value.
#
# The duplicate is not cosmetic, because the override pass copies the raw
# env value:
#   - a '!' secret lands in cleartext next to the credhub reference that was
#     supposed to replace it, defeating entombment
#   - a spruce operator is copied as a literal, reaches the director in the
#     uploaded cpi-config, and is parsed as a BOSH variable reference:
#       Variable name ' concat ... ' must only contain alphanumeric,
#       underscores, dashes, or forward slash characters
#     which fails every deployment against that director
#
# Keys the map genuinely does not read must still pass through -- that is
# what the override pass is for -- so this asserts both directions.
use strict;
use warnings;
use lib 't';
use Test::More;

use_ok('Genesis::Hook::CpiConfig') or BAIL_OUT('Genesis::Hook::CpiConfig failed to load');

# --- Test doubles ------------------------------------------------------

package Test::FakeEnv;

sub new {
	my ($class, %opts) = @_;
	return bless { cpi => $opts{cpi} // {} }, $class;
}

# gather_properties calls lookup in list context and treats the second
# element as "found", so the found flag has to be real: a bare undef value
# would send every lookup down the ocfp_config_lookup fallback instead.
sub lookup {
	my ($self, $key, $default) = @_;
	my ($prefix, $rest) = $key =~ /^(bosh-configs\.cpi)\.?(.*)$/;
	return (wantarray ? ($default, 0) : $default) unless defined $prefix;
	return (wantarray ? ($self->{cpi}, 1) : $self->{cpi}) unless length $rest;
	return (wantarray ? ($self->{cpi}{$rest}, 1) : $self->{cpi}{$rest})
		if exists $self->{cpi}{$rest};
	return wantarray ? ($default, 0) : $default;
}

# The override pass deliberately reads raw, unevaluated values.
sub lookup_unevaled { return $_[0]->{cpi} }

sub ocfp_config_lookup { return (undef, 0) }

sub cpi_credhub_base { '/cpi-config/properties/' }

package Test::Hook;

our @ISA = ('Genesis::Hook::CpiConfig');

sub new {
	my ($class, %opts) = @_;
	return bless { env => $opts{env}, credhub_secrets => {} }, $class;
}

sub env  { $_[0]->{env} }
sub iaas { 'test-iaas' }

package main;

sub gather {
	my ($cpi, @map) = @_;
	my $hook = Test::Hook->new(env => Test::FakeEnv->new(cpi => $cpi));
	my $config = $hook->gather_properties(@map);
	return ($config, $hook);
}

# --- baseline: no >path, behaviour is unchanged ------------------------
subtest 'without >path the source key is the output key, as before' => sub {
	my ($config) = gather(
		{ region => 'us-east-1', max_retries => 3 },
		qw/region max_retries:10/,
	);
	is($config->{region}, 'us-east-1', 'mapped value is emitted under its own key');
	is($config->{max_retries}, 3, 'env value wins over the declared default');
};

subtest 'unmodelled keys are still passed through' => sub {
	my ($config) = gather(
		{ region => 'us-east-1', some_extra_knob => 'passthrough' },
		qw/region/,
	);
	is($config->{region}, 'us-east-1', 'mapped key is present');
	is(
		$config->{some_extra_knob}, 'passthrough',
		'a key the map never reads is still carried by the override pass',
	);
};

# --- the regression ----------------------------------------------------
subtest 'a >path property does not leave its source key at the top level' => sub {
	my ($config) = gather(
		{ read_timeout => 1500 },
		qw/read_timeout:100>connection_options.read_timeout/,
	);

	is(
		$config->{connection_options}{read_timeout}, 1500,
		'value is filed under its declared >path',
	);
	ok(
		!exists $config->{read_timeout},
		'source key is not duplicated at the top level',
	);
};

subtest 'an alternate lookup key is consumed too' => sub {
	my ($config) = gather(
		{ host => 'vcenter.example.com' },
		qw/vcenter_address@host>vcenter.address/,
	);

	is($config->{vcenter}{address}, 'vcenter.example.com', 'value resolved via the @alt key');
	ok(!exists $config->{host}, 'the @alt source key is not left behind at the top level');
};

# --- entombment must survive a >path -----------------------------------
subtest 'a secret with a >path is not re-emitted in cleartext' => sub {
	my ($config, $hook) = gather(
		{ api_password => 's3cr3t-value' },
		qw/!api_password>credentials.password/,
	);

	# The name flattens the dotted path to 'credentials-password': a dot here
	# would be read by the director as a sub-key accessor. See the dedicated
	# subtest below.
	like(
		$config->{credentials}{password},
		qr{^\(\(/cpi-config/properties/cpi-config-property--credentials-password--[0-9a-f]{8}\)\)$},
		'the mapped path holds a credhub reference, not the secret',
	);
	ok(
		!exists $config->{api_password},
		'the raw secret is not copied back in under its source key',
	);

	my %entombed = map { $_ => 1 } values %{$hook->{credhub_secrets}};
	ok($entombed{'s3cr3t-value'}, 'the secret was still handed to credhub, so the reference resolves');

	my @cleartext = grep { !ref && defined && /s3cr3t-value/ } values %$config;
	is_deeply(\@cleartext, [], 'the secret appears nowhere in the emitted config');
};

# --- unevaluated operators must not reach the director ------------------
subtest 'a spruce operator in a >path property does not reach the top level' => sub {
	my ($config) = gather(
		{ agent_mbus => '(( concat "nats://" params.static_ip ":4222" ))' },
		qw/agent_mbus:"">agent.mbus/,
	);

	ok(
		!exists $config->{agent_mbus},
		'the unevaluated operator is not copied to a top-level key, where the director would reject it as a variable name',
	);
	is(
		$config->{agent}{mbus}, '(( concat "nats://" params.static_ip ":4222" ))',
		'the mapped path still carries the value for the normal evaluation path to resolve',
	);
};

# --- a real map: nothing mapped is left flat ---------------------------
subtest 'a fully >path-ed map emits no top-level source keys' => sub {
	my ($config) = gather(
		{
			pve_host       => '10.115.16.1',
			pve_node       => 'lab-pipes-0',
			pve_vm_storage => 'local-lvm-data',
			pve_agent_mbus => 'nats://10.115.16.4:4222',
			pve_log_level  => 'debug',   # deliberately not in the map
		},
		qw/
			!pve_host@host>pve.host
			!pve_node@node>pve.node
			pve_vm_storage@vm_storage:local-lvm>pve.vm_storage
			pve_agent_mbus@agent.mbus:"">agent.mbus
		/,
	);

	my @stray = sort grep { /^pve_/ && $_ ne 'pve_log_level' } keys %$config;
	is_deeply(\@stray, [], 'no mapped source key survives at the top level');

	is($config->{pve}{vm_storage}, 'local-lvm-data', 'mapped value is nested under its spec path');
	is($config->{agent}{mbus}, 'nats://10.115.16.4:4222', 'agent.mbus is nested');
	is($config->{pve_log_level}, 'debug', 'the unmodelled key is still passed through untouched');
};

# --- entombed names must survive BOSH's ((variable)) parser ---------------
# A '.' in a ((variable)) reference is a sub-key accessor, so an entombment
# name carrying the dotted config path is truncated by the director:
# ((.../cpi-config-property--pve.host--<sha>)) is looked up as the variable
# '.../cpi-config-property--pve' with sub-key 'host--<sha>', which 404s and
# kills every director-side CPI call through the cpi-config.
subtest 'an entombed secret on a nested path emits a dot-free variable name' => sub {
	my ($config, $hook) = gather(
		{ api_host => 'pve.example.com' },
		qw/!api_host>pve.host/,
	);

	my $ref = $config->{pve}{host};
	like($ref, qr{^\(\(/.*\)\)$}, 'the mapped path holds a credhub reference');

	my ($name) = $ref =~ /^\(\((.*)\)\)$/;
	unlike(
		$name, qr/\./,
		'the variable name carries no dot for the director to read as a sub-key',
	);
	is_deeply(
		[sort keys %{$hook->{credhub_secrets}}], [$name],
		'the secret is stored under exactly the name the reference cites',
	);
};

subtest 'paths that flatten to the same name keep distinct references' => sub {
	my $hook = Test::Hook->new(env => Test::FakeEnv->new(cpi => {}));
	my $a = $hook->cpi_entombment_path_for('pve.host', 'value');
	my $b = $hook->cpi_entombment_path_for('pve-host', 'value');

	unlike($a, qr/\./, 'the dotted path flattens');
	isnt(
		$a, $b,
		'the digest still covers the original key, so a flattened path cannot collide with a literal one',
	);
};

done_testing;
