#!/usr/bin/env perl
# Proves T82, the exodus pair read back from an ordinary delivery, and T83,
# the emergency hatch, where git.commit names the hand commit that ran while
# git.control_commit stays the marker's control commit, and where a branch
# with no marker records no control commit at all.  It carries the second
# clause of T78 as well, the source sweep that says no file under lib/ or
# bin/ spells the marker outside the builder, because this is the last task
# of the step to touch the files that spell it.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use File::Find;
use Test::More;

use Genesis;
use_ok 'Genesis::Env::DeploymentManager';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the pair a delivery leaves behind' => sub {
	plan tests => 4;

	# The delivery is written into copy A, because copy A is the copy this
	# row then stands on and reads, and a delivery left in copy B would
	# leave copy A's own branch standing at the markerless init commit.
	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	my $delivered = deliver($h, 'qa', control => $control, copy => 'a');

	stand_on($h, $h->slug('qa'));
	my $git = $h->git('a');
	my $context = Genesis::Env::DeploymentManager::_git_context($git);

	is($context->{branch}, $h->slug('qa'), 'the record names the branch');
	is($context->{commit}, $delivered,
		'git.commit is the deployment-branch commit the deploy stood on');
	is($context->{control_commit}, $control,
		'git.control_commit is the control commit the newest marker names');
	is($context->{control_commit}, harness_marker($h, $h->slug('qa')),
		"and agrees with the harness's own marker read");

	stand_on($h, $h->control);
};

subtest 'the emergency hatch keeps both hashes honest' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');
	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	deliver($h, 'qa', control => $control, copy => 'a');
	my $hand = hand_commit($h, $h->slug('qa'), copy => 'a',
		files   => {'qa.yml' => "---\nkit: dev\nhotfix: true\n"},
		message => 'raise the instance count for the incident',
	);

	stand_on($h, $h->slug('qa'));
	my $git = $h->git('a');
	my $context = Genesis::Env::DeploymentManager::_git_context($git);

	is($context->{commit}, $hand,
		'git.commit names the hand commit, which is what actually ran');
	is($context->{control_commit}, $control,
		'while git.control_commit stays the control commit beneath it');

	stand_on($h, $h->control);
};

subtest 'a branch with no marker records no control commit' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $init = init_branch($h, 'qa');

	stand_on($h, $h->slug('qa'));
	my $git = $h->git('a');
	my $context = Genesis::Env::DeploymentManager::_git_context($git);

	is($context->{commit}, $init, 'the pair still names what ran');
	ok(!exists $context->{control_commit},
		'and no control tip is recorded in place of a marker that is absent');

	stand_on($h, $h->control);
};

subtest 'the builder is the only site that spells the marker' => sub {
	plan tests => 2;

	# A comment that quotes the format is not a second speller.  Nothing
	# reads it, nothing renders from it, and a prose sentence naming the
	# string it is about is how the block beside the code explains itself.
	# What the row is after is a site that composes or matches the marker
	# for real, so the comment lines go before the match runs.
	#
	# The walk is anchored on the checkout root rather than on the working
	# directory, because a row above this one stands a copy on a branch and
	# the harness may leave the process somewhere else entirely.  no_chdir
	# keeps the full name openable, which is what find otherwise takes away
	# by stepping into each directory as it walks.
	my $top = $helper::TOPDIR;
	my (@read, @offenders);
	my $look = sub {
		my ($path) = @_;
		my $name = $path;
		$name =~ s{\A\Q$top\E/}{};
		return if $name eq 'lib/Genesis/CI/Marker.pm';
		push @read, $name;
		my $text = join('', grep {!/^\s*#/} split /^/, (slurp($path) // ''));
		push @offenders, $name if $text =~ /\[pipeline\]\s*control\\?\@/;
	};

	find({no_chdir => 1, wanted => sub {
		$look->($File::Find::name) if -f $File::Find::name && /\.pm$/;
	}}, "$top/lib");
	$look->("$top/bin/genesis");

	# Without this the row passes on a walk that read nothing at all, which
	# is the shape a sweep fails in rather than the shape it fails out of.
	cmp_ok(scalar @read, '>', 100,
		'the walk read the modules under lib/ and the genesis script');
	is_deeply(\@offenders, [],
		'no file under lib/ or bin/ spells the marker outside the builder');
};

done_testing;
