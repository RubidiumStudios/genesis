#!/usr/bin/env perl
# Proves T78's builder half: the one marker builder.  It renders
# "[pipeline] control@<sha> -> qa", refuses what no operator can cause, and
# every caller of the single writer asks it for the subject rather than
# spelling one.  The sweep that proves no other site under lib/ or bin/
# spells that subject by hand belongs with the change that points every
# writer and every reader at this module.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use_ok 'Genesis::CI::Marker';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the builder renders the subject a marker carries' => sub {
	plan tests => 4;

	is($Genesis::CI::Marker::PREFIX, '[pipeline] control@',
		'the prefix the builder writes and the reader matches is declared once');

	is(Genesis::CI::Marker::build('a1b2c3d4e5f6', 'qa'),
		'[pipeline] control@a1b2c3d4e5f6 -> qa',
		'the subject names the control commit and the receiving environment');

	is(Genesis::CI::Marker::build('a1b2c3d', 'acme-vsphere-west-1-mgmt'),
		'[pipeline] control@a1b2c3d -> acme-vsphere-west-1-mgmt',
		'the sha is written exactly as the caller resolved it');

	is(Genesis::CI::Marker::build('a1b2c3d', 'qa'),
		'[pipeline] control@a1b2c3d -> qa',
		'the environment is its own name and never the deployment slug');
};

subtest 'the builder refuses what no operator can cause' => sub {
	plan tests => 4;

	like(exception(sub {Genesis::CI::Marker::build(undef, 'qa')}),
		qr/needs a control sha, got undef/,
		'a missing sha is a caller defect and says so');

	like(exception(sub {Genesis::CI::Marker::build('nothex', 'qa')}),
		qr/needs a control sha, got 'nothex'/,
		'a sha that is not hex is refused and quoted back');

	like(exception(sub {Genesis::CI::Marker::build('a1b2c3d', undef)}),
		qr/needs an environment name/,
		'a missing environment name is refused');

	like(exception(sub {Genesis::CI::Marker::build('a1b2c3d', '')}),
		qr/needs an environment name/,
		'and an empty one is refused the same way');
};

subtest 'every writer takes its subject from the builder' => sub {
	plan tests => 1;

	# The one production writer is Service::Git::Session::apply_files, and
	# it takes its message from its caller, so the callers are where a
	# subject could be spelled by hand.  Each file that calls the writer
	# composes its message through the builder, the direct delivery in the
	# walk directly and the pull request's aggregate through its own
	# builder that asks this one.  The sweep that proves nothing under lib/
	# or bin/ spells the subject's text but the builder belongs to
	# genesis_env_deploymentmanager-git_context.t.
	my @callers = sort grep {
		slurp($_) =~ /->apply_files\(/
	} glob('lib/Genesis/CI/*.pm');
	my @without = grep {slurp($_) !~ /Genesis::CI::Marker::build\(/} @callers;
	ok(@callers && !@without,
		'every caller of the writer composes its subject through the builder')
		or diag(join("\n", 'callers: ', @callers, 'without the builder: ', @without));
};

# The bug the builder raises dies inside an eval, but only where Genesis is
# not told to ignore one, so the variable goes back to unset for the call.
sub exception {
	my ($code) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = '';
	eval {$code->(); 1} and return '';
	return $@;
}

done_testing;
