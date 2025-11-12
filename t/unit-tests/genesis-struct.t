#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Differences;

use_ok 'Genesis';

# Test struct_set_value() - Set values in nested structures
subtest 'struct_set_value() - basic operations' => sub {
	my $struct;

	# Set simple value
	$struct = {};
	struct_set_value($struct, 'key', 'value');
	is $struct->{key}, 'value', 'set simple key';

	# Set nested value
	$struct = {};
	struct_set_value($struct, 'level1.level2', 'nested');
	is $struct->{level1}{level2}, 'nested', 'set nested key';

	# Set array element
	$struct = {arr => []};
	struct_set_value($struct, 'arr[0]', 'first');
	is $struct->{arr}[0], 'first', 'set array element';
};

subtest 'struct_set_value() - overwriting' => sub {
	my $struct;

	# Overwrite existing value
	$struct = {key => 'old'};
	struct_set_value($struct, 'key', 'new');
	is $struct->{key}, 'new', 'overwrite simple value';

	# Overwrite with different type
	$struct = {key => 'string'};
	struct_set_value($struct, 'key', {nested => 'hash'});
	is ref($struct->{key}), 'HASH', 'overwrite with hash';
	is $struct->{key}{nested}, 'hash', 'overwrite hash value correct';
};

# Test struct_lookup() - Retrieve values from nested structures
subtest 'struct_lookup() - basic retrieval' => sub {
	my $struct = {
		simple => 'value',
		nested => {
			deep => 'nested_value'
		},
		array => ['one', 'two', 'three']
	};

	# Simple lookup
	is struct_lookup($struct, 'simple'), 'value', 'lookup simple key';

	# Nested lookup
	is struct_lookup($struct, 'nested.deep'), 'nested_value', 'lookup nested key';

	# Array lookup
	is struct_lookup($struct, 'array[0]'), 'one', 'lookup array element';
	is struct_lookup($struct, 'array[2]'), 'three', 'lookup array element by index';
};

subtest 'struct_lookup() - missing keys' => sub {
	my $struct = {key => 'value'};

	# Missing key returns undef
	is struct_lookup($struct, 'missing'), undef, 'missing key returns undef';

	# Deep missing key returns undef
	is struct_lookup($struct, 'missing.deep'), undef, 'deep missing key returns undef';

	# Missing array index returns undef
	$struct->{arr} = ['one'];
	is struct_lookup($struct, 'arr[10]'), undef, 'missing array index returns undef';
};

# Test flatten() - Convert nested structure to flat dotted keys
subtest 'flatten() - basic flattening' => sub {
	my $nested = {
		simple => 'value',
		nested => {
			key => 'nested_value'
		}
	};

	my $flat = flatten($nested);
	is $flat->{'simple'}, 'value', 'simple key preserved';
	is $flat->{'nested.key'}, 'nested_value', 'nested key flattened';
};

subtest 'flatten() - arrays' => sub {
	my $nested = {
		array => ['one', 'two', 'three']
	};

	my $flat = flatten($nested);
	is $flat->{'array[0]'}, 'one', 'array element 0 flattened';
	is $flat->{'array[1]'}, 'two', 'array element 1 flattened';
	is $flat->{'array[2]'}, 'three', 'array element 2 flattened';
};

subtest 'flatten() - complex structures' => sub {
	my $nested = {
		top => {
			middle => {
				bottom => 'deep_value'
			}
		},
		list => [
			{name => 'first'},
			{name => 'second'}
		]
	};

	my $flat = flatten($nested);
	is $flat->{'top.middle.bottom'}, 'deep_value', 'deep nesting flattened';
	is $flat->{'list[0].name'}, 'first', 'array of hashes flattened';
	is $flat->{'list[1].name'}, 'second', 'array of hashes flattened';
};

subtest 'flatten() - empty hashes and arrays' => sub {
	my $nested = {
		empty_hash => {},
		empty_array => [],
		nested_empty => {
			inner => {}
		},
		mixed => {
			value => 'test',
			empty => {}
		},
		some_items => [
			{odd => [1, 3]},
			{even => [2, 4]},
			{both => []},
			{}
		]
	};

	my $flat = flatten($nested);
	ok exists($flat->{empty_hash}), 'empty hash key exists in flattened structure';
	is ref($flat->{empty_hash}), 'HASH', 'empty hash value is HASH ref';
	is scalar(keys %{$flat->{empty_hash}}), 0, 'empty hash has 0 keys';
	ok exists($flat->{empty_array}), 'empty array key exists in flattened structure';
	is ref($flat->{empty_array}), 'ARRAY', 'empty array value is ARRAY ref';
	is scalar(@{$flat->{empty_array}}), 0, 'empty array has 0 elements';
	ok exists($flat->{'nested_empty.inner'}), 'nested empty hash key exists';
	is ref($flat->{'nested_empty.inner'}), 'HASH', 'nested empty hash value is HASH ref';
	is scalar(keys %{$flat->{'nested_empty.inner'}}), 0, 'nested empty hash has 0 keys';
	is $flat->{'mixed.value'}, 'test', 'value preserved alongside empty hash';
	ok exists($flat->{'mixed.empty'}), 'empty hash exists alongside value';
	is ref($flat->{'mixed.empty'}), 'HASH', 'empty hash value is HASH ref in mixed structure';
	is scalar(keys %{$flat->{'mixed.empty'}}), 0, 'empty hash in mixed structure has 0 keys';
	is $flat->{'some_items[0].odd[0]'}, 1, 'array element with values (first)';
	is $flat->{'some_items[0].odd[1]'}, 3, 'array element with values (second)';
	is $flat->{'some_items[1].even[0]'}, 2, 'array element with values (first)';
	is $flat->{'some_items[1].even[1]'}, 4, 'array element with values (second)';
	ok exists($flat->{'some_items[2].both'}), 'empty array in hash element preserved';
	is ref($flat->{'some_items[2].both'}), 'ARRAY', 'empty array in hash element is ARRAY ref';
	is scalar(@{$flat->{'some_items[2].both'}}), 0, 'empty array in hash element has 0 elements';
	ok exists($flat->{'some_items[3]'}), 'empty hash element in array preserved';
	is ref($flat->{'some_items[3]'}), 'HASH', 'empty hash element in array is HASH ref';
	is scalar(keys %{$flat->{'some_items[3]'}}), 0, 'empty hash element in array has 0 keys';
};

# Test unflatten() - Convert flat dotted keys back to nested structure
subtest 'unflatten() - basic unflattening' => sub {
	my $flat = {
		'simple' => 'value',
		'nested.key' => 'nested_value'
	};

	my $nested = unflatten($flat);
	is $nested->{simple}, 'value', 'simple key preserved';
	is $nested->{nested}{key}, 'nested_value', 'dotted key unflattened';
};

subtest 'unflatten() - arrays' => sub {
	my $flat = {
		'array[0]' => 'one',
		'array[1]' => 'two',
		'array[2]' => 'three'
	};

	my $nested = unflatten($flat);
	is ref($nested->{array}), 'ARRAY', 'array created';
	is $nested->{array}[0], 'one', 'array element 0 correct';
	is $nested->{array}[1], 'two', 'array element 1 correct';
	is $nested->{array}[2], 'three', 'array element 2 correct';
};

subtest 'flatten/unflatten roundtrip - empty hashes and arrays' => sub {
	my $original = {
		empty_hash => {},
		empty_array => [],
		nested_empty => {
			inner => {}
		},
		mixed => {
			value => 'test',
			empty => {}
		},
		some_items => [
			{odd => [1, 3]},
			{even => [2, 4]},
			{both => []},
			{}
		]
	};

	# Test flatten preserves empty structures
	my $flat = flatten($original);
	ok exists($flat->{empty_hash}), 'empty hash key exists in flattened structure';
	is ref($flat->{empty_hash}), 'HASH', 'empty hash value is HASH ref';
	is scalar(keys %{$flat->{empty_hash}}), 0, 'empty hash has 0 keys';
	ok exists($flat->{empty_array}), 'empty array key exists in flattened structure';
	is ref($flat->{empty_array}), 'ARRAY', 'empty array value is ARRAY ref';
	is scalar(@{$flat->{empty_array}}), 0, 'empty array has 0 elements';

	# Test unflatten preserves empty structures and roundtrip matches original
	my $roundtrip = unflatten($flat);
	is_deeply $roundtrip, $original, 'roundtrip matches original structure';
};

# Test deep_merge() - Recursive hash merging
subtest 'deep_merge() - simple merging' => sub {
	my $base = {
		a => 1,
		b => 2
	};
	my $override = {
		b => 3,
		c => 4
	};

	my $merged = deep_merge($base, $override);
	is $merged->{a}, 1, 'base key preserved';
	is $merged->{b}, 3, 'override key wins';
	is $merged->{c}, 4, 'new key added';
};

subtest 'priority_merge() - priority-aware merging with conflict detection' => sub {
	# Test 1: Basic priority - first structure wins
	my $high_priority = {
		foo => 'high',
		bar => 1
	};
	my $low_priority = {
		foo => 'low',
		baz => 2
	};

	my $result = priority_merge($high_priority, $low_priority);
	is $result->{foo}, 'high', 'high priority value preserved';
	is $result->{bar}, 1, 'high priority key preserved';
	is $result->{baz}, 2, 'non-conflicting low priority key added';

	# Test 2: Ancestor blocks descendants - deployment_roots => [] blocks deployment_roots[0].default
	$high_priority = {
		deployment_roots => []
	};
	$low_priority = {
		'deployment_roots' => [
			{ default => 'some/path' }
		]
	};

	$result = priority_merge($high_priority, $low_priority);
	is_deeply $result->{deployment_roots}, [], 'empty array from high priority preserved';

	# Test 3: Descendants block ancestors - deployment_roots[0].my_lab blocks deployment_roots => []
	$high_priority = {
		deployment_roots => [
			{ my_lab => 'some/path' }
		]
	};
	$low_priority = {
		deployment_roots => []
	};

	$result = priority_merge($high_priority, $low_priority);
	is_deeply $result->{deployment_roots}, [{ my_lab => 'some/path' }],
		'array with value from high priority preserved, ancestor blocked';

	# Test 4: Complex nested case with multiple conflicts
	$high_priority = {
		ui => {
			colors => {
				code => 'Yb'
			}
		}
	};
	$low_priority = {
		ui => {
			colors => {
				code => 'default',
				warning_alert => 'kYi'
			},
			theme => 'dark'
		}
	};

	$result = priority_merge($high_priority, $low_priority);
	is $result->{ui}{colors}{code}, 'Yb', 'high priority nested value preserved';
	is $result->{ui}{colors}{warning_alert}, 'kYi', 'non-conflicting nested value added';
	is $result->{ui}{theme}, 'dark', 'non-conflicting sibling key added';

	# Test 5: Empty hash/array preservation with priority
	$high_priority = {
		empty_config => {}
	};
	$low_priority = {
		empty_config => {
			default => 'value'
		}
	};

	$result = priority_merge($high_priority, $low_priority);
	is_deeply $result->{empty_config}, {}, 'empty hash from high priority preserved';
};

subtest 'deep_merge() - nested merging' => sub {
	my $base = {
		top => {
			a => 1,
			b => 2
		}
	};
	my $override = {
		top => {
			b => 3,
			c => 4
		}
	};

	my $merged = deep_merge($base, $override);
	is $merged->{top}{a}, 1, 'nested base key preserved';
	is $merged->{top}{b}, 3, 'nested override key wins';
	is $merged->{top}{c}, 4, 'nested new key added';
};

subtest 'deep_merge() - array handling' => sub {
	my $base = {
		list => ['one', 'two']
	};
	my $override = {
		list => ['three', 'four']
	};

	my $merged = deep_merge($base, $override);
	is ref($merged->{list}), 'ARRAY', 'array preserved';
	# Arrays are typically replaced, not merged
	is scalar(@{$merged->{list}}), 2, 'override array replaces base';
};

subtest 'deep_merge() - multiple sources' => sub {
	my $a = {key => 'a', a_only => 1};
	my $b = {key => 'b', b_only => 2};
	my $c = {key => 'c', c_only => 3};

	my $merged = deep_merge($a, $b, $c);
	is $merged->{key}, 'c', 'last source wins';
	is $merged->{a_only}, 1, 'first source keys preserved';
	is $merged->{b_only}, 2, 'middle source keys preserved';
	is $merged->{c_only}, 3, 'last source keys preserved';
};

# Test in_array() - Check if value exists in array
subtest 'in_array() - value checking' => sub {
	my @arr = ('one', 'two', 'three');

	ok in_array('two', @arr), 'value exists in array';
	ok !in_array('four', @arr), 'value not in array';
	ok in_array('one', @arr), 'first element found';
	ok in_array('three', @arr), 'last element found';
};

# Test index_of() - Find index of value in array
subtest 'index_of() - index finding' => sub {
	my @arr = ('one', 'two', 'three');

	is index_of('one', @arr), 0, 'first element index';
	is index_of('two', @arr), 1, 'middle element index';
	is index_of('three', @arr), 2, 'last element index';
	is index_of('missing', @arr), undef, 'missing element returns undef';
};

# Test compare_arrays() - Array difference analysis
# Returns: ([only in arr1], [in both], [only in arr2])
subtest 'compare_arrays() - identical arrays' => sub {
	my @a = (1, 2, 3);
	my @b = (1, 2, 3);
	my ($only_a, $both, $only_b) = compare_arrays(\@a, \@b);

	is scalar(@$only_a), 0, 'no items only in first array';
	is scalar(@$both), 3, 'all items in both arrays';
	is scalar(@$only_b), 0, 'no items only in second array';
	cmp_deeply $both, [1, 2, 3], 'common items correct';
};

subtest 'compare_arrays() - different arrays' => sub {
	my @a = (1, 2, 3);
	my @c = (1, 2, 4);
	my ($only_a, $both, $only_c) = compare_arrays(\@a, \@c);

	cmp_deeply $only_a, [3], 'items only in first array';
	cmp_deeply $both, [1, 2], 'items in both arrays';
	cmp_deeply $only_c, [4], 'items only in second array';
};

subtest 'compare_arrays() - length differences' => sub {
	my @a = (1, 2, 3);
	my @b = (1, 2);
	my ($only_a, $both, $only_b) = compare_arrays(\@a, \@b);

	cmp_deeply $only_a, [3], 'extra item in first array';
	cmp_deeply $both, [1, 2], 'common items';
	is scalar(@$only_b), 0, 'no extra items in second array';
};

# Test uniq() - Remove duplicate values
subtest 'uniq() - deduplication' => sub {
	my @arr = (1, 2, 2, 3, 3, 3, 4);
	my @unique = uniq(@arr);

	is scalar(@unique), 4, 'duplicates removed';
	cmp_deeply \@unique, [1, 2, 3, 4], 'unique values preserved';
};

subtest 'uniq() - order preservation' => sub {
	my @arr = (3, 1, 2, 1, 3, 2);
	my @unique = uniq(@arr);

	is scalar(@unique), 3, 'duplicates removed';
	is $unique[0], 3, 'first occurrence order preserved';
	is $unique[1], 1, 'second occurrence order preserved';
	is $unique[2], 2, 'third occurrence order preserved';
};

# Test get_opts() - Hash slicing with underscore-to-dash conversion
subtest 'get_opts() - hash slicing' => sub {
	my %config = (
		name => 'test-env',
		region => 'us-west-2',
		'instance-type' => 't2.micro',
		count => 5
	);

	# Simple key extraction
	my %result = get_opts(\%config, 'name', 'region');
	is $result{name}, 'test-env', 'extracted name key';
	is $result{region}, 'us-west-2', 'extracted region key';
	ok !exists($result{count}), 'did not extract unspecified key';

	# Underscore to dash conversion
	%result = get_opts(\%config, 'instance_type');
	is $result{instance_type}, 't2.micro', 'underscore key maps to dash key';

	# Mixed keys
	%result = get_opts(\%config, 'name', 'instance_type', 'count');
	is $result{name}, 'test-env', 'mixed: extracted name';
	is $result{instance_type}, 't2.micro', 'mixed: underscore to dash conversion';
	is $result{count}, 5, 'mixed: extracted count';

	# Non-existent keys
	%result = get_opts(\%config, 'missing', 'also_missing');
	ok !exists($result{missing}), 'non-existent key not in result';
	ok !exists($result{also_missing}), 'non-existent underscore key not in result';

	# Empty extraction
	%result = get_opts(\%config);
	is scalar(keys %result), 0, 'empty key list returns empty hash';
};

# Test delete_from_array() - Remove matching elements from array
subtest 'delete_from_array() - basic removal' => sub {
	my @arr = ('one', 'two', 'three', 'four');
	my @removed = delete_from_array(\@arr, qr/^two$/);

	is scalar(@arr), 3, 'array has 3 elements after removal';
	is scalar(@removed), 1, 'one element was removed';
	is $removed[0], 'two', 'correct element removed';
	cmp_deeply \@arr, ['one', 'three', 'four'], 'remaining elements correct';
};

subtest 'delete_from_array() - multiple matches' => sub {
	my @arr = ('apple', 'banana', 'apricot', 'cherry', 'avocado');
	my @removed = delete_from_array(\@arr, qr/^a/);

	is scalar(@removed), 3, 'three elements removed';
	cmp_deeply \@removed, ['apple', 'apricot', 'avocado'], 'all a-prefixed items removed';
	cmp_deeply \@arr, ['banana', 'cherry'], 'remaining elements correct';
};

subtest 'delete_from_array() - multiple patterns' => sub {
	my @arr = ('one', 'two', 'three', 'four', 'five');
	my @removed = delete_from_array(\@arr, qr/^t/, qr/our$/);

	is scalar(@removed), 3, 'three elements removed';
	cmp_deeply \@removed, ['two', 'three', 'four'], 'items matching either pattern removed';
	cmp_deeply \@arr, ['one', 'five'], 'remaining elements correct';
};

subtest 'delete_from_array() - no matches' => sub {
	my @arr = ('one', 'two', 'three');
	my @removed = delete_from_array(\@arr, qr/^missing$/);

	is scalar(@removed), 0, 'no elements removed';
	cmp_deeply \@arr, ['one', 'two', 'three'], 'array unchanged';
};

subtest 'delete_from_array() - empty array' => sub {
	my @arr = ();
	my @removed = delete_from_array(\@arr, qr/anything/);

	is scalar(@removed), 0, 'no elements removed from empty array';
	is scalar(@arr), 0, 'array still empty';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
