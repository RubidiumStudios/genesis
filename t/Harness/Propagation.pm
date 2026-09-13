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

	# The environment files land through write_env_file, which the repository
	# shaping brings with it.  Until then the deployment root alone seeds the
	# control branch.
	if ($self->can('write_env_file')) {
		$self->write_env_file($_, commit => 0) for @{$self->{envs}};
	}

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

1;
