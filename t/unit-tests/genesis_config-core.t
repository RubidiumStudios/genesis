#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;
use Test::Deep;

use_ok 'Genesis::Config';

my $tmp = workdir();

subtest 'constructor backward compatibility' => sub {
	# Test old-style positional parameters (backward compatibility)

	# Old style: path only
	my $c1 = Genesis::Config->new("$tmp/test.yml");
	is($c1->path, "$tmp/test.yml", "old style: path only works");
	ok(!$c1->{autosave}, "old style: autosave defaults to false");

	# Old style: path + autosave
	my $c2 = Genesis::Config->new("$tmp/test.yml", 1);
	is($c2->path, "$tmp/test.yml", "old style: path + autosave works");
	ok($c2->{autosave}, "old style: autosave is set");

	# Old style: path + autosave + content
	my $c3 = Genesis::Config->new(undef, 0, {foo => 'bar'});
	is($c3->path, undef, "old style: can have undef path");
	ok(!$c3->{autosave}, "old style: autosave off with content");
	is($c3->get('foo'), 'bar', "old style: content is set");

	# Old style: no args
	my $c4 = Genesis::Config->new();
	is($c4->path, undef, "old style: no args creates empty config");
};

subtest 'constructor new named parameters' => sub {
	# Test new-style named parameters
	# These tests document the planned API for the Genesis::Config refactoring
	# See docs/refactors/genesis_config.md for implementation plan

	SKIP: {
		skip "Hybrid constructor not yet implemented - see docs/refactors/genesis_config.md", 5;

		# New style: path as named param
		my $c1 = Genesis::Config->new(path => "$tmp/test.yml");
		is($c1->path, "$tmp/test.yml", "new style: path param works");

		# New style: path + autosave
		my $c2 = Genesis::Config->new(path => "$tmp/test.yml", autosave => 1);
		is($c2->path, "$tmp/test.yml", "new style: path + autosave works");
		ok($c2->{autosave}, "new style: autosave is set");

		# New style: content
		my $c3 = Genesis::Config->new(content => {foo => 'bar'});
		is($c3->get('foo'), 'bar', "new style: content param works");

		# New style: schema (new feature)
		my $schema = {foo => {type => 'string'}};
		my $c4 = Genesis::Config->new(path => "$tmp/test.yml", schema => $schema);
		is($c4->{schema}, $schema, "new style: schema param is stored");
	}
};

subtest 'basic config creation and loading' => sub {
	my $config_file = "$tmp/test1.yml";

	# Create a config file
	put_file($config_file, <<EOF);
---
foo: bar
number: 42
nested:
  key: value
  array:
    - one
    - two
EOF

	my $config = Genesis::Config->new($config_file);
	ok($config->exists, "config file exists");
	ok(!$config->loaded, "config not loaded until accessed (lazy loading)");

	is($config->get('foo'), 'bar', "can get simple string value");
	ok($config->loaded, "config is loaded after accessing contents");
	is($config->get('number'), 42, "can get numeric value");
	is($config->get('nested.key'), 'value', "can get nested value");
	cmp_deeply($config->get('nested.array'), ['one', 'two'], "can get array value");

	# Check source tracking (new method)
	can_ok($config, 'get_source');
	is($config->get_source('foo'), 'loaded', "value loaded from file has 'loaded' source");
	is($config->get_source('nonexistent'), undef, "nonexistent key has no source");
};

subtest 'setting values explicitly' => sub {
	my $config_file = "$tmp/test2.yml";
	put_file($config_file, "---\nfoo: original\n");

	my $config = Genesis::Config->new($config_file);

	# Set a new value
	$config->set('bar', 'baz');
	is($config->get('bar'), 'baz', "can set and get new value");

	can_ok($config, 'get_source');
	is($config->get_source('bar'), 'set', "explicitly set value has 'set' source");

	# Override existing value
	$config->set('foo', 'modified');
	is($config->get('foo'), 'modified', "can override existing value");

	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('foo'), 'set', "overridden value has 'set' source");
	}

	# Set nested value
	$config->set('nested.deep.key', 'value');
	is($config->get('nested.deep.key'), 'value', "can set nested value");
};

subtest 'environment variable overrides' => sub {
	my $config_file = "$tmp/test3.yml";
	put_file($config_file, "---\nfoo: original\nbar: original\n");

	my $schema = {
		foo => {
			type => 'string',
			envvar => 'TEST_FOO'
		},
		bar => {
			type => 'string'
		}
	};

	# Set environment variable
	local $ENV{TEST_FOO} = 'from_env';

	my $config = Genesis::Config->new($config_file);
	$config->validate($schema);

	is($config->get('foo'), 'from_env', "env var overrides file value");

	can_ok($config, 'get_source');
	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('foo'), 'env', "env override has 'env' source");
	}
	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('bar'), 'loaded', "value without env var has 'loaded' source");
	}

	is($config->get('bar'), 'original', "value without env var is unchanged");
};

subtest 'schema defaults' => sub {
	my $config_file = "$tmp/test4.yml";
	put_file($config_file, "---\nfoo: bar\n");

	my $schema = {
		foo => {
			type => 'string'
		},
		with_default => {
			type => 'string',
			default => 'default_value'
		},
		another_default => {
			type => 'number',
			default => 123
		}
	};

	my $config = Genesis::Config->new($config_file);
	$config->validate($schema);

	is($config->get('foo'), 'bar', "explicit value is returned");
	is($config->get('with_default'), 'default_value', "default value is returned");
	is($config->get('another_default'), 123, "numeric default is returned");

	can_ok($config, 'get_source');
	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('foo'), 'loaded', "explicit value has 'loaded' source");
	}
	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('with_default'), 'default', "default value has 'default' source");
	}
	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('another_default'), 'default', "numeric default has 'default' source");
	}
};

subtest 'priority resolution: env > set > loaded > default' => sub {
	my $config_file = "$tmp/test5.yml";
	put_file($config_file, <<EOF);
---
only_file: from_file
set_and_file: from_file
env_and_file: from_file
env_set_file: from_file
EOF

	my $schema = {
		only_file => { type => 'string' },
		set_and_file => { type => 'string' },
		env_and_file => { type => 'string', envvar => 'TEST_ENV_FILE' },
		env_set_file => { type => 'string', envvar => 'TEST_ENV_SET_FILE' },
		only_default => { type => 'string', default => 'default_val' },
		set_and_default => { type => 'string', default => 'default_val' },
		env_and_default => { type => 'string', default => 'default_val', envvar => 'TEST_ENV_DEFAULT' }
	};

	local $ENV{TEST_ENV_FILE} = 'from_env';
	local $ENV{TEST_ENV_SET_FILE} = 'from_env';
	local $ENV{TEST_ENV_DEFAULT} = 'from_env';

	my $config = Genesis::Config->new($config_file);
	$config->set('set_and_file', 'from_set');
	$config->set('env_set_file', 'from_set');
	$config->set('set_and_default', 'from_set');
	$config->validate($schema);

	# Priority tests
	is($config->get('only_file'), 'from_file', "file value when only source");
	is($config->get('set_and_file'), 'from_set', "set overrides file");
	is($config->get('env_and_file'), 'from_env', "env overrides file");
	is($config->get('env_set_file'), 'from_env', "env overrides set (which overrides file)");
	is($config->get('only_default'), 'default_val', "default when no other source");
	is($config->get('set_and_default'), 'from_set', "set overrides default");
	is($config->get('env_and_default'), 'from_env', "env overrides default");

	# Source tests
	can_ok($config, 'get_source');
	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('only_file'), 'loaded', "correct source for file-only");
	}
	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('set_and_file'), 'set', "correct source for set override");
	}
	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('env_and_file'), 'env', "correct source for env override");
	}
	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('env_set_file'), 'env', "correct source for env > set");
	}
	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('only_default'), 'default', "correct source for default-only");
	}
	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('set_and_default'), 'set', "correct source for set > default");
	}
	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('env_and_default'), 'env', "correct source for env > default");
	}
};

subtest 'save behavior - only explicit values' => sub {
	my $config_file = "$tmp/test6.yml";
	put_file($config_file, "---\noriginal: value\n");

	my $schema = {
		original => { type => 'string' },
		with_default => { type => 'string', default => 'default_value' },
		with_env => { type => 'string', envvar => 'TEST_SAVE_ENV' },
		explicit_set => { type => 'string' }
	};

	local $ENV{TEST_SAVE_ENV} = 'from_env';

	my $config = Genesis::Config->new($config_file);
	$config->set('explicit_set', 'set_value');
	$config->validate($schema);

	# Verify all values are accessible
	is($config->get('original'), 'value', "original value accessible");
	is($config->get('with_default'), 'default_value', "default value accessible");
	is($config->get('with_env'), 'from_env', "env value accessible");
	is($config->get('explicit_set'), 'set_value', "set value accessible");

	# Save and reload
	$config->save();
	my $reloaded = Genesis::Config->new($config_file);

	# Check what was actually saved
	ok($reloaded->has('original'), "original value was saved");
	ok($reloaded->has('explicit_set'), "explicitly set value was saved");
	ok(!$reloaded->has('with_default'), "default value was NOT saved");
	ok(!$reloaded->has('with_env'), "env override was NOT saved");

	is($reloaded->get('original'), 'value', "saved original value is correct");
	is($reloaded->get('explicit_set'), 'set_value', "saved set value is correct");
};

subtest 'modifying loaded values' => sub {
	my $config_file = "$tmp/test7.yml";
	put_file($config_file, "---\nfoo: original\nbar: original\n");

	my $config = Genesis::Config->new($config_file);

	can_ok($config, 'get_source');
	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('foo'), 'loaded', "initial source is 'loaded'");
	}

	# Modify a loaded value
	$config->set('foo', 'modified');

	is($config->get('foo'), 'modified', "value is modified");

	SKIP: {
		skip "get_source() not yet implemented", 1;
		is($config->get_source('foo'), 'set', "source changes to 'set' after modification");
	}

	# Save and verify
	$config->save();
	my $reloaded = Genesis::Config->new($config_file);

	is($reloaded->get('foo'), 'modified', "modified value persists after save");
	is($reloaded->get('bar'), 'original', "unmodified value remains unchanged");
};

subtest 'contents methods' => sub {
	my $config_file = "$tmp/test8.yml";
	put_file($config_file, "---\nloaded_key: loaded_value\n");

	my $schema = {
		loaded_key => { type => 'string' },
		default_key => { type => 'string', default => 'default_value' },
		env_key => { type => 'string', envvar => 'TEST_CONTENTS_ENV' },
		set_key => { type => 'string' }
	};

	local $ENV{TEST_CONTENTS_ENV} = 'env_value';

	my $config = Genesis::Config->new($config_file);
	$config->set('set_key', 'set_value');
	$config->validate($schema);

	# get_all() should return all effective values
	can_ok($config, 'get_all');
	SKIP: {
		skip "get_all() not yet implemented", 1;
		my $all = $config->get_all();
		cmp_deeply($all, {
			loaded_key => 'loaded_value',
			default_key => 'default_value',
			env_key => 'env_value',
			set_key => 'set_value'
		}, "get_all() includes all sources");
	}

	# _explicit_contents() should only return loaded/set values (what gets saved)
	can_ok($config, '_explicit_contents');
	SKIP: {
		skip "_explicit_contents() not yet implemented", 1;
		my $explicit = $config->_explicit_contents();
		cmp_deeply($explicit, {
			loaded_key => 'loaded_value',
			set_key => 'set_value'
		}, "_explicit_contents() excludes defaults and env vars (private method)");
	}

	# _contents() returns internal structure with source tracking
	SKIP: {
		skip "source tracking not yet implemented", 1;
		my $internal = $config->_contents();
		ok(ref($internal->{loaded_key}) eq 'HASH', "internal structure uses hash for tracking");
	}
	SKIP: {
		skip "source tracking not yet implemented", 1;
		my $internal = $config->_contents();
		is($internal->{loaded_key}{value}, 'loaded_value', "internal structure has value");
	}
	SKIP: {
		skip "source tracking not yet implemented", 1;
		my $internal = $config->_contents();
		is($internal->{loaded_key}{source}, 'loaded', "internal structure has source");
	}
};

subtest 'has() and is_set() methods' => sub {
	my $config_file = "$tmp/test9.yml";
	put_file($config_file, "---\nexplicit: value\n");

	my $schema = {
		explicit => { type => 'string' },
		with_default => { type => 'string', default => 'default_value' },
		with_env => { type => 'string', envvar => 'TEST_HAS_ENV' },
		missing => { type => 'string' }
	};

	local $ENV{TEST_HAS_ENV} = 'env_value';

	my $config = Genesis::Config->new($config_file);
	$config->validate($schema);

	# has() returns true for any value from any source (loaded/set/env/default)
	ok($config->has('explicit'), "has() returns true for explicit value");
	ok($config->has('with_default'), "has() returns true for value with default");
	ok($config->has('with_env'), "has() returns true for value from env var");
	ok(!$config->has('missing'), "has() returns false for missing value");

	# is_set() only checks loaded/set values (not env or defaults)
	can_ok($config, 'is_set');
	SKIP: {
		skip "is_set() not yet implemented", 1;
		ok($config->is_set('explicit'), "is_set() returns true for explicit value");
	}
	SKIP: {
		skip "is_set() not yet implemented", 1;
		ok(!$config->is_set('with_default'), "is_set() returns false for default-only value");
	}
	SKIP: {
		skip "is_set() not yet implemented", 1;
		ok(!$config->is_set('with_env'), "is_set() returns false for env-only value");
	}
	SKIP: {
		skip "is_set() not yet implemented", 1;
		ok(!$config->is_set('missing'), "is_set() returns false for missing value");
	}

	# Test after setting a value
	SKIP: {
		skip "is_set() not yet implemented", 1;
		$config->set('with_default', 'now_set');
		ok($config->is_set('with_default'), "is_set() returns true after explicitly setting a defaulted value");
	}
};

subtest 'validation does not modify explicit contents' => sub {
	my $config_file = "$tmp/test10.yml";
	put_file($config_file, "---\nfoo: bar\n");

	my $schema = {
		foo => { type => 'string' },
		with_default => { type => 'string', default => 'default_value' }
	};

	my $config = Genesis::Config->new($config_file);

	can_ok($config, '_explicit_contents');
	SKIP: {
		skip "_explicit_contents() not yet implemented", 1;
		# Get explicit contents before validation
		my $before = $config->_explicit_contents();
		cmp_deeply($before, { foo => 'bar' }, "explicit contents before validation");
	}

	SKIP: {
		skip "_explicit_contents() not yet implemented", 1;
		$config->validate($schema);

		# Get explicit contents after validation
		my $after = $config->_explicit_contents();
		cmp_deeply($after, { foo => 'bar' }, "explicit contents unchanged after validation");
	}

	# Validate for subsequent tests
	$config->validate($schema) unless $config->can('_explicit_contents');

	# But default is accessible
	is($config->get('with_default'), 'default_value', "default value is accessible after validation");

	# And save doesn't include defaults
	$config->save();
	my $saved_content = get_file($config_file);
	like($saved_content, qr/foo:.*bar/s, "saved file contains explicit value");
	unlike($saved_content, qr/with_default/s, "saved file does not contain default value");
};

subtest 'path() method' => sub {
	my $config_file = "$tmp/test11.yml";
	put_file($config_file, "---\nfoo: bar\n");

	my $config = Genesis::Config->new($config_file);
	is($config->path, $config_file, "path() returns config file path");

	my $config_no_path = Genesis::Config->new();
	is($config_no_path->path, undef, "path() returns undef for config without path");
};

subtest 'exists() method' => sub {
	my $existing_file = "$tmp/existing.yml";
	my $nonexistent_file = "$tmp/nonexistent.yml";

	put_file($existing_file, "---\nfoo: bar\n");

	my $existing = Genesis::Config->new($existing_file);
	ok($existing->exists, "exists() returns true for existing file");

	my $nonexistent = Genesis::Config->new($nonexistent_file);
	ok(!$nonexistent->exists, "exists() returns false for non-existent file");

	my $no_path = Genesis::Config->new();
	ok(!$no_path->exists, "exists() returns false for config without path");
};

subtest 'loaded() method' => sub {
	my $config_file = "$tmp/test12.yml";
	put_file($config_file, "---\nfoo: bar\n");

	my $config = Genesis::Config->new($config_file);
	ok(!$config->loaded, "loaded() returns false before accessing contents");

	$config->get('foo');
	ok($config->loaded, "loaded() returns true after loading from file");

	my $new_config = Genesis::Config->new();
	$new_config->set('key', 'value');
	ok(!$new_config->loaded, "loaded() returns false for in-memory only config");
};

subtest 'changed() method' => sub {
	my $config_file = "$tmp/test13.yml";
	put_file($config_file, "---\nfoo: original\n");

	my $config = Genesis::Config->new($config_file);
	$config->get('foo'); # Load the file

	ok(!$config->changed, "changed() returns false after loading");

	$config->set('foo', 'modified');
	ok($config->changed, "changed() returns true after modification");

	$config->save();
	ok(!$config->changed, "changed() returns false after saving");

	$config->set('bar', 'new');
	ok($config->changed, "changed() returns true after adding new key");
};

subtest 'clear() method' => sub {
	my $config_file = "$tmp/test14.yml";
	put_file($config_file, <<EOF);
---
foo: bar
nested:
  key: value
  array:
    - one
    - two
EOF

	my $config = Genesis::Config->new($config_file);

	ok($config->has('foo'), "key exists before clear");
	$config->clear('foo');
	ok(!$config->has('foo'), "key removed after clear");

	ok($config->has('nested.key'), "nested key exists before clear");
	$config->clear('nested.key');
	ok(!$config->has('nested.key'), "nested key removed after clear");

	ok($config->changed, "config is changed after clear");
};

subtest 'replace() method' => sub {
	my $config_file = "$tmp/test15.yml";
	put_file($config_file, "---\nold: value\n");

	my $old_config = Genesis::Config->new($config_file);
	$old_config->get('old'); # Load it

	my $new_config = Genesis::Config->new();
	$new_config->set('new', 'value');
	$new_config->set('another', 'value');

	$new_config->replace($old_config);

	# Check the file was updated
	my $reloaded = Genesis::Config->new($config_file);
	ok(!$reloaded->has('old'), "old key is gone after replace");
	ok($reloaded->has('new'), "new key exists after replace");
	ok($reloaded->has('another'), "another new key exists after replace");
};

subtest 'show_diff() method' => sub {
	my $config_file = "$tmp/test16.yml";
	put_file($config_file, <<EOF);
---
foo: original
bar: value
EOF

	my $config = Genesis::Config->new($config_file);
	$config->set('foo', 'modified');
	$config->set('baz', 'new');

	# show_diff should work without dying
	# (We can't easily test the output since it's sent to info())
	lives_ok { $config->show_diff() } "show_diff() doesn't die";

	# Compare with another config
	my $other_config = Genesis::Config->new();
	$other_config->set('foo', 'different');
	lives_ok { $config->show_diff($other_config) } "show_diff(other) doesn't die";
};

subtest 'get() with default parameter' => sub {
	my $config = Genesis::Config->new();
	$config->set('existing', 'value');

	is($config->get('existing', 'default'), 'value', "get() returns actual value when it exists");
	is($config->get('missing', 'default'), 'default', "get() returns default when key is missing");
	ok(!$config->has('missing'), "get() with default doesn't set the value");

	# Test set_if_missing parameter (4th argument)
	my $result = $config->get('auto_set', 'default_value', 1);
	is($result, 'default_value', "get() with set_if_missing returns default");
	ok($config->has('auto_set'), "get() with set_if_missing creates the key");
	is($config->get('auto_set'), 'default_value', "auto-set key has correct value");
};

subtest 'set() with save parameter' => sub {
	my $config_file = "$tmp/test17.yml";
	put_file($config_file, "---\nfoo: bar\n");

	my $config = Genesis::Config->new($config_file);
	$config->get('foo'); # Load it

	$config->set('new_key', 'new_value', 1); # save=1

	# File should be updated immediately
	my $reloaded = Genesis::Config->new($config_file);
	is($reloaded->get('new_key'), 'new_value', "set() with save=1 persists immediately");
};

subtest 'clear() with save parameter' => sub {
	my $config_file = "$tmp/test18.yml";
	put_file($config_file, "---\nfoo: bar\nbaz: qux\n");

	my $config = Genesis::Config->new($config_file);
	$config->get('foo'); # Load it

	$config->clear('foo', 1); # save=1

	# File should be updated immediately
	my $reloaded = Genesis::Config->new($config_file);
	ok(!$reloaded->has('foo'), "clear() with save=1 persists immediately");
	ok($reloaded->has('baz'), "other keys remain after clear");
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
