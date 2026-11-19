#!/usr/bin/env perl
# Proves T508 for genesis new (D176): an environment is manual unless its
# file says it is not, so new writes the key only where it has something to
# say.  Asked for --no-manual it writes manual: false, which is what lets the
# environment deploy when its branch moves.  Told nothing it writes no key,
# and the environment waits for a person.
#
# Under the manual provider the key is refused whichever way it is written,
# so new writes none there, where it used to write a manual: true that the
# next command's load refused.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis qw/slurp/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# Runs genesis new for one environment on a branch of its own, and answers
# the file it wrote with what the run said.  Each row names an environment
# of its own: the file's harnesses share one vault, and new asks before it
# clears secrets a name already holds there.
sub new_env {
	my ($provider, $name, @flags) = @_;
	my $h = make_harness(envs => ['qa'], type => 'bosh', kit => 'omega-v2.7.0',
		provider => $provider);
	init_branch($h, 'qa');
	refresh($h, 'a');
	my $git = $h->git('a');
	$git->create_branch("add-$name", 'refs/remotes/origin/' . $h->control);
	stand_on($h, "add-$name");
	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'new', $name, @flags);
	my $file = $h->a . "/$name.yml";
	return ($h, (-f $file ? slurp($file) : ''), unfolded($out, $err), $exit);
}

subtest 'told nothing, new writes no key and the environment is manual' => sub {
	plan tests => 3;

	# A name the harness vault holds no secrets for, so new asks nothing.
	my ($h, $file, $said, $exit) = new_env('concourse', 'uat');
	is($exit, 0, 'genesis new succeeds') or diag($said);
	unlike($file, qr/^\s+manual:/m, 'the file carries no manual key');

	my ($out, $err) = run_genesis($h, {restore => 0}, 'pipeline-describe');
	like(unfolded($out, $err), qr/uat\b[^\n]*\(manual/, 'and the pipeline reads it as manual');
};

subtest '--no-manual writes manual: false' => sub {
	plan tests => 3;

	my ($h, $file, $said, $exit) = new_env('concourse', 'dev', '--no-manual');
	is($exit, 0, 'genesis new succeeds') or diag($said);
	like($file, qr/^\s+manual:\s+false$/m, 'the file says the environment need not wait');

	my ($out, $err) = run_genesis($h, {restore => 0}, 'pipeline-describe');
	like(unfolded($out, $err), qr/dev\b[^\n]*\(automatic/, 'and the pipeline reads it as automatic');
};

subtest '--manual says so outright' => sub {
	plan tests => 2;

	my ($h, $file, $said, $exit) = new_env('concourse', 'stg', '--manual');
	is($exit, 0, 'genesis new succeeds') or diag($said);
	like($file, qr/^\s+manual:\s+true$/m, 'the file carries manual: true');
};

subtest 'under the manual provider new writes no key, whatever it is told' => sub {
	plan tests => 4;

	my %name = ('--no-manual' => 'prod', '--manual' => 'ops');
	for my $flag ('--no-manual', '--manual') {
		my ($h, $file, $said, $exit) = new_env('manual', $name{$flag}, $flag);
		is($exit, 0, "genesis new $flag succeeds") or diag($said);
		unlike($file, qr/^\s+manual:/m, 'and writes no manual key, which the load would refuse');
	}
};

done_testing;
