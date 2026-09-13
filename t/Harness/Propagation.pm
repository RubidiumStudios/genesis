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
	tip_of remote_sha refs_in branch_of files_at slurp
/;

push @EXPORT, qw/
	init_branch deliver propagation_set harness_marker
	add_deployment_root write_env_file
/;

push @EXPORT, qw/
	hand_commit local_only_commit squash_merge unrelated_branch
	diverge move_on_r delete_on_r delete_local
	rewrite_control rewrite_branch
/;

push @EXPORT, qw/
	fixture_vault fixture_applied fixture_pipeline_record certify
	fixture_hold fixture_proposed break_vault restore_vault
/;

push @EXPORT, qw/
	snapshot_w assert_w_restored fixture_command
	run_genesis run_genesis_in stand_on
/;

push @EXPORT, qw/assert_snapshot_invariant/;

push @EXPORT, qw/
	fault_git fail_on step_log reset_steps sever_remote restore_remote
	hold_session_lock release_session_lock
/;

push @EXPORT, qw/
	github_double gh_pull_request gh_close_pr gh_merge_pr
	gh_protection gh_unreachable gh_reachable gh_no_token gh_calls
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
# tip_of - a branch's tip in one of the two copies, or undef {{{
#
# The remote option reads the copy's remote-tracking ref instead, which is
# T, and is how a row tells L from T without reaching for git itself.
sub tip_of {
	my ($self, $branch, %opts) = @_;
	my $copy = $opts{copy} // 'a';
	my $ref  = $opts{remote} ? "refs/remotes/origin/$branch"
	                         : "refs/heads/$branch";
	return ref_in($self->{$copy}, $ref);
}

# }}}
# remote_sha - a branch's sha on R, or undef {{{
sub remote_sha {
	my ($self, $branch) = @_;
	return ref_in($self->{r}, "refs/heads/$branch");
}

# }}}
# refs_in - every ref in a repository, as a hashref of name to sha {{{
#
# The prefix option is handed to git as a ref pattern, so a caller wanting
# one namespace reads that namespace back rather than sorting the rest out
# for itself.
sub refs_in {
	my ($dir, %opts) = @_;
	my @args = ('git', 'for-each-ref', '--format=%(refname) %(objectname)');
	push @args, $opts{prefix} if $opts{prefix};
	my ($out) = run({dir => $dir}, @args);
	my %refs;
	for my $line (split /\n/, ($out // '')) {
		my ($name, $sha) = split /\s+/, $line, 2;
		$refs{$name} = $sha if $name;
	}
	return \%refs;
}

# }}}
# branch_of - the branch a repository is standing on {{{
sub branch_of {
	my ($dir) = @_;
	my ($branch) = run({dir => $dir}, 'git', 'rev-parse', '--abbrev-ref', 'HEAD');
	chomp $branch;
	return $branch;
}

# }}}
# files_at - a commit's paths with their contents {{{
#
# The rows that assert a mirror want the whole tree in one hashref, so they
# can compare a branch against its source without a call per file.  The ref
# that is not there reads back an empty set, because tree_of hands one up.
sub files_at {
	my ($self, $ref, %opts) = @_;
	my $dir = $opts{dir} // ($opts{copy} ? $self->{$opts{copy}} : $self->{r});
	my %files;
	for my $path (@{tree_of($dir, $ref)}) {
		my ($content) = run({dir => $dir}, 'git', 'show', "$ref:$path");
		$files{$path} = $content;
	}
	return \%files;
}

# }}}
# slurp - a file's whole contents, or undef {{{
#
# Genesis exports a slurp of its own that bails where the file is absent, so
# a test file that wants this one imports Genesis before the harness.
sub slurp {
	my ($path) = @_;
	return undef unless -f $path;
	return helper::get_file($path);
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

sub gh { $_[0]->{gh} }

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
# A caller that is comparing trees in one copy names that copy instead, so the
# marker and the trees it is read against come out of the same repository.
sub harness_marker {
	my ($self, $ref, %opts) = @_;
	my $limit = $opts{limit} // 20;
	my $only  = $opts{copy};
	die "harness_marker was given the copy $only, which is none of a, b, or r\n"
		if defined $only && !grep {$only eq $_} qw/a b r/;

	my @search = defined $only ? ($self->{$only})
	                           : ($self->{r}, $self->{a}, $self->{b});
	my ($dir) = grep {defined ref_in($_, $ref)} @search;
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
# _ensure_branch - give a copy a local branch it has never seen {{{
#
# _commit_in checks the branch out, and a checkout of a name the copy holds
# nowhere fails, so a helper that writes a deployment branch in copy B has to
# put the branch there first.  _branch_parent already answers the right
# commit, which is the copy's own branch where it has one and R's tip
# otherwise, and it brings the objects across by path so no
# remote-tracking ref moves.  Where neither repository has the branch there
# is nothing to create and the caller is left to fail on its own terms.
sub _ensure_branch {
	my ($self, $copy, $branch) = @_;
	return $self if ref_in($self->{$copy}, "refs/heads/$branch");

	my $at = $self->_branch_parent($copy, $branch) or return $self;
	run({dir => $self->{$copy}, onfailure => "Failed to write $branch in copy $copy"},
		'git', 'update-ref', "refs/heads/$branch", $at);
	return $self;
}

# }}}
# hand_commit - a commit on a branch carrying no marker {{{
#
# D33 keeps the emergency hatch open, so a row needs a commit an operator
# made by hand.  It is written from copy B by default, because a hand edit
# the operator's own clone has not seen is the interesting case.
sub hand_commit {
	my ($self, $branch, %opts) = @_;
	my $copy = $opts{copy} // 'b';
	$self->_ensure_branch($copy, $branch) if defined $branch;
	return $self->_commit_in($copy, $branch,
		files   => $opts{files} // {'by-hand.yml' => "---\nby: hand\n"},
		message => $opts{message} // 'Fix it by hand',
		push    => defined $opts{push} ? $opts{push} : 1,
	);
}

# }}}
# local_only_commit - a commit in copy A that is never pushed {{{
#
# The marker option takes a control sha to give the commit a marker subject
# or 0 to give it none, because T92 and T93 need both kinds of local commit
# standing in front of a refresh.
sub local_only_commit {
	my ($self, $branch, %opts) = @_;
	my $message = $opts{message} // 'a local change';
	$message = sprintf('[pipeline] control@%s -> local',
		substr($opts{marker}, 0, 12)) if $opts{marker};
	$self->_ensure_branch('a', $branch) if defined $branch;
	return $self->_commit_in('a', $branch,
		files   => $opts{files} // {'local.yml' => "---\nlocal: true\n"},
		message => $message,
		push    => 0,
	);
}

# }}}
# squash_merge - squash the PR branch onto the deployment branch {{{
#
# A squash keeps the merger's title as the subject and pushes the merged
# message down into the body, which is the shape the marker reader of M6
# has to survive.  keep_marker off is the site that lost it altogether.
sub squash_merge {
	my ($self, $env, %opts) = @_;
	my $branch  = $self->slug($env, %opts);
	my $pr      = $self->pr_branch($env, %opts);
	my $control = $opts{control} // $self->git('a')->sha($self->{control});
	my $keep    = defined $opts{keep_marker} ? $opts{keep_marker} : 1;

	# A row that has not built the pull request branch for itself gets the
	# aggregate built here, because the squash is about what the merge does
	# to the marker and not about how the branch came to exist.  The branch
	# is cut off the deployment branch first, which is where the product
	# opens it, and the delivery is written in copy A, which is the copy the
	# plumbing below reads its tree out of.
	unless (ref_in($self->{a}, "refs/heads/$pr")) {
		my $base = $self->_branch_parent('a', $branch);
		run({dir => $self->{a}, onfailure => "Failed to cut $pr"},
			'git', 'update-ref', "refs/heads/$pr", $base) if $base;
		$self->deliver($env, %opts,
			control => $control, pr => 1, copy => 'a', push => 0);
	}

	my ($tree) = run({dir => $self->{a}}, 'git', 'rev-parse', "$pr^{tree}");
	chomp $tree;
	my $parent = ref_in($self->{a}, "refs/heads/$branch");

	my $message = $opts{subject} // "Merge pull request from $pr";
	$message .= sprintf("\n\n[pipeline] control@%s -> %s\n",
		substr($control, 0, 12), $env) if $keep;

	my ($sha) = run({dir => $self->{a}, onfailure => "Failed to squash $pr"},
		'git', 'commit-tree', $tree, ($parent ? ('-p', $parent) : ()),
		'-m', $message);
	chomp $sha;
	run({dir => $self->{a}}, 'git', 'update-ref', "refs/heads/$branch", $sha);
	$self->push_from('a', $branch) if (defined $opts{push} ? $opts{push} : 1);
	return $sha;
}

# }}}
# unrelated_branch - a local branch of the slug's name sharing no history {{{
#
# T98 refuses on this shape, which is a branch of the right name whose
# counterpart on R exists and shares no ancestor with it.  An orphan root
# commit is the only way to build one.
sub unrelated_branch {
	my ($self, $env, %opts) = @_;
	my $branch = $self->slug($env, %opts);
	my $dir    = $self->{a};

	my $index = "$self->{base}/idx-" . int(rand(1_000_000));
	local $ENV{GIT_INDEX_FILE} = $index;
	run({dir => $dir}, 'git', 'read-tree', '--empty');
	my $tmp = "$self->{base}/blob-" . int(rand(1_000_000));
	helper::put_file($tmp, "an unrelated history\n");
	my ($blob) = run({dir => $dir}, 'git', 'hash-object', '-w', $tmp);
	chomp $blob;
	run({dir => $dir}, 'git', 'update-index', '--add', '--cacheinfo',
		"100644,$blob,unrelated");
	my ($tree) = run({dir => $dir}, 'git', 'write-tree');
	chomp $tree;
	unlink $index;

	my ($sha) = run({dir => $dir}, 'git', 'commit-tree', $tree,
		'-m', 'an unrelated root');
	chomp $sha;
	run({dir => $dir}, 'git', 'update-ref', "refs/heads/$branch", $sha);
	return $sha;
}

# }}}
# diverge - leave L and T each holding commits the other lacks {{{
#
# The refresh in the middle is what makes the divergence one copy A can
# read: the teammate's commits have to reach copy A's remote-tracking ref
# before the local ones are written, or the left-right count answers two
# ahead of a T that never moved.
sub diverge {
	my ($self, $branch, %opts) = @_;
	my $local  = defined $opts{local}  ? $opts{local}  : 1;
	my $remote = defined $opts{remote} ? $opts{remote} : 1;

	$self->_ensure_branch('b', $branch) if defined $branch;
	$self->_commit_in('b', $branch,
		files   => {"from-b-$_.yml" => "---\nn: $_\n"},
		message => "a teammate's change $_",
		push    => 1,
	) for 1 .. $remote;

	$self->refresh('a', $branch // $self->{control}) if $remote;

	$self->_ensure_branch('a', $branch) if defined $branch;
	$self->_commit_in('a', $branch,
		files   => {"from-a-$_.yml" => "---\nn: $_\n"},
		message => "a local change $_",
		push    => 0,
	) for 1 .. $local;

	return $self;
}

# }}}
# move_on_r - have copy B advance a branch on R behind copy A's back {{{
#
# This is how a row makes an expected-tip push fail under D51 and D83.  Copy
# A is not refreshed afterwards, so its remote-tracking ref still names the
# commit the run will offer git as the expected tip.
sub move_on_r {
	my ($self, $branch, %opts) = @_;
	run({dir => $self->{b}}, 'git', 'fetch', '-q', 'origin', $branch);
	run({dir => $self->{b}}, 'git', 'update-ref', "refs/heads/$branch",
		"refs/remotes/origin/$branch");
	return $self->_commit_in('b', $branch,
		files   => $opts{files} // {'moved.yml' => "---\nmoved: true\n"},
		message => $opts{message} // 'a teammate moved the branch',
		push    => 1,
	);
}

# }}}
# delete_on_r, delete_local - take branches away {{{
sub delete_on_r {
	my ($self, @branches) = @_;
	run({dir => $self->{r}, onfailure => "Failed to delete $_ from R"},
		'git', 'update-ref', '-d', "refs/heads/$_") for @branches;
	return $self;
}

sub delete_local {
	my ($self, $copy, @branches) = @_;
	run({dir => $self->{$copy}}, 'git', 'update-ref', '-d', "refs/heads/$_")
		for @branches;
	return $self;
}

# }}}
# rewrite_control, rewrite_branch - force-push with one commit dropped {{{
#
# T135 and T292 read a control commit that a rewrite made unreachable, and
# T245 wants the same thing done to a deployment branch, so the two share
# one body.  The returned sha is the commit that is now unreachable.
sub rewrite_control {
	my ($self, %opts) = @_;
	return $self->rewrite_branch($self->{control}, %opts);
}

sub rewrite_branch {
	my ($self, $branch, %opts) = @_;
	my $count = $opts{count} // 1;

	# The rewrite runs in copy B, because a rebase checks out and copy A's
	# working state is what the rows assert on.
	my $dir = $self->{b};
	run({dir => $dir}, 'git', 'fetch', '-q', 'origin', $branch);
	my ($listed) = run({dir => $dir}, 'git', 'rev-list',
		'--max-count=' . ($count + 2), "origin/$branch");
	my @shas = split /\n/, ($listed // '');
	my $drop = $opts{drop} // $shas[1];
	die "There is no commit to drop from $branch\n" unless $drop;

	run({dir => $dir}, 'git', 'checkout', '-q', '-B', "rewrite-$branch",
		"origin/$branch");
	run({dir => $dir, env => {GIT_SEQUENCE_EDITOR => 'true'},
			onfailure => "Failed to rewrite $branch"},
		'git', 'rebase', '--onto', "$drop~1", $drop, "rewrite-$branch");
	run({dir => $dir, onfailure => "Failed to force-push $branch"},
		'git', 'push', '-q', '--force', 'origin', "HEAD:$branch");
	run({dir => $dir}, 'git', 'checkout', '-q', $self->{control});

	return $drop;
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

# snapshot_w - read the five parts of working state {{{
#
# Branch, HEAD sha, current directory, porcelain status, and index.  The
# status and the index are read separately, because a file staged and then
# restored in the tree shows in one and not the other.
#
# The current directory is read before anything else, because a command that
# switched away can leave us standing in a directory the switch removed, and
# every reader below runs through pushd, which cannot return to a directory
# that is no longer there.  Where that has happened we step back into the copy
# and still answer the directory as undefined, which is what it is.
sub snapshot_w {
	my ($self, %opts) = @_;
	my $dir = $self->{$opts{copy} // 'a'};

	my $cwd = Cwd::getcwd();
	chdir $dir or die "cannot return to $dir: $!\n" unless defined $cwd;

	my ($branch) = run({dir => $dir}, 'git', 'rev-parse', '--abbrev-ref', 'HEAD');
	my $head     = ref_in($dir, 'HEAD');
	my ($status) = run({dir => $dir}, 'git', 'status', '--porcelain');
	my ($index)  = run({dir => $dir}, 'git', 'diff-index', '--cached', '--name-status', 'HEAD');
	chomp for grep {defined} ($branch, $status, $index);

	return {
		dir    => $dir,
		cwd    => $cwd,
		branch => $branch,
		head   => $head,
		status => $status // '',
		index  => $index  // '',
	};
}

# }}}
# assert_w_restored - I1, read through {{{
#
# Compares all five parts against the snapshot and names every one that
# differs.  It runs on success and on failure alike, because I1 promises
# restoration on every exit path and an assertion that only runs when the
# command succeeded proves nothing about the paths that matter.
our $BUILDER;
sub assert_w_restored {
	my ($w, $name) = @_;
	my $builder = $BUILDER // Test::More->builder;
	$name //= 'working state is restored';

	my $now = snapshot_w(bless {a => $w->{dir}}, __PACKAGE__);

	my @differed;
	push @differed, sprintf("branch: %s, was %s", $now->{branch}, $w->{branch})
		unless $now->{branch} eq $w->{branch};
	push @differed, sprintf("HEAD: %s, was %s", $now->{head} // '(none)', $w->{head} // '(none)')
		unless ($now->{head} // '') eq ($w->{head} // '');
	push @differed, sprintf("current directory: %s, was %s",
			$now->{cwd} // '(none)', $w->{cwd} // '(none)')
		unless ($now->{cwd} // '') eq ($w->{cwd} // '');
	push @differed, sprintf("tree: %s", $now->{status})
		unless $now->{status} eq $w->{status};
	push @differed, sprintf("index: %s", $now->{index})
		unless $now->{index} eq $w->{index};

	my $ok = $builder->ok(!@differed, $name);
	$builder->diag("    $_") for @differed;
	return $ok;
}

# }}}
# assert_snapshot_invariant - I7, read through {{{
#
# Two comparisons and not one, for D82's reason.  The source tree at the
# delivered control commit carries every environment's files, so no
# whole-tree comparison is possible: the branch has to match the source over
# the set's paths, and hold nothing outside the set.  The second is the half
# that fires in practice, because a copy-only writer never removes a leftover
# init or a path that dropped out of the set.
sub assert_snapshot_invariant {
	my ($self, $env, %opts) = @_;
	my $builder = $BUILDER // Test::More->builder;
	my $dir     = $self->{$opts{copy} // 'a'};
	my $branch  = $self->slug($env, %opts);
	my $at      = $opts{commit} // $branch;
	my $name    = $opts{name} // "$branch mirrors its marker's control commit";

	my $control = $self->harness_marker($at, copy => $opts{copy});
	unless ($control) {
		my $ok = $builder->ok(0, $name);
		$builder->diag("    no marker on $branch, so nothing names a source");
		return $ok;
	}

	my @set = $self->propagation_set($env, at => $control, %opts);
	my %in_set = map {$_ => 1} @set;

	my @differed;
	for my $path (@set) {
		my ($want) = run({dir => $dir, passfail => 0},
			'git', 'rev-parse', "$control:$path");
		my ($got)  = run({dir => $dir, passfail => 0},
			'git', 'rev-parse', "$at:$path");
		chomp for grep {defined} ($want, $got);
		next if defined $want && defined $got && $want eq $got;
		push @differed, sprintf("%s differs from control@%s", $path, substr($control, 0, 12));
	}

	my ($listing, $rc) = run({dir => $dir, passfail => 0},
		'git', 'ls-tree', '-r', '--name-only', $at);
	if ($rc) {
		# git writes its complaint to the same handle as the listing, so a
		# failed read whose output was walked would report the words of an
		# error message as leftover paths.
		push @differed, sprintf("%s is not a tree in the repository read", $at);
	} else {
		chomp $listing if defined $listing;
		for my $path (split /\n/, ($listing // '')) {
			next if $in_set{$path};
			push @differed, sprintf("%s is on the branch and not in the set", $path);
		}
	}

	my $ok = $builder->ok(!@differed, $name);
	$builder->diag("    $_") for @differed;
	return $ok;
}

# }}}
# fixture_command - the four shapes of working state that T3 drives {{{
#
# Not genesis commands.  T3 exercises the assertion itself, so each shape is
# the smallest piece of git that produces it.
sub fixture_command {
	my ($self, $kind, %opts) = @_;
	my $dir = $self->{$opts{copy} // 'a'};

	return sub {
		run({dir => $dir}, 'git', 'checkout', '-q', $self->slug('qa'));
		run({dir => $dir}, 'git', 'checkout', '-q', $self->{control});
	} if $kind eq 'restores';

	return sub {
		run({dir => $dir}, 'git', 'checkout', '-q', $self->slug('qa'));
	} if $kind eq 'leaves_branch';

	return sub {
		helper::put_file("$dir/left-behind.yml", "---\nstaged: true\n");
		run({dir => $dir}, 'git', 'add', '--', 'left-behind.yml');
	} if $kind eq 'leaves_staged';

	# The last checkout names the repository with -C rather than running from
	# it, because a run that pushd's out of only-here has nowhere to return to
	# once the checkout has removed it.
	return sub {
		helper::mkdir_or_fail("$dir/only-here");
		helper::put_file("$dir/only-here/thing.yml", "---\n");
		run({dir => $dir}, 'git', 'add', '-A');
		run({dir => $dir}, 'git', 'commit', '-q', '-m', 'a directory on one branch');
		chdir "$dir/only-here" or die "cannot enter only-here: $!\n";
		run({}, 'git', '-C', $dir, 'checkout', '-q', 'HEAD~1');
	} if $kind eq 'loses_cwd';

	die "fixture_command does not know the kind '$kind'\n";
}

# }}}
# run_genesis - run a whole command in a copy and assert the restoration {{{
#
# Every row that runs a command goes through here, so the W snapshot and the
# assertion cannot be forgotten.  A row that asserts the restoration itself
# passes restore => 0 and calls the assertion in its own words.
#
# The exit code is handed back exactly as run gives it, because run has
# already shifted $?, and shifting it a second time turns every real code into
# a zero.
sub run_genesis {
	my ($self, @argv) = @_;
	my %opts = %{ref($argv[0]) eq 'HASH' ? shift @argv : {}};
	my $copy = $opts{copy} // 'a';
	my $dir  = $self->{$copy};
	$dir .= "/$opts{dir}" if $opts{dir};

	my $w = $self->snapshot_w(copy => $copy);

	my %env = (
		GENESIS_TOPDIR => $helper::TOPDIR,
		GENESIS_LIB    => "$helper::TOPDIR/lib",
		SAFE_TARGET    => $self->{vault_target},
	);
	$env{GENESIS_PIPELINE_TASK} = $opts{pipeline_task} if $opts{pipeline_task};
	$env{PATH} = join(':', $self->_path_prefix(%opts), $ENV{PATH});
	# gh_no_token is one shot.  The flag is consumed here whatever this run
	# decides, so the token is missing from this command's environment alone
	# and the run after it carries the token again.  The per-run no_token
	# option withholds it without arming anything.
	if ($self->{gh}) {
		my $armed = delete $self->{gh}{no_token};
		$env{GITHUB_AUTH_TOKEN} = $self->{gh}{token}
			unless $opts{no_token} || $armed;
	}

	# The fault plan reaches a spawned command through the environment, and the
	# subclass installs itself in the child through PERL5OPT.  The child's own
	# -I has to name lib/ as well as t/, because PERL5OPT is read before
	# bin/genesis compiles and puts GENESIS_LIB on @INC itself.
	if ($self->{fault}) {
		$env{GENESIS_HARNESS_GIT_PLAN} = $self->{fault}{plan};
		$env{GENESIS_HARNESS_GIT_LOG}  = $self->{fault}{log};
		$env{PERL5OPT} = join(' ',
			'-I' . $helper::TOPDIR . '/t', '-I' . $helper::TOPDIR . '/lib',
			'-MHarness::Propagation::Git', ($ENV{PERL5OPT} // ()));
	}

	helper::set_stdin(join("\n", @{$opts{answers}}, '')) if $opts{answers};
	my ($out, $rc, $err) = run({
			dir      => $dir,
			env      => \%env,
			stderr   => 0,
			passfail => 0,
		}, "$helper::TOPDIR/bin/genesis", @argv);
	helper::reset_stdin if $opts{answers};

	assert_w_restored($w, "working state is restored after `genesis @argv`")
		if ($opts{restore} // 1);

	return ($out, $err, $rc);
}

# }}}
# run_genesis_in - the same run, in a named copy {{{
sub run_genesis_in {
	my ($self, $copy, @argv) = @_;
	my %opts = %{ref($argv[0]) eq 'HASH' ? shift @argv : {}};
	return $self->run_genesis({%opts, copy => $copy}, @argv);
}

# }}}
# stand_on - put a copy on a branch, and optionally in a subdirectory {{{
sub stand_on {
	my ($self, $branch, %opts) = @_;
	my $dir = $self->{$opts{copy} // 'a'};
	run({dir => $dir, onfailure => "Failed to stand on $branch"},
		'git', 'checkout', '-q', $branch);
	chdir "$dir/$opts{dir}" or die "cannot enter $opts{dir}: $!\n" if $opts{dir};
	return $self;
}

# }}}
# fault_git - a subclass handle, with the plan and the log armed {{{
#
# The plan and the log are files named by the environment, so a command the
# harness spawns picks both up.  run_genesis carries them and PERL5OPT to the
# child, which is how a whole command meets an injected fault.
#
# Service::Git caches one instance per repository and answers every later
# caller with it, whatever class that caller named, so a copy that was read
# before the fault was armed already holds a plain handle.  We re-bless the
# cached instance rather than building a second one, and drop the harness's
# own cached handle, so every handle onto that copy faults from here on.
sub fault_git {
	my ($self, %opts) = @_;
	my $copy = $opts{copy} // 'a';

	$self->{fault}{plan} //= "$self->{base}/git-plan.json";
	$self->{fault}{log}  //= "$self->{base}/git-steps.log";
	helper::put_file($self->{fault}{plan}, '{}');
	helper::put_file($self->{fault}{log}, '');

	$ENV{GENESIS_HARNESS_GIT_PLAN} = $self->{fault}{plan};
	$ENV{GENESIS_HARNESS_GIT_LOG}  = $self->{fault}{log};

	require Harness::Propagation::Git;
	my $git = Harness::Propagation::Git->new($self->{$copy});
	bless $git, 'Harness::Propagation::Git';
	delete $self->{"_git_$copy"};

	return $self->{"_fault_git_$copy"} = $git;
}

# }}}
# fail_on - arm one named git step to die on its nth call {{{
sub fail_on {
	my ($git, $step, $n, %opts) = @_;
	my $file = $ENV{GENESIS_HARNESS_GIT_PLAN}
		or die "fail_on needs fault_git to have run first\n";

	my $plan = JSON::PP->new->decode(helper::get_file($file));
	$plan->{$step} = {n => $n, from => $opts{from} ? 1 : 0,
		message => $opts{message}};
	helper::put_file($file, JSON::PP->new->canonical->encode($plan));
	return $git;
}

# }}}
# step_log - every intercepted call, in order {{{
sub step_log {
	my ($git) = @_;
	my $file = $ENV{GENESIS_HARNESS_GIT_LOG} or return ();
	return () unless -f $file;
	my $json = JSON::PP->new;
	return map {$json->decode($_)} grep {/\S/} split /\n/, helper::get_file($file);
}

# }}}
# reset_steps - empty the log and the counters between a row's phases {{{
sub reset_steps {
	my ($git) = @_;
	helper::put_file($ENV{GENESIS_HARNESS_GIT_LOG}, '') if $ENV{GENESIS_HARNESS_GIT_LOG};
	if (my $file = $ENV{GENESIS_HARNESS_GIT_PLAN}) {
		my $plan = JSON::PP->new->decode(helper::get_file($file));
		delete $plan->{_counts};
		helper::put_file($file, JSON::PP->new->canonical->encode($plan));
	}
	return $git;
}

# }}}
# sever_remote - make every remote step fail as an unreachable remote would {{{
#
# The text is the one a real unreachable remote emits, because the code that
# tells a network failure from an authentication one reads stderr, and a row
# asserts that the run named the network as the reason.  The after option
# severs the remote partway through a run, which the unsurvivable rows need.
sub sever_remote {
	my ($self, %opts) = @_;
	my $git = $self->{"_fault_git_a"} // $self->fault_git;
	my $message = "fatal: unable to access '$self->{r}': "
		. "Could not resolve host: the remote is unreachable";
	fail_on($git, $_, $opts{after} // 1, from => 1, message => $message)
		for qw/fetch_branch fetch_branches push delete_remote_branch/;
	return $self;
}

# }}}
# restore_remote - disarm the remote steps again {{{
sub restore_remote {
	my ($self) = @_;
	my $file = $ENV{GENESIS_HARNESS_GIT_PLAN} or return $self;
	my $plan = JSON::PP->new->decode(helper::get_file($file));
	delete $plan->{$_} for qw/fetch_branch fetch_branches push delete_remote_branch/;
	helper::put_file($file, JSON::PP->new->canonical->encode($plan));
	return $self;
}

# }}}
# hold_session_lock - take the switch lock in a child process {{{
#
# The lock lands at M5, so here the harness takes the flock the design fixes,
# on genesis-session.lock in the git directory, and writes the pid and the
# command inside for the refusal message to read.  The pid is the first line
# and the command the second, so a reader that splits on newline gets both
# whatever the command holds.  A row that wants the lock released by the
# kernel kills the holder rather than letting it finish.
sub hold_session_lock {
	my ($self, %opts) = @_;
	my $dir  = $self->{$opts{copy} // 'a'};
	my $lock = "$dir/.git/genesis-session.lock";

	my $pid = fork();
	die "cannot fork a lock holder: $!\n" unless defined $pid;
	unless ($pid) {
		open my $fh, '>', $lock or POSIX::_exit(2);
		require Fcntl;
		flock($fh, Fcntl::LOCK_EX()) or POSIX::_exit(2);
		print $fh sprintf("%d\n%s\n", $$, $opts{command} // 'genesis propagate');
		require IO::Handle;
		$fh->flush;

		# Hold it until the row releases us, and never outlive the test that
		# forked us, so a row that dies leaves no process behind.
		my $parent = getppid();
		for (1 .. 300) {
			POSIX::_exit(0) if getppid() != $parent;
			sleep 1;
		}
		POSIX::_exit(0);
	}

	# Wait for the child to have the lock, so a row never races its own setup.
	for (1 .. 100) {
		last if -s $lock;
		select undef, undef, undef, 0.05;
	}
	push @{$self->{holders}}, $pid;
	return $pid;
}

# }}}
# release_session_lock - let the holder finish, or kill it outright {{{
sub release_session_lock {
	my ($self, $pid, %opts) = @_;
	kill($opts{hard} ? 'KILL' : 'TERM', $pid);
	waitpid($pid, 0);
	$self->{holders} = [grep {$_ != $pid} @{$self->{holders} || []}];
	return $self;
}

# }}}
# github_double - a fixture curl first on the path, with a state file {{{
#
# A double stands in for the GitHub API and for nothing else besides vault.
# It has to reach a spawned command, so it is a binary on the path rather than
# an object, and every call lands in a log the row reads back.  The two
# environment variables are the only thing the parent's environment gains: the
# path entry is added by _path_prefix for the run under test alone.
sub github_double {
	my ($self, %opts) = @_;

	my $bin = "$self->{base}/gh-bin";
	helper::mkdir_or_fail($bin);
	my $curl = "$bin/curl";
	helper::put_file($curl, 0755, helper::get_file("$helper::TOPDIR/t/Harness/bin/curl"));

	# The readers below take the double rather than the harness, because that
	# is how a row names them, so the double carries a way back to the state
	# file it is written in terms of.
	my $gh = $self->{gh} = {
		harness    => $self,
		bin        => $bin,
		state      => "$self->{base}/gh-state.json",
		log        => "$self->{base}/gh-calls.log",
		token      => $opts{token}      // 'harness-token',
		repository => $opts{repository} // 'owner/repo',
		domain     => 'github.test',
		admin      => defined $opts{admin} ? ($opts{admin} ? 1 : 0) : 1,
	};

	$self->_gh_write({prs => [], protection => {}, admin => $gh->{admin},
		domain => $gh->{domain}});
	helper::put_file($gh->{log}, '');

	$ENV{GENESIS_HARNESS_GH_STATE} = $gh->{state};
	$ENV{GENESIS_HARNESS_GH_LOG}   = $gh->{log};

	return $gh;
}

# }}}
# _gh_read and _gh_write - the double's state, kept in one file {{{
sub _gh_read {
	my ($self) = @_;
	return JSON::PP->new->decode(helper::get_file($self->{gh}{state}));
}

sub _gh_write {
	my ($self, $state) = @_;
	helper::put_file($self->{gh}{state}, JSON::PP->new->canonical->encode($state));
	return $state;
}

# }}}
# gh_pull_request - declare an open pull request with a review state {{{
#
# An environment names the two branches the propagation flow would have used,
# so a row that cares about neither says env and no more.
sub gh_pull_request {
	my ($gh, %opts) = @_;
	my $self  = $gh->{harness};
	my $state = $self->_gh_read;

	my $env = $opts{env};
	my $number = scalar(@{$state->{prs}}) + 1;
	push @{$state->{prs}}, {
		number  => $number,
		state   => 'open',
		merged  => JSON::PP::false,
		head    => {ref => $opts{head} // ($env ? $self->pr_branch($env) : '')},
		base    => {ref => $opts{base} // ($env ? $self->slug($env)      : '')},
		title   => $opts{title} // '',
		body    => $opts{body}  // '',
		created_at => $opts{at} // '2026-09-13T00:00:00Z',
		reviews => [($opts{review} && $opts{review} ne 'none') ? {
			state       => uc($opts{review}),
			user        => {login => $opts{reviewer} // 'reviewer'},
			body        => $opts{review_body} // '',
			submitted_at=> $opts{at} // '2026-09-13T00:00:00Z',
		} : ()],
	};
	$self->_gh_write($state);
	return $number;
}

# }}}
# gh_close_pr and gh_merge_pr - the two ways a pull request leaves the open set {{{
sub gh_close_pr {
	my ($gh, $number, %opts) = @_;
	my $self  = $gh->{harness};
	my $state = $self->_gh_read;
	for my $pr (@{$state->{prs}}) {
		next unless $pr->{number} == $number;
		$pr->{state}  = 'closed';
		$pr->{merged} = $opts{merged} ? JSON::PP::true : JSON::PP::false;
		$pr->{merged_at} = $opts{merged} ? ($opts{at} // '2026-09-13T00:00:00Z') : undef;
	}
	return $self->_gh_write($state);
}

sub gh_merge_pr {
	my ($gh, $number, %opts) = @_;
	my $self  = $gh->{harness};
	my $state = $self->_gh_read;
	$state->{merge_method}{$number} = $opts{method} // 'rebase';
	$self->_gh_write($state);
	gh_close_pr($gh, $number, merged => 1, at => $opts{at});
	return $self->_gh_read;
}

# }}}
# gh_protection - what the protection endpoints answer and record {{{
sub gh_protection {
	my ($gh, %opts) = @_;
	my $self  = $gh->{harness};
	my $state = $self->_gh_read;
	$state->{admin} = ($opts{admin} ? 1 : 0) if defined $opts{admin};
	$state->{protection}{$opts{branch}} = $opts{settings} if $opts{branch};
	$self->_gh_write($state);
	return $state->{protection};
}

# }}}
# gh_unreachable, gh_reachable, gh_no_token, gh_calls {{{
#
# gh_no_token takes the harness rather than the double, because the token is
# a fact about the environment a run is given and not about the API, and it is
# one shot: run_genesis consumes the flag, so the command after it carries the
# token again and the fixture curl stays where it is.
sub gh_unreachable {
	my ($gh) = @_;
	my $self  = $gh->{harness};
	my $state = $self->_gh_read;
	$state->{unreachable} = 1;
	return $self->_gh_write($state);
}

sub gh_reachable {
	my ($gh) = @_;
	my $self  = $gh->{harness};
	my $state = $self->_gh_read;
	delete $state->{unreachable};
	return $self->_gh_write($state);
}

sub gh_no_token {
	my ($self) = @_;
	$self->{gh}{no_token} = 1;
	return $self;
}

sub gh_calls {
	my ($gh) = @_;
	return () unless -f $gh->{log};
	my $json = JSON::PP->new;
	return map {$json->decode($_)} grep {/\S/} split /\n/, helper::get_file($gh->{log});
}

# }}}
# _path_prefix - the fixture binaries one run sees, and no other {{{
#
# The fixture git, the fixture curl, and the wrappers the observers write sit
# first on the path for the run under test alone, so the harness's own git
# calls still reach the real git and no fixture is left on the parent's path
# once the run is over.  The two directories are named whether or not they
# have been written yet, because a path entry that is not there is one the
# child steps over.
sub _path_prefix {
	my ($self, %opts) = @_;
	my @prefix;
	push @prefix, $self->_fake_git_dir($opts{git_version}) if $opts{git_version};
	push @prefix, "$self->{base}/gh-bin", "$self->{base}/bin";
	return @prefix;
}

# }}}
# _fake_git_dir - a git that reports a chosen version and passes the rest on {{{
#
# The prerequisites check asks git for its version through the shell, so a
# fixture on the path is what a row drives the floor with.  Everything else is
# handed to the real git, so the run still does real work on real refs.
sub _fake_git_dir {
	my ($self, $version) = @_;
	my $dir = "$self->{base}/git-$version";
	return $dir if -d $dir;

	helper::mkdir_or_fail($dir);
	my ($real) = run({}, 'bash', '-c', 'command -v git');
	chomp $real;
	helper::put_file("$dir/git", 0755, <<"EOS");
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then
  echo "git version $version"
  exit 0
fi
exec $real "\$@"
EOS
	return $dir;
}

# }}}

1;
