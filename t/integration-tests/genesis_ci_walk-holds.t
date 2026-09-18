#!/usr/bin/env perl
# Proves T139, T155, T163, T168, and T178: an ancestor's undeployed set
# holds a commit and everything after it, an ancestor that has certified
# nothing holds everything below it, the three hold reasons read in the
# exact forms Publish and outcomes fixes, and the words entry point appear
# nowhere in the output.
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

# The environment file a row commits by hand, written here for the same
# reason the triggering-path rows write one: the harness's own writer commits
# without publishing, and a control branch ahead of the remote meets the
# pre-flight's refusal before the walk ever runs.  Every file it writes
# carries the shared ops file, because a row that changes a file no
# environment tracks changes nothing either environment's set holds.
sub env_file {
	my (%opts) = @_;
	my @lines = (
		'---', 'kit:', '  name:    dev', '  version: latest',
		'  features: []', 'genesis:', "  env: $opts{env}", '  pipeline:',
	);
	push @lines, "    prior_env: $opts{prior}" if $opts{prior};
	push @lines, '    manual: true' if $opts{manual};
	push @lines, '    require_pr: true' if $opts{require_pr};
	push @lines, '    track_additional_files:', '    - ops/shared.yml';
	push @lines, "leaf: $opts{leaf}" if defined $opts{leaf};
	return join("\n", @lines, '');
}

# The two-stage pipeline every row here stands on.  lab comes first and qa
# follows it, both track the shared ops file, and both branches are delivered
# and certified at the seeding commit, so the only commits the walk finds due
# are the ones the row makes.
sub chained_harness {
	my (%opts) = @_;
	return ready_harness(
		kit     => 'omega-v2.7.0',
		chained => 1,
		tracked => ['ops/shared.yml'],
		%opts,
	);
}

subtest 'a hold stops the delivery and holds everything after it' => sub {
	# Five rather than four, because run_genesis asserts the restoration of
	# the working state in its own words and that assertion is counted here.
	plan tests => 5;

	my $h = chained_harness();
	my $first = commit_on_control($h,
		files   => {'qa.yml' => env_file(env => 'qa', prior => 'lab', leaf => 1)},
		message => 'Tune qa first',
		push    => 1,
	);
	certify($h, 'lab', control_commit => $first);

	my $second = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nshared: 2\n"},
		message => 'Bump shared ops',
		push    => 1,
	);
	my $third = commit_on_control($h,
		files   => {'qa.yml' => env_file(env => 'qa', prior => 'lab', leaf => 3)},
		message => 'Tune qa third',
		push    => 1,
	);

	my ($out, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	is(harness_marker($h, $h->slug('qa')), $first,
		'only the first commit was delivered');
	like($err, qr/control\@\Q@{[substr($second, 0, 7)]}\E[^\n]*\n\s*H held by lab \(ops\/shared\.yml\)/,
		'the second is held');
	like($err, qr/control\@\Q@{[substr($third, 0, 7)]}\E[^\n]*\n\s*H held behind control\@\Q@{[substr($second, 0, 7)]}\E/,
		'the third is held behind the second');
	unlike("$out$err", qr/entry point/i, 'the retired term appears nowhere');
};

subtest 'an ancestor that has certified nothing holds everything' => sub {
	plan tests => 4;

	# lab's branch already holds the shared files, and lab has never
	# deployed, so its undeployed set is its whole propagation set.
	my $h = chained_harness(certified => ['qa']);

	my $due = commit_on_control($h,
		files   => {'qa.yml' => env_file(env => 'qa', prior => 'lab', leaf => 9)},
		message => 'Tune qa',
		push    => 1,
	);

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	isnt(harness_marker($h, $h->slug('qa')), $due,
		'qa received nothing while lab has certified nothing');
	like($err, qr/held by .?lab.?, which has never certified a commit/,
		'the never-certified form is exact');
	like($err, qr/held, awaiting deployment \(lab at control\@[0-9a-f]+\)/,
		'the environment qualifier names lab and the commit');
};

subtest 'a held pull request environment reads held and not idempotent' => sub {
	plan tests => 4;

	# qa delivers into a pull request and lab has certified nothing, so
	# everything qa would take is held and its pending list is empty.  The
	# arm answers idempotent for any environment with nothing due, and a
	# word written onto the record from there is the first thing the
	# report's own settling reads, which takes the qualifier with it.
	my $h = chained_harness(certified => ['qa']);

	my $due = commit_on_control($h,
		files   => {'qa.yml' => env_file(env => 'qa', prior => 'lab',
			require_pr => 1, leaf => 11)},
		message => 'Tune qa behind an ancestor that has deployed nothing',
		push    => 1,
	);

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');
	my $said = unfolded($err);

	isnt(harness_marker($h, $h->pr_branch('qa')), $due,
		'qa received nothing, because everything it would take is held');
	unlike($said, qr/qa:\s*idempotent/,
		'and it is not recorded as an environment with nothing to do');
	like($said, qr/held, awaiting deployment \(lab at control\@[0-9a-f]+\)/,
		'the qualifier names what it is waiting for');
};

subtest 'an ancestor with no control_commit in its record holds too' => sub {
	plan tests => 4;

	my $h = chained_harness();
	# A record that exists and is readable but carries no git.control_commit.
	certify($h, 'lab', commit => 'deadbeef', control_commit => '');
	my $due = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nshared: 5\n"},
		message => 'Bump shared ops',
		push    => 1,
	);

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	like($err, qr/held, awaiting pipeline-apply/,
		'lab records awaiting pipeline-apply');
	isnt(harness_marker($h, $h->slug('qa')), $due,
		'qa is held behind it');
	# Nothing was set to control's tip in the missing commit's place, so lab
	# received nothing rather than being read as deployed at the tip.
	unlike($err, qr/\blab: (?:delivered|would deliver)\b/,
		'lab was delivered nothing in its place');
};

subtest 'an environment with no branch anywhere waits for the apply' => sub {
	# Two assertions and one restoration for each of the two runs.
	plan tests => 6;

	# The branch goes from R, from copy A's own refs, and from the
	# remote-tracking ref that would put it back, which leaves the
	# repository as genesis pipeline-apply has not reached it.  Nothing cut
	# a branch for lab, so there is no ref to read a marker off and nothing
	# to deliver onto.
	my $unbranch = sub {
		my ($h) = @_;
		my $branch = $h->slug('lab');
		delete_on_r($h, $branch);
		delete_local($h, 'a', $branch);
		run({dir => $h->a, onfailure => "Failed to drop the tracking ref"},
			'git', 'update-ref', '-d', "refs/remotes/origin/$branch");
		return $branch;
	};

	my $h = chained_harness(envs => ['lab']);
	$unbranch->($h);
	commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nshared: 9\n"},
		message => 'Bump shared ops',
		push    => 1,
	);

	my (undef, $err) = run_genesis($h, {answers => ['y']}, 'propagate');

	like($err, qr/held, awaiting pipeline-apply/,
		'the run says the environment waits for the apply that cuts it');
	unlike($err, qr/\blab: (?:delivered|would deliver)\b/,
		'and nothing was delivered to an environment with no branch');

	# D56 ranks a standing hold ahead of the apply, and an environment can
	# be in both states at once, so the row that reads the branch has to
	# read the hold first.  The run would otherwise send an operator to a
	# command that changes nothing while the hold still stands.
	my $held = chained_harness(envs => ['lab']);
	$unbranch->($held);
	fixture_hold($held, 'lab', reason => 'vsphere maintenance');
	commit_on_control($held,
		files   => {'ops/shared.yml' => "---\nshared: 9\n"},
		message => 'Bump shared ops',
		push    => 1,
	);

	my (undef, $held_err) = run_genesis($held, {answers => ['y']}, 'propagate');

	like($held_err, qr/held, needs clearing \(vsphere maintenance\)/,
		'a hold standing against it outranks the apply');
	unlike($held_err, qr/awaiting pipeline-apply/,
		'and the apply is not offered while the hold stands');
};

subtest 'a certified commit the repository lacks stops the run' => sub {
	plan tests => 4;

	my $h = chained_harness();
	# A record naming a commit no repository here holds, which is what a
	# rewritten control or a clone that never fetched the certified commit
	# leaves behind.  The range the hold is read over cannot resolve, and an
	# unreadable range is not an ancestor with nothing undeployed.
	certify($h, 'lab', commit => 'deadbeef',
		control_commit => '0' x 39 . '1');
	my $due = commit_on_control($h,
		files   => {'ops/shared.yml' => "---\nshared: 8\n"},
		message => 'Bump shared ops',
		push    => 1,
	);

	my (undef, $err, $exit) = run_genesis($h, {answers => ['y']}, 'propagate');

	isnt($exit, 0, 'the run refused rather than delivering');
	like($err, qr/0{39}1/, 'the refusal names the commit that would not resolve');
	isnt(harness_marker($h, $h->slug('qa')), $due,
		'nothing was delivered to qa behind the unreadable hold');
};

subtest 'the hold reason carries the ancestor\'s own state' => sub {
	# Six: three rows, and one restoration assertion for each of the three
	# runs the row makes.
	plan tests => 6;

	# The manual harness is run out before the automated one is built,
	# because two harnesses share one vault mount and one set of environment
	# names, so the second one to attach owns every record the first wrote.
	my $manual = chained_harness();
	commit_on_control($manual,
		files   => {'ops/shared.yml' => "---\nshared: 7\n"},
		message => 'Bump shared ops',
		push    => 1,
	);
	my (undef, $manual_err) = run_genesis($manual, {answers => ['y']}, 'propagate');
	like($manual_err,
		qr/held by .?lab.? \(.?ops\/shared\.yml.?\), lab awaiting deployment/,
		'under the manual provider the ancestor awaits deployment');

	my (undef, $dry_err) = run_genesis($manual, 'propagate', '--dry-run');
	like($dry_err,
		qr/held by .?lab.? \(.?ops\/shared\.yml.?\), lab awaiting deployment/,
		'--dry-run prints the same words');

	# The run reaches the walk as the pipeline's own job does, because the
	# gate that stands in front of a hand run under an automated provider
	# wants a controlling terminal for the acknowledgement and a spawned
	# command has none.
	my $auto = chained_harness(provider => 'concourse');
	commit_on_control($auto,
		files   => {'lab.yml' => env_file(env => 'lab', manual => 1)},
		message => 'Let lab wait for its trigger',
		push    => 1,
	);
	commit_on_control($auto,
		files   => {'ops/shared.yml' => "---\nshared: 7\n"},
		message => 'Bump shared ops',
		push    => 1,
	);
	my (undef, $auto_err) = run_genesis($auto,
		{pipeline_task => 'propagate'}, 'propagate');
	like($auto_err,
		qr/held by .?lab.? \(.?ops\/shared\.yml.?\), lab awaiting its trigger/,
		'an automated provider with genesis.pipeline.manual awaits a trigger');
};

done_testing;
