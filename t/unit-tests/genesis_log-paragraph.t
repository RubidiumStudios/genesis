#!/usr/bin/env perl
# Proves T522's logger half: a message logged as a paragraph stands apart
# from what is around it on the terminal, by one blank line before and one
# after, and two of them in a row share the one between (D186).
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Output qw/stderr_from/;

use Genesis;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 60;

# The label a warning carries here, whatever log style the run has.
my ($LABEL) = stderr_from {warning('x')} =~ /\A(.*?)x\n\z/s;
my $PAD = ' ' x length($LABEL);

subtest 'a paragraph has a blank line before it and one after' => sub {
	plan tests => 2;

	my $said = stderr_from {
		info('  first');
		warning({paragraph => 1}, 'the middle');
		info('  last');
	};
	is($said, "  first\n\n${LABEL}the middle\n\n  last\n",
		'between two lines, it stands apart from both');

	$said = stderr_from {
		info('  first');
		warning('the middle');
		info('  last');
	};
	is($said, "  first\n${LABEL}the middle\n  last\n",
		'and a warning not asked to be one is written as before');
};

subtest 'two paragraphs in a row share the blank line between them' => sub {
	plan tests => 2;

	my $said = stderr_from {
		info('  first');
		warning({paragraph => 1}, 'one');
		warning({paragraph => 1}, 'two');
		info('  last');
	};
	is($said, "  first\n\n${LABEL}one\n\n${LABEL}two\n\n  last\n",
		'one blank line between them, not two');

	$said = stderr_from {
		info("  first\n");
		warning({paragraph => 1}, 'one');
		info('  last');
	};
	is($said, "  first\n\n${LABEL}one\n\n  last\n",
		'and a blank line already there is not added to');
};

subtest "a paragraph's own lines keep the label's indent" => sub {
	plan tests => 2;

	my $said = stderr_from {
		info('  first');
		warning({paragraph => 1}, "Could not protect %s: refused\nIt needs: a, b", 'control');
		info('  last');
	};
	is($said, "  first\n\n${LABEL}Could not protect control: refused\n${PAD}It needs: a, b\n\n  last\n",
		'a second line sits under the first one\'s text');

	$said = stderr_from {
		warning({paragraph => 1}, "one\n\nHand that list on.");
		info('  last');
	};
	like($said, qr/\Q${LABEL}\Eone\n\s*\n\Q${PAD}\EHand that list on\.\n\n  last\n\z/,
		'and a blank line inside it is kept, with what follows still indented');
};

done_testing;
