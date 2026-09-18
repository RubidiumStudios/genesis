#!/usr/bin/env perl
# Proves the arms of Genesis::CI::Preflight::assert_not_disowned, which two
# commands ask about one state and are answered in their own words: the
# propagate run refuses, the deploy warns, and inside a pipeline job both
# refuse.
#
# The sub is driven directly here rather than through a spawned command,
# because the words each caller supplies are the subject.  A row that spawned
# a command could prove the sentence its own caller passes and nothing about
# the sentence another caller would get, which is how the job refusal came to
# tell a propagate run that a job never deploys.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Output;

use Genesis;
use Genesis::Exit qw/CONFIG/;

use_ok 'Genesis::CI::Preflight';

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# disowned_top - a repository whose configuration has disowned its pipeline
#
# The applied record stands and pipeline.enabled reads false, which is the
# one state this sub exists to answer for.  The timestamp is fixed so a row
# can read it back.
sub disowned_top {
	my (%opts) = @_;
	my $h = make_harness(envs => ['qa'], pipeline => $opts{pipeline} // 0);
	fixture_applied($h,
		control => $h->git('a')->sha($h->control),
		at      => '2026-09-12 14:02:11 -0400')
		unless defined $opts{applied} && !$opts{applied};
	return top_for($h);
}

# refusal_from - what the sub refused with, as the refusal composed it
#
# The message is wrapped for the terminal before it is raised, so reading it
# back off the death would rest on where a line break landed.  The arguments
# are read as the refusal composed them instead, and the exit code comes off
# the options hash, which is the only place a code survives a bail raised
# inside an eval.  It is the shape the provider gate's own unit file uses.
sub refusal_from {
	my ($code) = @_;

	my @raised;
	my $died;
	{
		# once as well as redefine, because the refusal is the only mention
		# of the glob in this file and Perl reads a single mention as a typo.
		no warnings qw/once redefine/;
		local *Genesis::CI::Preflight::bail =
			sub {push @raised, [@_]; die "refused\n"};
		eval {$code->(); 1} or $died = $@;
	}
	unless (@raised) {
		diag("nothing was refused, and the code died with: $died")
			if defined $died;
		return ('', undef);
	}

	my @args = @{$raised[0]};
	my $opts = ref($args[0]) eq 'HASH' ? shift(@args) : {};
	my ($format, @rest) = @args;

	return (sprintf($format, @rest), $opts->{exitcode});
}

subtest 'a disowned pipeline that is not disowned at all' => sub {
	# The two early returns, which are what keeps a repository with no
	# pipeline, and one whose pipeline is live, out of every arm below.
	plan tests => 2;

	is(Genesis::CI::Preflight::assert_not_disowned(disowned_top(pipeline => 1)),
		1, 'an enabled pipeline passes whatever the applied record says');
	is(Genesis::CI::Preflight::assert_not_disowned(disowned_top(applied => 0)),
		1, 'and a repository that never applied one is disowning nothing');
};

subtest 'the propagate run refuses' => sub {
	plan tests => 5;

	my ($said, $code) = refusal_from(sub {
		Genesis::CI::Preflight::assert_not_disowned(disowned_top(),
			command => 'propagate')
	});

	is($code, CONFIG, 'it exits CONFIG');
	like($said, qr/Refusing to run #C\{genesis propagate\}/,
		'it names the command the operator ran');
	like($said, qr/applied it from control\@\w+ at 2026-09-12 14:02:11 -0400/,
		'with the applied record and when it was applied');
	like($said,
		qr/Set #C\{pipeline\.enabled: true\} again, or tear the pipeline down by hand/,
		'and both remedies');
	like($said, qr/Nothing was written\./,
		'and the closing sentence it did not have to ask for');
};

subtest "the deploy's own words carry through" => sub {
	plan tests => 3;

	my ($said, $code) = refusal_from(sub {
		Genesis::CI::Preflight::assert_not_disowned(disowned_top(),
			command => 'qa deploy',
			outcome => 'Nothing was deployed.')
	});

	is($code, CONFIG, 'it exits CONFIG for the deploy too');
	like($said, qr/Refusing to run #C\{genesis qa deploy\}/,
		'and it names the deploy');
	like($said, qr/Nothing was deployed\./, 'with the deploy closing sentence');
};

subtest 'the deploy warns where it is told to warn' => sub {
	plan tests => 4;

	my $answer;
	my ($out, $err) = output_from {
		$answer = Genesis::CI::Preflight::assert_not_disowned(disowned_top(),
			command => 'qa deploy',
			outcome => 'Nothing was deployed.',
			locally => 'warn')
	};
	my $said = $out.$err;

	ok(ref($answer) eq 'HASH', 'it answers the applied record rather than 1');
	is($answer->{at}, '2026-09-12 14:02:11 -0400',
		'which is the record the caller may go on to read');
	like($said, qr/the pipeline is disabled in/, 'it says so');
	unlike($said, qr/Refusing to run/,
		'and it is a warning rather than a refusal');
};

subtest 'inside a job every caller is refused' => sub {
	# The sentence about what a job must not do is the caller's, because the
	# sub cannot know what the caller was about to do.  A run told that a job
	# never deploys is told about a command it is not.
	plan tests => 6;

	local $ENV{GENESIS_PIPELINE_TASK} = 'propagate-qa';

	my ($said, $code) = refusal_from(sub {
		Genesis::CI::Preflight::assert_not_disowned(disowned_top(),
			command => 'propagate')
	});

	is($code, CONFIG, 'the propagate run exits CONFIG');
	like($said, qr/#C\{GENESIS_PIPELINE_TASK\} is set/,
		'it says why it knows it is in a job');
	like($said, qr/A job never acts on what its own configuration disowns\./,
		'and says what a job must not do in words that fit any command');
	unlike($said, qr/deploys/,
		'never telling a propagate run about a deploy');

	my ($deploy_said) = refusal_from(sub {
		Genesis::CI::Preflight::assert_not_disowned(disowned_top(),
			command => 'qa deploy',
			outcome => 'Nothing was deployed.',
			in_job  => 'A job never deploys what its own configuration disowns.',
			locally => 'warn')
	});

	like($deploy_said,
		qr/A job never deploys what its own configuration disowns\./,
		'and the deploy says what it was about to do');
	like($deploy_said, qr/Nothing was deployed\./,
		'with locally => warn changing nothing inside a job');
};

done_testing;
