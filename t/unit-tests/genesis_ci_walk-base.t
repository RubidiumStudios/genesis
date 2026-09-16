#!/usr/bin/env perl
# Proves T145 at the two subs that decide it: control names the commit that
# introduced an environment, and an init-only branch is walked from that
# commit rather than from the whole of control.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::CI::Walk;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# One environment file, in the shape the harness writes the ones it seeds.
sub env_file {
	my (%opts) = @_;
	my @lines = (
		'---', 'kit:', '  name:    dev', '  version: latest',
		'  features: []', 'genesis:', "  env: $opts{env}", '  pipeline:',
		"    prior_env: $opts{prior}",
	);
	push @lines, "leaf: $opts{leaf}" if defined $opts{leaf};
	return join("\n", @lines, '');
}

# The repository every row below reads through.  lab and qa stand on the
# seeding commit, which is control's root, and prod is introduced part way
# along, so the rows have both an environment whose E is the root and one
# whose E has a commit before it.  lab's branch is delivered to and the other
# two are cut and left alone, which is the init-only shape D61 is about.
sub fixture {
	my $h = make_harness(envs => ['lab', 'qa'], root => '',
		kit => 'omega-v2.7.0');
	my $git  = Service::Git->new($h->a);
	my $seed = $git->sha($h->control);

	init_branch($h, $_) for qw/lab qa/;
	deliver($h, 'lab', control => $seed);

	my $tune = commit_on_control($h,
		files   => {'lab.yml' => slurp($h->a . '/lab.yml') . "# tuned\n"},
		message => 'Tune lab', push => 1);
	my $e = commit_on_control($h,
		files   => {'prod.yml' => env_file(env => 'prod', prior => 'qa')},
		message => 'Add prod', push => 1);
	init_branch($h, 'prod');
	my $later = commit_on_control($h,
		files   => {'prod.yml' =>
			env_file(env => 'prod', prior => 'qa', leaf => 2)},
		message => 'Tune prod', push => 1);
	refresh($h, 'a');

	return ($h, $git, {
		seed => $seed, tune => $tune, e => $e, later => $later,
		control => $git->sha($h->control),
	});
}

# The same repository with prod's file moved under a directory after it was
# added, which is what a repository that restructures its deployment root
# leaves behind.  The move carries the content across unchanged, so git's
# similarity heuristic has the easiest case there is to see.
sub moved_fixture {
	my $h = make_harness(envs => ['lab'], root => '', kit => 'omega-v2.7.0');
	my $git  = Service::Git->new($h->a);
	my $body = env_file(env => 'prod', prior => 'lab');

	my $add = commit_on_control($h,
		files   => {'prod.yml' => $body},
		message => 'Add prod', push => 1);
	my $moved = commit_on_control($h,
		files   => {'prod.yml' => undef, 'deployments/prod.yml' => $body},
		message => 'Move the deployments under a root', push => 1);
	my $tuned = commit_on_control($h,
		files   => {'deployments/prod.yml' =>
			env_file(env => 'prod', prior => 'lab', leaf => 2)},
		message => 'Tune prod', push => 1);
	refresh($h, 'a');

	return ($h, $git, {add => $add, moved => $moved, tuned => $tuned,
		control => $git->sha($h->control)});
}

# A repository that retired an environment and brought it back, which is the
# shape the oldest-add rule exists for.
sub readd_fixture {
	my $h = make_harness(envs => ['lab'], root => '', kit => 'omega-v2.7.0');
	my $git  = Service::Git->new($h->a);
	my $body = env_file(env => 'prod', prior => 'lab');

	my $first = commit_on_control($h,
		files   => {'prod.yml' => $body},
		message => 'Add prod', push => 1);
	commit_on_control($h,
		files   => {'prod.yml' => undef},
		message => 'Retire prod', push => 1);
	my $again = commit_on_control($h,
		files   => {'prod.yml' => $body},
		message => 'Bring prod back', push => 1);
	refresh($h, 'a');

	return ($h, $git, {first => $first, again => $again,
		control => $git->sha($h->control)});
}

# The unseeded shape again, this time under a deployment root, so a row can
# hand walk_base the prefixed path plan hands it and read the same answer.
sub rooted_fixture {
	my $h = make_harness(envs => ['lab', 'qa'], root => 'deployments',
		kit => 'omega-v2.7.0');
	my $git = Service::Git->new($h->a);

	my $tune = commit_on_control($h,
		files   => {'deployments/lab.yml' =>
			slurp($h->a . '/deployments/lab.yml') . "# tuned\n"},
		message => 'Tune lab', push => 1);
	my $e = commit_on_control($h,
		files   => {'deployments/prod.yml' =>
			env_file(env => 'prod', prior => 'qa')},
		message => 'Add prod', push => 1);
	init_branch($h, 'prod');
	refresh($h, 'a');

	return ($h, $git, {tune => $tune, e => $e,
		control => $git->sha($h->control)});
}

subtest 'control names the commit that introduced an environment' => sub {
	plan tests => 3;

	my ($h, $git, $at) = fixture();

	is(Genesis::CI::Walk::introducing_commit($git, $at->{control}, 'prod.yml'),
		$at->{e}, 'the add is E and not the later change to the same file');
	is(Genesis::CI::Walk::introducing_commit($git, $at->{control}, 'lab.yml'),
		$at->{seed}, 'an environment seeded with the repository names its root');
	is(Genesis::CI::Walk::introducing_commit($git, $at->{control}, 'nope.yml'),
		undef, 'a file control never carried has no introducing commit');
};

subtest 'a moved environment file still names its original add' => sub {
	plan tests => 2;

	my ($h, $git, $at) = moved_fixture();

	is(Genesis::CI::Walk::introducing_commit($git, $at->{control},
		'deployments/prod.yml'), $at->{add},
		'the introduction is the first add and not the restructure');
	isnt(Genesis::CI::Walk::introducing_commit($git, $at->{control},
		'deployments/prod.yml'), $at->{moved},
		'so no routing commit between the two falls outside the walk');
};

subtest 'a file added, removed, and added again names the first add' => sub {
	plan tests => 2;

	my ($h, $git, $at) = readd_fixture();

	is(Genesis::CI::Walk::introducing_commit($git, $at->{control}, 'prod.yml'),
		$at->{first},
		'the environment belongs to control from the oldest add onward');
	isnt(Genesis::CI::Walk::introducing_commit($git, $at->{control}, 'prod.yml'),
		$at->{again}, 'and not from the one that brought it back');
};

subtest 'a branch with a marker is walked from that marker' => sub {
	plan tests => 2;

	my ($h, $git, $at) = fixture();

	my ($base, $state) = Genesis::CI::Walk::walk_base(
		git      => $git,
		ref      => 'refs/remotes/origin/' . $h->slug('lab'),
		control  => $at->{control},
		env_file => 'lab.yml',
	);
	is($base, $at->{seed}, 'the base is the newest marker the branch carries');
	is($state, 'seeded', 'and the branch reads as seeded');
};

subtest 'an init-only branch is walked from the commit before E' => sub {
	plan tests => 2;

	my ($h, $git, $at) = fixture();

	# The commit before E, so that E itself is the first commit the walk
	# considers and is holdable like any other.
	my ($base, $state) = Genesis::CI::Walk::walk_base(
		git      => $git,
		ref      => 'refs/remotes/origin/' . $h->slug('prod'),
		control  => $at->{control},
		env_file => 'prod.yml',
	);
	is($base, $at->{tune}, 'the base is the commit before the one that added prod');
	is($state, 'unseeded', 'and the branch reads as unseeded');
};

subtest 'an environment introduced at the root is walked from nothing' => sub {
	plan tests => 2;

	my ($h, $git, $at) = fixture();

	# There is no commit before control's root, so the base is undefined and
	# the walk reads the whole of control, which begins at E all the same.
	my ($base, $state) = Genesis::CI::Walk::walk_base(
		git      => $git,
		ref      => 'refs/remotes/origin/' . $h->slug('qa'),
		control  => $at->{control},
		env_file => 'qa.yml',
	);
	is($base, undef, 'a root commit has no parent to stand the walk on');
	is($state, 'unseeded', 'and the branch still reads as unseeded');
};

subtest 'a deployment root changes no answer the base rests on' => sub {
	plan tests => 2;

	my ($h, $git, $at) = rooted_fixture();

	# plan hands walk_base the path prefixed with the deployment root,
	# because the environment names its file relative to that root and every
	# reading here is made through the git root.
	my ($base, $state) = Genesis::CI::Walk::walk_base(
		git      => $git,
		ref      => 'refs/remotes/origin/' . $h->slug('prod'),
		control  => $at->{control},
		env_file => 'deployments/prod.yml',
	);
	is($base, $at->{tune},
		'the base is the commit before the one that added prod, as bare');
	is($state, 'unseeded', 'and the branch reads as unseeded');
};

done_testing;
