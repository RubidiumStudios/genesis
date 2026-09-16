#!/usr/bin/env perl
# Proves T193: a local branch whose name matches the configured remote changes
# nothing about where the run publishes or about what it publishes, because the
# publish helper takes its remote as a required named argument.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a branch named for the remote is not published as one' => sub {
	# Five rather than four, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	plan tests => 5;

	my $h = make_harness(envs => ['lab'], mode => 'direct',
		kit => 'omega-v2.7.0', tracked => ['ops/lab.yml']);
	fixture_vault($h);
	init_branch($h, 'lab');
	fixture_applied($h, control => $h->git('a')->sha($h->control));
	fixture_pipeline_record($h, 'lab', dependencies => [], discovery => 'complete');
	certify($h, 'lab', control_commit => ref_in($h->a, 'refs/heads/'.$h->control));

	# The shape H4 names: a local branch whose name is the remote's.
	local_branch($h, 'origin');

	commit_on_control($h,
		files   => {'ops/lab.yml' => "---\nops: one\n"},
		message => 'add an op for lab',
		push    => 1,
	);

	my (undef, undef, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');

	is($exit, 0, 'the run published');
	ok(defined ref_in($h->r, 'refs/heads/lab/bosh'),
		'the deployment branch landed on R');
	is(ref_in($h->r, 'refs/heads/origin'), undef,
		'the branch named for the remote was never published');
	is(ref_in($h->r, 'refs/heads/'.$h->control),
		ref_in($h->a, 'refs/heads/'.$h->control),
		'control is where the operator left it');
};

subtest 'the helper refuses a remote it was not given by name' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['lab'], vault => 0);
	my $git = $h->git('a');

	my $err = '';
	{
		local $ENV{GENESIS_IGNORE_EVAL} = '';
		eval { $git->push('origin', 'lab/bosh') };
		$err = $@ // '';
	}
	like($err, qr/needs its remote by name/,
		'a positional remote is refused rather than guessed at');

	my $results = $git->push(remote => 'origin', refs => []);
	is_deeply($results, [], 'no refs is a no-op and not a failure');
};

done_testing;
