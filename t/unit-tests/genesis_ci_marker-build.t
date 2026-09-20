#!/usr/bin/env perl
# Proves T78's builder half: the one marker builder.  A direct-mode delivery
# onto qa/bosh writes "[pipeline] control@<sha> -> qa", and it writes it by
# asking the builder rather than by spelling the subject itself.  The sweep
# that proves no other site under lib/ or bin/ spells that subject by hand
# belongs with the change that points every writer and every reader at this
# module.
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
use_ok 'Genesis::CI::Propagation';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the builder renders the subject a marker carries' => sub {
	plan tests => 4;

	is($Genesis::CI::Marker::PREFIX, '[pipeline] control@',
		'the prefix the builder writes and the reader matches is declared once');

	is(Genesis::CI::Marker::build('a1b2c3d4e5f6', 'qa'),
		'[pipeline] control@a1b2c3d4e5f6 -> qa',
		'the subject names the control commit and the receiving environment');

	is(Genesis::CI::Marker::build('a1b2c3d', 'lmelt-vsphere-canwest-1-mgmt'),
		'[pipeline] control@a1b2c3d -> lmelt-vsphere-canwest-1-mgmt',
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

subtest 'a direct-mode delivery writes the built subject' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');

	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	my $short = substr($control, 0, 12);

	my $git = $h->git('a');
	stand_on($h, $h->slug('qa'));

	# The prefix is moved for the length of the delivery, because a row that
	# read the real prefix back would pass just as well against a writer that
	# spelled the subject with its own sprintf.  A writer that asks the
	# builder picks the moved prefix up, and one that does not commits the
	# fixed string and turns both rows red.  The first subtest is what holds
	# the real prefix to its declared spelling.
	my $subject;
	{
		local $Genesis::CI::Marker::PREFIX = '[moved] control@';
		Genesis::CI::Propagation::_apply_propagation_commit(
			$git, 'qa', $control, $short, {changed => ['qa.yml'], deleted => []});

		# The local branch rather than the remote-tracking one, because the
		# delivery is never pushed.
		($subject) = subjects_of($h, $h->slug('qa'), 1, local => 1);

		is($subject, Genesis::CI::Marker::build($short, 'qa'),
			'the writer committed exactly what the builder renders');
	}

	is($subject, "[moved] control\@$short -> qa",
		'and it took the prefix from the builder rather than spelling its own');

	stand_on($h, $h->control);
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
