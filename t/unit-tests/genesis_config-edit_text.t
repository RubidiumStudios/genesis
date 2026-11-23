#!perl
# Proves T516 (D182): Genesis::Config::edit_yaml_text changes one key of a
# YAML file by editing its lines, so every line it does not touch, and so
# every comment, blank line and the order of the keys, is as the owner left
# it.  It is not a YAML parser and is not trusted as one: a shape it cannot
# edit it declines, answering undef, and its caller checks what it did answer
# by parsing it.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use JSON::PP ();
use Genesis::Config;

sub edit { Genesis::Config::edit_yaml_text(@_) }

my $KEPT = <<'EOF';
---
# How I like it.
output_style: fun # loud

embedded_genesis: ignore   # use, check, ignore
suppress_warnings:
  # these are noisy
  bosh_target: false
ui:
  colors:
    code: Yb

# The end.
EOF

subtest 'a key that is there has its value changed, and nothing else' => sub {
	(my $want = $KEPT) =~ s/output_style: fun # loud/output_style: plain # loud/;
	is(edit($KEPT, sets => [[output_style => 'plain']]), $want,
		'the comment after the value, and every other line, are kept');

	($want = $KEPT) =~ s/embedded_genesis: ignore   # use/embedded_genesis: warn   # use/;
	is(edit($KEPT, sets => [[embedded_genesis => 'warn']]), $want,
		'with the spacing ahead of its comment');

	($want = $KEPT) =~ s/    code: Yb/    code: Gb/;
	is(edit($KEPT, sets => [['ui.colors.code' => 'Gb']]), $want, 'at any depth');

	($want = $KEPT) =~ s/  bosh_target: false/  bosh_target: true/;
	is(edit($KEPT, sets => [['suppress_warnings.bosh_target' => JSON::PP::true]]), $want,
		'and a boolean is written as the word');
};

# A comment starts at a # that has a space before it and is outside quotes.
# One inside a quoted value, or hard against a plain one, is the value's own.
subtest 'the comment at the end of a line is told from a # in the value' => sub {
	is(edit(qq{k: "a # b" # real\n}, sets => [[k => 'c']]), "k: c # real\n",
		'a # inside double quotes is not where the comment starts');
	is(edit(qq{k: 'a # b'   # real\n}, sets => [[k => 'c']]), "k: c   # real\n",
		'nor one inside single quotes');
	is(edit("k: a#b # real\n", sets => [[k => 'c']]), "k: c # real\n",
		'nor one hard against a plain value');
	is(edit("k: a#b\n", sets => [[k => 'c']]), "k: c\n", 'which may have no comment after it at all');
	is(edit("k: v #\n", sets => [[k => 'c']]), "k: c #\n", 'an empty comment is kept');
	is(edit("k:   # nothing yet\n", sets => [[k => 'c']]), "k: c # nothing yet\n",
		'and one after a key with no value');
	is(edit("p: # about p\n  a: 1 # about a\n", sets => [['p.b' => 'x']]),
		"p: # about p\n  a: 1 # about a\n  b: x\n",
		'a comment on a parent\'s own line stays when a key is added under it');
	is(edit("p: # about p\n  a: 1 # about a\nq: 2 # about q\n", unsets => ['p.a']),
		"p: # about p\nq: 2 # about q\n",
		'and a removed key takes its own comment and no other');
};

subtest 'a key that is not there is added' => sub {
	is(edit($KEPT, sets => [[show_duration => JSON::PP::true]]), $KEPT."show_duration: true\n",
		'at the end, where it has no parent in the file');

	(my $want = $KEPT) =~ s/(  bosh_target: false\n)/$1  deprecations: true\n/;
	is(edit($KEPT, sets => [['suppress_warnings.deprecations' => JSON::PP::true]]), $want,
		"under its parent, after the parent's last key and at its keys' indent");

	($want = $KEPT) =~ s/(    code: Yb\n)/$1    warning_alert: kYi\n/;
	is(edit($KEPT, sets => [['ui.colors.warning_alert' => 'kYi']]), $want, 'at any depth');

	is(edit("---\noutput_style: fun\n", sets => [['ui.colors.code' => 'Gb']]),
		"---\noutput_style: fun\nui:\n  colors:\n    code: Gb\n",
		'with every parent it lacks');
};

subtest 'a value is quoted where a plain one would be read as something else' => sub {
	for my $case (['no', '"no"'], ['true', '"true"'], ['12', '"12"'], ['a: b', '"a: b"'],
			['with # hash', '"with # hash"'], ['', '""'], ['say "hi"', '"say \"hi\""'],
			['<DEPLOYMENT_ROOT>/bosh_logs', '<DEPLOYMENT_ROOT>/bosh_logs'], ['/var/log/genesis', '/var/log/genesis']) {
		my ($value, $written) = @$case;
		is(edit("k: v\n", sets => [[k => $value]]), "k: $written\n", "'$value' is written $written");
	}
};

subtest 'a key is removed with what is under it' => sub {
	(my $want = $KEPT) =~ s/output_style: fun # loud\n//;
	is(edit($KEPT, unsets => ['output_style']), $want, 'a scalar is one line, and the comment above the file stays');

	($want = $KEPT) =~ s/suppress_warnings:\n  # these are noisy\n  bosh_target: false\n//;
	is(edit($KEPT, unsets => ['suppress_warnings']), $want, 'a mapping goes with its keys');

	($want = $KEPT) =~ s/    code: Yb\n//;
	is(edit($KEPT, unsets => ['ui.colors.code']), $want, 'a nested key leaves its parents');

	is(edit($KEPT, unsets => ['show_duration']), $KEPT, 'and a key that is not there changes nothing');
};

subtest 'a list is not mistaken for keys' => sub {
	my $text = "logs:\n  - file: a.log\n    level: INFO\ndeployment_roots:\n- /ops\n";
	is(edit($text, sets => [[level => 'DEBUG']]), $text."level: DEBUG\n",
		'a key of the same name inside a list item is left alone');
	is(edit($text, unsets => ['logs']), "deployment_roots:\n- /ops\n", 'and a list goes whole with its key');
	is(edit($text, unsets => ['deployment_roots']), "logs:\n  - file: a.log\n    level: INFO\n",
		'as does one written at its key\'s own indent');
};

subtest 'a shape it cannot edit is declined' => sub {
	is(edit("ui: {colors: {code: Yb}}\n", sets => [['ui.colors.code' => 'Gb']]), undef,
		'a key inside a flow mapping');
	is(edit("output_style: fun\n", sets => [['output_style.loud' => 'yes']]), undef,
		'a key under one that holds a plain value');
	is(edit("note: |\n  two\n  lines\n", sets => [[note => 'one']]), undef, 'a block scalar');
	is(edit("ui:\n  colors:\n    code: Yb\n", sets => [[ui => 'plain']]), undef,
		'a plain value over a mapping');
	is(edit("k: v\n", sets => [[k => ['a']]]), undef, 'a value that is not a scalar');
	is(edit("k: v\n", sets => [['logs[0].file' => 'x']]), undef, 'a path into a list');
	is(edit("\tk: v\n", sets => [[k => 'w']]), undef, 'a file indented with tabs');
};

done_testing;
