package Harness::Propagation;
# The scenario harness: a bare remote plus two repository copies, which runs
# whole commands and asserts the invariants.  Every state-building helper in
# the suite lives here, so no test file declares one of its own.
use strict;
use warnings;

use Exporter qw/import/;
use Cwd ();
use JSON::PP;
use POSIX ();
use Genesis qw/run/;
use Service::Git;

# require rather than use, because helper's import resets HOME and the test
# file has already run it.  We want the package loaded and nothing else.
require helper;

our @EXPORT = qw/
	make_harness
	commit_on_control commit_from_b publish_from_b push_from refresh
	ref_in tree_of upstream_of counts
/;

push @EXPORT, qw/
	init_branch deliver propagation_set harness_marker
	add_deployment_root write_env_file
/;

push @EXPORT, qw/
	fixture_vault fixture_applied fixture_pipeline_record certify
	fixture_hold fixture_proposed break_vault restore_vault
/;

# ref_in - one ref's sha in a repository at a path, or undef {{{
#
# The first reader the harness owns, because every row below reads a ref and
# a reader declared once per test file is a reader that answers differently
# in each of them.  The rest of the shared readers land beside it.
sub ref_in {
	my ($dir, $ref) = @_;
	my ($sha) = run({dir => $dir, passfail => 0},
		'git', 'rev-parse', '--verify', '--quiet', $ref);
	chomp $sha if defined $sha;
	return $sha || undef;
}

# }}}
# tree_of - a commit's paths, sorted, or an empty list where the ref is absent {{{
#
# The stderr of the read is captured separately rather than folded into the
# output, because a row proving an absence has to read an empty list back and
# not git's complaint about the name it asked for.
sub tree_of {
	my ($dir, $ref) = @_;
	my ($out, $rc) = run({dir => $dir, passfail => 0, stderr => 0},
		'git', 'ls-tree', '-r', '--name-only', $ref);
	return [] if $rc || !defined $out;
	chomp $out;
	return [sort grep {length} split /\n/, $out];
}

# }}}
# upstream_of - the upstream a branch tracks in a repository, or undef {{{
#
# The read is stderr-suppressed and its status is checked, because a branch
# with no upstream is a state several rows prove rather than an accident, and
# git complains to stderr when it is asked for one that is not there.
sub upstream_of {
	my ($dir, $branch) = @_;
	my ($out, $rc) = run({dir => $dir, stderr => 0},
		'git', 'rev-parse', '--abbrev-ref', '--symbolic-full-name',
		"$branch\@{upstream}");
	return undef if $rc || !defined $out;
	chomp $out;
	return $out;
}

# }}}
# counts - how far a branch is ahead of and behind its remote-tracking ref {{{
#
# The two numbers come back in the order git prints them, ahead first, and the
# read names the remote-tracking ref outright rather than the upstream, so a
# row can weigh the refs even where no upstream is configured.
sub counts {
	my ($dir, $branch) = @_;
	my ($out) = run({dir => $dir}, 'git', 'rev-list', '--left-right', '--count',
		"refs/heads/$branch...refs/remotes/origin/$branch");
	chomp $out;
	return split /\s+/, $out;
}

# }}}
# make_harness - build R, copy A, copy B, and the deployment root {{{
#
# The bare repository stands as R.  Copy A belongs to the operator and every
# command under test runs there; copy B belongs to a teammate, and the publish
# helpers write from it, because most hazards only appear once somebody else
# has published.
sub make_harness {
	my (%opts) = @_;

	my $base = helper::workdir() . sprintf('/ph-%d-%06d', $$, int(rand(1_000_000)));
	helper::mkdir_or_fail($base);

	my $self = bless {
		base      => $base,
		r         => "$base/r.git",
		a         => "$base/a",
		b         => "$base/b",
		type      => $opts{type}      // 'bosh',
		control   => $opts{control}   // 'control',
		pr_prefix => $opts{pr_prefix} // 'pr/',
		envs      => $opts{envs}      // ['qa'],
		provider  => $opts{provider}  // 'manual',
		mode      => $opts{mode}      // 'direct',
		root      => $opts{root}      // '',
		pipeline  => defined $opts{pipeline} ? $opts{pipeline} : 1,
		kit       => $opts{kit},
		roots     => {},
		mount     => $opts{exodus_mount} // '/secret/exodus/',
	}, __PACKAGE__;

	run({dir => $base, onfailure => "Failed to build R"},
		'git', 'init', '-q', '--bare', $self->{r});

	$self->_clone('a');
	$self->_clone('b');
	$self->_seed_control;

	$self->fixture_vault if (defined $opts{vault} ? $opts{vault} : 1);
	$self->github_double if $opts{github};

	return $self;
}

# }}}
# _clone - clone R into one of the two copies with a deterministic identity {{{
sub _clone {
	my ($self, $copy) = @_;
	my $dir = $self->{$copy};

	run({dir => $self->{base}, onfailure => "Failed to clone copy $copy"},
		'git', 'clone', '-q', $self->{r}, $dir);
	run({dir => $dir}, 'git', 'config', 'user.email', "copy-$copy\@genesis.example.com");
	run({dir => $dir}, 'git', 'config', 'user.name',  "Copy $copy");
	run({dir => $dir}, 'git', 'symbolic-ref', 'HEAD', "refs/heads/$self->{control}");

	return $dir;
}

# }}}
# _create_root - lay a deployment root down in a directory that already exists {{{
#
# Genesis::Top->create appends the deployment name to the path it is handed and
# refuses to write into a directory that is already there, so it cannot put the
# first root at copy A's git root, which is where that root has to sit.  We let
# it build the root under a scratch directory of its own and move what it wrote
# into place, so the repository the rows run against is still one the real code
# path made rather than a hand-written .genesis/config that can drift from the
# schema.
sub _create_root {
	my ($self, $root) = @_;

	require Genesis::Top;

	# Genesis::Top->create reads the global configuration, which a real command
	# sets up at startup and which a test file otherwise has to provide for
	# itself.  The harness provides it, so no row has to remember to.
	no warnings 'once';
	helper::provide_rc() unless defined $Genesis::RC;

	my $scratch = sprintf('%s/top-%06d', $self->{base}, int(rand(1_000_000)));
	helper::mkdir_or_fail($scratch);

	# The create points GENESIS_ROOT at the root it just built and names the
	# repository's vault in GENESIS_TARGET_VAULT and SAFE_TARGET.  Under
	# no_vault that name is the empty string, which is not the same as having
	# no target at all, so both are put back as they were and GENESIS_ROOT is
	# pointed at where the root actually ends up.
	my %was = map {$_ => $ENV{$_}} qw/GENESIS_TARGET_VAULT SAFE_TARGET/;

	my $made = Genesis::Top->create($scratch, $self->{type}, no_vault => 1)->path;

	for my $var (keys %was) {
		defined $was{$var} ? ($ENV{$var} = $was{$var}) : delete $ENV{$var};
	}

	opendir(my $dh, $made)
		or die "Failed to read the new deployment root at $made: $!";
	my @entries = grep {$_ ne '.' && $_ ne '..'} readdir($dh);
	closedir($dh);

	for my $entry (@entries) {
		rename("$made/$entry", "$root/$entry")
			or die "Failed to move $entry into the deployment root: $!";
	}
	rmdir($made);
	rmdir($scratch);
	$ENV{GENESIS_ROOT} = $root;

	return $root;
}

# }}}
# _seed_control - write the deployment root and publish the control branch {{{
#
# The first root sits at copy A's own git root, so the repository the rows run
# against and the deployment root are one directory.
#
# Copy B's control branch is created from origin's, with the upstream set, so
# that every push from copy B moves copy B's own remote-tracking ref.  A push
# that leaves T behind would make a divergence read straight after a publish
# report `ahead`, which is a fault in the harness and not in the code.
sub _seed_control {
	my ($self) = @_;

	my $root = $self->{root} ? "$self->{a}/$self->{root}" : $self->{a};
	helper::mkdir_or_fail($root) unless -d $root;
	$self->_create_root($root);

	# The environment files land through write_env_file and are committed with
	# the root, so the control branch's first commit is a repository a command
	# can be run against rather than a deployment root with nothing in it.
	$self->write_env_file($_, commit => 0) for @{$self->{envs}};

	run({dir => $self->{a}}, 'git', 'add', '-A');
	run({dir => $self->{a}, onfailure => "Failed to seed control"},
		'git', 'commit', '-q', '-m', 'seed the control branch');
	run({dir => $self->{a}, onfailure => "Failed to publish control"},
		'git', 'push', '-q', '-u', 'origin', $self->{control});
	run({dir => $self->{b}}, 'git', 'fetch', '-q', 'origin');
	run({dir => $self->{b}, onfailure => "Failed to track control in copy B"},
		'git', 'checkout', '-q', '-B', $self->{control},
		'--track', "origin/$self->{control}");

	return $self;
}

# }}}
# Accessors - the paths, the names, and the two vault addresses D103 fixes {{{
sub r { $_[0]->{r} }
sub a { $_[0]->{a} }
sub b { $_[0]->{b} }
sub type { $_[0]->{type} }
sub control { $_[0]->{control} }
sub envs { $_[0]->{envs} }

sub git {
	my ($self, $copy) = @_;
	$copy //= 'a';
	return $self->{"_git_$copy"} //= Service::Git->new($self->{$copy});
}

sub slug {
	my ($self, $env, %opts) = @_;
	return sprintf('%s/%s', $env, $opts{type} // $self->{type});
}

sub pr_branch {
	my ($self, $env, %opts) = @_;
	return $self->{pr_prefix} . $self->slug($env, %opts);
}

sub exodus_mount { $_[0]->{mount} }

sub applied_path {
	my ($self, %opts) = @_;
	return sprintf('%s_pipelines/%s', $self->{mount}, $opts{type} // $self->{type});
}

sub env_path {
	my ($self, $env, %opts) = @_;
	return $self->{mount} . $self->slug($env, %opts);
}

# }}}
# _write_tree - lay a file set into a copy, removing the undefined paths {{{
sub _write_tree {
	my ($self, $dir, $files) = @_;
	for my $path (sort keys %{$files || {}}) {
		if (defined $files->{$path}) {
			helper::put_file("$dir/$path", $files->{$path});
			run({dir => $dir}, 'git', 'add', '--', $path);
		} else {
			run({dir => $dir, passfail => 1}, 'git', 'rm', '-q', '-f', '--', $path);
		}
	}
	return $self;
}

# }}}
# _commit_in - commit a file set in one copy and return the new sha {{{
#
# The branch is positional and the control branch stands in where a caller
# leaves it undefined, because the branch is the one thing every caller names
# and an option that most callers must remember to set is an option that some
# caller will forget.
#
# The push is per branch and carries no forced refspec, and it sets the
# upstream, so the pushing copy's own remote-tracking ref moves with every
# publish and a divergence read taken straight after reports in-sync.
sub _commit_in {
	my ($self, $copy, $branch, %opts) = @_;
	my $dir = $self->{$copy};
	$branch //= $self->{control};

	my ($current) = run({dir => $dir}, 'git', 'rev-parse', '--abbrev-ref', 'HEAD');
	chomp $current;
	run({dir => $dir}, 'git', 'checkout', '-q', $branch) unless $current eq $branch;

	$self->_write_tree($dir, $opts{files});

	my $message = $opts{message} // 'a commit';
	for my $trailer (sort keys %{$opts{trailers} || {}}) {
		$message .= "\n\n" unless $message =~ /\n\n/;
		$message .= sprintf("%s: %s\n", $trailer, $opts{trailers}{$trailer});
	}

	run({dir => $dir, onfailure => "Failed to commit on $branch in copy $copy"},
		'git', 'commit', '-q', '-m', $message);

	my ($sha) = run({dir => $dir}, 'git', 'rev-parse', 'HEAD');
	chomp $sha;
	run({dir => $dir, onfailure => "Failed to push $branch from copy $copy"},
		'git', 'push', '-q', '-u', 'origin', $branch) if $opts{push};

	return $sha;
}

# }}}
# commit_on_control - the operator's own commit in copy A {{{
sub commit_on_control {
	my ($self, %opts) = @_;
	my $branch = delete $opts{branch};
	return $self->_commit_in('a', $branch, %opts);
}

# }}}
# commit_from_b - a teammate's commit, made and left unpublished {{{
sub commit_from_b {
	my ($self, %opts) = @_;
	my $branch = delete $opts{branch};
	return $self->_commit_in('b', $branch, %opts, push => 0);
}

# }}}
# publish_from_b - a teammate's commit, published with a real git push {{{
#
# The push moves copy B's own remote-tracking ref, so a divergence read taken
# straight after a publish reports in-sync with no second refresh, and copy A's
# refs stay put until copy A fetches.
sub publish_from_b {
	my ($self, %opts) = @_;
	my $branch = delete $opts{branch};
	return $self->_commit_in('b', $branch, %opts, push => 1);
}

# }}}
# push_from - push named branches from one copy, per branch {{{
#
# The push sets the upstream, as the push inside _commit_in does, so that the
# harness's two push paths leave a branch in the same state whichever one of
# them put it on R.
sub push_from {
	my ($self, $copy, @branches) = @_;
	my %results;
	for my $branch (@branches) {
		$results{$branch} = run({dir => $self->{$copy}, passfail => 1},
			'git', 'push', '-q', '-u', 'origin', $branch) ? 1 : 0;
	}
	return \%results;
}

# }}}
# refresh - fetch in one copy, so T moves and L does not {{{
sub refresh {
	my ($self, $copy, @branches) = @_;
	my @refspecs = map {"+refs/heads/$_:refs/remotes/origin/$_"} @branches;
	run({dir => $self->{$copy}, passfail => 1},
		'git', 'fetch', '-q', 'origin', @refspecs);
	return $self;
}

# }}}
# _has_commit - whether a repository holds a commit, without dying on absence {{{
sub _has_commit {
	my ($dir, $commitish) = @_;
	return run({dir => $dir, passfail => 1, stderr => 0},
		'git', 'cat-file', '-e', "$commitish^{commit}") ? 1 : 0;
}

# }}}
# _repo_holding - the first of the three repositories that holds a commit {{{
#
# A control commit is written in copy A, but a row is free to publish one from
# copy B or to name one that only R still has, and a reader that looked in one
# repository alone would answer an empty set rather than say so.  Copy A is
# asked first, because that is where the operator's commits are made.
sub _repo_holding {
	my ($self, $commitish) = @_;
	for my $dir ($self->{a}, $self->{r}, $self->{b}) {
		return $dir if _has_commit($dir, $commitish);
	}
	die "No repository in the harness holds $commitish\n";
}

# }}}
# _fetch_commit - bring a commit's objects into one copy, touching no ref {{{
#
# A delivery written in copy B reads the control commit's blobs out of copy B's
# own object database, and copy B has not fetched since the control commit was
# published.  The fetch names the source repository by path rather than by the
# remote's name, because a path carries no configured refspec and so no
# remote-tracking ref moves: only `refresh` is allowed to move T.
sub _fetch_commit {
	my ($self, $copy, $commitish, @branches) = @_;
	my $dir = $self->{$copy};
	@branches = ($self->{control}) unless @branches;

	return $dir if _has_commit($dir, $commitish);
	for my $source ($self->{r}, map {$self->{$_}} grep {$_ ne $copy} qw/a b/) {
		run({dir => $dir, passfail => 1, stderr => 0},
			'git', 'fetch', '-q', '--no-tags', $source, @branches);
		return $dir if _has_commit($dir, $commitish);
	}
	die "The commit $commitish is in none of the harness's repositories\n";
}

# }}}
# _branch_parent - the commit a delivery should sit on, in the writing copy {{{
#
# The copy's own branch wins where it has one, so a row that has deliberately
# left the copy behind or ahead keeps the shape it built.  Where the copy has
# never seen the branch, R's tip stands in, and the objects come with it, so
# the push that follows fast-forwards rather than being refused.
sub _branch_parent {
	my ($self, $copy, $branch) = @_;

	my $local = ref_in($self->{$copy}, "refs/heads/$branch");
	return $local if $local;

	my $on_r = ref_in($self->{r}, "refs/heads/$branch");
	return undef unless $on_r;

	$self->_fetch_commit($copy, $on_r, $branch);
	return $on_r;
}

# }}}
# init_branch - cut an environment's branch on R as the apply would {{{
#
# D42 makes the missing deployment branch an orphan whose root commit adds a
# single init file and carries [ci skip], and D80 has the apply create it with
# plumbing and no checkout.  We write the objects straight into copy A's
# database with a private index and push the ref, so no working tree moves.
sub init_branch {
	my ($self, $env, %opts) = @_;
	my $branch = $self->slug($env, %opts);
	my $dir    = $self->{a};

	my $seed = "$self->{base}/init-" . int(rand(1_000_000));
	helper::put_file($seed, "This branch is managed by genesis pipeline-apply.\n");

	my ($blob) = run({dir => $dir, onfailure => "Failed to write the init blob"},
		'git', 'hash-object', '-w', $seed);
	chomp $blob;

	my $index = "$self->{base}/idx-" . int(rand(1_000_000));
	my $tree  = do {
		local $ENV{GIT_INDEX_FILE} = $index;
		run({dir => $dir}, 'git', 'update-index', '--add', '--cacheinfo',
			"100644,$blob,init");
		my ($t) = run({dir => $dir}, 'git', 'write-tree');
		chomp $t;
		$t;
	};
	unlink $index;

	my ($sha) = run({dir => $dir, onfailure => "Failed to write the init commit"},
		'git', 'commit-tree', $tree, '-m',
		sprintf('Initialize %s branch [ci skip]', $branch));
	chomp $sha;

	run({dir => $dir, onfailure => "Failed to write refs/heads/$branch"},
		'git', 'update-ref', "refs/heads/$branch", $sha);
	if (defined $opts{push} ? $opts{push} : 1) {
		run({dir => $dir, onfailure => "Failed to push $branch"},
			'git', 'push', '-q', '-u', 'origin', $branch);
	}

	return $sha;
}

# }}}
# deliver - write one delivered commit onto a deployment branch {{{
#
# A delivery is a mirror under D69, so the commit's tree is the propagation set
# as it stood at the delivered control commit and nothing else.  The keep and
# corrupt options exist so a row can stop the mirror's removing half or land a
# file at the wrong content, which is what the snapshot assertion has to catch.
#
# It is written in copy B by default, because a delivery is a teammate's
# published work and the operator's clone is meant to read behind it until it
# refreshes.  There is no remove_init option: the mirror starts from an empty
# index, so the init file goes by construction.
sub deliver {
	my ($self, $env, %opts) = @_;
	my $copy    = $opts{copy} // 'b';
	my $branch  = $opts{pr} ? $self->pr_branch($env, %opts)
	                        : $self->slug($env, %opts);
	my $dir     = $self->{$copy};
	my $control = $opts{control} or die "deliver needs a control commit\n";

	my @set = $self->propagation_set($env, at => $control, %opts);
	my %keep = map {$_ => 1} @{$opts{keep} || []};

	$self->_fetch_commit($copy, $control);
	my $parent = $self->_branch_parent($copy, $branch);

	my $index = "$self->{base}/idx-" . int(rand(1_000_000));
	local $ENV{GIT_INDEX_FILE} = $index;

	if ($parent && %keep) {
		run({dir => $dir}, 'git', 'read-tree', $parent);
		my ($held) = run({dir => $dir}, 'git', 'ls-files');
		chomp $held if defined $held;
		for my $path (split /\n/, ($held // '')) {
			next if $keep{$path};
			run({dir => $dir}, 'git', 'update-index', '--force-remove', '--', $path);
		}
	} else {
		run({dir => $dir}, 'git', 'read-tree', '--empty');
	}

	my $corrupt = $opts{corrupt} || {};
	my $files   = $opts{files}   || {};
	for my $path (@set) {
		my $content = exists $corrupt->{$path} ? $corrupt->{$path}
		            : exists $files->{$path}   ? $files->{$path}
		            : undef;
		my $blob;
		if (defined $content) {
			my $tmp = "$self->{base}/blob-" . int(rand(1_000_000));
			helper::put_file($tmp, $content);
			($blob) = run({dir => $dir}, 'git', 'hash-object', '-w', $tmp);
		} else {
			($blob) = run({dir => $dir}, 'git', 'rev-parse', "$control:$path");
		}
		chomp $blob;
		run({dir => $dir}, 'git', 'update-index', '--add', '--cacheinfo',
			"100644,$blob,$path");
	}

	my ($tree) = run({dir => $dir}, 'git', 'write-tree');
	chomp $tree;
	unlink $index;

	my $message = sprintf("[pipeline] control@%s -> %s",
		substr($control, 0, 12), $env);
	$message .= "\n\n" . $opts{body} if $opts{body};

	my ($sha) = run({dir => $dir, onfailure => "Failed to write the delivery"},
		'git', 'commit-tree', $tree, ($parent ? ('-p', $parent) : ()),
		'-m', $message);
	chomp $sha;

	run({dir => $dir}, 'git', 'update-ref', "refs/heads/$branch", $sha);
	if (defined $opts{push} ? $opts{push} : 1) {
		run({dir => $dir, onfailure => "Failed to push $branch"},
			'git', 'push', '-q', '-u', 'origin', $branch);
	}

	return $sha;
}

# }}}
# propagation_set - the set's paths, read by the harness from a commit's tree {{{
#
# The harness computes the set itself rather than calling propagation_files,
# because a row that asserts a delivery against the product's own reader would
# be asserting the reader against itself.  M4 changes propagation_files and
# must not silently change what the snapshot assertion compares.
sub propagation_set {
	my ($self, $env, %opts) = @_;
	my $at   = $opts{at} // $self->{control};
	my $root = $opts{root} // $self->{root};
	my $prefix = $root ? "$root/" : '';

	my ($listing) = run({dir => $self->_repo_holding($at)},
		'git', 'ls-tree', '-r', '--name-only', $at);
	chomp $listing if defined $listing;
	my @all = split /\n/, ($listing // '');

	my @kinds = (
		qr{^\Q$prefix\E\Q$env\E(?:[.-].*)?\.yml$},   # the env file hierarchy
		qr{^\Q$prefix\E\.genesis/config$},           # non-triggering
		qr{^\Q$prefix\E\.genesis/bin/genesis$},      # the embedded genesis
		qr{^\Q$prefix\E(?:bin|ops|dev)/},            # reactions, ops, kit source
		qr{^\Q$prefix\Ekit-overrides\.yml$},
	);
	# track_additional_files joins the set git-root-relative, in one form, so
	# the walk and the writer name a tracked path the same way.
	push @kinds, map {qr{^\Q$_\E$}}
		@{$opts{extra} || ($self->{extra} || {})->{$env} || []};

	my @set = grep {my $p = $_; grep {$p =~ $_} @kinds} @all;
	return sort @set;
}

# }}}
# harness_marker - the harness's own read of a branch's newest marker {{{
#
# Deliberately separate from the product's marker reader, for the same reason
# propagation_set is: a row must not assert a reader against itself.  It walks
# subjects and bodies alike, because a squash puts the marker in the body.
#
# R is asked first, because a delivery is published and R is what every copy
# eventually agrees with; a copy is only read where R has no such ref at all.
sub harness_marker {
	my ($self, $ref, %opts) = @_;
	my $limit = $opts{limit} // 20;

	my ($dir) = grep {defined ref_in($_, $ref)} ($self->{r}, $self->{a}, $self->{b});
	return undef unless defined $dir;

	my ($log) = run({dir => $dir},
		'git', 'log', "-$limit", '--format=%H%x00%B%x01', $ref);
	for my $entry (split /\x01\n?/, ($log // '')) {
		my (undef, $body) = split /\x00/, $entry, 2;
		next unless defined $body;
		next unless $body =~ m{\[pipeline\] control\@([0-9a-f]{7,40}) -> };
		my ($full) = run({dir => $dir, passfail => 0, stderr => 0},
			'git', 'rev-parse', $1);
		chomp $full if defined $full;
		return $full || undef;
	}
	return undef;
}

# }}}
# add_deployment_root - a second root sharing an environment name {{{
#
# The H32 shape: one repository, two deployment roots, one environment name.
# Under D66 each root composes its own slug, so the two never share a branch.
#
# Genesis::Top->create appends a directory to the path it is handed, so naming
# that directory outright lands the second root at its repository-relative path
# with no scratch directory and no move.  The first root sits at copy A's git
# root and so cannot be built that way, which is why _create_root exists.
sub add_deployment_root {
	my ($self, %opts) = @_;
	my $type = $opts{type} or die "add_deployment_root needs a type\n";
	my $path = $opts{path} // $type;

	require Genesis::Top;

	no warnings 'once';
	helper::provide_rc() unless defined $Genesis::RC;

	# create points GENESIS_ROOT at the root it has just built and names the
	# repository's vault in GENESIS_TARGET_VAULT and SAFE_TARGET.  The first
	# root is the one the rows run against, so all three go back as they were.
	my %was = map {$_ => $ENV{$_}} qw/GENESIS_ROOT GENESIS_TARGET_VAULT SAFE_TARGET/;
	Genesis::Top->create($self->{a}, $type, no_vault => 1, directory => $path);
	for my $var (keys %was) {
		defined $was{$var} ? ($ENV{$var} = $was{$var}) : delete $ENV{$var};
	}

	$self->{roots}{$type} = {path => $path, envs => $opts{envs} // []};
	$self->write_env_file($_, root => $path, type => $type, commit => 0)
		for @{$opts{envs} || []};

	run({dir => $self->{a}}, 'git', 'add', '-A');
	run({dir => $self->{a}, onfailure => "Failed to add the $type root"},
		'git', 'commit', '-q', '-m', "add the $type deployment root");
	run({dir => $self->{a}}, 'git', 'push', '-q', 'origin', $self->{control});

	return $path;
}

# }}}
# write_env_file - write an environment file on control {{{
#
# The site option writes the file at a level of the hierarchy rather than at
# the leaf, which is what the merged-read rows of D79 need.  The type option is
# taken for symmetry with the helpers that compose a slug and is not written,
# because nothing in the file body names a deployment type.
sub write_env_file {
	my ($self, $env, %opts) = @_;
	my $root   = $opts{root} // $self->{root};
	my $prefix = $root ? "$root/" : '';
	my $name   = $opts{site} // $env;
	my $path   = "$prefix$name.yml";

	my $body = "---\nkit:\n  name:    dev\n  version: latest\n  features: []\n";
	$body .= "genesis:\n  env: $name\n" unless $opts{site};
	for my $key (sort keys %{$opts{genesis} || {}}) {
		$body .= sprintf("  %s: %s\n", $key, $opts{genesis}{$key});
	}
	if (my $pipeline = $opts{pipeline}) {
		$body .= "  pipeline:\n";
		$body .= sprintf("    %s: %s\n", $_, $pipeline->{$_}) for sort keys %$pipeline;
	}

	helper::put_file("$self->{a}/$path", $body);
	if (defined $opts{commit} ? $opts{commit} : 1) {
		run({dir => $self->{a}}, 'git', 'add', '--', $path);
		run({dir => $self->{a}, onfailure => "Failed to write $path"},
			'git', 'commit', '-q', '-m', "write $path");
	}

	return $path;
}

# }}}
# fixture_vault - spin the suite's own vault and point the harness at it {{{
#
# A real vault rather than a double, because the rows run whole commands and a
# genesis child cannot read a double that lives in the parent's memory.  The
# suite already owns one, under t/bin/vault, so we spin that rather than a
# second kind of fixture.
#
# helper::vault_start is the TAP-free half of helper::vault_ok, and the fixture
# calls that half, because a fixture that emitted a test of its own would add
# to the plan of whatever subtest happened to build the harness.
#
# The vault is spun once and then shared by every harness in the file, so the
# fixture clears the exodus mount as it attaches and each harness starts on an
# empty record tree rather than on whatever the subtest above it wrote.  The
# removal is forced, because the first harness of a run finds nothing there.
sub fixture_vault {
	my ($self) = @_;
	return $self->{vault_target} if $self->{vault_target};

	my $target = helper::vault_start('genesis-propagation-harness');
	$self->{vault_target} = $target;
	$self->{vault_url}    = $helper::VAULT_URL{$target};

	run({env => {SAFE_TARGET => $target}, passfail => 1, stderr => 0},
		'safe', 'rm', '-rf', $self->exodus_mount);

	return $target;
}

# }}}
# _write_record - write one flat record under a vault path {{{
sub _write_record {
	my ($self, $path, %fields) = @_;
	$self->fixture_vault;
	for my $key (sort keys %fields) {
		next unless defined $fields{$key};
		run({env => {SAFE_TARGET => $self->{vault_target}},
		     onfailure => "Failed to write $path:$key"},
			'safe', 'set', $path, "$key=$fields{$key}");
	}
	return $path;
}

# }}}
# _now - the one timestamp form a record's value takes {{{
#
# EXODUS_TIME_FORMAT under D58, which is the value form.  A path never carries
# one of these, and the two forms are kept apart on purpose.
sub _now {
	my ($self, $at) = @_;
	return $at if defined $at;
	my @t = localtime(time);
	return POSIX::strftime('%Y-%m-%d %H:%M:%S %z', @t);
}

# }}}
# fixture_applied - the pipeline's own facts, at <exodus mount>_pipelines/<type> {{{
#
# The leading underscore makes the address unreachable from any environment,
# because Genesis::Env::_env_name_errors requires a name to start with a
# lowercase letter.  That is D103's reason for choosing it.
sub fixture_applied {
	my ($self, %opts) = @_;
	return $self->_write_record($self->applied_path(%opts),
		control_commit => $opts{control},
		provider       => $opts{provider} // $self->{provider},
		at             => $self->_now($opts{at}),
	);
}

# }}}
# fixture_pipeline_record - an environment's compiled pipeline facts {{{
#
# Beside that environment's own exodus record, under a pipeline subpath.  Its
# absence is how the walk knows the applied record does not know the
# environment, so a row that wants that case simply does not call this.
sub fixture_pipeline_record {
	my ($self, $env, %opts) = @_;
	return $self->_write_record($self->env_path($env, %opts) . '/pipeline',
		dependencies => join(',', @{$opts{dependencies} || []}),
		discovery    => $opts{discovery} // 'complete',
	);
}

# }}}
# certify - write or advance an environment's exodus deployment record {{{
#
# git.commit is the deployment-branch commit the deploy stood on and
# git.control_commit is the control commit that tip's newest marker names,
# which D87 makes the pair the hatch case has to tell apart.
#
# dependencies_read is the fact half of the staleness comparison under D77, and
# it is written as one comma-joined value rather than as a list, because that
# is the one form a flat exodus record can carry.
sub certify {
	my ($self, $env, %opts) = @_;
	return $self->_write_record($self->env_path($env, %opts),
		'git.commit'         => $opts{commit},
		'git.control_commit' => $opts{control_commit},
		'dated'              => $self->_now($opts{at}),
		'state'              => $opts{state} // 'success',
		'dependencies_read'  => exists $opts{dependencies_read}
			? join(',', @{$opts{dependencies_read} || []}) : undef,
	);
}

# }}}
# fixture_hold - the hold record, with four fields and nothing else {{{
sub fixture_hold {
	my ($self, $env, %opts) = @_;
	die "fixture_hold needs a reason\n" unless defined $opts{reason};
	return $self->_write_record($self->env_path($env, %opts) . '/hold',
		reason   => $opts{reason},
		user     => $opts{user}     // 'operator',
		hostname => $opts{hostname} // 'harness.example.com',
		at       => $self->_now($opts{at}),
	);
}

# }}}
# fixture_proposed - the record naming what an open pull request proposes {{{
#
# The pull request's number arrives under pr, which is what the GitHub double
# and every row that opens one call it, and lands in the record's own field
# name, which is number.  A caller that has the record's spelling to hand may
# use number instead.
sub fixture_proposed {
	my ($self, $env, %opts) = @_;
	return $self->_write_record($self->env_path($env, %opts) . '/proposed',
		control_commit => $opts{control},
		number         => $opts{pr} // $opts{number},
		url            => $opts{url},
		at             => $self->_now($opts{at}),
	);
}

# }}}
# break_vault - make a read refuse, so a row can assert the refusal {{{
#
# The records are moved aside rather than deleted, so restore_vault can put
# them back and a row can assert on both sides of the break in one fixture.
#
# applied is additive to envs rather than an alternative to it, and an envs of
# its own decides the environment list even where that list is empty, so
# break_vault($h, envs => [], applied => 1) takes the applied record alone
# while break_vault($h, applied => 1) takes it along with every environment.
#
# Both movers name the fixture's target outright, so a harness that never built
# the fixture is refused rather than left to move records in whatever vault the
# ambient safe target happens to be.
sub break_vault {
	my ($self, %opts) = @_;
	die "break_vault needs a vault fixture, and this harness has none\n"
		unless $self->{vault_target};
	my $envs = exists $opts{envs} ? $opts{envs} : $self->{envs};
	my @paths = map {$self->env_path($_)} @{$envs || []};
	push @paths, $self->applied_path if $opts{applied};

	for my $path (@paths) {
		my $aside = $path . '-aside';
		run({env => {SAFE_TARGET => $self->{vault_target}}, passfail => 1},
			'safe', 'move', $path, $aside);
		push @{$self->{broken}}, [$path, $aside];
	}
	return $self;
}

# }}}
# restore_vault - put back what break_vault moved aside {{{
sub restore_vault {
	my ($self) = @_;
	die "restore_vault needs a vault fixture, and this harness has none\n"
		unless $self->{vault_target};
	for my $pair (@{delete($self->{broken}) || []}) {
		run({env => {SAFE_TARGET => $self->{vault_target}}, passfail => 1},
			'safe', 'move', $pair->[1], $pair->[0]);
	}
	return $self;
}

# }}}

1;
