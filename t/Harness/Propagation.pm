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
use Genesis qw/run load_yaml_file/;
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
	branches_on_r fresh_clone subjects_of heads_in reachable_on_r
	newest_record
/;

push @EXPORT, qw/trailers_of/;

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
	amend_tip local_branch local_branch_only unset_control
	set_remotes set_repo_config move_on_r_at
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

push @EXPORT, qw/
	record_at vault_read_log fixture_preflight
/;

push @EXPORT, qw/
	child_recorder child_runs lock_probe lock_probe_log
	shuttle_spy shuttle_requests fixture_kit skip_on
/;

# The scenarios and the one-line shapes.
push @EXPORT, qw/
	ready_envs ready_harness seeded_harness staged due_harness gated_harness
	held_harness held_prod tracked_harness two_env_harness inherited_harness
	ready with_open_pr two_roots a_delivery seeded two_due three_due three
	chain gated proposed automated top_for
/;

push @EXPORT, qw/
	stale_set_delivery stage_unrelated modify_unrelated
/;

# _guard_env, _release_env - the fixture variables the parent has to hold {{{
#
# A fixture that arms a spawned command sets its variables in the parent
# process, because the child reads them out of the environment it inherits
# and a `local` in the arming sub would be undone before the command ever
# ran.  helper::local_env hands back a guard that puts each variable back as
# it found it, and the guards are kept here, so a fixture arms a variable and
# forgets it.
#
# They are released when a new harness is built and again when the file ends.
# Without that release a second harness in one file arms its own files and
# then reads the first harness's, and a file that armed anything at all hands
# the next file an environment it never asked for.
our @ENV_GUARDS;
sub _guard_env {
	my (%vars) = @_;
	push @ENV_GUARDS, helper::local_env(%vars);
	return;
}

sub _release_env {
	pop(@ENV_GUARDS)->restore while @ENV_GUARDS;
	return;
}

END {_release_env()}

# }}}
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
# branch_of - the branch a repository is standing on, or undef {{{
#
# The read is guarded the way tree_of and upstream_of are, because a
# repository whose HEAD is unborn prints a fatal to stderr and the word HEAD
# to stdout, and a reader that folds the two together answers git's complaint
# as though it were a branch name.
sub branch_of {
	my ($dir) = @_;
	my ($out, $rc) = run({dir => $dir, stderr => 0},
		'git', 'rev-parse', '--abbrev-ref', 'HEAD');
	return undef if $rc || !defined $out;
	chomp $out;
	return $out;
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
# branches_on_r - R's branch names, short and sorted {{{
#
# refs_in answers full refnames in a hashref, and the rows that ask this ask
# it against a plain list, so the shortening and the sort live here rather
# than in five copies at the call sites.
sub branches_on_r {
	my ($self) = @_;
	my $refs = refs_in($self->{r}, prefix => 'refs/heads');
	return [sort map {substr($_, length 'refs/heads/')} keys %$refs];
}

# }}}
# fresh_clone - a third clone of R, made now {{{
#
# A row that asks what a clone made today can still fetch needs a clone that
# carries none of the fixture's own history of fetches, which neither copy A
# nor copy B is once the harness has been built.  What such a clone sees of R
# is its remote-tracking refs, since a clone cuts exactly one local branch
# for itself whatever R holds.
sub fresh_clone {
	my ($self, %opts) = @_;
	my $dir = "$self->{base}/clone-" . int(rand(1_000_000));
	run({dir => $self->{base}, onfailure => "Failed to clone R"},
		'git', 'clone', '-q', $self->{r}, $dir);
	run({dir => $dir}, 'git', 'config', 'user.email', 'clone@genesis.example.com');
	run({dir => $dir}, 'git', 'config', 'user.name', 'A fresh clone');
	return $dir;
}

# }}}
# subjects_of - the last n subjects on a branch, oldest first {{{
#
# The remote-tracking ref rather than the local one, because a row asking
# what a run wrote is asking what reached R.  The reverse puts them in the
# order they were committed, which is how the rows read them.
#
# The read is stderr-suppressed and its status is checked, the way the eight
# readers above are, so a branch that is not there answers an empty list
# rather than git's complaint split into subjects.
sub subjects_of {
	my ($self, $branch, $n, %opts) = @_;
	my $copy = $opts{copy} // 'a';
	my $ref  = $opts{local} ? $branch : "refs/remotes/origin/$branch";
	my ($out, $rc) = run({dir => $self->{$copy}, stderr => 0, passfail => 0},
		'git', 'log', "--max-count=$n", '--format=%s', $ref);
	return () if $rc || !defined $out;
	chomp $out;
	return reverse grep {length} split /\n/, $out;
}

# }}}
# heads_in - every local head in a copy, as a sorted list of lines {{{
#
# A row that proves a command left L alone takes this before and after and
# compares the two, so the shape only has to be stable and readable.
sub heads_in {
	my ($self, %opts) = @_;
	my $copy = $opts{copy} // 'a';
	my $refs = refs_in($self->{$copy}, prefix => 'refs/heads');
	return [map {"$_ $refs->{$_}"} sort keys %$refs];
}

# }}}
# reachable_on_r - can R reach this commit at all {{{
#
# A record naming a commit R cannot reach is the breach D103's staleness read
# and M13's pre-flight both have to catch, and a row proves it by asking R
# rather than by trusting the record.  The object is looked for first,
# because merge-base cannot be asked about a commit the repository does not
# hold.
sub reachable_on_r {
	my ($self, $sha) = @_;
	return 0 unless $sha;
	my $ok = run({dir => $self->{r}, passfail => 1},
		'git', 'cat-file', '-e', "$sha^{commit}");
	return 0 unless $ok;
	for my $branch (@{$self->branches_on_r}) {
		return 1 if run({dir => $self->{r}, passfail => 1},
			'git', 'merge-base', '--is-ancestor', $sha, $branch);
	}
	return 0;
}

# }}}
# newest_record - the newest entry of a record set, read back nested {{{
#
# The fixture writes a flat record, because an exodus record is flat, and a
# row reads it as $record->{git}{commit}, so the dotted keys are inflated
# here.
#
# A record set is either one record at the path itself, which is what the
# harness's own writers lay down, or a path whose children are the entries,
# one per deploy and named for when it happened, which is what the deploy
# writes.  record_at reads the first shape and has no notion of the second,
# so where it answers nothing the children are listed through safe and the
# newest of them by name is the entry.  The path's own record is preferred,
# because an environment's record has children of its own that are not
# entries of its set, such as its hold and its proposal.
sub newest_record {
	my ($self, $path) = @_;
	my $flat = $self->record_at($path) // $self->_newest_entry($path);
	return undef unless $flat;

	my %nested;
	for my $key (sort keys %$flat) {
		my @parts = split /\./, $key;
		my $leaf  = pop @parts;
		my $at    = \%nested;
		$at = ($at->{$_} //= {}) for @parts;
		$at->{$leaf} = $flat->{$key};
	}
	return \%nested;
}

# }}}
# _newest_entry - the newest child of a record set, flat, or undef {{{
#
# safe export answers the whole subtree under the path it was given, keyed by
# each entry's own path without the leading slash, so the set's entries are
# the keys one segment below the path and the newest is the last of them in
# name order.
sub _newest_entry {
	my ($self, $path) = @_;
	$self->fixture_vault;
	my ($out, $rc) = run({env => {SAFE_TARGET => $self->{vault_target}},
			stderr => 0, passfail => 0},
		'safe', 'export', $path);
	return undef if $rc || !$out;
	my $exported = eval {JSON::PP->new->decode($out)} or return undef;

	(my $key = $path) =~ s{/{2,}}{/}g;
	$key =~ s{^/}{};
	$key =~ s{/$}{};
	my ($newest) = reverse sort grep {m{^\Q$key\E/[^/]+$}} keys %$exported;
	return defined $newest ? $exported->{$newest} : undef;
}

# }}}
# trailers_of - one commit's trailers, as git itself parses them {{{
#
# A row proving a gate has to read the trailer back, and picking the message
# apart here would prove this file's own regex rather than what git sees, so
# the message is handed to `git interpret-trailers --parse`, which is the
# reader the gate itself will use.  A commit carrying no trailer, and a
# commit the copy does not hold, each answer an empty hashref, so a row
# proving an absence reads it rather than trapping a death.
sub trailers_of {
	my ($self, $ref, %opts) = @_;
	my $dir = $self->{$opts{copy} // 'a'};
	return {} unless _has_commit($dir, $ref);

	my ($message) = run({dir => $dir}, 'git', 'log', '-1', '--format=%B', $ref);
	my $file = "$self->{base}/trailers.msg";
	helper::put_file($file, $message // '');

	my ($parsed) = run({dir => $dir},
		'git', 'interpret-trailers', '--parse', $file);

	my %trailers;
	for my $line (split /\n/, ($parsed // '')) {
		$trailers{$1} = $2 if $line =~ /^(\S[^:]*):\s*(.*)$/;
	}
	return \%trailers;
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

	# Whatever the harness above this one armed in the parent goes back before
	# the new one arms anything of its own, so no fixture of this harness is
	# read through a variable naming the last harness's file.
	_release_env();

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
		# The default is an enabled pipeline section, because the .genesis/config
		# schema declares the pipeline key and nearly every row runs against a
		# repository that has one.  A row that wants the section switched off,
		# or wants no section at all, says so.
		pipeline  => defined $opts{pipeline} ? $opts{pipeline} : 1,
		source_control => $opts{source_control},
		kit       => $opts{kit},
		embed     => $opts{embed},
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

	# create writes no pipeline section at all, and every row that reads a
	# provider reads it out of this file, so the section is written afterwards
	# from the options the harness was declared with.
	$self->_seed_pipeline_section($root);

	# The kit goes in before the seeding commit, so a row that named one runs
	# against a repository whose kit is part of the control branch rather than
	# against a working tree carrying a directory nothing tracks.
	$self->_install_kit($root);

	# The embedded genesis goes in before the seeding commit too, so a row
	# that asserts the eighth kind of the propagation set has a file to find
	# on the control branch rather than a path nothing tracks.
	$self->_embed_genesis($root) if $self->{embed};

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
# _seed_pipeline_section - the pipeline block the declared options ask for {{{
#
# The pipeline option takes three values rather than two.  1 is an enabled
# pipeline, 0 is a section whose enabled is false, and the string none is a
# configuration with no pipeline section at all, because those are two
# different refusals and one boolean cannot tell them apart.  A hashref means
# an enabled pipeline with those repository-wide keys set.
#
# The mode option writes nothing here.  Whether a delivery goes through a
# pull request is a per-environment question, so make_harness's pr mode is
# written as genesis.pipeline.require_pr on each environment file instead.
#
# The control branch and the pull-request prefix are written as the options
# name them, so a row that asked for a control branch of its own gets a
# repository whose configuration agrees with the branch the harness built.
#
# The repository is written too, and it is the one value the harness cannot
# leave to the code.  Copy A is cloned from a bare repository at a
# filesystem path, so its origin URL carries no GitHub owner/repo pair and
# the derivation has nothing to read.  A row that proves that refusal takes
# the override away by naming repository as undef.
sub _seed_pipeline_section {
	my ($self, $root) = @_;
	my $want = $self->{pipeline};
	return $self if defined $want && $want eq 'none';

	require Genesis::Config;
	my $config = Genesis::Config->new("$root/.genesis/config");
	my %keys = (ref $want eq 'HASH') ? %$want : ();
	my %sc   = (
		control_branch => $self->{control},
		pr_prefix      => $self->{pr_prefix},
		repository     => sprintf('genesis/%s-deployments', $self->{type}),
		%{$self->{source_control} || {}},
	);

	$config->set('pipeline.enabled' => (ref $want eq 'HASH') ? 1 : ($want ? 1 : 0));
	$config->set('pipeline.provider.type' => $self->{provider});
	$config->set("pipeline.source_control.$_" => $sc{$_})
		for grep {defined $sc{$_}} sort keys %sc;
	$config->set("pipeline.$_" => $keys{$_}) for sort keys %keys;
	$config->save;

	return $self;
}

# }}}
# _install_kit - put one of the kits the suite ships in as the dev kit {{{
#
# make_harness's kit option names a kit rather than describing one, so a row
# that wants the blueprint that raises or the manifest that reads exodus says
# so in a word.  The copy lands at the deployment root's dev directory, which
# is where the kit reference every environment file carries points.
#
# A value carrying a slash is read as a path under the checkout root instead,
# so a row can name a kit the suite already ships elsewhere, such as
# t/src/ops-blueprint, rather than a copy of it written for these rows alone.
# A bare name still resolves under t/kits/.
sub _install_kit {
	my ($self, $root) = @_;
	my $name = $self->{kit} or return $self;

	my $from = $name =~ m{/}
		? "$helper::TOPDIR/$name"
		: "$helper::TOPDIR/t/kits/$name";
	die "make_harness does not know the kit $name\n" unless -d $from;
	run({dir => $self->{base}, onfailure => "Failed to install the $name kit"},
		'cp', '-R', $from, "$root/dev");

	return $self;
}

# }}}
# _embed_genesis - stand a genesis in at .genesis/bin/genesis {{{
#
# Genesis::Top::embed writes the running genesis there for CI to call, and a
# row that wants that path in a tree wants a file rather than the megabytes of
# the real one, so the harness writes an executable stub and commits it with
# the deployment root.
sub _embed_genesis {
	my ($self, $root) = @_;

	helper::mkdir_or_fail("$root/.genesis/bin") unless -d "$root/.genesis/bin";
	helper::put_file("$root/.genesis/bin/genesis", 0755,
		"#!/bin/sh\n# stands in for the genesis Top::embed writes\nexit 0\n");

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
		qr{^\Q$prefix\Ekit-overrides\.yml$},
	);
	# The hierarchy is the ancestors and the environment's own file, which is
	# what propagation_files joins from actual_environment_files, and Genesis
	# names an ancestor by a cumulative hyphen-prefix of the environment.  A
	# pattern anchored on the environment's own name alone matches the leaf
	# and nothing above it, and a delivery written from that leaves the site
	# file off the branch, so every genesis.pipeline.* key set there reads as
	# absent to a command standing on the deployment branch.
	my @tokens = split /-/, $env;
	for my $i (0 .. $#tokens - 1) {
		my $ancestor = join('-', @tokens[0 .. $i]);
		push @kinds, qr{^\Q$prefix$ancestor\E\.yml$};
	}
	# The reactions, the ops files, and the kit source are one kind, and the
	# environment file's own tracked list narrows that kind wherever the file
	# at $at declares one, so a delivery made under a wider list leaves behind
	# paths the next delivery has to remove.  Where the file declares no list
	# at all the kind stands unnarrowed, which is every environment the suite
	# writes without saying otherwise.
	my $tracked = $self->_tracked_files($at, "$prefix$env.yml");
	push @kinds, defined $tracked
		? (map {qr{^\Q$prefix$_\E$}} @$tracked)
		: qr{^\Q$prefix\E(?:bin|ops|dev)/};
	# track_additional_files joins the set git-root-relative, in one form, so
	# the walk and the writer name a tracked path the same way.
	push @kinds, map {qr{^\Q$_\E$}}
		@{$opts{extra} || ($self->{extra} || {})->{$env} || []};

	my @set = grep {my $p = $_; grep {$p =~ $_} @kinds} @all;
	return sort @set;
}

# }}}
# _tracked_files - the tracked list an environment file declares at a commit {{{
#
# D69 reads the set from the tree at the commit being delivered, so the list
# that narrows it is read there too and never from the working tree.  The
# answer is the list's deployment-root-relative paths where the file declares
# one, and undef where it declares none, which is how propagation_set tells a
# narrowed kind from an untouched one.
#
# The list is genesis.pipeline.track_additional_files, which is the key
# Genesis::Env::track_additional_files reads out of the merged environment,
# because two readers of one key must not disagree about where it lives.
#
# The parse is cached on the file's own text, because spruce is a process per
# call and every delivery reads the set.
my %TRACKED;
sub _tracked_files {
	my ($self, $at, $path) = @_;

	my ($body, $rc) = run({dir => $self->_repo_holding($at), stderr => 0},
		'git', 'show', "$at:$path");
	return undef unless defined $rc && $rc == 0 && defined $body;
	return $TRACKED{$body} if exists $TRACKED{$body};

	my $tmp = "$self->{base}/env-" . int(rand(1_000_000)) . '.yml';
	helper::put_file($tmp, $body);
	my ($yaml, $failed) = load_yaml_file($tmp);
	unlink $tmp;

	# The key is read where the product reads it, which is under
	# genesis.pipeline, and a file that puts something other than a map there
	# declares no list at all rather than dying on the read.
	my $genesis  = $failed ? {} : (($yaml || {})->{genesis} || {});
	my $pipeline = ref $genesis eq 'HASH' ? ($genesis->{pipeline} || {}) : {};
	my $declared = ref $pipeline eq 'HASH'
		? $pipeline->{track_additional_files} : undef;
	return $TRACKED{$body} = ref $declared eq 'ARRAY' ? $declared
	                       : defined $declared        ? [$declared]
	                       :                            undef;
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
# amend_tip - amend a branch tip in place and force-push it {{{
#
# T85 needs the amend case, in which the subject a reader would walk is
# replaced and the message it replaced is pushed down into the body, so a
# marker that was in the subject is now in the body alone.
sub amend_tip {
	my ($self, $branch, %opts) = @_;
	my $copy = $opts{copy} // 'b';
	my $dir  = $self->{$copy};

	run({dir => $dir}, 'git', 'fetch', '-q', 'origin', $branch);
	run({dir => $dir}, 'git', 'checkout', '-q', '-B', $branch,
		"refs/remotes/origin/$branch");

	if (my $files = $opts{files}) {
		helper::put_file("$dir/$_", $files->{$_}) for keys %$files;
		run({dir => $dir}, 'git', 'add', '-A');
	}

	my $message = $opts{message};
	if (!defined $message && defined $opts{subject}) {
		my ($old) = run({dir => $dir}, 'git', 'log', '-1', '--format=%B', $branch);
		$message = "$opts{subject}\n\n$old";
	}

	run({dir => $dir, onfailure => "Failed to amend $branch"},
		'git', 'commit', '-q', '--amend', '--allow-empty',
		($message ? ('-m', $message) : ('--no-edit')));

	run({dir => $dir, onfailure => "Failed to force-push $branch"},
		'git', 'push', '-q', '--force', 'origin', $branch)
		if (defined $opts{push} ? $opts{push} : 1);

	return ref_in($dir, "refs/heads/$branch");
}

# }}}
# local_branch - a branch that no delivery created {{{
sub local_branch {
	my ($self, $branch, %opts) = @_;
	my $copy = $opts{copy} // 'a';
	my $at   = $opts{at} // branch_of($self->{$copy});
	my $sha  = ref_in($self->{$copy}, $at) // $at;

	run({dir => $self->{$copy}}, 'git', 'update-ref', "refs/heads/$branch", $sha);
	$self->push_from($copy, $branch) if $opts{push};
	return $sha;
}

# }}}
# local_branch_only - a deployment branch R has never had {{{
#
# T97 and the no-remote arm of T89 turn on a branch this clone made and never
# published, which is a different shape from unrelated_branch, where R has the
# branch and the two share no ancestor.
sub local_branch_only {
	my ($self, $env, %opts) = @_;
	return $self->local_branch($self->slug($env, %opts), %opts, push => 0);
}

# }}}
# unset_control - a repository whose control branch exists nowhere {{{
#
# T100 needs control gone from R, from both copies' local refs, and from their
# remote-tracking refs, because the refresh never prunes and a surviving
# remote-tracking ref would re-create the local branch.
sub unset_control {
	my ($self, %opts) = @_;
	my $control = $self->{control};

	for my $copy (qw/a b/) {
		run({dir => $self->{$copy}}, 'git', 'checkout', '-q', '-B',
			"parked-$copy");
		run({dir => $self->{$copy}, passfail => 1},
			'git', 'update-ref', '-d', "refs/heads/$control");
		run({dir => $self->{$copy}, passfail => 1},
			'git', 'update-ref', '-d', "refs/remotes/origin/$control");
	}
	run({dir => $self->{r}, passfail => 1},
		'git', 'update-ref', '-d', "refs/heads/$control");

	return $self;
}

# }}}
# set_remotes - shape a copy's remotes and its control upstream {{{
#
# T57 needs a repository whose remotes are dev and origin and whose control
# branch has no upstream, which is what a site that clones from one remote and
# pushes to another looks like.
#
# Every remote is fetched as it goes in, so a row that reads a divergence
# straight afterwards has the remote-tracking refs to read it from.  A row
# whose remote is a url something only has to parse, such as the github url
# a derivation reads an owner and repository out of, says fetch => 0 and
# gets the remote without the conversation, which keeps the row off the
# network and off whatever that machine's git configuration rewrites a
# github url into.
sub set_remotes {
	my ($self, %opts) = @_;
	my $copy = $opts{copy} // 'a';
	my $dir  = $self->{$copy};

	if (my $remotes = $opts{remotes}) {
		my ($existing) = run({dir => $dir}, 'git', 'remote');
		chomp $existing if defined $existing;
		run({dir => $dir}, 'git', 'remote', 'remove', $_)
			for grep {length} split /\n/, ($existing // '');
		run({dir => $dir}, 'git', 'remote', 'add', $_, $remotes->{$_})
			for sort keys %$remotes;
		if (defined $opts{fetch} ? $opts{fetch} : 1) {
			run({dir => $dir}, 'git', 'fetch', '-q', $_) for sort keys %$remotes;
		}
	}

	if (exists $opts{upstream}) {
		my $key = "branch.$self->{control}";
		if ($opts{upstream}) {
			run({dir => $dir}, 'git', 'config', "$key.remote", $opts{upstream});
			run({dir => $dir}, 'git', 'config', "$key.merge",
				"refs/heads/$self->{control}");
		} else {
			run({dir => $dir, passfail => 1},
				'git', 'config', '--unset', "$key.remote");
			run({dir => $dir, passfail => 1},
				'git', 'config', '--unset', "$key.merge");
		}
	}

	return $self->git($copy);
}

# }}}
# set_repo_config - write one key into .genesis/config and commit it {{{
#
# make_harness takes the pipeline options it knows about, and the rows that
# turn one arbitrary key on need a way in that does not rebuild the harness.
#
# The path is computed once, relative to the git root, and the same path is
# what the write, the commit, and the return all use, so a row that reads the
# file back reads the file the commit carries.
sub set_repo_config {
	my ($self, $key, $value, %opts) = @_;
	my $root = $opts{root} // $self->{root};
	my $path = ($root ? "$root/" : '') . '.genesis/config';

	require Genesis::Config;
	my $config = Genesis::Config->new("$self->{a}/$path");
	$config->set($key => $value);
	$config->save;

	if (defined $opts{commit} ? $opts{commit} : 1) {
		run({dir => $self->{a}}, 'git', 'add', '--', $path);
		run({dir => $self->{a}, onfailure => "Failed to write $path"},
			'git', 'commit', '-q', '-m', "set $key");
	}

	return $path;
}

# }}}
# move_on_r_at - arm a push to R for a named step of the next run {{{
#
# move_on_r acts at once, which the run's own refresh then absorbs, so no push
# is ever rejected.  This commits in copy B straight away, so it can return the
# sha, and leaves the push to R for the step the row names, which is the fault
# plan carrying an action rather than a death.
#
# The plan is armed here where a row armed none of its own, because the row
# wants a teammate to move a branch and should not have to know that the way
# the harness times that is the fault plan.
sub move_on_r_at {
	my ($self, $branch, %opts) = @_;

	run({dir => $self->{b}}, 'git', 'fetch', '-q', 'origin', $branch);
	run({dir => $self->{b}}, 'git', 'checkout', '-q', '-B', $branch,
		"refs/remotes/origin/$branch");
	my $sha = $self->_commit_in('b', $branch,
		files   => $opts{files} // {'armed.yml' => "---\narmed: true\n"},
		message => $opts{message} // 'a teammate moved the branch',
		push    => 0,
	);

	# The plan file is the one fault_git arms, keyed by step name.  This entry
	# carries an action rather than a death, so the subclass runs it and then
	# delegates to SUPER:: as it would have anyway.
	#
	# The guard reads this harness's own plan rather than the environment,
	# because the environment is global to the file and a second harness that
	# read it would arm its entry in the first harness's plan and leave its own
	# copy A handle unblessed, where no wrapper fires at all.
	$self->fault_git unless $self->{fault}{plan};
	my $file = $self->{fault}{plan};
	my $plan = JSON::PP->new->decode(helper::get_file($file));
	$plan->{$opts{at} // 'push'} = {
		n      => $opts{nth} // 1,
		from   => 0,
		action => ['push', '-q', '--force', 'origin', $branch],
		in     => $self->{b},
	};
	helper::put_file($file, JSON::PP->new->canonical->encode($plan));

	return $sha;
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
#
# A value that is an arrayref renders as a YAML list rather than a scalar,
# because genesis.pipeline.track_dependencies and its neighbours are lists and
# sprintf of a reference writes an address into the file.  A value that is a
# hashref of scalars and flat lists renders as a block one level in, so a row
# writes genesis.pipeline.track_additional_files through the genesis option
# without composing the body itself.
#
# The genesis key is written wherever anything is to be nested under it, and
# not only where the env key is.  A site file carrying genesis or pipeline
# entries used to emit those entries with no parent above them, which is a
# file no YAML reader will load.
#
# A harness declared in pr mode writes genesis.pipeline.require_pr on every
# environment file it writes, because whether a delivery needs a pull request
# is a per-environment question and there is no repository-wide key for it.
sub write_env_file {
	my ($self, $env, %opts) = @_;
	my $root   = $opts{root} // $self->{root};
	my $prefix = $root ? "$root/" : '';
	my $name   = $opts{site} // $env;
	my $path   = "$prefix$name.yml";
	my %genesis  = %{$opts{genesis}  || {}};
	my %pipeline = %{$opts{pipeline} || {}};
	$pipeline{require_pr} = 'true'
		if $self->{mode} eq 'pr' && !$opts{site};
	# One file carries one pipeline key, so entries handed in under genesis
	# fold into the pipeline block wherever a row fills both, and the pipeline
	# option wins a key the two of them name together.
	%pipeline = (%{delete $genesis{pipeline}}, %pipeline)
		if %pipeline && ref $genesis{pipeline} eq 'HASH';
	my $nested = %genesis || %pipeline;

	my $body = "---\nkit:\n  name:    dev\n  version: latest\n  features: []\n";
	$body .= "genesis:\n" if !$opts{site} || $nested;
	$body .= "  env: $name\n" unless $opts{site};
	$body .= _yaml_pair($_, $genesis{$_}, 1) for sort keys %genesis;
	if (%pipeline) {
		$body .= "  pipeline:\n";
		$body .= _yaml_pair($_, $pipeline{$_}, 2) for sort keys %pipeline;
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
# _yaml_pair - one key and its value at a depth, block, list, or scalar {{{
#
# A hashref renders as a block of its own pairs one level in, which is how a
# row writes genesis.pipeline.track_additional_files through the genesis
# option.  Anything deeper than a hash of scalars and flat lists dies by name,
# because sprintf of a reference writes an address into the file and a row
# that asked for it should hear so rather than read HASH(0x...) back.
sub _yaml_pair {
	my ($key, $value, $depth) = @_;
	my $pad = '  ' x $depth;
	if (ref $value eq 'HASH') {
		my $block = sprintf("%s%s:\n", $pad, $key);
		for my $inner (sort keys %$value) {
			die "write_env_file cannot write $key.$inner, because a value "
			  . "nested more than one level deep is not supported\n"
				if ref $value->{$inner} && ref $value->{$inner} ne 'ARRAY';
			$block .= _yaml_pair($inner, $value->{$inner}, $depth + 1);
		}
		return $block;
	}
	if (ref $value eq 'ARRAY') {
		die "write_env_file cannot write the list $key, because an entry of "
		  . "it is a reference rather than a scalar\n"
			if grep {ref} @$value;
		return sprintf("%s%s: []\n", $pad, $key) unless @$value;
		return sprintf("%s%s:\n", $pad, $key)
			. join('', map {sprintf("%s  - %s\n", $pad, $_)} @$value);
	}
	return sprintf("%s%s: %s\n", $pad, $key, $value);
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
#
# A recording safe is laid down beside the target, so vault_read_log can say
# what a run read.  Only a wrapper on the path can see the reads a child
# process makes, and _path_prefix already names the directory the wrapper sits
# in, so the wrapper reaches a spawned command through run_genesis and the
# parent's own path is left exactly as it was.
sub fixture_vault {
	my ($self) = @_;
	return $self->{vault_target} if $self->{vault_target};

	my $target = helper::vault_start('genesis-propagation-harness');
	$self->{vault_target} = $target;
	$self->{vault_url}    = $helper::VAULT_URL{$target};

	run({env => {SAFE_TARGET => $target}, passfail => 1, stderr => 0},
		'safe', 'rm', '-rf', $self->exodus_mount);

	$self->{vault_log} = "$self->{base}/vault-reads.log";
	my $bin = "$self->{base}/bin";
	helper::mkdir_or_fail($bin) unless -d $bin;
	helper::put_file("$bin/safe", 0755, <<"EOS");
#!/usr/bin/env bash
# Records a read and hands the call on to the real safe.  Only a wrapper on
# the path can see what a spawned genesis child reads.
case "\$1" in
	get|read|export) echo "\$2" >> "$self->{vault_log}" ;;
esac
exec @{[_real_safe()]} "\$@"
EOS

	return $target;
}

# }}}
# _real_safe - the safe the recording wrapper hands its call on to {{{
sub _real_safe { return _real_tool('safe') }

# }}}
# _real_tool - the tool on the path underneath the harness's own wrappers {{{
#
# A wrapper is written with the real tool's path baked into it, and the
# harness's own fixture directories are stepped over while that path is being
# found, so a wrapper written while those directories sit on the path still
# reaches the tool underneath rather than calling itself.
sub _real_tool {
	my ($name) = @_;
	for my $dir (split /:/, ($ENV{PATH} // '')) {
		next if $dir =~ m{/ph-\d+-\d+/(bin|gh-bin)$};
		return "$dir/$name" if -x "$dir/$name";
	}
	return $name;
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
# record_at - read one vault path back, or undef {{{
#
# The harness writes records through five fixtures and read none of them back,
# so every row that asserted on a written record had to reach for safe itself.
#
# The read runs on the parent's own path, which the recording wrapper is
# deliberately kept off, so a row reading a record to assert on it never counts
# as one of the reads the run under test made.
#
# safe export answers with the whole subtree under the path it was given, so a
# deployment record that has a pipeline record and a hold beneath it comes back
# as three entries and only one of them is the record that was asked for.  The
# entry is picked out by its key, which safe writes without the leading slash,
# and a path with nothing of its own at it answers undef even where its
# children answered.
sub record_at {
	my ($self, $path) = @_;
	$self->fixture_vault;
	my ($out, $rc) = run({env => {SAFE_TARGET => $self->{vault_target}},
			stderr => 0, passfail => 0},
		'safe', 'export', $path);
	return undef if $rc || !$out;
	my $exported = eval {JSON::PP->new->decode($out)} or return undef;

	(my $key = $path) =~ s{/{2,}}{/}g;
	$key =~ s{^/}{};
	$key =~ s{/$}{};
	return $exported->{$key};
}

# }}}
# vault_read_log - every vault path the last run read, in order {{{
#
# T326 asserts that a predecessor's record is read exactly once, and only the
# wrapper on the path can see the reads a child process makes, so the log is a
# file the wrapper appends to and this reads.  run_genesis empties it as each
# run starts, which is what makes the answer the last run's reads rather than
# every read since the harness was built.
sub vault_read_log {
	my ($self) = @_;
	my $file = $self->{vault_log} or return [];
	return [] unless -f $file;
	return [grep {length} split /\n/, (helper::get_file($file) // '')];
}

# }}}
# fixture_preflight - the three shapes the pre-flight classifies {{{
#
# D80 has the pre-flight name a safe.directory refusal, a missing committer
# identity, and a repository with no commits, each with its fix.  Each shape is
# built in a fresh repository beside the harness rather than in either clone,
# because the safe.directory shape needs an ownership git will actually refuse
# and neither clone can be given one.
#
# The first two shapes leave a marker in the repository and lean on the fixture
# git for the rest, because neither an ownership git refuses nor a missing
# global identity can be arranged by a process running as the one user that
# owns everything the suite writes.
sub fixture_preflight {
	my ($self, $kind, %opts) = @_;
	my $dir = $opts{copy} ? $self->{$opts{copy}}
	        : "$self->{base}/preflight-$kind-" . int(rand(1_000_000));

	unless ($opts{copy}) {
		helper::mkdir_or_fail($dir);
		run({dir => $dir}, 'git', 'init', '-q');
	}
	$self->_preflight_git;

	if ($kind eq 'no_commits') {
		run({dir => $dir}, 'git', 'config', 'user.email', 'nobody@example.com');
		run({dir => $dir}, 'git', 'config', 'user.name', 'Nobody');

	} elsif ($kind eq 'no_identity') {
		helper::put_file("$dir/a-file", "a line\n");
		run({dir => $dir}, 'git', 'config', 'user.email', 'nobody@example.com');
		run({dir => $dir}, 'git', 'config', 'user.name', 'Nobody');
		run({dir => $dir}, 'git', 'add', '-A');
		run({dir => $dir}, 'git', 'commit', '-q', '-m', 'a commit');
		run({dir => $dir}, 'git', 'config', '--unset', 'user.email');
		run({dir => $dir}, 'git', 'config', '--unset', 'user.name');
		helper::put_file("$dir/.git/harness-no-identity", "1\n");

	} elsif ($kind eq 'safe_directory') {
		helper::put_file("$dir/a-file", "a line\n");
		run({dir => $dir}, 'git', 'config', 'user.email', 'nobody@example.com');
		run({dir => $dir}, 'git', 'config', 'user.name', 'Nobody');
		run({dir => $dir}, 'git', 'add', '-A');
		run({dir => $dir}, 'git', 'commit', '-q', '-m', 'a commit');
		helper::put_file("$dir/.git/harness-dubious", "1\n");

	} else {
		die "fixture_preflight does not know the shape $kind\n";
	}

	return $dir;
}

# }}}
# _preflight_git - the git that makes a marked repository behave {{{
#
# It finds the repository a call is about, from a -C or from the working
# directory, and turns whichever marker that repository carries into the
# environment the real git reads the shape out of.  A dubious ownership is what
# git refuses the safe.directory case on, and an empty home with no global and
# no system configuration is what leaves a committer identity missing even
# though helper::import wrote the suite one.
#
# run_genesis already puts this directory first for the command under test, so
# a whole run meets the shape, and a row that reads the shape itself puts the
# same directory first for the length of the row.
sub _preflight_git {
	my ($self) = @_;
	my $bin = "$self->{base}/bin";
	return "$bin/git" if -x "$bin/git";

	helper::mkdir_or_fail($bin) unless -d $bin;
	my $home = "$self->{base}/preflight-home";
	helper::mkdir_or_fail($home) unless -d $home;

	helper::put_file("$bin/git", 0755, <<"EOS");
#!/usr/bin/env bash
# The repository a call is about is the one -C names, or the one the working
# directory sits in, and each shape is a marker file that repository carries.
dir="\$PWD"
prev=
for arg in "\$@"; do
  [ "\$prev" = "-C" ] && dir="\$arg"
  prev="\$arg"
done
while [ -n "\$dir" ] && [ "\$dir" != "/" ] && [ "\$dir" != "." ]; do
  if [ -f "\$dir/.git/harness-dubious" ]; then
    export GIT_TEST_ASSUME_DIFFERENT_OWNER=1
    break
  fi
  if [ -f "\$dir/.git/harness-no-identity" ]; then
    export HOME="$home"
    export GIT_CONFIG_GLOBAL="$home/.gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    break
  fi
  dir="\$(dirname "\$dir")"
done
exec @{[_real_tool('git')]} "\$@"
EOS
	return "$bin/git";
}

# }}}
# fixture_kit - a dev kit with the hook bodies a row needs {{{
#
# helper::mk_test_kit builds a kit with no hooks at all, so a row that needs a
# blueprint that raises, or a hook that probes the lock, or a hook that spawns
# a genesis child of its own has nothing else to build on.  A row that wants
# one of the two kits the suite ships names it through make_harness's kit
# option instead, and those two are exodus-reader and broken-blueprint.
sub fixture_kit {
	my ($self, %opts) = @_;
	my $name    = $opts{name}    // 'pipeline';
	my $version = $opts{version} // '0.0.1';
	my $root    = $opts{root} // $self->{root};
	my $dir     = join('/', grep {length} $self->{a}, $root, 'dev');

	helper::mkdir_or_fail($dir) unless -d $dir;
	helper::mkdir_or_fail("$dir/hooks") unless -d "$dir/hooks";
	helper::put_file("$dir/kit.yml",
		"name: $name\nversion: $version\ngenesis_version_min: 3.0.0\n");

	for my $hook (sort keys %{$opts{hooks} || {}}) {
		helper::put_file("$dir/hooks/$hook", 0755,
			"#!/bin/bash\nset -eu\n" . $opts{hooks}{$hook});
	}

	return $dir;
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

	# vault_read_log answers for the last run, so the log starts every run
	# empty and nothing the harness read before this one is counted in it.
	helper::put_file($self->{vault_log}, '') if $self->{vault_log};

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

	_guard_env(
		GENESIS_HARNESS_GIT_PLAN => $self->{fault}{plan},
		GENESIS_HARNESS_GIT_LOG  => $self->{fault}{log},
	);

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
# skip_on - make the nth call of a step report and not land {{{
#
# The armed call returns without delegating, so the write is reported in the
# step log and never reaches the repository.  fail_on cannot make that shape,
# because a death is not a silence, and T119 needs the silence.  The return
# option says what the skipped call answers, for a step whose caller weighs
# the answer rather than trusting the absence of a death.
sub skip_on {
	my ($git, $step, $n, %opts) = @_;
	my $file = $ENV{GENESIS_HARNESS_GIT_PLAN}
		or die "skip_on needs fault_git to have run first\n";

	my $plan = JSON::PP->new->decode(helper::get_file($file));
	$plan->{$step} = {n => $n, from => $opts{from} ? 1 : 0,
		skip => 1, return => $opts{return}};
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

	_guard_env(
		GENESIS_HARNESS_GH_STATE => $gh->{state},
		GENESIS_HARNESS_GH_LOG   => $gh->{log},
	);

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
# child_recorder - watch every genesis child a command spawns {{{
#
# M14 asks that a run spawn no second genesis process and M15 asks that it
# spawn exactly one, so both want the same observer and the harness carries
# one rather than two.  The wrapper is t/Harness/bin/genesis-recorder, copied
# onto the directory _path_prefix already names, and GENESIS_CALLBACK_BIN
# points at it, so a child spawned through the hook helper's genesis function
# and a child that resolves the bare name on the path are each recorded.
#
# The parent's own path is left exactly as it was.  run_genesis carries the
# fixture directory to the run under test alone, which is what keeps the
# harness's own calls on the real binaries.
#
# hold_lock has the wrapper put a stranger in the window D46 leaves open
# between the session's finish and the child's own start, and probe has it
# poll the lock while the child runs.
sub child_recorder {
	my ($self, %opts) = @_;
	my $copy = $opts{copy} // 'a';
	my $bin  = "$self->{base}/bin";
	helper::mkdir_or_fail($bin) unless -d $bin;

	$self->{child_copy} = $copy;
	$self->{child_log}  = "$self->{base}/children.jsonl";
	$self->{child_plan} = "$self->{base}/child-plan.json";

	my $path = "$bin/genesis";
	helper::put_file($path, 0755,
		helper::get_file("$helper::TOPDIR/t/Harness/bin/genesis-recorder"));
	helper::put_file($self->{child_log}, '');
	helper::put_file($self->{child_plan}, JSON::PP->new->canonical->encode({
		exec      => (defined $opts{exec} ? $opts{exec} : 1) ? 1 : 0,
		exit      => $opts{exit},
		probe     => $opts{probe} ? 1 : 0,
		hold_lock => $opts{hold_lock},
		real      => _real_genesis(),
		lock      => "$self->{$copy}/.git/genesis-session.lock",
		log       => $self->{child_log},
	}));

	_guard_env(
		GENESIS_HARNESS_CHILD_PLAN => $self->{child_plan},
		GENESIS_CALLBACK_BIN       => $path,
	);

	return $path;
}

# }}}
# _real_genesis - the genesis the recording wrapper hands its call on to {{{
#
# The wrapper stands where the bare name resolves, so the real binary is named
# outright as the git root's own bin/genesis rather than looked up on a path
# the wrapper is sitting on.
sub _real_genesis { return "$helper::TOPDIR/bin/genesis" }

# }}}
# child_runs - each recorded child, in order {{{
sub child_runs {
	my ($self) = @_;
	my $log = $self->{child_log} or return ();
	return () unless -f $log;
	my $json = JSON::PP->new;
	return map {$json->decode($_)}
		grep {/\S/} split /\n/, (helper::get_file($log) // '');
}

# }}}
# lock_probe - is the switch lock held, and by whom {{{
#
# A non-blocking flock, so the probe answers rather than waiting.  The pid and
# the command are written inside the lock file by whoever took it, the pid on
# the first line and the command on the second, which is how a row can name
# the stranger standing in the window.
sub lock_probe {
	my ($self, %opts) = @_;
	my $copy = $opts{copy} // 'a';
	my $file = "$self->{$copy}/.git/genesis-session.lock";
	return undef unless -f $file;

	require Fcntl;
	open my $fh, '<', $file or return undef;
	if (flock($fh, Fcntl::LOCK_EX() | Fcntl::LOCK_NB())) {
		flock($fh, Fcntl::LOCK_UN());
		close $fh;
		return undef;
	}
	my $held = do {local $/; <$fh>};
	close $fh;

	my ($pid, $command) = split /\n/, ($held // ''), 2;
	chomp $command if defined $command;
	return {pid => $pid, command => $command};
}

# }}}
# lock_probe_bin, lock_probe_log - the same probe as a script {{{
#
# A kit hook cannot call a sub in this process, so the probe is also the
# committed t/Harness/bin/lock-probe, copied onto the fixture directory and
# taking a label.  The lock file and the log reach it through the environment,
# which is how they reach a hook running several processes down from the row.
sub lock_probe_bin {
	my ($self) = @_;
	return $self->{lock_probe_bin} if $self->{lock_probe_bin};

	my $bin = "$self->{base}/bin";
	helper::mkdir_or_fail($bin) unless -d $bin;
	my $path = "$bin/lock-probe";
	$self->{lock_probe_log} = "$self->{base}/lock-probe.jsonl";

	helper::put_file($path, 0755,
		helper::get_file("$helper::TOPDIR/t/Harness/bin/lock-probe"));
	helper::put_file($self->{lock_probe_log}, '');

	_guard_env(
		GENESIS_HARNESS_LOCK_FILE => "$self->{a}/.git/genesis-session.lock",
		GENESIS_HARNESS_LOCK_LOG  => $self->{lock_probe_log},
	);

	return $self->{lock_probe_bin} = $path;
}

sub lock_probe_log {
	my ($self) = @_;
	my $log = $self->{lock_probe_log} or return ();
	return () unless -f $log;
	my $json = JSON::PP->new;
	return map {$json->decode($_)}
		grep {/\S/} split /\n/, (helper::get_file($log) // '');
}

# }}}
# shuttle_spy, shuttle_requests - what a run put to the shuttle {{{
#
# Under the manual provider there is no backend at all and D23 refuses a file
# one, so nothing in the tree can tell a run that made no request from a run
# that had nowhere to make one.  The spy is that difference: the log it names
# is empty until something writes a request into it, and a row reading an
# empty log is reading an answer rather than an absence.
#
# The log is written empty rather than removed, so a row that reads no
# requests back has read a file the spy really laid down.  A reader that
# short-circuited on a missing file would answer the same empty list for a
# spy that was never stood up at all, which is the one answer it must not be
# able to give.
#
# A request is one JSON object on a line of its own, which is the form every
# other log the harness owns takes.
sub shuttle_spy {
	my ($self, %opts) = @_;
	my $log = "$self->{base}/shuttle.jsonl";
	helper::put_file($log, '');
	_guard_env(GENESIS_SHUTTLE_SPY => $log);
	return $self->{shuttle} = bless {harness => $self, log => $log},
		'Harness::Propagation::Spy';
}

sub shuttle_requests {
	my ($spy) = @_;
	return () unless -f $spy->{log};
	my $json = JSON::PP->new;
	return map {$json->decode($_)}
		grep {/\S/} split /\n/, (helper::get_file($spy->{log}) // '');
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

# ready_envs - the five things every walking row needs first {{{
#
# The init branch on R per environment, the applied record, each
# environment's pipeline record, the delivery, and the certified commit.
# The delivered and certified lists say which environments get which, each
# defaulting to every environment, so a row can stand an unseeded or an
# uncertified environment up without building the tree by hand.  Without it
# eleven test files repeat eight setup lines per subtest, and the helper
# rule forbids wrapping those beside a test.
sub ready_envs {
	my ($self, %opts) = @_;
	my @envs    = @{$opts{envs} // $self->{envs}};
	my $control = $opts{control} // $self->git('a')->sha($self->{control});
	my %delivered = map {($_ => 1)} @{$opts{delivered} // \@envs};
	my %certified = map {($_ => 1)} @{$opts{certified} // \@envs};

	$self->fixture_vault;
	$self->fixture_applied(control => $control,
		provider => $opts{provider} // $self->{provider}, %opts)
		unless defined $opts{applied} && !$opts{applied};

	for my $env (@envs) {
		$self->init_branch($env, %opts);
		$self->fixture_pipeline_record($env, %opts,
			dependencies => $opts{dependencies}{$env} // []);
		$self->deliver($env, %opts, control => $control) if $delivered{$env};
		$self->certify($env, %opts, control_commit => $control)
			if $certified{$env};
	}
	$self->refresh('a', $self->{control}, map {$self->slug($_, %opts)} @envs);

	return $self;
}

# }}}
# deliver_all - one delivery per environment at control's tip {{{
#
# A method rather than an exported name, because a row asks a scenario for
# its shape and only the harness's own composition wants the whole set
# delivered in one line.
sub deliver_all {
	my ($self, %opts) = @_;
	my $control = $opts{control} // $self->git('a')->sha($self->{control});
	$self->deliver($_, %opts, control => $control)
		for @{$opts{envs} // $self->{envs}};
	return $self;
}

# }}}
# The named shapes {{{
#
# Each is make_harness, then ready_envs, then the one thing its name says.
# Every one passes its options through, so a row that wants PR mode, a
# second type, or a third environment asks for it in the call.
sub ready_harness {
	my (%opts) = @_;
	my $h = make_harness(%opts, envs => $opts{envs} // ['lab', 'qa']);
	return $h->ready_envs(%opts);
}

# seeded_harness is the same shape over one environment, and its applied
# option turned off leaves the applied record out, which is the shape a row
# proving the membership test of D43 and D103 needs, since the undef stands
# in for a roster.
sub seeded_harness {
	my (%opts) = @_;
	return ready_harness(%opts, envs => $opts{envs} // ['qa']);
}

# staged is the pipeline that has been applied and has propagated nothing
# yet, which is the unseeded reading the walk has to answer for.  The name is
# the step files'.
sub staged {
	my (%opts) = @_;
	return ready_harness(%opts, delivered => [], certified => []);
}

# due_harness answers the harness and its control commits in list context,
# because the rows that name a commit index into them, and the harness alone
# in scalar context, because the rows that only want the shape say so.
sub due_harness {
	my (%opts) = @_;
	my $h = ready_harness(%opts, envs => $opts{envs} // ['qa']);
	my @due = _due($h, $opts{count} // 2);
	$h->refresh('a');
	return wantarray ? ($h, @due) : $h;
}

# gated_harness lays four control commits, of which the third carries the
# Genesis-Stage trailer, and answers in the same two shapes due_harness does.
sub gated_harness {
	my (%opts) = @_;
	my $h = ready_harness(%opts, envs => $opts{envs} // ['qa']);
	my @shas;
	for my $n (1 .. 4) {
		push @shas, $h->commit_on_control(
			files    => {"change-$n.yml" => "---\nn: $n\n"},
			message  => "A change on control, $n",
			($n == 3 ? (trailers => {'Genesis-Stage' => $opts{stage} // 'prod'}) : ()),
			push     => 1,
		);
	}
	$h->refresh('a');
	return wantarray ? ($h, @shas) : $h;
}

sub held_harness {
	my (%opts) = @_;
	my $h = ready_harness(%opts, envs => $opts{envs} // ['lab', 'prod']);
	$h->fixture_hold($opts{env} // 'prod', reason => $opts{reason} // 'on-hold');
	return $h;
}

# held_prod is the one-environment prod tree the hold rows stand on, and it
# writes no hold of its own, because every one of those rows writes the hold
# through the command it is testing.  The name says whose tree it is.
sub held_prod {
	my (%opts) = @_;
	return ready_harness(%opts, envs => $opts{envs} // ['prod'],
		delivered => $opts{delivered} // [],
		certified => $opts{certified} // []);
}

# tracked_harness names its prerequisites positionally, because every call
# reads as a list of environment names and an options hash around two of
# them would say nothing the list does not.
sub tracked_harness {
	my (@prereqs) = @_;
	@prereqs = ('lab') unless @prereqs;
	my $h = make_harness(envs => [@prereqs, 'qa']);
	$h->write_env_file('qa', genesis => {
		track_dependencies => [map {$h->slug($_)} @prereqs]});
	# write_env_file commits in copy A and pushes nothing, and the commit a
	# delivery's marker names has to be on R, so control goes up before the
	# walk reads it.
	$h->push_from('a', $h->control);
	return $h->ready_envs;
}

sub two_env_harness {
	my (%opts) = @_;
	return ready_harness(%opts, envs => $opts{envs} // ['lab', 'qa']);
}

# inherited_harness writes its pipeline keys at a site file rather than at
# the leaf, which is the merged read D79 asks for, and leaf_keys puts a
# second set at the leaf so a row can watch the two meet.
sub inherited_harness {
	my (%opts) = @_;
	my $h = make_harness(%opts, envs => $opts{envs} // ['qa']);
	my $site = $opts{site} // 'site';
	$h->write_env_file($site, site => $site,
		pipeline => $opts{pipeline_keys} // {manual_gate => 1});
	$h->write_env_file($_, pipeline => $opts{leaf_keys})
		for $opts{leaf_keys} ? @{$opts{envs} // ['qa']} : ();
	# Both writes commit in copy A alone, so control goes up before the walk
	# reads the commit a delivery's marker will name.
	$h->push_from('a', $h->control);
	return $h->ready_envs(%opts);
}

# ready is the PR-mode shape.  admin off is a site whose token the
# protection endpoints refuse, which is how a row means "could not grant the
# merge method", and due lays one control commit the branch has yet to
# receive.
sub ready {
	my (%opts) = @_;
	my $h = make_harness(%opts, envs => $opts{envs} // ['prod'],
		mode => 'pr', github => 1);
	$h->ready_envs(%opts);
	gh_protection($h->{gh}, admin => (defined $opts{admin} ? $opts{admin} : 1));

	$h->commit_on_control(
		files   => $opts{due},
		message => $opts{message} // 'A change due to propagate',
		push    => 1,
	) if $opts{due};
	$h->refresh('a');

	return $h;
}

# with_open_pr is ready with one commit due, a pull request open on the
# double, and a proposed record naming it, which is the whole shape a pull
# request column reads.  The record takes the number under pr, because that
# is what the double and every row that opens one call it.
sub with_open_pr {
	my (%opts) = @_;
	my $env = $opts{env} // 'qa';
	my $h = ready(%opts, envs => $opts{envs} // [$env],
		due => $opts{due} // {"$env.yml" => "---\nkit: dev\nn: 2\n"});
	my $gh = $h->{gh};
	my $control = $h->git('a')->sha($h->control);

	my $number = gh_pull_request($gh,
		env    => $env,
		head   => $h->pr_branch($env),
		base   => $h->slug($env),
		review => $opts{review} // 'none',
	);
	$h->fixture_proposed($env, pr => $number, control => $control);

	return ($h, $gh, $number, $control);
}

# two_roots is the lab and prod pair across a second deployment root.  The
# second ready names that root's path as well as its type, because the
# propagation set is read under a prefix and a delivery given the type alone
# would mirror the first root's files onto the second root's branch.
sub two_roots {
	my (%opts) = @_;
	my @envs   = @{$opts{envs} // ['lab', 'prod']};
	my $second = $opts{second} // 'vault';
	my $h = make_harness(%opts, envs => \@envs);
	add_deployment_root($h, type => $second, envs => \@envs);
	$h->ready_envs(%opts, envs => \@envs);
	$h->ready_envs(%opts, envs => \@envs, type => $second, root => $second);
	return $h;
}

# }}}
# The three one-off shapes the writer and the command classes need {{{
#
# stale_set_delivery stands up the one shape the writer's removing half needs,
# which is a branch delivered under a tracked set that control has since
# narrowed.  It is built in two control commits, because the whole point of
# the shape is that the branch was delivered under the wider set and control
# now declares the narrower one.  It is not a_delivery, which is one plain
# delivery at control's tip, so it takes a name of its own.
sub stale_set_delivery {
	my ($self, %opts) = @_;
	my $env  = $opts{env}  // 'qa';
	my $root = $opts{root} // $self->{root};
	my $file = $opts{file} // 'ops/extra.yml';
	my $path = $opts{path} // join('/', grep {length} $root, $file);

	$self->fixture_vault;
	$self->init_branch($env, %opts);

	# The wider set: the extra file is tracked, and the delivery carries it.
	# The environment file is staged rather than committed on its own, so the
	# tracked list and the file it names arrive in the same control commit.
	$self->_stage_env_file($env, %opts, root => $root,
		genesis => {pipeline => {track_additional_files => [$file]}});
	my $wide = $self->commit_on_control(
		files   => {$path => "---\nextra: true\n"},
		message => 'Track an extra file',
		push    => 1,
	);
	$self->deliver($env, %opts, control => $wide);

	# The narrower set: the extra file is dropped from the tracked list and
	# stays on the branch until a delivery removes it.
	$self->_stage_env_file($env, %opts, root => $root,
		genesis => {pipeline => {track_additional_files => []}});
	my $narrow = $self->commit_on_control(
		files   => {},
		message => 'Stop tracking the extra file',
		push    => 1,
	);
	$self->refresh('a');

	return $narrow;
}

# _stage_env_file writes the environment file without committing it and puts
# it in copy A's index, so the commit that follows carries it.  write_env_file
# either commits the file alone or leaves it unstaged, and neither of those
# lets a tracked list ride into the control commit that acts on it.
sub _stage_env_file {
	my ($self, $env, %opts) = @_;
	my $path = $self->write_env_file($env, %opts, commit => 0);
	run({dir => $self->{a}, onfailure => "Failed to stage $path"},
		'git', 'add', '--', $path);
	return $path;
}

# T204 refuses on a staged index and T205 ignores an unstaged edit, and both
# refusals name the file, so each helper hands its path back rather than
# leaving the row to repeat the literal.
sub stage_unrelated {
	my ($self, $path, %opts) = @_;
	my $copy = $opts{copy} // 'a';
	helper::put_file("$self->{$copy}/$path",
		$opts{content} // "a change nobody asked about\n");
	run({dir => $self->{$copy}, onfailure => "Failed to stage $path"},
		'git', 'add', '--', $path);
	return $path;
}

sub modify_unrelated {
	my ($self, $path, %opts) = @_;
	my $copy = $opts{copy} // 'a';
	my $was  = slurp("$self->{$copy}/$path") // '';
	helper::put_file("$self->{$copy}/$path",
		$was . ($opts{content} // "# edited in the working tree\n"));
	return $path;
}

# }}}
# The one-line shapes a row stands on top of a scenario {{{
sub a_delivery {
	my ($h, $env, %opts) = @_;
	return $h->deliver($env, %opts,
		control => $opts{control} // $h->git('a')->sha($h->{control}));
}

sub seeded {
	my (%opts) = @_;
	my $h = make_harness(envs => $opts{envs} // ['qa'], vault => 0, %opts);
	$h->init_branch($_, %opts) for @{$opts{envs} // ['qa']};
	my $control = $h->commit_on_control(
		files   => $opts{files} // {'qa.yml' => "---\nkit: dev\n"},
		message => $opts{message} // 'change qa',
		push    => 1,
	);
	my $delivered = $h->deliver(($opts{envs} // ['qa'])->[0], %opts,
		control => $control);
	return ($h, $control, $delivered);
}

sub two_due   {return _due(shift, 2, @_)}
sub three_due {return _due(shift, 3, @_)}

# three is three_due under the name the rows that want a run of three use,
# and it is the same sub rather than a second body saying the same thing.
*three = \&three_due;

sub chain {
	my ($h, %opts) = @_;
	my @envs = @{$opts{envs} // $h->{envs}};
	return map {
		$h->commit_on_control(
			files   => {"$_.yml" => "---\nkit: {name: dev}\n"},
			message => "Tune $_",
			push    => 1,
		)
	} @envs;
}

sub _due {
	my ($h, $n, %opts) = @_;
	return map {
		$h->commit_on_control(
			files   => {"due-$_.yml" => "---\nn: $_\n"},
			message => "A change due to propagate, $_",
			push    => 1,
		)
	} 1 .. $n;
}

sub gated {
	my ($h, %opts) = @_;
	return $h->commit_on_control(%opts,
		trailers => {'Genesis-Stage' => $opts{stage} // 'prod'},
		message  => $opts{message} // 'Gate the change',
		push     => 1,
	);
}

sub proposed {
	my ($h, $env, %opts) = @_;
	return $h->fixture_proposed($env, %opts);
}

sub automated {
	my ($h, %opts) = @_;
	$h->set_repo_config('pipeline.provider.type', $opts{provider} // 'concourse');
	return $h;
}

# top_for's config option writes the whole .genesis/config on control before
# the Top is built, so a row can ask for the shape with no provider key at
# all rather than editing one key of the file make_harness left.
sub top_for {
	my ($h, %opts) = @_;
	require Genesis::Top;
	my $root = $opts{root} // $h->{root};
	_write_whole_config($h, $opts{config}, root => $root) if $opts{config};
	return Genesis::Top->new(join('/', grep {length} $h->a, $root));
}

# }}}
# _write_whole_config - replace .genesis/config and commit it on control {{{
sub _write_whole_config {
	my ($h, $config, %opts) = @_;
	my $root = $opts{root} // $h->{root};
	my $path = ($root ? "$root/" : '') . '.genesis/config';

	unlink "$h->{a}/$path";
	require Genesis::Config;
	my $written = Genesis::Config->new("$h->{a}/$path");
	$written->set($_ => $config->{$_}) for sort keys %$config;
	$written->save;

	run({dir => $h->{a}}, 'git', 'add', '--', $path);
	run({dir => $h->{a}, onfailure => "Failed to write $path"},
		'git', 'commit', '-q', '-m', "write $path");

	return $path;
}

# }}}

1;
