#!/usr/bin/env perl
# Proves T259: two due control commits become exactly one aggregate commit on
# the pull request branch, whose subject is the marker naming the newer and
# whose body lists both oldest first with their diff --stat lines, and whose
# pull request body is that commit body verbatim.
#
# The row is not green on arrival.  Task 16.1 writes the bare marker as the
# whole message, with the control commit spelled in full, so the subject reads
# the long sha the marker builder was handed, the body is empty, and the pull
# request carries the subject as its body because the strip of a first line
# finds no newline to strip.  What the row adds on top of that is the count,
# the per-commit entries in order, the summary of the files each commit
# touched inside this environment's set, and the equality of the commit body
# and the pull request body.
#
# The two due commits are laid through the environment file at the deployment
# root, because a path under prod/ is in no propagation set and a commit
# written there would route nowhere and leave nothing due.  The second one
# also writes docs/runbook.md, which is in no kind the set is built from, so
# the last assertion separates a body scoped by the propagation set from one
# scoped by the commit's whole diff.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use JSON::PP;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'two due commits become one aggregate' => sub {
	plan tests => 11;

	my $h   = ready(kit => 'omega-v2.7.0');
	my $gh  = $h->{gh};
	my $git = $h->git('a');
	my $pr  = $h->pr_branch('prod');

	# The environment file is written through the harness and committed by
	# hand, because the run reads require_pr out of that very file and a body
	# composed here that dropped the key would take the whole arm with it,
	# while the harness's own commit carries a message this row cannot name.
	my $path = $h->write_env_file('prod', params => {instances => 2},
		commit => 0);
	my $first = commit_on_control($h,
		files   => {$path => slurp($h->a."/$path")},
		message => 'Raise the instance count',
		push    => 1,
	);

	$path = $h->write_env_file('prod',
		params => {instances => 2, signing => 'rotated'}, commit => 0);
	my $second = commit_on_control($h,
		files   => {
			$path                => slurp($h->a."/$path"),
			'kit-overrides.yml'  => "---\nsigning: new\n",
			'docs/runbook.md'    => "Rotate the signing key by hand.\n",
		},
		message => 'Rotate the uaa signing key',
		push    => 1,
	);

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run succeeded');

	refresh($h, 'a', $pr);
	my @log = $git->log_subjects("origin/$pr", format => '%H');
	my $deployment_tip = $git->sha('origin/'.$h->slug('prod'));
	my @above = grep {!$git->is_ancestor($_, $deployment_tip)} @log;
	is(scalar @above, 1, 'exactly one commit sits above the deployment branch');

	my ($subject) = $git->log_subjects("origin/$pr", limit => 1, format => '%s');
	is($subject,
		sprintf('[pipeline] control@%s -> prod', $git->sha($second, short => 1)),
		'the subject is the marker naming the newer commit');

	my ($body) = run({dir => $h->a}, 'git', 'log', '-1', '--format=%b',
		"origin/$pr");
	my $short_first  = $git->sha($first,  short => 1);
	my $short_second = $git->sha($second, short => 1);

	like($body, qr/Carries 2 control commits:/,
		'the body says how many it carries');
	cmp_ok(index($body, $short_first), '<', index($body, $short_second),
		'the older commit is listed first');
	like($body, qr/\Q$short_first\E Raise the instance count/,
		'each entry is the short hash and the subject');
	like($body, qr/kit-overrides\.yml\s+\|\s+2 \+\+/,
		'and the diff --stat lines for the files it changed in the set');
	unlike($body, qr/docs\/runbook\.md/,
		'and nothing outside this environment set');

	my ($create) = grep {($_->{method} // '') eq 'POST'} gh_calls($gh);
	my $payload = JSON::PP->new->decode($create->{body});
	is($payload->{body}, $body =~ s/\s+$//r,
		'the pull request body is the commit body verbatim');
	is($payload->{title}, $subject, 'and the title is its subject');
};

# Proves T260: a gate travels with the commits ahead of it and ends the
# delivery, the body names what waits, and the later commit is held.
#
# The row is not green on arrival.  The walk already trims the due list to the
# gate and records the commit after it as gate-ahead, so the aggregate stops
# in the right place and the report already says why that one commit waits.
# What is missing is the paragraph: nothing in the aggregate's body says the
# delivery stopped at a gate, and nothing on the delivered entry even says
# which of the two commits the gate is, so the arm has no reading of the
# trailer to compose one from.
#
# The three due commits are laid through the environment file at the
# deployment root for the reason the row above records: a path under prod/ is
# in no propagation set, so a commit written there would route nowhere and
# leave nothing due.
subtest 'a gate ends the aggregate and holds what follows' => sub {
	plan tests => 8;

	my $h  = ready(kit => 'omega-v2.7.0');
	my $pr = $h->pr_branch('prod');

	my $path = $h->write_env_file('prod', params => {instances => 2},
		commit => 0);
	commit_on_control($h,
		files   => {$path => slurp($h->a."/$path")},
		message => 'Raise the cf instance count',
		push    => 1,
	);

	$path = $h->write_env_file('prod',
		params => {instances => 2, signing => 'rotated'}, commit => 0);
	my $gate = commit_on_control($h,
		files    => {$path => slurp($h->a."/$path")},
		message  => 'Rotate the uaa signing key',
		trailers => {'Genesis-Stage' =>
			'rotate the uaa signing key before anything after it'},
		push     => 1,
	);

	$path = $h->write_env_file('prod',
		params => {instances => 3, signing => 'rotated'}, commit => 0);
	my $after = commit_on_control($h,
		files   => {$path => slurp($h->a."/$path")},
		message => 'Raise the cf instance count again',
		push    => 1,
	);

	my ($out, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run succeeded');

	refresh($h, 'a', $pr);
	is(harness_marker($h, "origin/$pr"), $gate, 'the aggregate ends at the gate');

	my ($body) = run({dir => $h->a}, 'git', 'log', '-1', '--format=%b',
		"origin/$pr");
	like($body, qr/Carries 2 control commits:/,
		'it carries the gate and the one ahead of it');
	like($body,
		qr/^Gate: rotate the uaa signing key before anything after it\./m,
		'the body carries the gate line');
	like($body, qr/Holding 1 later commit for prod until this deploys\./,
		'and says what waits behind it');

	# The report is written to standard error and folded to the terminal
	# width on its way out, so both phrases are read off the run put back on
	# one line rather than off whichever column the fold landed in.
	my $said = unfolded($out, $err);
	my $short_after = substr($after, 0, 7);
	like($said,
		qr/control\@\Q$short_after\E Raise the cf instance count again\s+held/,
		'the later commit is recorded held');
	like($said,
		qr/gate: rotate the uaa signing key before anything after it/,
		'with the gate as its reason, in the words the trailer gave');
};

done_testing;
