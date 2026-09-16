#!/usr/bin/env perl
# Proves T154, T164, T167, and T177: a broken environment ends itself and
# the run walks on, every environment in scope still ends with an outcome,
# a partial delivery is reset to T, and a blueprint error records failed.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# The environment file a row commits by hand, written here for the reason the
# hold rows write one: the harness's own writer commits without publishing,
# so a row that wants a file on control publishes the commit it rides in on.
# The body is the block mapping write_env_file lays down, because
# Genesis::Env::is_valid_env_file reads the kit's name and version out of a
# block mapping and a flow mapping of the same two keys leaves the repository
# with no environments at all.
sub env_file {
	my (%opts) = @_;
	my @lines = (
		'---', 'kit:',
		sprintf('  name:    %s', $opts{kit} // 'dev'),
		sprintf('  version: %s', $opts{version} // 'latest'),
		'  features: []', 'genesis:', "  env: $opts{env}",
	);
	push @lines, '  kit_blueprint_fails: 1' if $opts{blueprint_fails};
	push @lines, '  pipeline:', "    prior_env: $opts{prior}"
		if $opts{prior};
	push @lines, "n: $opts{n}" if defined $opts{n};
	return join("\n", @lines, '');
}

# The three-stage pipeline the ordering rows stand on.  lab comes first, qa
# follows it, and prod follows qa, so an environment that ends in a failure
# has one environment walked ahead of it and one below it that its silence
# holds.
sub chained_three {
	my (%opts) = @_;
	return ready_harness(
		envs    => ['lab', 'qa', 'prod'],
		kit     => 'omega-v2.7.0',
		chained => 1,
		%opts,
	);
}

subtest 'a broken environment ends itself and the run walks on' => sub {
	# Five rather than four, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	# Every subtest in this file is counted the same way.
	plan tests => 5;

	my $h = chained_three();

	# qa's file names a kit this repository does not hold, which is a file
	# Genesis::Env::is_valid_env_file still reads as an environment and
	# Genesis::Top::load_env cannot load.  That is the environment-local
	# failure of D60, and it is the one the run has to walk past.
	my $due = commit_on_control($h,
		files => {
			'lab.yml'  => env_file(env => 'lab', n => 1),
			'qa.yml'   => env_file(env => 'qa', prior => 'lab',
			                       kit => 'ghost', version => '1.0.0'),
			'prod.yml' => env_file(env => 'prod', prior => 'qa', n => 1),
		},
		message => 'Tune all three', push => 1);

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	like($err, qr/qa.*failed/s, 'qa records failed with its error');
	is(harness_marker($h, $h->slug('lab')), $due,
		'lab was walked before it');
	like($err, qr/^\s*prod\b/m, 'prod was walked after it');
	like($err, qr/held by .?qa.?, which could not be read/,
		'prod is held because qa answered nothing');
};

subtest 'a partial delivery is reset and the run continues' => sub {
	plan tests => 6;

	my $h = chained_three();
	my @due;
	for my $n (1, 2) {
		push @due, commit_on_control($h,
			files   => {'qa.yml' => env_file(env => 'qa', prior => 'lab',
			                                 n => $n)},
			message => "Tune qa $n", push => 1);
	}

	my $git = fault_git($h);
	fail_on($git, 'commit', 2, message => 'qa blew up mid-delivery');

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');

	# T is R's own tip, and the run publishes nothing for an environment it
	# refuses, so a branch that is back at T reads the same marker in copy A
	# as it does in R.  Both are read, because the branch in copy A is one
	# the pre-flight cut this run and a marker read off R alone would stand
	# still whether the reset happened or not.
	is(harness_marker($h, $h->slug('qa'), copy => 'a'),
		harness_marker($h, $h->slug('qa'), copy => 'r'),
		'qa was reset to T, so no partial delivery survived');
	isnt(harness_marker($h, $h->slug('qa'), copy => 'a'), $due[0],
		'the first delivery, which did land, went with it');
	like($err, qr/qa.*failed/s, 'qa records failed');
	like($err, qr/^\s*prod\b/m, 'the run walked on to prod');
	isnt($exit, 0, 'the run reports that it was partial');
};

subtest 'every environment in scope ends with an outcome' => sub {
	plan tests => 5;

	my $h = chained_three();
	commit_on_control($h,
		files => {
			'lab.yml'  => env_file(env => 'lab', n => 5),
			'qa.yml'   => env_file(env => 'qa', prior => 'lab',
			                       kit => 'ghost', version => '1.0.0'),
			'prod.yml' => env_file(env => 'prod', prior => 'qa', n => 5),
		},
		message => 'Tune all three', push => 1);

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	for my $env (qw/lab qa prod/) {
		like($err, qr/^\s*\Q$env\E\b/m, "$env is in the report");
	}
	# The fixed outcome words of D96 arrive with the renderer, so what is
	# asserted here is that none of the three falls silent: every one of them
	# carries a line saying what became of it.
	my @outcome_lines = grep {
		/^\s*(?:lab|qa|prod):\s.*(?:delivered|would deliver|nothing due|failed|not attempted|held|awaiting)/
	} split /\n/, $err;
	ok(scalar(@outcome_lines) >= 3, 'each of the three carries an outcome');
};

subtest 'a blueprint error records failed and the run goes on' => sub {
	plan tests => 5;

	# The suite's broken-blueprint kit refuses any environment whose file
	# sets genesis.kit_blueprint_fails, so qa's set cannot be enumerated at
	# the commit that sets it while lab's renders as it always did.  That is
	# D78's blueprint error, read on control while the run enumerates the
	# repository-side fragments.
	my $h = ready_harness(envs => ['lab', 'qa'], kit => 'broken-blueprint');
	commit_on_control($h,
		files => {
			'lab.yml' => env_file(env => 'lab', n => 8),
			'qa.yml'  => env_file(env => 'qa', blueprint_fails => 1),
		},
		message => 'Break the blueprint for qa', push => 1);

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	like($err, qr/qa.*failed/s, 'qa records failed');
	like($err, qr/blueprint/i, 'the blueprint\'s own error is carried');
	like($err, qr/^\s*lab: (?:delivered|would deliver)/m,
		'the run went on and delivered to lab');
	unlike($err, qr/not yet/i, 'no outcome word reading not yet appears');
};

done_testing;
