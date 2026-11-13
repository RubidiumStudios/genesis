#!/usr/bin/env perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use Genesis;
use_ok 'Genesis::CI::Status';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 120;

# A report with no environments says why.
#
# The pipeline's environments are read from control, so a control that
# carries no environment file gives a report with a header, the column
# headings, and nothing under them.  An operator standing on another branch,
# whose files they can see, was left to work out that the report had not read
# that branch.  The table says so now, under the header that names the commit
# it read.

sub record {
	return {
		pipeline => 'doomsday',
		provider => 'manual',
		control  => {branch => 'control', commit => '766a596aaaaaaaa', shape_commit => '766a596aaaaaaaa'},
		environments => [],
		@_,
	};
}

subtest 'an empty report says control carries no environment' => sub {
	plan tests => 3;
	my $out = Genesis::CI::Status::render_tree(record(), standing_on => 'control');

	like($out, qr/no environments/, 'it says there are none');
	like($out, qr/control\@766a596 carries no environment file/,
		'names the commit that was read, and what it lacks');
	like($out, qr/the pipeline is read from control/, 'and says that is where the pipeline is read from');
};

subtest 'an operator on another branch is told that branch was not read' => sub {
	plan tests => 3;
	my $out = Genesis::CI::Status::render_tree(record(), standing_on => 'master');

	like($out, qr/this branch, master, is not read/, 'the branch they stand on is named as not read');
	like($out, qr/commit its environment files to control and push/,
		'with what puts its environments in the pipeline');

	$out = Genesis::CI::Status::render_tree(record(), standing_on => 'control');
	unlike($out, qr/is not read/, 'and nothing of the kind is said to one standing on control');
};

subtest 'a report with environments says none of it' => sub {
	plan tests => 1;
	my $row = {env => 'lab', depth => 0, reading => 'caught up', outcome => 'idempotent'};
	my $out = eval {Genesis::CI::Status::render_tree(record(environments => [$row]), standing_on => 'master')} // "died: $@";

	unlike($out, qr/no environments|is not read/, 'the note is for an empty report alone');
};

done_testing;
