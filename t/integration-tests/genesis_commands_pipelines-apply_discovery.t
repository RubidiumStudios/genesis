#!/usr/bin/env perl
# Proves T130, T131, and T133: the apply computes each environment's dependency
# set from the declared list and the manifest's exodus paths, warns and marks
# discovery incomplete where the blueprint will not render, and writes the
# result beside that environment's own exodus record.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{NOCOLOR} = 1;

# _unfolded - what the run said, put back on one line
#
# A warning is folded to the terminal's width on its way out, so a phrase a
# row is looking for arrives with a newline and an indent somewhere in the
# middle of it.  The two streams are joined on a newline, so that no phrase
# can match across the seam where one ends and the other begins, and their
# whitespace is collapsed before anything is matched.
sub _unfolded {
	my $said = join("\n", map {$_ // ''} @_);
	$said =~ s/\s+/ /g;
	return $said;
}

subtest 'the set is the union of the declared and the discovered' => sub {
	# Three rows, and one more for the run's own restoration assertion, which
	# run_genesis makes unless a row turns it off.
	plan tests => 4;

	# The fixture kit takes bare deployment names and composes
	# secret/exodus/<name>/<this environment's type> for each of them, so the
	# manifest this row renders reads /secret/exodus/dev/bosh and
	# /secret/exodus/ops/bosh and the discovered half is those two slugs.
	my $h = make_harness(envs => ['qa'], kit => 'exodus-reader');
	write_env_file($h, 'qa',
		genesis  => {reads_exodus       => ['dev', 'ops']},
		pipeline => {track_dependencies => ['vault', 'dev/bosh']},
	);
	certify($h, 'dev', commit => 'abc123', type => 'bosh');
	certify($h, 'ops', commit => 'def456', type => 'bosh');

	my (undef, undef, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the apply exits 0');

	is(secret($h->env_path('qa') . '/pipeline:dependencies'),
		'dev/bosh,ops/bosh,qa/vault',
		'the union counts dev/bosh once and resolves the bare type to this env');
	is(secret($h->env_path('qa') . '/pipeline:discovery'), 'complete',
		'discovery ran, so the record says complete');
};

subtest 'the deployment excludes its own exodus path' => sub {
	# One row, and one more for the run's own restoration assertion.
	plan tests => 2;

	# The environment names itself in the list the kit reads, so its own
	# record is one of the paths the manifest carries and the set has to
	# drop it.
	my $h = make_harness(envs => ['qa'], kit => 'exodus-reader');
	write_env_file($h, 'qa', genesis => {reads_exodus => ['qa', 'dev']});
	certify($h, 'dev', commit => 'abc123', type => 'bosh');

	run_genesis($h, 'pipeline-apply');
	is(secret($h->env_path('qa') . '/pipeline:dependencies'), 'dev/bosh',
		'the deployment does not depend on itself');
};

subtest 'an environment that will not render is warned about, not refused' => sub {
	# Five rows, and one more for the run's own restoration assertion.
	plan tests => 6;

	# The kit refuses to render at all for a deployment it was told to
	# require that has no exodus record, and the row seeds none, so the
	# blueprint exits non-zero and the discovered half is unavailable.  The
	# kit takes bare deployment names and composes the path it looks for,
	# so the name the row writes is the name the refusal carries.
	my $h = make_harness(envs => ['qa'], kit => 'exodus-reader');
	write_env_file($h, 'qa',
		genesis  => {requires_exodus    => ['prod']},
		pipeline => {track_dependencies => ['vault']},
	);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = _unfolded($out, $err);

	is($exit, 0, 'the apply carries on and needs no escape flag');
	# The two halves of what the operator is told arrive from two places.
	# The hook writes its own refusal to stderr and Genesis passes it
	# through, so that is where the prerequisite is named, and the warning
	# the render failure raises names the environment and what it fell back
	# to.  A row matching one alone would pass on the other.
	like($said, qr{qa requires prod},
		'the run names the prerequisite whose exodus record is absent');
	like($said, qr{Could not render qa, so only its declared dependencies},
		'and the warning says which environment fell back to its declared set');

	is(secret($h->env_path('qa') . '/pipeline:dependencies'), 'qa/vault',
		'the environment takes its declared set alone');
	is(secret($h->env_path('qa') . '/pipeline:discovery'), 'incomplete',
		'its discovery is marked incomplete');
};

subtest 'an environment that will not load keeps its declared set' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	# The harness names no kit, so the dev kit the environment file points at
	# resolves to nothing and the environment will not load at all.  A load
	# failure costs the manifest and nothing else, which is the same loss the
	# render failure above takes, so the declared half is still read through a
	# bare environment that needs no kit and only the discovered half is gone.
	my $h = make_harness(envs => ['qa']);
	write_env_file($h, 'qa',
		pipeline => {track_dependencies => ['vault', 'lab/bosh']},
	);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = _unfolded($out, $err);

	is($exit, 0, 'the apply carries on past an environment it cannot load');
	like($said, qr{Could not load qa, so only its declared dependencies},
		'the warning names the environment and what it fell back to');

	is(secret($h->env_path('qa') . '/pipeline:dependencies'),
		'lab/bosh,qa/vault',
		'the declared half is wired anyway, bare type and pair alike');
	is(secret($h->env_path('qa') . '/pipeline:discovery'), 'incomplete',
		'and only the discovery it actually lost is marked incomplete');
};

subtest 'an environment joins the set at the next apply and not before' => sub {
	# Three rows, and one more for each of the two runs' restoration
	# assertions.
	plan tests => 5;

	my $h = make_harness(envs => ['qa'], kit => 'exodus-reader');
	run_genesis($h, 'pipeline-apply');
	have_secret($h->env_path('qa') . '/pipeline:discovery',
		'the environment the apply reached has its subpath');

	# The membership test is the subpath's absence, so an environment added
	# after an apply carries none until an apply reaches it, and the two
	# halves of that statement are the two rows below.
	write_env_file($h, 'staging');
	no_secret($h->env_path('staging') . '/pipeline:discovery',
		'an environment added after the apply has none of its own yet');

	run_genesis($h, 'pipeline-apply');
	have_secret($h->env_path('staging') . '/pipeline:discovery',
		'and the next apply gives it one, which is how it joins the set');
};

done_testing;
