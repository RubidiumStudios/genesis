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
use utf8;

use lib 't';
use helper;
use Test::More;
use Genesis qw(bail struct_lookup);
use Cwd qw(abs_path);

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

require_ok 'Genesis::Hook::CpiConfig';

# Genesis::Hook requires the class name to match
# Genesis::Hook::<Type>::<KitName> so label() can parse it.
{
	package Genesis::Hook::CpiConfig::gp_kit;
	use parent -norequire, 'Genesis::Hook::CpiConfig';
	sub perform {$_[0]->done({})}
}

my $kit = mock "Genesis::Kit::CpiConfigGP" => {
	name    => 'gp-kit',
	version => '1.0.0',
	id      => sub {$_[0]->name.'/'.$_[0]->version},
	kit_bug => sub {my ($self,$msg,@a) = @_; bail("Throwing a kit bug: ".$msg, @a)},
};

# One env per call so each subtest gets a fresh hook from init().
my $seq = 0;
sub mock_env {
	my (%opts) = @_;
	my $cpi = $opts{cpi} // {};
	$seq++;
	return mock "Genesis::Env::CpiConfigGP::$seq" => {
		name             => "gp-env-$seq",
		type             => 'bosh',
		kit              => $kit,
		iaas             => 'test-iaas',
		cpi_name         => 'test_cpi',
		cpi_credhub_base => '/cpi-config/properties/',
		file             => 'gp-env.yml',

		# gather_properties reads lookup in list context and treats the
		# second element as "found", so the flag has to be real: a bare
		# undef would send every lookup down the OCFP fallback instead.
		#
		# Traversal is struct_lookup, as Genesis::Env::lookup does.  A
		# flat hash-key check agrees with the real thing only while
		# nothing is nested, and every interesting case here is nested.
		lookup => sub {
			my ($self, $key, $default) = @_;
			my ($rest) = $key =~ /^bosh-configs\.cpi\.?(.*)$/;
			return (wantarray ? ($default, undef) : $default) unless defined $rest;
			return (wantarray ? ($cpi, '.') : $cpi) unless length $rest;
			my ($value, $found) = struct_lookup($cpi, $rest);
			return (wantarray ? ($default, undef) : $default) unless $found;
			return wantarray ? ($value, $found) : $value;
		},

		# The override pass deliberately reads raw, unevaluated values.
		lookup_unevaled => sub {
			my ($self, $key) = @_;
			my ($rest) = ($key // '') =~ /^bosh-configs\.cpi\.?(.*)$/;
			return $cpi unless defined($rest) && length $rest;
			my ($value) = struct_lookup($cpi, $rest);
			return $value;
		},

		ocfp_config_lookup => sub {
			my ($self, $key, $default) = @_;
			return wantarray ? ($default, undef) : $default;
		},
	};
}

# Constructed through init(), not blessed directly: a double that skips
# real construction stays green while production breaks.
sub gather {
	my ($cpi, @map) = @_;
	my $hook = Genesis::Hook::CpiConfig::gp_kit->init(env => mock_env(cpi => $cpi));
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

	# The name flattens the dotted path: a dot in a CredHub name is read by
	# the director as a sub-key accessor, so the reference would 404.
	like(
		$config->{credentials}{password},
		qr{^\(\(/cpi-config/properties/cpi-config-property--credentials_password--[0-9a-f]{8}\)\)$},
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

# =======================================================================
# CHARACTERISATION -- what the two-pass implementation does TODAY.
#
# These are not statements of intent.  Several pin behaviour that is
# wrong, so that the change which corrects it has to say so out loud
# rather than quietly altering something nobody wrote down.  Each is
# marked with whether it is expected to survive.
# =======================================================================

subtest 'CHARACTERISATION: passthrough hands whole subtrees through by reference' => sub {
	plan tests => 3;

	# CHANGES: leaf-level flattening replaces subtree-by-reference, which
	# is what lets a vault ref nested inside a hash go un-entombed today.
	my ($config) = gather(
		{
			pve  => {host => 'h', node => 'n'},
			deep => {a => {b => 'nested'}},
			nics => [{ip => '1.1.1.1'}, {ip => '2.2.2.2'}],
		},
	);

	is_deeply($config->{pve}, {host => 'h', node => 'n'},
		'a two-level hash passes through intact');
	is($config->{deep}{a}{b}, 'nested', 'and arbitrary depth does too');
	is($config->{nics}[1]{ip}, '2.2.2.2', 'as do arrays');
};

subtest 'CHARACTERISATION: the emitted config aliases the operator data' => sub {
	plan tests => 2;

	# DEFECT.  unflatten assigns the passthrough hashref into its result
	# by reference, and the mapped path then writes through it -- so
	# building a CPI config rewrites the environment's own parameters.
	# Anything reading bosh-configs.cpi afterwards sees the rewrite.
	my %operator = (pve => {host => 'DIRECT', extra => 'x'});
	my ($config) = gather({%operator}, '!pve_host@host>pve.host');

	# The value handed in is gone from the caller's own structure.
	isnt($operator{pve}{host}, 'DIRECT',
		'the input hash no longer holds what the caller put there');
	like($operator{pve}{host}, qr/^\(\(/,
		'it has been overwritten with the credhub reference');
};

subtest 'CHARACTERISATION: a literal dotted key at a mapped path loses its value' => sub {
	plan tests => 2;

	# DEFECT.  pve_host is not found, so the property takes its empty
	# default and files it at pve.host -- which makes the override pass
	# see the operator's own key as "already handled" and skip it.
	my ($config) = gather({'pve.host' => 'DIRECT'}, 'pve_host>pve.host');

	is($config->{pve}{host}, '',
		'the kit default ships instead of the operator value');
	isnt($config->{pve}{host}, 'DIRECT',
		'the value the operator set is discarded silently');
};

subtest 'CHARACTERISATION: an undef override is dropped, not emitted' => sub {
	plan tests => 2;

	# SURVIVES.  The override pass deletes rather than emitting undef.
	# The warning that comes with it is the next subtest's subject, so it
	# is swallowed here rather than left to litter the run.
	local $SIG{__WARN__} = sub {};
	my ($config) = gather({known => 'v', gone => undef}, 'known');

	is($config->{known}, 'v', 'a defined override is emitted');
	ok(!exists $config->{gone}, 'an undef override is absent from the output');
};

subtest 'CHARACTERISATION: an undef override warns from the vault regex' => sub {
	plan tests => 1;

	# DEFECT, cosmetic but operator-visible: raw Perl noise on stderr for
	# any null-valued key, because the guard is !ref($value) with no
	# defined($value).
	my @warnings;
	local $SIG{__WARN__} = sub {push @warnings, $_[0]};
	gather({gone => undef}, 'unrelated:x');

	ok(scalar(grep {/uninitialized value/} @warnings),
		'a null override produces an uninitialized-value warning');
};

subtest 'CHARACTERISATION: an explicit null at a mapped path takes the kit default' => sub {
	plan tests => 1;

	# DECIDE.  Setting a key to null means "skip the platform default and
	# use the kit's" -- a third behaviour nobody declared.  It is reached
	# because `last if $src` fires on the key merely existing.
	my ($config) = gather(
		{read_timeout => undef},
		'read_timeout:100>connection_options.read_timeout',
	);

	is($config->{connection_options}{read_timeout}, 100,
		'an explicitly null value falls through to the declared default');
};

done_testing;
