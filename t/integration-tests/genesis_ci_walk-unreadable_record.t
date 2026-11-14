#!/usr/bin/env perl
# Proves T489: in a run over many environments, a record the vault will not
# let the run read fails its own environment and no other (D159).
#
# The walk makes four reads of its own for each environment: the hold, the
# deployment history its certified commit comes from, the proposed record,
# and the pipeline record.  Each row here has the vault refuse one of them
# for the middle environment of a chain of three, and reads the same three
# things off the run: that environment ends failed, naming the path and what
# the vault said; the one below it is held as behind an ancestor that could
# not be read; and the one above it, which the failure has nothing to do
# with, is delivered.  The run exits non-zero.
#
# A reader that took the refusal for nothing stored would answer no hold, a
# never-certified environment, no proposal, or an environment the pipeline
# does not know, and the walk would act on each of those.
#
# Genesis accounts for itself on standard error, which is where info writes,
# so every report a row reads comes out of the second value run_genesis
# answers rather than the first.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/run/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# lab, then qa, then prod, each following the one before, and all three
# tracking one shared file, so one commit touching it is due to all of them.
sub chain_of_three {
	return ready_harness(
		envs    => ['lab', 'qa', 'prod'],
		kit     => 'omega-v2.7.0',
		chained => 1,
		tracked => ['ops/shared.yml'],
	);
}

my %READS = (
	'the hold'               => 'hold',
	'the deployment history' => 'deployments',
	'the proposed record'    => 'proposed',
	'the pipeline record'    => 'pipeline',
);

for my $what (sort keys %READS) {
	subtest "$what of one environment cannot be read" => sub {
		# Seven rows, and one for the run's own restoration assertion.
		plan tests => 8;

		my $h = chain_of_three();
		my $due = commit_on_control($h,
			files   => {'ops/shared.yml' => "---\nshared: 2\n"},
			message => 'Bump shared ops',
			push    => 1,
		);
		# lab has deployed the commit, so nothing but the read that fails
		# stands between qa and its delivery.
		certify($h, 'lab', control_commit => $due);
		my $path = $h->env_path('qa').'/'.$READS{$what};
		my $before = ref_in($h->r, 'refs/heads/'.$h->slug('qa'));
		break_vault_reads($h, $path);

		my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
		my $said = unfolded($err);

		isnt($exit, 0, 'the run exits non-zero');
		like($err, qr/^\s*qa: failed/m, 'qa, whose record it was, ends failed')
			or diag $err;
		is(ref_in($h->r, 'refs/heads/'.$h->slug('qa')), $before, 'and nothing is delivered to it');
		# A reader that exports names the path without its leading slash.
		like($said, qr/\Q@{[$path =~ s{^\/}{}r]}\E/, 'naming the path that could not be read');
		like($said, qr/permission denied/, 'and what the vault answered');
		like($said, qr/held by qa, which could not be read/,
			'prod, below it, is held behind an ancestor that could not be read');
		is(harness_marker($h, $h->slug('lab')), $due,
			'and lab, which the failure has nothing to do with, is delivered');
	};
}

done_testing;
