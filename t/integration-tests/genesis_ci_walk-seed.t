#!/usr/bin/env perl
# Proves T145 and T146: an unseeded branch is walked from E, its first
# delivery deletes init and carries a marker, and E is holdable like any
# other commit.
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

# The environment file a row commits by hand.  The harness writes the ones it
# seeds, and an environment introduced part way along control is written here
# in the same shape, because the walk reads the predecessor and the tracked
# files out of genesis.pipeline and a flat key says nothing to it.
sub env_file {
	my (%opts) = @_;
	my @lines = (
		'---', 'kit:', '  name:    dev', '  version: latest',
		'  features: []', 'genesis:', "  env: $opts{env}", '  pipeline:',
	);
	push @lines, "    prior_env: $opts{prior}" if $opts{prior};
	push @lines, '    track_additional_files:', '    - ops/shared.yml'
		if $opts{shared};
	push @lines, "leaf: $opts{leaf}" if defined $opts{leaf};
	return join("\n", @lines, '');
}

subtest 'the walk starts at E and the first delivery deletes init' => sub {
	# Six rather than five, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	plan tests => 6;

	my $h = make_harness(envs => ['lab'], kit => 'omega-v2.7.0');
	my $seed = $h->git('a')->sha($h->control);
	fixture_applied($h, control => $seed);
	fixture_pipeline_record($h, 'lab');
	init_branch($h, 'lab');
	deliver($h, 'lab', control => $seed);

	# qa is introduced on control and its branch is cut but never delivered to.
	my $e = commit_on_control($h,
		files   => {'qa.yml' => env_file(env => 'qa', prior => 'lab')},
		message => 'Add qa', push => 1);
	fixture_pipeline_record($h, 'qa');
	init_branch($h, 'qa');

	my $later = commit_on_control($h,
		files   => {'qa.yml' =>
			env_file(env => 'qa', prior => 'lab', leaf => 2)},
		message => 'Tune qa', push => 1);

	# lab is certified once, at the newest commit, so that nothing it has
	# left undeployed holds qa and each of qa's own commits is free to
	# travel.  A certification per commit would land three records inside
	# one second, which the audit keys on and so collapses into one.
	certify($h, 'lab', control_commit => $later);
	refresh($h, 'a');

	my (undef, undef, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($exit, 0, 'the run succeeded');

	my ($log) = run({dir => $h->a}, 'git', 'log', '--format=%H',
		'refs/remotes/origin/'.$h->slug('qa'));
	my @commits = grep {/\S/} split /\n/, $log;
	is(scalar(@commits), 3, 'the init commit plus two deliveries');

	my $first = $commits[-2];
	like(scalar(run({dir => $h->a}, 'git', 'log', '--format=%s', '-1', $first)),
		qr/\Qcontrol\E\@\Q@{[substr($e, 0, 7)]}\E/,
		'the first delivery names E and not the tip');

	my @files = @{tree_of($h->a, 'refs/remotes/origin/'.$h->slug('qa'))};
	ok(!(grep {$_ eq 'init'} @files), 'the first delivery deleted init');
	is(harness_marker($h, $h->slug('qa')), $later,
		'the branch ends at the newest due commit');
};

subtest 'the walk starts at E and reaches back no further' => sub {
	# Four rather than three, for the restoration assertion the run makes.
	plan tests => 4;

	my $h = make_harness(envs => ['lab'], kit => 'omega-v2.7.0');
	my $seed = $h->git('a')->sha($h->control);
	fixture_applied($h, control => $seed);
	fixture_pipeline_record($h, 'lab');
	init_branch($h, 'lab');
	deliver($h, 'lab', control => $seed);

	# A gated commit on the kit source, which is a file every environment's
	# propagation set carries, laid before qa existed on control at all.  The
	# gate is what makes the base observable: a commit from before E routes to
	# qa nowhere, since qa's own file is not in that commit's tree, but a gate
	# read over qa's range holds the very commit that introduced qa.  So a
	# walk that fell back to the whole of control delivers qa nothing.
	commit_on_control($h,
		files    => {'dev/notes.txt' => "a note beside the kit\n"},
		message  => 'Note something in the kit',
		trailers => {'Genesis-Stage' => 'schema change'},
		push     => 1);

	my $e = commit_on_control($h,
		files   => {'qa.yml' => env_file(env => 'qa', prior => 'lab')},
		message => 'Add qa', push => 1);
	fixture_pipeline_record($h, 'qa');
	init_branch($h, 'qa');

	# lab is certified at the newest commit, so nothing it has left
	# undeployed holds qa and qa's own commit is free to travel.
	certify($h, 'lab', control_commit => $e);
	refresh($h, 'a');

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');
	is($exit, 0, 'the run succeeded');
	is(harness_marker($h, $h->slug('qa')), $e,
		'the commit that introduced qa reached its branch');
	unlike($err, qr/gate: schema change/,
		'and no gate from before qa existed was read over its range');
};

subtest 'E is holdable, and its environment holds its own descendants' => sub {
	# Six rather than five, for the restoration assertion the run makes.
	plan tests => 6;

	my $h = make_harness(envs => ['lab'], kit => 'omega-v2.7.0',
		tracked => ['ops/shared.yml']);
	my $seed = $h->git('a')->sha($h->control);
	fixture_applied($h, control => $seed);
	fixture_pipeline_record($h, 'lab');
	init_branch($h, 'lab');
	deliver($h, 'lab', control => $seed);
	certify($h, 'lab', control_commit => $seed);

	# E touches a shared file lab has not deployed, and adds qa and prod.
	commit_on_control($h,
		files => {
			'ops/shared.yml' => "---\nshared: 3\n",
			'qa.yml'   => env_file(env => 'qa',   prior => 'lab', shared => 1),
			'prod.yml' => env_file(env => 'prod', prior => 'qa',  shared => 1),
		},
		message => 'Add qa and prod, bump shared ops', push => 1);
	fixture_pipeline_record($h, $_) for qw/qa prod/;
	init_branch($h, $_) for qw/qa prod/;
	refresh($h, 'a');

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	my @files = @{tree_of($h->a, 'refs/remotes/origin/'.$h->slug('qa'))};
	is(scalar(@files), 1, 'the branch holds one file');
	is($files[0], 'init', 'init is still on it');
	is(harness_marker($h, $h->slug('qa')), undef, 'no marker was written');
	like($err, qr/held, awaiting deployment \(lab at control\@[0-9a-f]+\)/,
		'qa names lab and the commit lab must certify');
	like($err, qr/held by .?qa.?, which has never certified a commit/,
		'prod is held because qa has certified nothing');
};

done_testing;
