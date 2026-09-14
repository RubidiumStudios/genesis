#!/usr/bin/env perl
# Proves the pull request branch refusing to collide with a deployment
# branch, and the branch name being composed in one place with both
# baseline literals gone.
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
	my $branch = eval { $top->pr_branch_for('lab') };
	my $err = $@;

	is($branch, undef, 'the join does not answer');
	like($err, qr{pr-lab/bosh},
		'and the refusal names the branch it would have collided with');
};

subtest 'the two baseline literals are gone' => sub {
	plan tests => 3;

	my (@prefix_literals, @head_patterns, @prefix_readers);
	for my $file (modules_under_lib()) {
		my $source = slurp($file);
		push @prefix_literals, $file if $source =~ m{["']pr/\$};
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
