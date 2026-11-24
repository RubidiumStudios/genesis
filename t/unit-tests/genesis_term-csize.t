#!/usr/bin/env perl
use strict;
use warnings;
use lib 't';
use helper;

use_ok 'Genesis::Term';

subtest 'csize returns display width of colored strings' => sub {
	is(csize("hello"), 5, 'plain text returns character count');
	is(csize(""), 0, 'empty string returns 0');
	is(csize("ab"), 2, 'short string works');
	is(csize("#G{hi}"), 2, 'colored string width ignores color markup');
};

# The width is what a terminal advances by, not a count of characters: a
# variation selector takes no column and a wide emoji takes two.  A label
# measured a column out puts every wrapped line of its message a column out.
subtest 'csize measures terminal columns, not characters' => sub {
	plan tests => 11;

	local $ENV{GENESIS_NO_UTF8} = '';

	is(csize("\x{26A0}\x{FE0F} "), 2, 'a sign, its emoji selector and a space are two columns');
	is(csize("\x{1F4A5}"), 2, 'a wide emoji is two');
	is(csize("e\x{0301}"), 1, 'a combining mark takes none');
	is(csize("a\x{200D}b"), 2, 'nor does a joiner');

	is(csize('#E{warning}'), 2, 'the warning emoji is two columns');
	is(csize('#E{information}'), 2, 'the information emoji is two');
	is(csize('#E{collision}'), 2, 'the collision emoji is two');
	is(csize('#E{notice}'), 3, 'the notice emoji, wide with a space after it, is three');

	is(csize('#ky{[#E{warning}WARNING]} '), 12, 'the warning label is twelve columns');
	is(csize('#RW{[#E{collision}ERROR]} '), 10, 'and the error label ten');

	local $ENV{GENESIS_NO_UTF8} = 1;
	is(csize('#ky{[#E{warning}WARNING]} '), 10, 'with no emoji, the label is its letters and brackets');
};

done_testing;
