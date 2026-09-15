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

# An assertion helper, beside the test that uses it.  The pattern takes the
# brackets bare or escaped, because a site that renders the marker writes it
# out as it will read on the commit while a site that matches it escapes the
# brackets for the regex engine, and the escaped form is the one that matters
# here: three of the four spellers this step retired were written that way,
# and a guard blind to that shape is blind to the likeliest next one.
#
# A comment that quotes the format is not a second speller.  Nothing reads
# it, nothing renders from it, and a prose sentence naming the string it is
# about is how a block beside the code explains itself.  What the row is
# after is a site that composes or matches the marker for real, so every
# comment comes out of the line before the match runs.
sub marker_spellers_in {
	my (@files) = @_;
	my $top = $ENV{GENESIS_TOPDIR};

	my @found;
	for my $file (@files) {
		my $short = $file;
		$short =~ s{^\Q$top\E/}{} if defined $top;
		next if $short eq 'lib/Genesis/CI/Marker.pm';

		open my $fh, '<', $file or die "cannot read $file: $!\n";
		my $n = 0;
		while (my $line = <$fh>) {
			$n++;
			push @found, "$short:$n"
				if strip_comment($line) =~ /\[?pipeline\\?\]\s*control\\?\@/;
		}
		close $fh;
	}
	return sort @found;
}

subtest 'the builder is the only site that spells the marker' => sub {
	plan tests => 1;

	# sweep_files is the suite's one tree reader.  It is anchored on the
	# checkout root rather than on the working directory, which matters
	# because the rows above this one stand a copy on a branch, it covers
	# every module and script under lib/ and every executable under bin/
	# rather than the two shapes a hand-rolled walk remembers, and it dies
	# on an empty walk, so the row cannot pass on having read nothing.
	my @found = marker_spellers_in(sweep_files());
	is_deeply(\@found, [],
		'no file under lib/ or bin/ spells the marker outside the builder')
		or diag(join("\n", map {"  $_"} @found));
};

done_testing;
