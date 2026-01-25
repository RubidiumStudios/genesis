#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::Deep;

# Test Genesis::Secret base class and factory
# Note: Cannot instantiate Genesis::Secret directly, must use build() or subclasses

use_ok 'Genesis::Secret';
use_ok 'Genesis::Secret::Invalid';

subtest 'class_of() helper maps types correctly' => sub {
	# Standard types - ucfirst() works for these
	is(Genesis::Secret::class_of('random'), 'Genesis::Secret::Random', "random -> Random");
	is(Genesis::Secret::class_of('invalid'), 'Genesis::Secret::Invalid', "invalid -> Invalid");
	is(Genesis::Secret::class_of('x509'), 'Genesis::Secret::X509', "x509 -> X509");

	# Exception types - require explicit mapping in class_of()
	is(Genesis::Secret::class_of('dhparams'), 'Genesis::Secret::DHParams', "dhparams -> DHParams");
	is(Genesis::Secret::class_of('ssh'), 'Genesis::Secret::SSH', "ssh -> SSH");
	is(Genesis::Secret::class_of('rsa'), 'Genesis::Secret::RSA', "rsa -> RSA");
	is(Genesis::Secret::class_of('uuid'), 'Genesis::Secret::UUID', "uuid -> UUID");
	is(Genesis::Secret::class_of('userprovided'), 'Genesis::Secret::UserProvided', "userprovided -> UserProvided");
	is(Genesis::Secret::class_of('user-provided'), 'Genesis::Secret::UserProvided', "user-provided -> UserProvided (alias)");
};

subtest 'build() factory creates correct subclass instances' => sub {
	# Skip validation to allow testing without full environment
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $random = Genesis::Secret->build('random', 'kit', 'test/path:key', size => 32);
	isa_ok($random, 'Genesis::Secret::Random', "build('random') creates Random instance");
	is($random->path, 'test/path:key', "path is set correctly");
	is($random->get('size'), 32, "size definition is preserved");

	my $invalid = Genesis::Secret->build('invalid', 'kit', 'another/path:key',
		data => {foo => 'bar'},
		subject => 'test',
		errors => ['error1']
	);
	isa_ok($invalid, 'Genesis::Secret::Invalid', "build('invalid') creates Invalid instance");
	is($invalid->valid, 0, "Invalid secret reports valid=0");
};

subtest 'build() returns Invalid for unknown types' => sub {
	my $bad = Genesis::Secret->build('nonexistent_type', 'kit', 'some/path:key');
	isa_ok($bad, 'Genesis::Secret::Invalid', "Unknown type returns Invalid");
	is($bad->valid, 0, "Invalid secret reports valid=0");

	# Check that error message mentions the type
	my $desc = $bad->describe;
	like($desc, qr/nonexistent_type/i, "describe() mentions the unknown type");
};

subtest 'common accessors work correctly' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'my/path:value', size => 16, fixed => 1);
	isa_ok($secret, 'Genesis::Secret::Random');

	# path accessor
	is($secret->path, 'my/path:value', "path() returns the secret path");

	# type accessor
	is($secret->type, 'random', "type() returns the type string");

	# label accessor
	is($secret->label, 'Random', "label() returns capitalized type");

	# definition accessor
	my $def = $secret->definition;
	is(ref($def), 'HASH', "definition() returns a hash");
	is($def->{size}, 16, "definition contains size");

	# get() accessor
	is($secret->get('size'), 16, "get('size') returns size");
	is($secret->get('fixed'), 1, "get('fixed') returns fixed flag");
	is($secret->get('nonexistent'), undef, "get() returns undef for missing key");
	is($secret->get('nonexistent', 'default'), 'default', "get() returns default for missing key");

	# has() accessor
	ok($secret->has('size'), "has('size') returns true");
	ok($secret->has('fixed'), "has('fixed') returns true");
	ok(!$secret->has('nonexistent'), "has('nonexistent') returns false");

	# has() with falsy value - should still return true if key exists
	my $unfixed = Genesis::Secret->build('random', 'kit', 'other/path:key', size => 8, fixed => 0);
	ok($unfixed->has('fixed'), "has('fixed') returns true even when fixed => 0");
	is($unfixed->get('fixed'), 0, "get('fixed') returns 0 (falsy value)");

	# set() accessor
	$secret->set('custom_prop', 'custom_value');
	is($secret->get('custom_prop'), 'custom_value', "set() stores new value");
	ok($secret->has('custom_prop'), "has() returns true after set()");

	# set() to change existing definition value
	is($secret->get('size'), 16, "size is initially 16");
	$secret->set('size', 32);
	is($secret->get('size'), 32, "set() changes existing definition value");
};

subtest 'source tracking' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Test with kit source
	my $kit_secret = Genesis::Secret->build('random', 'kit', 'path:key',
		size => 8, _feature => 'some-feature'
	);
	is($kit_secret->source, 'kit', "source() returns 'kit' for kit secrets");
	ok($kit_secret->from_kit, "from_kit() returns true for kit secrets");
	ok(!$kit_secret->from_manifest, "from_manifest() returns false for kit secrets");
	is($kit_secret->feature, 'some-feature', "feature() returns the feature name");

	# Test with manifest source
	my $manifest_secret = Genesis::Secret->build('random', 'manifest', 'path:key',
		size => 8, _ch_name => 'my.var'
	);
	is($manifest_secret->source, 'manifest', "source() returns 'manifest' for manifest secrets");
	ok(!$manifest_secret->from_kit, "from_kit() returns false for manifest secrets");
	ok($manifest_secret->from_manifest, "from_manifest() returns true for manifest secrets");
	is($manifest_secret->var_name, 'my.var', "var_name() returns the variable name");
};

subtest 'all_paths() method' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	# Base case - single path
	my $simple = Genesis::Secret->build('random', 'kit', 'simple/path:key', size => 8);
	my @paths = $simple->all_paths;
	cmp_deeply(\@paths, ['simple/path:key'], "all_paths() returns single path for simple secret");

	# Random with format - should include format_path
	my $formatted = Genesis::Secret->build('random', 'kit', 'fmt/path:value',
		size => 8, format => 'base64'
	);
	@paths = $formatted->all_paths;
	cmp_deeply(\@paths, ['fmt/path:value', 'fmt/path:value-base64'],
		"all_paths() includes format_path for formatted random secret");
};

subtest 'loaded and reset state' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 8);
	is($secret->loaded, 0, "loaded() is 0 initially");

	# Simulate loading a value
	$secret->set_value('test_value', in_sync => 1, loaded => 1);
	is($secret->loaded, 1, "loaded() is 1 after set_value with loaded flag");
	is($secret->has_value, 1, "has_value() is 1 after set_value");

	# Reset
	$secret->reset;
	is($secret->loaded, 0, "loaded() is 0 after reset");
	ok(!$secret->has_value, "has_value() is false after reset");
};

subtest 'set_value and value accessors' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 8);

	# Set pending value
	$secret->set_value('pending_val');
	is($secret->{value}, 'pending_val', "set_value stores in {value}");
	is($secret->value, 'pending_val', "value() returns pending value");

	# Set value as in_sync (stored)
	$secret->set_value('stored_val', in_sync => 1);
	ok(!exists $secret->{value}, "in_sync moves value out of {value}");
	is($secret->{stored_value}, 'stored_val', "in_sync stores in {stored_value}");
	is($secret->value, 'stored_val', "value() returns stored value");

	# Pending value takes precedence
	$secret->set_value('new_pending');
	is($secret->value, 'new_pending', "pending value takes precedence over stored");
};

subtest 'update_value merges hashes' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 8);

	# Set initial hash value
	$secret->set_value({key1 => 'val1', key2 => 'val2'}, in_sync => 1);

	# Update with partial hash
	$secret->update_value({key2 => 'updated', key3 => 'new'});

	my $val = $secret->value;
	is(ref($val), 'HASH', "value is still a hash");
	is($val->{key1}, 'val1', "unchanged key preserved");
	is($val->{key2}, 'updated', "updated key has new value");
	is($val->{key3}, 'new', "new key added");
};

subtest 'promote_value_to_stored' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 8);
	$secret->set_value('pending');
	is($secret->{value}, 'pending', "value in pending state");
	is($secret->loaded, 0, "not loaded yet");

	$secret->promote_value_to_stored;
	ok(!exists $secret->{value}, "pending value cleared");
	is($secret->{stored_value}, 'pending', "value moved to stored");
	is($secret->loaded, 1, "marked as loaded");
};

subtest 'check_value for missing values' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 8);

	# No value set
	my ($status, $msg) = $secret->check_value;
	is($status, 'missing', "check_value returns 'missing' for empty secret");
};

subtest 'describe() method' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 16, fixed => 1);

	# Scalar context
	my $desc = $secret->describe;
	like($desc, qr/Random/i, "describe() includes label");
	like($desc, qr/16/, "describe() includes size");
	like($desc, qr/fixed/i, "describe() includes fixed flag");

	# List context
	my @parts = $secret->describe;
	is($parts[0], 'path:key', "describe() list: first element is path");
	like($parts[1], qr/Random/i, "describe() list: second element is label");
};

subtest 'reject() creates Invalid instance' => sub {
	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $rejected = Genesis::Secret->reject(
		'Test Subject',
		['Error 1', 'Error 2'],
		'test/path:key',
		{foo => 'bar'}
	);

	isa_ok($rejected, 'Genesis::Secret::Invalid', "reject() returns Invalid instance");
	is($rejected->valid, 0, "rejected secret is not valid");
	is($rejected->get('subject'), 'Test Subject', "subject is stored");
	cmp_deeply($rejected->get('errors'), ['Error 1', 'Error 2'], "errors are stored");
};

subtest 'validate_definition delegation' => sub {
	# When GENESIS_SKIP_SECRET_DEFINITION_VALIDATION is not set,
	# validate_definition should delegate to _validate_constructor_opts or use defaults

	# Test with valid Random definition
	my $secret = Genesis::Secret->build('random', 'kit', 'path:key', size => 32);
	isa_ok($secret, 'Genesis::Secret::Random', "valid definition creates correct class");
	is($secret->valid, 1, "valid definition produces valid secret");

	# Test with invalid Random definition (missing size)
	my $invalid = Genesis::Secret->build('random', 'kit', 'path:key');
	isa_ok($invalid, 'Genesis::Secret::Invalid', "invalid definition returns Invalid");
	is($invalid->valid, 0, "invalid definition produces invalid secret");
};

subtest 'cannot instantiate Genesis::Secret directly' => sub {
	# Attempting to call new() directly on Genesis::Secret should fail
	# This is enforced by a bug() call in new()
	# bug() calls die() when inside eval (checks $^S), so we can catch it

	local $ENV{GENESIS_SKIP_SECRET_DEFINITION_VALIDATION} = 1;

	my $error;
	eval {
		Genesis::Secret->new('some/path:key', size => 8);
	};
	$error = $@;

	ok($error, "Genesis::Secret->new() dies when called directly");
	like($error, qr/Cannot directly instantiate.*Genesis::Secret/i,
		"error message mentions cannot directly instantiate");
};

done_testing;
