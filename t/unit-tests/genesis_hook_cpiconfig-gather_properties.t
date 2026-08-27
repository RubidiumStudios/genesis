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
use Test::Exception;
use Test::Output;
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

# struct_lookup traversal over a dataset, as Genesis::Env::lookup does.
# gather_properties reads in list context and treats the second element as
# "found", so the flag has to be real -- a bare undef would send every
# lookup down the OCFP fallback instead.
sub reader_over {
	my ($data, $prefix) = @_;
	return sub {
		my ($self, $key, $default) = @_;
		my ($rest) = $key =~ /^\Q$prefix\E\.?(.*)$/;
		return (wantarray ? ($default, undef) : $default) unless defined $rest;
		return (wantarray ? ($data, '.') : $data) unless length $rest;
		my ($value, $found) = struct_lookup($data, $rest);
		return (wantarray ? ($default, undef) : $default) unless $found;
		return wantarray ? ($value, $found) : $value;
	};
}

# One env entry has three views, and the hook depends on their being
# different: unevaluated shows the operator as written, merged shows the
# resolved value, entombed shows the credhub reference.
sub vaulted {
	my (%o) = @_;
	return bless {
		raw      => sprintf('(( vault "%s" ))', $o{path}),
		resolved => $o{secret},
		entombed => sprintf('((%s))', $o{ref}),
	}, 'Test::Vaulted';
}

# A plain scalar reads the same in all three; only a vaulted value differs.
sub project {
	my ($data, $view) = @_;
	return $data->{$view}                                      if ref($data) eq 'Test::Vaulted';
	return {map {($_ => project($data->{$_}, $view))} CORE::keys %$data}
	                                                           if ref($data) eq 'HASH';
	return [map {project($_, $view)} @$data]                   if ref($data) eq 'ARRAY';
	return $data;
}

sub operator_lookups {
	my ($cpi) = @_;
	my $unevaled = project($cpi, 'raw');
	return (
		lookup               => reader_over(project($cpi, 'resolved'), 'bosh-configs.cpi'),
		lookup_entombed_self => reader_over(project($cpi, 'entombed'), 'bosh-configs.cpi'),
		lookup_unevaled      => sub {
			my ($self, $key) = @_;
			my ($rest) = ($key // '') =~ /^bosh-configs\.cpi\.?(.*)$/;
			return $unevaled unless defined($rest) && length $rest;
			my ($value) = struct_lookup($unevaled, $rest);
			return $value;
		},
	);
}

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

		operator_lookups($cpi),

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

# =======================================================================
# _parse_property -- descriptor string to spec.  Pure; no lookups.
# =======================================================================

subtest '_parse_property - the parts a descriptor can carry' => sub {
	plan tests => 9;

	my $hook = Genesis::Hook::CpiConfig::gp_kit->init(env => mock_env());

	# An absent `:` clause is undef, not ''.  Collapsing the two is what
	# made the kit's "this property is required" statement unenforceable:
	# the descriptor could no longer say whether a default was declared.
	is_deeply($hook->_parse_property('region'), {
		key => 'region', alts => [], default => undef, optional => 0,
		secret => 0, path => 'region', lookups => ['region'],
	}, 'no : clause means no default, which makes the property required');

	is_deeply($hook->_parse_property('!api_key'), {
		key => 'api_key', alts => [], default => undef, optional => 0,
		secret => 1, path => 'api_key', lookups => ['api_key'],
	}, 'a leading ! marks it secret');

	is_deeply($hook->_parse_property('key@a,b'), {
		key => 'key', alts => ['a','b'], default => undef, optional => 0,
		secret => 0, path => 'key', lookups => ['key','a','b'],
	}, 'alts are comma-separated and follow the key in lookup order');

	is_deeply($hook->_parse_property('region:us-east-1'), {
		key => 'region', alts => [], default => 'us-east-1', optional => 0,
		secret => 0, path => 'region', lookups => ['region'],
	}, 'a default is taken verbatim, JSON decoding happens at resolve time');

	# An empty default is a declaration, so the clause may be empty.  This
	# form did not parse at all before: the default demanded a character.
	is_deeply($hook->_parse_property('region:'), {
		key => 'region', alts => [], default => '', optional => 0,
		secret => 0, path => 'region', lookups => ['region'],
	}, 'an empty : clause declares an empty default');

	is_deeply($hook->_parse_property('pve_host:>pve.host'), {
		key => 'pve_host', alts => [], default => '', optional => 0,
		secret => 0, path => 'pve.host', lookups => ['pve_host'],
	}, 'an empty default may be followed by a path');

	is_deeply($hook->_parse_property('endpoint?'), {
		key => 'endpoint', alts => [], default => undef, optional => 1,
		secret => 0, path => 'endpoint', lookups => ['endpoint'],
	}, 'a trailing ? marks it optional, which is not the same as defaulted');

	is_deeply($hook->_parse_property('!host@addr:def>a.b.c'), {
		key => 'host', alts => ['addr'], default => 'def', optional => 0,
		secret => 1, path => 'a.b.c', lookups => ['host','addr'],
	}, 'every part at once, with the path overriding the key');

	# The descriptor comes from a kit's hook, so its author is the one who
	# has to fix it -- the message repeats the grammar for that reason.
	local $ENV{GENESIS_IGNORE_EVAL} = '';
	quietly {
		throws_ok {$hook->_parse_property('@nokey')}
			qr/Invalid CPI config property specification/,
			'a descriptor with no key is refused';
	};
};

# =======================================================================
# _resolve -- spec to (value, found).  Consults the operator's namespace
# across every name before the OCFP config across every name.
# =======================================================================

# An env whose OCFP side is populated too, so precedence is observable.
sub mock_env_with_ocfp {
	my (%opts) = @_;
	my ($cpi, $ocfp) = ($opts{cpi} // {}, $opts{ocfp} // {});
	$seq++;
	return mock "Genesis::Env::CpiConfigGPO::$seq" => {
		name => "gpo-env-$seq", type => 'bosh', kit => $kit,
		iaas => 'test-iaas', cpi_name => 'test_cpi',
		cpi_credhub_base => '/cpi-config/properties/', file => 'gpo-env.yml',
		operator_lookups($cpi),
		ocfp_config_lookup => sub {
			my ($self, $key, $default) = @_;
			my ($rest) = $key =~ /^cpi\.test-iaas\.(.*)$/;
			return (wantarray ? ($default, undef) : $default) unless defined $rest;
			my ($value, $found) = struct_lookup($ocfp, $rest);
			return (wantarray ? ($default, undef) : $default) unless $found;
			return wantarray ? ($value, $found) : $value;
		},
	};
}

sub resolve_with {
	my ($descriptor, %sources) = @_;
	my $hook = Genesis::Hook::CpiConfig::gp_kit->init(env => mock_env_with_ocfp(%sources));
	return $hook->_resolve($hook->_parse_property($descriptor));
}

subtest '_resolve - the operator is consulted before the platform' => sub {
	plan tests => 3;

	my ($v, $found) = resolve_with('region',
		cpi => {region => 'operator'}, ocfp => {region => 'platform'});
	is($v, 'operator', 'an operator value wins over the OCFP config');
	ok($found, 'and reports found');

	($v) = resolve_with('region', ocfp => {region => 'platform'});
	is($v, 'platform', 'the OCFP config supplies it when the operator does not');
};

subtest '_resolve - every operator name precedes every platform name' => sub {
	plan tests => 2;

	# The defect this replaces consulted both sources per name, so an OCFP
	# value under the primary beat an operator value under an alt -- an
	# operator using the older spelling was silently overridden by the
	# platform, which is the one thing an alt must not do.
	my ($v) = resolve_with('default_key_name@keypair_name',
		cpi  => {keypair_name     => 'operator-old-spelling'},
		ocfp => {default_key_name => 'platform'});
	is($v, 'operator-old-spelling',
		'an operator value under an alt beats a platform value under the key');

	# Within a source, the primary still precedes its alts.
	($v) = resolve_with('default_key_name@keypair_name',
		cpi => {default_key_name => 'primary', keypair_name => 'alt'});
	is($v, 'primary', 'the primary name wins over its alt within a source');
};

subtest '_resolve - presence is what stops the search, not definedness' => sub {
	plan tests => 3;

	# Nulling a key is how an operator discards an OCFP value and falls
	# back to the kit.  A defined-based test would quietly remove that.
	my ($v, $found) = resolve_with('read_timeout:100',
		cpi => {read_timeout => undef}, ocfp => {read_timeout => 1500});
	ok($found, 'a null operator value counts as found');
	ok(!defined($v), 'and resolves to undef rather than the platform value');

	# The first name that is PRESENT settles it: a null on the name the
	# operator wrote is not overridden by an alt they did not.
	($v) = resolve_with('read_timeout@timeout',
		cpi => {read_timeout => undef, timeout => 'alt-value'});
	ok(!defined($v), 'a null on the primary is not rescued by a set alt');
};

subtest '_resolve - nothing anywhere is reported as not found' => sub {
	plan tests => 2;

	my ($v, $found) = resolve_with('missing', cpi => {}, ocfp => {});
	ok(!$found, 'absent from both sources reports not found');
	ok(!defined($v), 'with no value');
};

# =======================================================================
# Single-pass resolution: every operator leaf is classified once, against
# the map's source keys and its output paths, and emitted once.
# =======================================================================

subtest 'a mapped path may be set directly, and resolves the property' => sub {
	plan tests => 3;

	# The CPI address is a second route into the same property, not a
	# passthrough.  If it were passthrough the ! would never apply and the
	# secret would ship in the clear.
	# Warns, since nothing unmodelled shares the block; swallowed here
	# because the warning is its own subtest's subject.
	my ($config, $hook);
	stderr_from {
		($config, $hook) = gather(
			{pve => {host => 's3cr3t'}},
			'!pve_host@host>pve.host',
		);
	};

	like($config->{pve}{host}, qr/^\(\(.*cpi-config-property--pve_host--/,
		'the value set by its path is entombed like the key form');
	my %entombed = map {$_ => 1} values %{$hook->{credhub_secrets}};
	ok($entombed{'s3cr3t'}, 'and the secret reached credhub');
	ok(!exists $config->{pve_host}, 'nothing is left at the source key');
};

subtest 'known and unknown leaves in one block are split' => sub {
	plan tests => 3;

	# The reason the path form is allowed at all: an operator writing one
	# nested block should not have to split it across two spellings.
	my ($config) = gather(
		{pve => {host => 'h', unknown => 'passed'}},
		'pve_host>pve.host',
	);

	is($config->{pve}{host}, 'h', 'the modelled leaf resolves its property');
	is($config->{pve}{unknown}, 'passed', 'the unmodelled leaf passes through');
	ok(!exists $config->{pve_host}, 'and the source key is not duplicated');
};

subtest 'the path form warns when no sibling justifies it' => sub {
	plan tests => 3;

	# The path form exists so a mixed block need not be split across two
	# spellings.  Alone, it only buys the rename exposure: if the kit's map
	# follows a CPI rename, the leaf silently becomes a dead passthrough.
	my $config;
	my $err = stderr_from {
		($config) = gather({pve => {host => 'h'}}, 'pve_host>pve.host');
	};

	like($err, qr/pve\.host/, 'the warning names the path that was written');
	like($err, qr/pve_host/, 'and the key that would have done instead');
	is($config->{pve}{host}, 'h', 'while the value still resolves');
};

subtest 'the path form is silent when an unmodelled sibling justifies it' => sub {
	plan tests => 2;

	my $config;
	my $err = stderr_from {
		($config) = gather(
			{pve => {host => 'h', unknown => 'y'}},
			'pve_host>pve.host',
		);
	};

	is($err, '', 'a block carrying both kinds of leaf warns nothing');
	is($config->{pve}{unknown}, 'y', 'and the unmodelled leaf passes through');
};

subtest 'the key form takes no rename exposure, so never warns' => sub {
	plan tests => 1;

	my $err = stderr_from {gather({pve_host => 'h'}, 'pve_host>pve.host')};
	is($err, '', 'addressing a property by its key is silent');
};

subtest 'one property may not be set two ways' => sub {
	plan tests => 3;
	local $ENV{GENESIS_IGNORE_EVAL} = '';

	# Every pair of routes into one property collides, so the message names
	# the two leaves that did it rather than assuming which forms they were.
	quietly {
		throws_ok {
			gather({pve_host => 'by-key', pve => {host => 'by-path'}},
				'pve_host>pve.host')
		} qr/pve\.host\s+and\s+pve_host/s,
			'the key and its path together are refused, naming both';

		# The lookbehind matters: without it the `host` inside `pve.host`
		# satisfies the match and a message naming the wrong pair passes.
		throws_ok {
			gather({pve_host => 'by-key', host => 'by-alt'},
				'pve_host@host>pve.host')
		} qr/(?<![\w.])host\s+and\s+pve_host/s,
			'the key and one of its alts together are refused, naming both';

		throws_ok {
			gather({host => 'by-alt', pve => {host => 'by-path'}},
				'pve_host@host>pve.host')
		} qr/(?<![\w.])host\s+and\s+pve\.host/s,
			'an alt and the path together are refused, naming both';
	};
};

subtest 'a quoted dotted key is refused' => sub {
	plan tests => 1;
	local $ENV{GENESIS_IGNORE_EVAL} = '';

	# The ~ escape flatten would need for this is broken -- a key holding a
	# literal tilde round-trips to a dot -- so the form is prohibited.
	quietly {
		throws_ok {gather({'pve.host' => 'literal'}, 'unrelated:x')}
			qr/quoted|literal dot|nested instead/i,
			'a literally-dotted operator key is refused';
	};
};

subtest 'entombment: an env-file vault value is not re-entombed' => sub {
	plan tests => 3;

	# Written as (( vault ... )), so it reaches the hook already entombed
	# by the manifest.  ! has nothing left to do -- re-entombing would
	# store a reference to a reference.
	my $secret = vaulted(
		path   => 'secret/pve:host',
		secret => '10.115.16.1',
		ref    => 'genesis-entombed/pve--host--abc12345',
	);
	my ($config, $hook) = gather({pve_host => $secret}, '!pve_host>pve.host');

	is($config->{pve}{host}, '((genesis-entombed/pve--host--abc12345))',
		'the reference from the entombed manifest is emitted as-is');
	is_deeply($hook->{credhub_secrets}, {}, 'nothing new was entombed');
	unlike($config->{pve}{host}, qr/10\.115\.16\.1/,
		'and the secret itself does not appear');
};

subtest 'entombment: a passthrough vault value arrives entombed too' => sub {
	plan tests => 2;

	# The unmodelled side reads the same manifest, so a vault reference
	# nested anywhere is already a credhub reference by the time it is
	# emitted -- which is what retired the hand-rolled regex.
	my ($config, $hook) = gather({
		pve => {custom => vaulted(
			path   => 'secret/pve:custom',
			secret => 'do-not-leak',
			ref    => 'genesis-entombed/pve--custom--def67890',
		)},
	});

	is($config->{pve}{custom}, '((genesis-entombed/pve--custom--def67890))',
		'an unmodelled vault value is emitted as its reference');
	unlike($config->{pve}{custom}, qr/do-not-leak/,
		'and never in the clear');
};

subtest 'entombment: an empty value cannot be entombed' => sub {
	plan tests => 1;
	local $ENV{GENESIS_IGNORE_EVAL} = '';

	# Declared with an empty default, so it survives the required check and
	# reaches entombment holding '' -- which cannot be stored as a secret.
	quietly {
		throws_ok {gather({}, '!api_password:>credentials.password')}
			qr/entomb.*api_password/is,
			'a secret defaulting to empty is refused at entombment';
	};
};

# =======================================================================
# The three ways a kit says what happens when a property is not set.
# The descriptor has always carried this distinction; nothing enforced it,
# because the parser collapsed "no : clause" into "default of ''".
# =======================================================================

subtest 'no : clause means required, and an unset required property bails' => sub {
	plan tests => 2;
	local $ENV{GENESIS_IGNORE_EVAL} = '';

	# The original code meant to do this -- it bailed `unless defined
	# $default` -- but set `$default //= ''` three statements earlier, so
	# the guard could never fire.  It has been dead since the feature
	# landed, which is why an unset required property shipped as ''.
	quietly {
		throws_ok {gather({}, 'pve_host>pve.host')}
			qr/pve_host/,
			'a required property found nowhere names itself';

		throws_ok {gather({}, 'pve_host>pve.host')}
			qr/required|no default/i,
			'and says why it failed rather than shipping an empty value';
	};
};

subtest 'an empty : clause means default to empty, which is not an error' => sub {
	plan tests => 2;

	my ($config) = gather({}, 'pve_node:>pve.node');
	ok(exists $config->{pve}{node}, 'the property is emitted');
	is($config->{pve}{node}, '', 'holding the empty default the kit declared');
};

subtest 'a ? means omit entirely when unset' => sub {
	plan tests => 1;

	my ($config) = gather({}, 'pve_node?>pve.node');
	ok(!exists $config->{pve}, 'nothing is emitted for an unset optional property');
};

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

subtest 'the emitted config does not alias the operator data' => sub {
	plan tests => 2;

	# It used to: unflatten assigned the passthrough hashref into its
	# result by reference and the mapped path wrote through it, so
	# building a CPI config rewrote the environment's own parameters.
	my %operator = (pve => {host => 'DIRECT', extra => 'x'});
	my ($config) = gather(\%operator, '!pve_host@host>pve.host');

	is($operator{pve}{host}, 'DIRECT',
		'the input hash still holds what the caller put there');
	like($config->{pve}{host}, qr/^\(\(/,
		'while the emitted config holds the credhub reference');
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

subtest 'a null override produces no Perl warnings' => sub {
	plan tests => 1;

	# It used to: the hand-rolled vault regex guarded !ref($value) without
	# defined($value), so any null-valued key printed raw Perl noise.
	my @warnings;
	local $SIG{__WARN__} = sub {push @warnings, $_[0]};
	gather({gone => undef}, 'unrelated:x');

	is_deeply(\@warnings, [], 'no warnings reach the operator');
};

subtest 'an explicit null clears the OCFP value, leaving the kit default' => sub {
	plan tests => 1;

	# SURVIVES, and is the point rather than a side effect: nulling a key
	# is how an operator discards whatever the platform put in the OCFP
	# config and falls back to what the kit declares.  So presence has to
	# be tested apart from definedness -- a key that exists stops the
	# search whatever it holds, and only an absent key reaches OCFP.
	my ($config) = gather(
		{read_timeout => undef},
		'read_timeout:100>connection_options.read_timeout',
	);

	is($config->{connection_options}{read_timeout}, 100,
		'a null operator value discards OCFP and takes the kit default');
};

done_testing;
