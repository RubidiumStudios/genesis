#!perl
# The compiler base writes YAML by hand rather than taking a serializer
# dependency, so every rule that serializer keeps is asserted here by
# reading the emitted document back through a real YAML reader.  A value
# reaches the document in one of three positions, which are a hash value,
# a bare list item, and a value under a key of a hash that is itself a
# list item, and the three have to agree about every kind of value.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use JSON::PP;
use Genesis qw/load_yaml/;
use Genesis::CI::Compiler::AST;
use Genesis::CI::ProviderCompiler::Concourse;

$ENV{NOCOLOR} = 1;

my $compiler = Genesis::CI::ProviderCompiler::Concourse->new(
	ast => Genesis::CI::Compiler::AST->new(),
);

# Serializes the structure and reads it straight back, which is the only
# question any row in this file asks.
sub round_trip {
	my ($data) = @_;
	my $yaml = $compiler->dump_yaml($data);
	my ($read, $rc, $err) = load_yaml("---\n$yaml\n");
	return ($read, $rc, $err, $yaml);
}

subtest 'a boolean keeps its type in each of the three positions' => sub {
	plan tests => 4;

	my $data = {
		plain => JSON::PP::true,
		falsy => JSON::PP::false,
		list  => [JSON::PP::true, JSON::PP::false],
		under => [{key => JSON::PP::true, second => JSON::PP::false}],
	};

	my ($read, $rc, $err, $yaml) = round_trip($data);
	is $rc, 0, 'the document parses' or diag("$err\n$yaml");
	is_deeply $read, $data, 'and every boolean comes back as a boolean'
		or diag($yaml);

	# Said again by name, because a stringified boolean reads as 1 or 0 and
	# a dropped one reads as a shorter list, and the assertion above would
	# name neither.
	isa_ok $read->{plain}, 'JSON::PP::Boolean', 'the hash value';
	is scalar(@{$read->{list}}), 2, 'and the list keeps both of its items';
};

subtest 'a multi-line string survives at every depth' => sub {
	plan tests => 3;

	my $script = "set -e\necho one\necho two";
	my $data = {
		top    => $script,
		nested => {deeper => {deepest => $script}},
		list   => [$script],
		under  => [{run => {args => ['-ce', $script]}}],
	};

	my ($read, $rc, $err, $yaml) = round_trip($data);
	is $rc, 0, 'the document parses' or diag("$err\n$yaml");
	is_deeply $read, $data, 'and the script reads back exactly as written'
		or diag($yaml);

	# The defect this row was written for indents a block scalar by two
	# spaces wherever it sits, so the deepest copy is the one that fails
	# first and is worth naming.
	is $read->{nested}{deeper}{deepest}, $script,
		'including the copy furthest from the top level';
};

subtest 'a trailing newline is kept or dropped as the value has it' => sub {
	plan tests => 2;

	my $data = {
		kept    => "one\ntwo\n",
		dropped => "one\ntwo",
	};

	my ($read, $rc, $err, $yaml) = round_trip($data);
	is $rc, 0, 'the document parses' or diag("$err\n$yaml");
	is_deeply $read, $data, 'and each value keeps the ending it had'
		or diag($yaml);
};

subtest 'the quoting rules keep a string a string' => sub {
	plan tests => 2;

	# Each of these is a value a reader would take for something other than
	# a string if it reached the document bare.
	my $data = {
		word_yes   => 'yes',
		word_no    => 'no',
		word_on    => 'on',
		word_off   => 'off',
		true       => 'true',
		false      => 'false',
		null       => 'null',
		octal_ish  => '0755',
		with_colon => 'key: value',
		with_hash  => 'trailing # comment',
		with_quote => 'a "quoted" word',
		backslash  => 'a\\path',
		empty      => '',
		spaced     => '  padded  ',
	};

	my ($read, $rc, $err, $yaml) = round_trip($data);
	is $rc, 0, 'the document parses' or diag("$err\n$yaml");
	is_deeply $read, $data, 'and every value comes back as the string it was'
		or diag($yaml);
};

subtest 'a key is spelled by the same rules a value is' => sub {
	plan tests => 3;

	# A key used to be written exactly as it stood, so each of these
	# produced a document that came back as something else or would not
	# parse at all.
	#
	# The four words YAML 1.1 reads as booleans, which are on, off, yes,
	# and no, are not among them.  The writer quotes one, which is right
	# for the reader a pipeline meets, but spruce puts a marker in front
	# of a quoted key it recognises as one of the four, so this reader
	# cannot be asked the question at all.
	my $data = {
		'a: b'       => 'colon',
		'x #y'       => 'comment marker',
		'0755'       => 'octal looking',
		'true'       => 'a word a reader takes for a boolean',
		'null'       => 'and one it takes for nothing',
		'plain_key'  => 'left alone',
		'with space' => 'spaces in it',
	};

	my ($read, $rc, $err, $yaml) = round_trip($data);
	is $rc, 0, 'the document parses' or diag("$err\n$yaml");
	is_deeply $read, $data, 'and every key comes back as the key it was'
		or diag($yaml);

	# A key beneath a list item is written by its own sub, so it is asked
	# for separately.
	my ($nested, $nrc, $nerr, $nyaml) = round_trip({list => [{'a: b' => 'v'}]});
	is_deeply $nested, {list => [{'a: b' => 'v'}]},
		'including a key under a list item' or diag("$nerr\n$nyaml");
};

subtest 'the empty and undefined cases keep their shape' => sub {
	plan tests => 2;

	my $data = {
		nothing    => undef,
		empty_list => [],
		empty_hash => {},
		list       => [undef, 'after'],
		nested     => [[1, 2], [3]],
	};

	my ($read, $rc, $err, $yaml) = round_trip($data);
	is $rc, 0, 'the document parses' or diag("$err\n$yaml");
	is_deeply $read, $data, 'and each empty value reads back empty'
		or diag($yaml);
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
