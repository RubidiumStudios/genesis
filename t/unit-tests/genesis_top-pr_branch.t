#!/usr/bin/env perl
# Proves T47, the pull request branch refusing to collide with a
# deployment branch, and T49, the branch name being composed in one place
# with both baseline literals gone.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit;
use Genesis::Top;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

sub modules_under_lib {
	my @found;
	my @queue = ('lib');
	while (my $dir = shift @queue) {
		opendir(my $dh, $dir) or next;
		for my $entry (sort readdir($dh)) {
			next if $entry eq '.' or $entry eq '..';
			my $path = "$dir/$entry";
			if (-d $path) {
				push @queue, $path;
			} elsif ($path =~ m{\.pm$}) {
				push @found, $path;
			}
		}
		closedir($dh);
	}
	return @found;
}

subtest 'the default prefix cannot collide' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['lab', 'pr-lab'], vault => 0);
	my $top = Genesis::Top->new($h->a, no_vault => 1);

	is($top->pr_branch_for('lab'), 'pr/lab/bosh',
		'the default prefix composes pr/lab/bosh');
	isnt($top->pr_branch_for('lab'), $top->branch_for('pr-lab'),
		'which is nothing any deployment branch claims');
};

subtest 'a prefix that collides is refused by name' => sub {
	plan tests => 3;

	my $h = make_harness(
		envs => ['lab', 'pr-lab'], pr_prefix => 'pr-', vault => 0,
	);
	my $top = Genesis::Top->new($h->a, no_vault => 1);

	is($top->branch_for('pr-lab'), 'pr-lab/bosh',
		"the environment pr-lab owns the branch the join would take");

	local $ENV{GENESIS_IGNORE_EVAL} = '';

	# The refusal is wrapped for the terminal before it is raised, so
	# reading the message back would rest on where a line break happened to
	# land.  The arguments are read as the refusal composed them instead.
	my @raised;
	no warnings 'redefine';
	local *Genesis::Top::bail = sub {push @raised, [@_]; die "refused\n"};

	my $branch = eval { $top->pr_branch_for('lab') };

	is($branch, undef, 'the join does not answer');
	ok(scalar(grep {!ref($_) && $_ eq 'pr-lab/bosh'} @{$raised[0] || []}),
		'and the refusal names the branch it would have collided with')
		or diag('the refusal was raised with: '
			. join(', ', map {ref($_) ? ref($_) : $_} @{$raised[0] || []}));
};

subtest 'the refusal exits CONFIG' => sub {
	plan tests => 1;

	my $h = make_harness(
		envs => ['lab', 'pr-lab'], pr_prefix => 'pr-', vault => 0,
	);

	# An exit code only exists in a process that exits, and bail dies
	# instead of exiting whenever it is reached from inside an eval, which
	# a test file always is.  So the refusal is provoked in a process of
	# its own and its status is read back from there.
	my $cmd = sprintf(
		q{%s -I%s/lib -MGenesis::Top -e '}.
		q{Genesis::Top->new($ARGV[0], no_vault => 1)->pr_branch_for(q{lab})}.
		q{' %s},
		$^X, $helper::TOPDIR, $h->a
	);
	run_fails($cmd, Genesis::Exit::CONFIG,
		'the refusal exits Genesis::Exit::CONFIG');
};

subtest 'the two baseline literals are gone' => sub {
	plan tests => 3;

	my (@prefix_literals, @head_patterns, @prefix_readers);
	for my $file (modules_under_lib()) {
		my $source = slurp($file);
		# A join puts something after the prefix, which is an interpolated
		# variable, a format placeholder, or a closing delimiter and a
		# concatenation.  The delimiter is whichever one the quote opened
		# on, so q{pr/} and q(pr/) and q[pr/] are caught beside the two
		# ordinary quotes.  A declared default closes on the slash and is
		# followed by a comma or a semicolon, and prose about the name
		# carries an ordinary word after it, so the sweep passes over the
		# constant, the schema entry, and the comments, and catches only
		# the compositions.  It does not ask what comes before the prefix,
		# because a hand-composed name can sit anywhere in a string.
		push @prefix_literals, $file
			if $source =~ m{pr/(?: \$ | % | ["'\}\)\]>]\s*\. )}x;
		push @head_patterns,   $file if $source =~ m{\^propagate/};
		push @prefix_readers,  $file
			if $file ne 'lib/Genesis/Top.pm'
			&& $source =~ m{pipeline\.source_control\.pr_prefix};
	}

	is_deeply(\@prefix_literals, [],
		'no module builds a pull request branch from a pr/ literal')
		or diag("still building the name by hand: @prefix_literals");
	is_deeply(\@head_patterns, [],
		'no module matches pull request heads on propagate/')
		or diag("still matching the old head: @head_patterns");
	is_deeply(\@prefix_readers, [],
		'pr_prefix is read in one place')
		or diag("open-coded prefix read: @prefix_readers");
};

done_testing;
