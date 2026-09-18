#!/usr/bin/env perl
# Proves T244: both flags refuse at Genesis::Exit::CONFIG when the pipeline is
# not enabled, each naming the recorded deployed commit and the session that
# opens only under a pipeline, and each writes nothing.
#
# What the rows catch: an implementation that declared the two flags and left
# them inert, which exits 0 rather than CONFIG; one that refused with a bare
# usage error, which exits 2 and names neither the record nor the session; one
# that refused every use of the flags rather than the ones outside a pipeline,
# which the enabled-pipeline row at the end of the first subtest catches; and
# one that gave each flag its own wording, which the second subtest catches by
# comparing the two sentences.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'both flags refuse where the pipeline is not enabled' => sub {
	plan tests => 11;

	my $h = make_harness(envs => ['qa'], kit => 'omega-v2.7.0', pipeline => 0);
	init_branch($h, 'qa');
	certify($h, 'qa',
		commit         => 'deadbee',
		control_commit => 'cafef00',
	);
	stand_on($h, $h->control);

	my $before = snapshot_w($h);

	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'qa', 'deploy', '--redeploy');
	is($exit, Genesis::Exit::CONFIG, 'the redeploy exits CONFIG');
	like($err, qr/deployed commit is recorded/,
		'the redeploy says the deployed commit is recorded');
	like($err, qr/opens only under a pipeline/,
		'the redeploy names the session that opens only under a pipeline');
	unlike($out, qr/bosh deploy/i, 'nothing reached BOSH');
	assert_w_restored($before, 'the redeploy left working state alone');

	($out, $err, $exit) = run_genesis($h, {restore => 0}, 'qa', 'info', '--as-deployed');
	is($exit, Genesis::Exit::CONFIG, 'the info run exits CONFIG');
	like($err, qr/deployed commit is recorded/,
		'the info run says the deployed commit is recorded');
	like($err, qr/opens only under a pipeline/,
		'the info run names the session that opens only under a pipeline');
	assert_w_restored($before, 'the info run left working state alone');

	# The same flag in a repository whose pipeline is on, so that the two
	# refusals above are about the pipeline being off and not about a flag
	# the parser never heard of.
	my $g = make_harness(envs => ['qa'], kit => 'omega-v2.7.0');
	my $gc = commit_on_control($g,
		files   => {'ops/base.yml' => "---\nversion: one\n"},
		message => 'the certified content',
		push    => 1,
	);
	init_branch($g, 'qa');
	deliver($g, 'qa', control => $gc);
	refresh($g, 'a');
	stand_on($g, $g->control);

	my (undef, undef, $on_exit) = run_genesis($g, 'qa', 'info', '--as-deployed');
	isnt($on_exit, Genesis::Exit::CONFIG,
		'the same flag under an enabled pipeline meets no such refusal');
};

subtest 'the two flags share one help sentence' => sub {
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);

	# Genesis renders help through the log, which is standard error, so the
	# two sentences are read off the second return value and not the first.
	my (undef, $deploy_help) = run_genesis($h, 'qa', 'deploy', '--help-full');
	my (undef, $info_help)   = run_genesis($h, 'qa', 'info', '--help-full');

	my ($deploy_sentence) = $deploy_help =~ /--redeploy\s+(.*?)(?:\n\s*\n|\z)/s;
	my ($info_sentence)   = $info_help   =~ /--as-deployed\s+(.*?)(?:\n\s*\n|\z)/s;

	ok(defined $deploy_sentence, 'the deploy help carries --redeploy');
	ok(defined $info_sentence, 'the info help carries --as-deployed');

	my $squash = sub { my $t = shift // ''; $t =~ s/\s+/ /g; $t =~ s/^\s|\s$//g; $t };
	is($squash->($info_sentence), $squash->($deploy_sentence),
		'both flags print the same sentence about the deployed commit');
};

done_testing;
