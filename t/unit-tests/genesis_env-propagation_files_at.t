#!/usr/bin/env perl
# Proves T111: a control commit moves a flat repository's files under a bosh/
# deployment root, and the writer reads the set from that commit's tree, so it
# delivers the moved set under its new prefix, removes the root-level files the
# branch still held, and runs no rename detection at all.  Every kind that asks
# whether a path exists asks the commit, so a glob in the tracked list expands
# there, a kit at latest resolves to the archive the commit holds, and a path
# control has taken up again does not ride along with a delivery of the commit
# that dropped it.  The blueprint's repository-side fragments are the one kind
# enumerated on control, by one sub that answers the same way whether or not
# the environment carries a loaded kit.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::CI::Marker;
use Genesis::Env;
use Genesis::Top;
use Service::Git;
use Service::Git::Session;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the set is read at the delivered commit, not from the working tree' => sub {
	plan tests => 5;

	# A flat repository: the deployment root is the git root.  The kit moves
	# with everything else, so the reader has to find it under the new prefix
	# to name the kit source at all.
	#
	# The ops file is the kind whose resolution has to follow the moving
	# root, and it is tracked by its exact name as well as named by the
	# kit's blueprint, so both readers name the one file for two reasons and
	# the tree holds no ops file that only one of them knows about.
	my $h = make_harness(envs => ['qa'], root => '',
		kit => 't/src/ops-blueprint');
	fixture_vault($h);
	write_env_file($h, 'qa',
		pipeline => {track_additional_files => ['ops/extra.yml']});
	init_branch($h, 'qa');

	my $flat = commit_on_control($h,
		files   => {'ops/extra.yml' => "---\nextra: fragment\n"},
		message => 'add the fragment the blueprint names',
	);
	deliver($h, 'qa', copy => 'a', control => $flat);

	# The restructure: every path moves under bosh/, which is the one
	# transition between the two layouts.
	my $held = files_at($h, $flat, copy => 'a');
	my %moved;
	$moved{"bosh/$_"} = $held->{$_} for keys %$held;
	$moved{$_} = undef for keys %$held;
	my $restructure = commit_on_control($h,
		files   => {%moved},
		message => 'move the deployment under bosh',
	);

	# The deployment root exists only from the restructure onward, and the
	# handle is built there rather than at the copy root, because Service::Git
	# keeps one instance per repository and fixes its prefix at that first
	# construction.  The Top and the environment are built before the session
	# opens, because a deployment branch is not a repository a Top can be
	# opened on.
	my $in_root = in_root($h, root => 'bosh');
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = Genesis::Env->bare('qa', $top);

	# The reader names the kit source as a directory, because what it hands
	# git is a pathspec, so the two sides are compared as the paths each of
	# them covers in the tree at the commit.
	my @expected = sort(propagation_set($h, 'qa', at => $restructure, root => 'bosh'));
	my @at = $env->propagation_files_at($restructure, git => $git);
	is_deeply([covered_paths($h->a, $restructure, @at)], [@expected],
		'the reader answers with the set as it stood at the commit');
	ok(!in_set('qa.yml', @at), 'the root-level spelling is not in the set');

	# The same reader, standing in the same restructured tree, answers the
	# commit before the restructure with the flat spelling, which is the
	# reading a prefix taken from today's configuration cannot give.
	is_deeply([covered_paths($h->a, $flat,
			$env->propagation_files_at($flat, git => $git))],
		[sort(propagation_set($h, 'qa', at => $flat, root => ''))],
		'and at the commit before the restructure it answers the flat set');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));
	$session->apply_files($restructure,
		env     => $env,
		message => Genesis::CI::Marker::build($restructure, 'qa'),
	);
	$session->finish;
	assert_w_restored($w, 'the session restores the working state');

	is_deeply(tree_of($h->a, $h->slug('qa')), [@expected],
		'the moved set lands under its new prefix and the root-level files are gone');
};

subtest 'no rename detection runs' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], root => 'bosh',
		kit => 't/src/ops-blueprint');
	fixture_vault($h);
	write_env_file($h, 'qa', root => 'bosh',
		pipeline => {track_additional_files => ['ops/old.yml']});
	init_branch($h, 'qa');

	my $before = commit_on_control($h,
		files   => {'bosh/ops/old.yml' => "---\nname: a\n"},
		message => 'add an ops file',
	);
	deliver($h, 'qa', copy => 'a', control => $before);

	# A commit that moves a file and edits it, which git's similarity
	# heuristic reads as a delete plus an add.  The tracked list follows the
	# file in the same commit, so the environment names the new path from the
	# commit onward and the old one from nowhere at all.
	write_env_file($h, 'qa', root => 'bosh', commit => 0,
		pipeline => {track_additional_files => ['ops/new.yml']});
	my $after = commit_on_control($h,
		files   => {'bosh/qa.yml'      => slurp($h->a . '/bosh/qa.yml'),
		            'bosh/ops/old.yml' => undef,
		            'bosh/ops/new.yml' => "---\nname: a\nedited: yes\n"},
		message => 'move and edit the ops file',
	);

	my $in_root = in_root($h);
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = Genesis::Env->bare('qa', $top);

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));
	my $result = $session->apply_files($after,
		env     => $env,
		message => Genesis::CI::Marker::build($after, 'qa'),
	);
	$session->finish;
	assert_w_restored($w, 'the session restores the working state');

	is_deeply([sort @{$result->{removed}}], ['bosh/ops/old.yml'],
		'the old path is removed as an ordinary path outside the set');
	ok(in_set('bosh/ops/new.yml', @{$result->{delivered}}),
		'and the new path is delivered as an ordinary path inside it');
};

subtest 'a glob in the tracked list expands at the commit' => sub {
	plan tests => 6;

	my $h = make_harness(envs => ['qa'], root => 'bosh',
		kit => 't/src/ops-blueprint');
	fixture_vault($h);
	write_env_file($h, 'qa', root => 'bosh',
		pipeline => {track_additional_files => ['ops/*.yml']});
	init_branch($h, 'qa');

	my $control = commit_on_control($h,
		files   => {'bosh/ops/one.yml'   => "---\none: yes\n",
		            'bosh/ops/two.yml'   => "---\ntwo: yes\n",
		            'bosh/ops/notes.txt' => "not a fragment\n"},
		message => 'track the ops files by pattern',
	);

	my $in_root = in_root($h);
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = Genesis::Env->bare('qa', $top);

	my @at = $env->propagation_files_at($control, git => $git);
	ok(in_set('bosh/ops/one.yml', @at),
		'the first path the pattern names is in the set');
	ok(in_set('bosh/ops/two.yml', @at),
		'and so is the second');
	ok(!in_set('bosh/ops/notes.txt', @at),
		'while a path the pattern does not name stays out of it');

	# The two readers expand the same pattern against two different things,
	# the commit's tree and the working tree, and they have to agree, because
	# a delivery reading short takes the operator's files off the branch.
	# The working-tree reading is covered against the commit before the two
	# are compared, because the set is a list of pathspecs and the blueprint
	# names a fragment nobody has written, which is in one reading as a
	# pathspec and in neither as a file.
	my $loaded = $top->load_env('qa');
	is_deeply([grep {m{^bosh/ops/}} @at],
		[grep {m{^bosh/ops/}}
			covered_paths($h->a, $control, $loaded->propagation_files)],
		'and the working-tree reader names the same paths');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));
	$session->apply_files($control,
		env     => $env,
		message => Genesis::CI::Marker::build($control, 'qa'),
	);
	$session->finish;
	assert_w_restored($w, 'the session restores the working state');

	my $tree = tree_of($h->a, $h->slug('qa'));
	ok(in_set('bosh/ops/one.yml', @$tree) && in_set('bosh/ops/two.yml', @$tree),
		'and the delivery carries both onto the branch');
};

subtest 'the glob translation keeps the corners a shell keeps' => sub {
	plan tests => 4;

	# A star first in a brace group is still first in its path segment, so
	# it refuses a leading dot as a star first in the segment does.
	my $group = Genesis::Env::_glob_regex('ops/{*.yml,*.yaml}');
	ok('ops/one.yaml' =~ $group,
		'a brace group matches each of the patterns it holds');
	ok(!('ops/.hidden.yml' =~ $group),
		'and a star first in a group still refuses a leading dot');

	# A closing bracket first in a class is that bracket rather than the end
	# of the class, which is the one place a class does not end where it
	# looks like it does.
	my $class = Genesis::Env::_glob_regex('ops/[]x]one.yml');
	ok('ops/]one.yml' =~ $class,
		'a bracket first in a class is that bracket');
	ok(!('ops/one.yml' =~ $class),
		'and the class still has to match something');
};

subtest 'a kit at latest is the newest archive the commit holds' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], root => 'bosh');
	fixture_vault($h);
	install_compiled_kit($h,
		't/repos/compiled-kit-test/.genesis/kits/compiled-0.0.1.tar.gz');
	install_compiled_kit($h,
		't/repos/compiled-kit-test/.genesis/kits/compiled-0.0.2.tar.gz');

	# The environment names the kit by name at latest, which is the spelling
	# local_kit_version resolves to the newest version it can see.
	my $control = commit_on_control($h,
		files   => {'bosh/qa.yml' => <<'EOF'},
---
kit:
  name:     compiled
  version:  latest
  features: []
genesis:
  env: qa
EOF
		message => 'name the compiled kit at latest',
	);

	my $in_root = in_root($h);
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = Genesis::Env->bare('qa', $top);

	my %was = map {$_ => $ENV{$_}}
		qw/GENESIS_ROOT GENESIS_TARGET_VAULT SAFE_TARGET/;
	my @at = $env->propagation_files_at($control, git => $git);

	ok(in_set('bosh/.genesis/kits/compiled-0.0.2.tar.gz', @at),
		'the newest archive the commit holds is the kit source');
	ok(!in_set('bosh/.genesis/kits/compiled-0.0.1.tar.gz', @at),
		'and the older one it also holds is not');

	my $loaded = $top->load_env('qa');
	is_deeply([grep {m{/kits/}} @at],
		[grep {m{/kits/}} $loaded->propagation_files],
		'so both readers name one archive for one environment file');

	# The Top a materialised tree is read through sets GENESIS_ROOT, and a
	# Top that attaches a vault sets two more, so a reader that left any of
	# them behind would change what every later command in the process reads.
	is_deeply({map {$_ => $ENV{$_}} keys %was}, {%was},
		'and the read leaves the process environment as it found it');
};

subtest 'both readers name the blueprint fragments the same way' => sub {
	plan tests => 4;

	# The kit's blueprint names one repository-side fragment, which is the kind
	# that is read on control because that is where the kit lives.
	my $h = make_harness(envs => ['qa'], root => 'bosh',
		kit => 't/src/ops-blueprint');
	fixture_vault($h);
	my $control = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => "---\nextra: fragment\n"},
		message => 'add the fragment the blueprint names',
	);

	my $in_root = in_root($h);
	my $git    = Service::Git->new($h->a . '/bosh');
	my $top    = Genesis::Top->new($h->a . '/bosh');
	my $bare   = Genesis::Env->bare('qa', $top);
	my $loaded = $top->load_env('qa');

	my @from_bare = $bare->_blueprint_fragments($git);
	is_deeply([@from_bare], ['ops/extra.yml'],
		'the fragments are enumerated from the kit the environment declares');
	is_deeply([$loaded->_blueprint_fragments($git)], [@from_bare],
		'and a loaded kit names the same ones');

	ok(in_set('bosh/ops/extra.yml', $bare->propagation_files_at($control, git => $git)),
		'so the at-commit reader carries the fragment');
	ok(in_set('bosh/ops/extra.yml', $loaded->propagation_files),
		'and the working-tree reader carries it too');
};

subtest 'the fragments are read at the commit, not where the session stands' => sub {
	plan tests => 3;

	# The restructure again, and this time the fragment the blueprint names
	# travels with it.  The branch still holds the flat layout, so the tree
	# the session stands on has no deployment root at bosh/ at all.
	my $h = make_harness(envs => ['qa'], root => '',
		kit => 't/src/ops-blueprint');
	fixture_vault($h);
	init_branch($h, 'qa');

	my $flat = commit_on_control($h,
		files   => {'ops/extra.yml' => "---\nextra: fragment\n"},
		message => 'add the fragment the blueprint names',
	);
	deliver($h, 'qa', copy => 'a', control => $flat);

	my $held = files_at($h, $flat, copy => 'a');
	my %moved;
	$moved{"bosh/$_"} = $held->{$_} for keys %$held;
	$moved{$_} = undef for keys %$held;
	my $restructure = commit_on_control($h,
		files   => {%moved},
		message => 'move the deployment under bosh',
	);

	my $in_root = in_root($h, root => 'bosh');
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = Genesis::Env->bare('qa', $top);

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));

	# This is the state the writer reads its set in, and the kit the
	# blueprint belongs to is nowhere in this tree.
	ok(in_set('bosh/ops/extra.yml',
			$env->propagation_files_at($restructure, git => $git)),
		'the fragment is named while the session stands on the branch');

	$session->apply_files($restructure,
		env     => $env,
		message => Genesis::CI::Marker::build($restructure, 'qa'),
	);
	$session->finish;
	assert_w_restored($w, 'the session restores the working state');

	ok(in_set('bosh/ops/extra.yml', @{tree_of($h->a, $h->slug('qa'))}),
		'and the delivery carries it onto the branch under its new prefix');
};

# raised_by - the arguments a refusal was raised with, or undef
#
# bail wraps its message for the terminal before it raises, so reading the
# message back would rest on where a line break landed.  The arguments the
# refusal composed are read instead, which is the same shape the repository
# configuration rows use.
sub raised_by {
	my ($code) = @_;
	my @raised;
	no warnings qw/once redefine/;
	local *Genesis::Env::bail = sub {push @raised, [@_]; die "refused\n"};
	my $answered = eval {$code->(); 1};
	return ($answered ? undef : $raised[0]);
}

sub names_in {
	my ($raised, $pattern) = @_;
	return scalar(grep {!ref($_) && $_ =~ $pattern} @{$raised || []});
}

subtest 'a commit that carries no kit is refused' => sub {
	plan tests => 3;

	# No kit is installed, so the commit holds an environment and its
	# configuration and nothing to deploy them with.
	my $h = make_harness(envs => ['qa'], root => 'bosh', vault => 0);
	my $control = commit_on_control($h,
		files   => {'bosh/ops/one.yml' => "---\none: yes\n"},
		message => 'add an ops file and no kit',
	);

	my $in_root = in_root($h);
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh', no_vault => 1);
	my $env = Genesis::Env->bare('qa', $top);

	my $raised = raised_by(sub {$env->propagation_files_at($control, git => $git)});
	ok($raised, 'the read refuses rather than answering a set with no kit in it');
	ok(names_in($raised, qr{declares the kit}),
		'and the refusal says the environment declares a kit');
	ok(names_in($raised, qr{\Q@{[substr($control, 0, 10)]}\E}),
		'and names the commit that does not carry it');
};

subtest 'a read with no vault to lend refuses by name' => sub {
	plan tests => 3;

	# The kit is there, so the read gets as far as the hook that names the
	# fragments, which is the step that wants a vault.
	my $h = make_harness(envs => ['qa'], root => 'bosh', vault => 0,
		kit => 't/src/ops-blueprint');
	my $control = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => "---\nextra: fragment\n"},
		message => 'add the fragment the blueprint names',
	);

	my $in_root = in_root($h);
	my $git = Service::Git->new($h->a . '/bosh');
	# A Top that holds no vault is what a command outside propagation has,
	# and Service::Vault::None is the absence of a vault rather than a vault
	# that can be lent to the tree the read writes out.
	my $top = Genesis::Top->new($h->a . '/bosh', no_vault => 1);
	my $env = Genesis::Env->bare('qa', $top);

	my $raised = raised_by(sub {$env->propagation_files_at($control, git => $git)});
	ok($raised, 'the read refuses rather than letting the hook ask for one');
	ok(names_in($raised, qr{without a vault}),
		'and the refusal names the read it was for');
	ok(names_in($raised, qr{Service::Vault::None}),
		'and says what the command holds instead');
};

subtest 'a tracked path that fell out of the list is read at the commit' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa'], root => 'bosh',
		kit => 't/src/ops-blueprint');
	# The wider list tracks one path and a delivery carries it; the narrower
	# list drops it and leaves it on the branch until a delivery removes it.
	my $narrow = stale_set_delivery($h, copy => 'a', file => 'ops/tracked.yml');

	# Control takes the path up again, so the working tree and the commit being
	# delivered disagree about the set, and the commit wins because the set is
	# computed there.
	write_env_file($h, 'qa', root => 'bosh',
		pipeline => {track_additional_files => ['ops/tracked.yml']});

	my $in_root = in_root($h);
	my $git    = Service::Git->new($h->a . '/bosh');
	my $top    = Genesis::Top->new($h->a . '/bosh');
	my $env    = Genesis::Env->bare('qa', $top);
	my $loaded = $top->load_env('qa');

	ok(!in_set('bosh/ops/tracked.yml', $env->propagation_files_at($narrow, git => $git)),
		'the reader answers the narrowed list the delivered commit declares');
	ok(in_set('bosh/ops/tracked.yml', $loaded->propagation_files),
		'while a reader working from the working tree would keep the path');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));
	$session->apply_files($narrow,
		env     => $env,
		message => Genesis::CI::Marker::build($narrow, 'qa'),
	);
	$session->finish;
	assert_w_restored($w, 'the session restores the working state');

	ok(!in_set('bosh/ops/tracked.yml', @{tree_of($h->a, $h->slug('qa'))}),
		'and the delivery removes the path the commit stopped tracking');
};

subtest 'the non-triggering half is read at the commit too' => sub {
	# The working-tree reader has a row of the same shape, and the two files
	# that cover the split read as one story only if the reader at a commit
	# answers the same two kinds.
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], type => 'bosh',
		kit => 't/src/ops-blueprint');
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

	my $git   = Service::Git->new($h->a);
	my $sha   = $git->sha($h->control);
	my $top   = Genesis::Top->new($h->a);
	my $env   = Genesis::Env->bare('qa', $top);
	my @quiet = $env->propagation_files_at($sha, git => $git, triggering => 0);

	ok(in_set('.genesis/config', @quiet),
		'.genesis/config is non-triggering at the commit as well');
	ok(in_set('bin/notify', @quiet),
		'and so is the reaction script the commit declares');
	is_deeply([sort @quiet], ['.genesis/config', 'bin/notify'],
		'and the non-triggering half names those two and nothing else');
};

done_testing;
