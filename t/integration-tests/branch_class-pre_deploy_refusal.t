#!/usr/bin/env perl
# Proves T195 and T322: a pre-deploy command refuses from a deployment
# branch, a pull request branch, and an artifacts branch, naming the
# condition, exiting DATAERR, and leaving the operator where they stood.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Genesis::Exit;

# The refusals are read back as whole sentences, so the width they fold at
# is the file's to fix rather than the terminal's to decide.
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# said - a refusal's own sentence, however the terminal folded it {{{
#
# A bare fragment like "deployment branch" is carried by a refusal that
# names the right class in the wrong sentence, so each row below matches
# the whole sentence instead.  The text arrives wrapped at the width above,
# and a fold is a newline where the sentence has a space, so every run of
# whitespace in the expected text matches any run of whitespace in the
# refusal.
sub said {
	my ($sentence) = @_;
	my $pattern = join('\s+', map {quotemeta} split(' ', $sentence));
	return qr/$pattern/;
}

# }}}

# The kit is the one the suite ships whose new hook writes the environment
# file the command asks for, because create bails when it finds no kit and
# the last row here runs the command through to a write.
my $h = make_harness(envs => ['qa'], type => 'bosh', kit => 'omega-v2.7.0');
my $git = $h->git('a');

# The three derived branches are delivered rather than seeded, so each one
# carries .genesis/config and the gate has a Top to read.  A bare branch
# would leave the gate with nothing and the refusal would come from create
# for its own reasons and at its own exit code.
my $control = $git->sha($h->control);
deliver($h, 'qa', control => $control);
deliver($h, 'qa', control => $control, pr => 1);
refresh($h, 'a');
# The delivery was written in copy B and published, so copy A knows the
# deployment branch as a remote-tracking ref alone and the artifacts branch
# is cut from that ref.  Naming the bare slug here asks git to resolve a
# local branch copy A does not have.
$git->create_branch('artifacts/' . $h->slug('qa'),
	'origin/' . $h->slug('qa'));

# Every run below is a refusal, so nothing writes and the runner's own
# restoration assertion is the right one.  The rows that would have taken a
# snapshot of their own take none, because run_genesis has already taken it.
subtest 'genesis new refuses from a deployment branch' => sub {
	stand_on($h, $h->slug('qa'));

	my ($out, $err, $exit) = run_genesis($h, 'new', 'prod');

	is($exit, Genesis::Exit::DATAERR(),
		'the refusal exits DATAERR');
	like($err, said(sprintf(
			'%s is a deployment branch, which holds what was delivered, '.
			'and this command changes what will be delivered.',
			$h->slug('qa'))),
		'the refusal names the branch, its class, and what it would change');
	like($err, said('git checkout ' . $h->control),
		'and the remedy is the checkout that fixes it');
	ok(!-f $h->a . '/prod.yml',
		'no environment file was written');
};

subtest 'a secrets command refuses from the same branch' => sub {
	stand_on($h, $h->slug('qa'));

	my ($out, $err, $exit) = run_genesis($h, 'qa', 'check-secrets');

	is($exit, Genesis::Exit::DATAERR(),
		'the second pre-deploy command refuses the same way');
	like($err, said(sprintf(
			'%s is a deployment branch, which holds what was delivered, '.
			'and this command changes what will be delivered.',
			$h->slug('qa'))),
		'and refuses in the same sentence');
};

subtest 'genesis new refuses from a pull request branch' => sub {
	stand_on($h, $h->pr_branch('qa'));

	my ($out, $err, $exit) = run_genesis($h, 'new', 'prod');

	is($exit, Genesis::Exit::DATAERR(),
		'a pull request branch refuses too');
	like($err, said(sprintf(
			'%s is a pull request branch, which a propagate run rewrites, '.
			'and this command changes what will be delivered.',
			$h->pr_branch('qa'))),
		'the refusal names the pull request branch and its class');
	like($err, said('git checkout ' . $h->control),
		'and the remedy is the checkout that fixes it');
	ok(!-f $h->a . '/prod.yml',
		'no environment file was written');
};

subtest 'genesis new refuses from an artifacts branch' => sub {
	stand_on($h, 'artifacts/' . $h->slug('qa'));

	my ($out, $err, $exit) = run_genesis($h, 'new', 'prod');

	is($exit, Genesis::Exit::DATAERR(),
		'an artifacts branch refuses too');
	like($err, said(sprintf(
			'artifacts/%s is an artifacts branch, which a deploy writes to, '.
			'and this command changes what will be delivered.',
			$h->slug('qa'))),
		'the refusal names the artifacts branch and its class');
	like($err, said('git checkout ' . $h->control),
		'and the remedy is the checkout that fixes it');
	ok(!-f $h->a . '/prod.yml',
		'no environment file was written');
};

subtest 'propagate is exempt, and runs from a deployment branch' => sub {
	# propagate declares branch_target => control and switches there inside
	# its own session, so the gate leaves it where it stands.  Standing it
	# on the one branch every row above is refused from is what makes the
	# exemption, rather than the class, the thing this row reads.
	stand_on($h, $h->slug('qa'));

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '--dry-run');

	is($exit, 0, 'propagate runs where every other pre-deploy command is refused');
	unlike($err, said('is a deployment branch'),
		'and no branch refusal was raised against it');
};

subtest 'control is permitted' => sub {
	stand_on($h, $h->control);

	# restore => 0, because --no-commit leaves the environment file staged
	# and the index the runner snapshotted is deliberately not the one the
	# run leaves behind.
	my ($out, $err, $exit) = run_genesis($h, {restore => 0},
		'new', 'prod', '--no-commit');

	is($exit, 0, 'the same command on control runs');
	ok(-f $h->a . '/prod.yml', 'and writes the environment file');
};

done_testing;
