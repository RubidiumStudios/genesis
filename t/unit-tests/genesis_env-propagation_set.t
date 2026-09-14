#!/usr/bin/env perl
# Proves T53, the propagation set gaining its eighth kind, T54, the
# triggering split with its two control-only exclusions, and T313, a
# tracked extra path landing in the set in one form.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Cwd ();
use Genesis;
use Genesis::Top;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

sub in_set {
	my ($path, @set) = @_;
	return scalar(grep {$_ eq $path} @set);
}

# The product names the kit source as a directory, because what it hands git
# is a pathspec, and the harness names the files a tree actually holds, so the
# two are compared as the tracked paths each of them covers.  A pathspec entry
# nothing tracks, such as a fragment the blueprint names before anybody wrote
# it, covers nothing and drops out of both sides.
sub covered_paths {
	my ($dir, @pathspec) = @_;

	my ($listing) = run({dir => $dir},
		'git', 'ls-tree', '-r', '--name-only', 'HEAD');
	my @tracked = split /\n/, ($listing // '');

	my %covered;
	for my $entry (@pathspec) {
		if ($entry =~ m{/$}) {
			$covered{$_} = 1 for grep {index($_, $entry) == 0} @tracked;
		} else {
			$covered{$entry} = 1 if grep {$_ eq $entry} @tracked;
		}
	}
	return sort keys %covered;
}

subtest 'the embedded genesis is the eighth kind and it triggers' => sub {
	plan tests => 4;

	my $h = make_harness(
		envs  => ['qa'], type => 'bosh',
		kit   => 't/src/ops-blueprint', embed => 1,
	);
	commit_on_control($h,
		files   => {'ops/extra.yml' => "---\nextra: fragment\n"},
		message => 'add the fragment the blueprint names');
	my $top = Genesis::Top->new($h->a);
	my $env = $top->load_env('qa');

	ok(in_set('.genesis/bin/genesis', $env->propagation_files),
		'the embedded genesis is in the set');
	ok(in_set('.genesis/bin/genesis', $env->propagation_files(triggering => 1)),
		'and it is triggering, because a genesis version changes rendering');
	ok(!in_set('.genesis/bin/genesis', $env->propagation_files(triggering => 0)),
		'so it is not among the non-triggering paths');

	is_deeply([covered_paths($h->a, $env->propagation_files)],
		[propagation_set($h, 'qa')],
		'and the harness and the product cover the same tracked paths');
};

subtest 'the file reaches a deployment branch' => sub {
	plan tests => 1;

	my $h = make_harness(
		envs  => ['qa'], type => 'bosh',
		kit   => 't/src/ops-blueprint', embed => 1,
	);
	my $control = commit_on_control($h,
		files   => {'ops/extra.yml' => "---\nextra: fragment\n"},
		message => 'publish', push => 1);
	init_branch($h, 'qa');
	deliver($h, 'qa', control => $control);

	# The delivery is written and pushed from copy B, so copy A's
	# remote-tracking ref still names the init commit until it is fetched.
	refresh($h, 'a', $h->slug('qa'));
	my $tree = tree_of($h->a, 'origin/' . $h->slug('qa'));
	ok(in_set('.genesis/bin/genesis', @$tree),
		'the delivered branch carries the embedded genesis, where today it carries none');
};

subtest 'the set says which paths do not mean deploy me' => sub {
	plan tests => 8;

	my $h = make_harness(envs => ['qa'], type => 'bosh', kit => 't/src/ops-blueprint');
	# write_env_file renders a hash of scalars and flat lists and no deeper,
	# and a reaction is a list of maps, so this one file is written by hand.
	put_file($h->a . '/qa.yml', <<'EOF');
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env: qa
  reactions:
    post-deploy:
      - script: notify
EOF
	put_file($h->a . '/bin/notify', "#!/bin/sh\nexit 0\n");
	run({dir => $h->a}, 'git', 'add', '-A');
	run({dir => $h->a, onfailure => 'Failed to declare the reaction'},
		'git', 'commit', '-q', '-m', 'declare a post-deploy reaction');

	my $top = Genesis::Top->new($h->a);
	my $env = $top->load_env('qa');

	# Each of the two non-triggering kinds is read from both sides, because
	# a sub that ignored the option and handed the whole set back would
	# satisfy either half on its own.
	my @quiet = $env->propagation_files(triggering => 0);
	my @loud  = $env->propagation_files(triggering => 1);

	ok(in_set('.genesis/config', @quiet),
		'.genesis/config is non-triggering, since nothing in it reaches the manifest');
	ok(!in_set('.genesis/config', @loud),
		'so it is not among the triggering paths');

	ok(in_set('bin/notify', @quiet),
		'a reaction script is non-triggering too, taking effect at the next deploy');
	ok(!in_set('bin/notify', @loud),
		'and it is not among the triggering paths either');

	ok(in_set('qa.yml', @loud),
		'the environment file hierarchy is triggering');
	ok(!in_set('qa.yml', @quiet),
		'and it is not among the non-triggering paths');

	my @all = $env->propagation_files;
	ok(!in_set('.genesis/pipeline-overrides-manual.yml', @all),
		'the pipeline overrides file is control-only and never in the set');
	ok(!scalar(grep {m{^\.genesis/manifests/}} @all),
		'and .genesis/manifests never propagates from control');
};

subtest 'a tracked extra path joins the set in one form' => sub {
	plan tests => 4;

	my $h = make_harness(
		envs => ['qa'], type => 'bosh', root => 'bosh',
		kit  => 't/src/ops-blueprint',
	);
	write_env_file($h, 'qa',
		root     => 'bosh',
		pipeline => {track_additional_files => ['ops/<env>.yml']},
	);
	put_file($h->a . '/bosh/ops/qa.yml', "---\nextra: tracked\n");

	# propagation_files reads the repository through Service::Git->new('.'),
	# which is the deployment root a command is run from, so the row stands
	# there rather than in the checkout the suite itself was started from.
	my $was = Cwd::getcwd();
	chdir "@{[$h->a]}/bosh" or die "cannot enter the deployment root: $!\n";
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = $top->load_env('qa');
	my @set = $env->propagation_files;
	my @triggering = $env->propagation_files(triggering => 1);
	my @quiet = $env->propagation_files(triggering => 0);
	chdir $was or die "cannot return to $was: $!\n";

	ok(in_set('bosh/ops/qa.yml', @set),
		'the path resolves against the deployment root and lands git-root-relative');
	ok(!in_set('ops/qa.yml', @set),
		'and never in its deployment-root-relative form');
	ok(in_set('bosh/ops/qa.yml', @triggering),
		'a tracked path defaults to triggering');
	ok(!in_set('bosh/ops/qa.yml', @quiet),
		'and so it is never among the non-triggering paths');
};

done_testing;
