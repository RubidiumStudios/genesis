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
use Harness::GitEnv;

# require rather than use, because helper's import resets HOME and the test
# file has already run it.  We want the package loaded and nothing else.
require helper;

# Everything the harness exports, in one list.  A name pushed on in a
# statement of its own drifts away from the rest, and the file had accumulated
# sixteen such pushes, so the next reader looking for a name had sixteen places
# to look.  The blank lines group the readers, the writers, the fixtures, the
# runners, the doubles, and the scenarios.
our @EXPORT = qw/
	make_harness
	ref_in tree_of upstream_of counts
	tip_of remote_sha refs_in branch_of git_in blob_at files_at slurp
	in_set covered_paths in_root plain env_line env_row
	branches_on_r fresh_clone clone_copy subjects_of commits_on heads_in
	reachable_on_r
	newest_record trailers_of unfolded env_body

	commit_on_control commit_from_b publish_from_b push_from refresh
	init_branch deliver propagation_set edited_file harness_marker
	add_deployment_root write_env_file due_commit due_on_control patch_calls
	hand_commit local_only_commit squash_merge unrelated_branch
	diverge move_on_r delete_on_r delete_local
	rewrite_control rewrite_branch
	amend_tip local_branch local_branch_only unset_control tag_branch
	set_remotes second_remote drop_remotes broken_pushurl
	set_repo_config move_on_r_at

	fixture_vault fixture_applied fixture_pipeline_record certify
	fixture_hold fixture_proposed fixture_director fixture_bosh
	break_vault break_vault_writes restore_vault
	record_at record_keys proposed_for vault_read_log bosh_runs fixture_preflight fixture_kit
	fixture_command install_compiled_kit shimmed_git real_tool
	fixture_fly

	snapshot_w assert_w_restored assert_snapshot_invariant
	run_genesis run_genesis_in stand_on

	fault_git fail_on skip_on step_log reset_steps
	sever_remote restore_remote
	hold_session_lock release_session_lock fork_and_switch
	child_recorder child_runs lock_probe lock_probe_log
	shuttle_spy shuttle_requests

	github_double gh_pull_request gh_close_pr gh_merge_pr
	gh_protection gh_unreachable gh_reachable gh_no_token gh_calls

	automation_blocks automation_block_lines load_with automated_config
	compilable_pipeline shuttle

	ready_envs ready_harness fanned_harness seeded_harness staged
	due_harness gated_harness
	held_harness held_prod held_prod_delivered deployable_prod
	tracked_harness two_env_harness
	inherited_harness
	ready with_open_pr two_roots a_delivery seeded two_due three_due three
	chain gated proposed automated top_for
	stale_set_delivery stage_unrelated modify_unrelated
/;

# $DEFAULT_EXODUS_MOUNT - the exodus mount a harness clears and owns {{{
#
# The vault fixture clears this subtree whole as it attaches, so a row may
# name a mount below it and may not name one above it.
our $DEFAULT_EXODUS_MOUNT = '/secret/exodus/';

# }}}
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

# %HOLDERS - the lock holders this file has forked and not yet released {{{
#
# A row that forks a holder and then dies before releasing it leaves that
# holder sitting on the flock for the five minutes it gives itself, and the
# next row or the next file that wants the same lock waits the whole of it
# out.  Whatever is still registered when the file ends is killed and reaped
# here, so a failing row costs the run nothing beyond its own failure.
our %HOLDERS;
sub _reap_holders {
	for my $pid (sort keys %HOLDERS) {
		kill('KILL', $pid);
		waitpid($pid, 0);
		delete $HOLDERS{$pid};
	}
	return;
}

END {_release_env(); _reap_holders()}

# }}}
# ref_in - one ref's sha in a repository at a path, or undef {{{
#
# The first reader the harness owns, because every row below reads a ref and
# a reader declared once per test file is a reader that answers differently
# in each of them.  The rest of the shared readers land beside it.
sub ref_in {
	my ($dir, $ref) = @_;
	my ($sha) = run({dir => $dir},
		'git', 'rev-parse', '--verify', '--quiet', $ref);
	chomp $sha if defined $sha;
	return $sha || undef;
}

# }}}
# tree_of - a commit's paths, sorted, or an empty arrayref where the ref is absent {{{
#
# The stderr of the read is captured separately rather than folded into the
# output, because a row proving an absence has to read an empty arrayref back
# and not git's complaint about the name it asked for.
sub tree_of {
	my ($dir, $ref) = @_;
	my ($out, $rc) = run({dir => $dir, stderr => 0},
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
# git_in - one line of git's answer in a repository, or undef {{{
#
# The readers above answer the questions rows ask most often, and a row that
# wants something else, such as a commit's subject or its parent list, needs
# somewhere to ask it that is not a copy of the same four lines in each file.
#
# The stderr is captured apart from the output rather than folded into it, so
# a row running before a ref exists reads undef back rather than reading
# git's complaint about the name it asked for as though it were an answer.
# The trailing newline goes, because every caller wants the line and not the
# line break.
sub git_in {
	my ($dir, @args) = @_;
	my ($out, $rc) = run({dir => $dir, stderr => 0}, 'git', @args);
	return undef if $rc || !defined $out;
	chomp $out;
	return $out;
}

# }}}
# blob_at - one path's bytes on a ref, exactly as the object holds them {{{
#
# files_at reads through Genesis::run, which strips trailing whitespace from
# everything it hands back, so a row comparing a file against the string the
# product wrote would be comparing a trimmed copy of it.  git's output is
# read straight off a pipe here instead and nothing is trimmed, which is what
# lets a row assert a file's bytes rather than its shape.
#
# The tree is asked first, so a ref or a path that is not there answers undef
# quietly rather than letting git complain to the test's own stderr.
sub blob_at {
	my ($dir, $ref, $path) = @_;
	return undef unless grep {$_ eq $path} @{tree_of($dir, $ref)};

	open(my $pipe, '-|', 'git', '-C', $dir, 'cat-file', 'blob', "$ref:$path")
		or return undef;
	my $content = do {local $/; <$pipe>};
	close $pipe;
	return $content;
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
# in_set - whether a path is one of the paths a reader answered {{{
#
# The readers answer lists, and nearly every row about a set asks whether one
# path is in one of them, so the question is asked here rather than in a copy
# of the same grep in each file that asks it.
#
# The answer is a yes or a no, because that is the question, and every caller
# reads it as one.  A count would invite a row to assert on how many times a
# list held one path, which is a question about the list and not about the
# path.
sub in_set {
	my ($path, @set) = @_;
	return (grep {$_ eq $path} @set) ? 1 : 0;
}

# }}}
# plain - a rendered line or tree with the colour taken out {{{
#
# A colour escape ends in the letter m, so a word boundary can never hold in
# front of a coloured name and a row matching on words would fail for a
# reason that has nothing to do with what the report said.  Every file that
# reads a rendered report asks for this, so it is asked here rather than once
# per file.
sub plain {
	my ($text) = @_;
	return '' unless defined $text;
	$text =~ s/\e\[[0-9;]*m//g;
	return $text;
}

# }}}
# env_line - the one rendered row an environment's name opens {{{
#
# The row is selected by the indent that opens a row as well as by the name,
# because the header above the table names environments too, and the line
# comes back with its colour taken out so the caller asserts on words.
sub env_line {
	my ($tree, $name) = @_;
	my ($line) = grep {plain($_) =~ /^\s{2,}\Q$name\E\s/}
		split(/\n/, $tree // '');
	return plain($line // '');
}

# }}}
# env_row - one environment's record out of a report the run emitted {{{
#
# A report answers a list of environments and a row asks about one of them,
# so the selection is made here rather than in a copy of the same grep in
# each file that reads a record.
sub env_row {
	my ($record, $name) = @_;
	my ($row) = grep {$_->{env} eq $name} @{$record->{environments} || []};
	return $row;
}

# }}}
# covered_paths - the tracked paths a list of pathspecs covers at a ref {{{
#
# The product names the kit source as a directory, because what it hands git
# is a pathspec, and the harness names the files a tree actually holds, so the
# two are compared as the tracked paths each of them covers.  A pathspec entry
# nothing tracks, such as a fragment the blueprint names before anybody wrote
# it, covers nothing and drops out of both sides.
#
# The ref is named rather than assumed, because a row comparing a reading
# taken at one commit against the tree of another would otherwise cover its
# pathspecs against whatever the copy happens to be standing on.
sub covered_paths {
	my ($dir, $ref, @pathspec) = @_;

	my @tracked = @{tree_of($dir, $ref)};

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

# }}}
# in_root - stand in a copy's deployment root for the rest of the scope {{{
#
# Every row that reads a propagation set needs it, because propagation_files
# and track_additional_files both reach for Service::Git->new('.'), and the
# handle and the prefix a row gets depend on where the process is standing.
#
# The guard is handed back rather than kept, so it lets go at the end of the
# caller's scope and not at the end of the file, and it steps back in DESTROY
# rather than at a statement a failure can skip, which is the whole reason it
# exists.
sub in_root {
	my ($self, %opts) = @_;
	my $root = exists $opts{root} ? $opts{root} : $self->{root};
	my $dir  = join('/', grep {defined && length} $self->{$opts{copy} // 'a'}, $root);
	return Harness::Propagation::ChdirGuard->enter($dir);
}

{
	package Harness::Propagation::ChdirGuard;

	sub enter {
		my ($class, $dir) = @_;
		my $was = Cwd::getcwd();
		chdir $dir or die "cannot enter $dir: $!\n";
		return bless {was => $was}, $class;
	}

	sub DESTROY {
		my ($self) = @_;
		chdir $self->{was} or warn "cannot return to $self->{was}: $!\n";
	}
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
	my ($self) = @_;
	my $dir = "$self->{tmp}/clone-" . int(rand(1_000_000));
	run({dir => $self->{base}, onfailure => "Failed to clone R"},
		'git', 'clone', '-q', $self->{r}, $dir);
	run({dir => $dir}, 'git', 'config', 'user.email', 'clone@genesis.example.com');
	run({dir => $dir}, 'git', 'config', 'user.name', 'A fresh clone');
	return $dir;
}

# }}}
# clone_copy - a copy cut from R now, carrying only what R can reach {{{
#
# A row that wants to run real code inside a third clone wants a Service::Git
# handle on it, which the git accessor builds from a copy key, so the clone is
# registered under a key of its own and every accessor the harness already has
# -- git, tip_of, snapshot_w, stand_on -- reads it.  The default key is c,
# because a and b are the two copies the harness builds, and a row that wants
# a second clone names its own.
#
# The clone is made over file://, which fresh_clone does not do and which
# matters here.  Git clones a plain local path by hardlinking the whole object
# store, so a commit that no ref of R can reach still arrives in the copy, and
# a row asking what a clone made today does not have would be handed it
# anyway.  file:// forces the ordinary transfer, which sends what the refs
# reach and nothing else.
#
# It is then stood on control, because R is bare and its own HEAD never names
# the control branch, so a clone of it otherwise lands on an unborn HEAD with
# no local branch at all.
sub clone_copy {
	my ($self, %opts) = @_;
	my $key = $opts{as} // 'c';

	# The key names a field of the harness itself, so one that is already
	# taken would replace a copy, a path, or a fixture for every accessor
	# that reads it afterwards, and it would do it without a word.  A row
	# that asks for a key the harness holds is told so instead.
	die "The harness already holds '$key', so no copy can be registered there\n"
		if exists $self->{$key};

	my $dir = "$self->{tmp}/copy-" . int(rand(1_000_000));

	run({dir => $self->{base}, onfailure => "Failed to cut a copy from R"},
		'git', 'clone', '-q', "file://$self->{r}", $dir);
	run({dir => $dir}, 'git', 'config', 'user.email', "copy-$key\@genesis.example.com");
	run({dir => $dir}, 'git', 'config', 'user.name', "Copy $key");
	run({dir => $dir, onfailure => "Failed to stand the copy on control"},
		'git', 'checkout', '-q', $self->{control});

	$self->{$key} = $dir;
	return $key;
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
	my ($out, $rc) = run({dir => $self->{$copy}, stderr => 0},
		'git', 'log', "--max-count=$n", '--format=%s', $ref);
	return () if $rc || !defined $out;
	chomp $out;
	return reverse grep {length} split /\n/, $out;
}

# }}}
# commits_on - every commit a ref can reach, newest first {{{
#
# A row asking whether a teammate's delivery survived a run asks whether its
# sha is still on the branch, and a list of shas answers that without the row
# having to know where on the branch the commit sits.  It takes a directory
# rather than a copy, because a row asks it of R as often as of a copy.
#
# The read is stderr-suppressed and its status is checked, the way the readers
# above it are, so a ref that is not there answers an empty list rather than
# git's complaint split into shas.
sub commits_on {
	my ($dir, $ref) = @_;
	my ($out, $rc) = run({dir => $dir, stderr => 0},
		'git', 'rev-list', $ref);
	return () if $rc || !defined $out;
	chomp $out;
	return grep {length} split /\n/, $out;
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
# and the pre-flight both have to catch, and a row proves it by asking R
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
# writes.  One export answers both questions, because safe hands back the
# whole subtree under the path in a single call, so the path's own record and
# the children below it are read together rather than exported twice.  The
# path's own record is preferred, because an environment's record has children
# of its own that are not entries of its set, such as its hold and its
# proposal.
sub newest_record {
	my ($self, $path) = @_;
	my $exported = $self->_exported($path) or return undef;

	my $key  = _export_key($path);
	my $flat = $exported->{$key};
	unless ($flat) {
		my ($newest) = reverse sort
			grep {m{^\Q$key\E/[^/]+$}} keys %$exported;
		$flat = defined $newest ? $exported->{$newest} : undef;
	}
	return undef unless $flat;

	my %nested;
	for my $dotted (sort keys %$flat) {
		my @parts = split /\./, $dotted;
		my $leaf  = pop @parts;
		my $at    = \%nested;
		$at = ($at->{$_} //= {}) for @parts;
		$at->{$leaf} = $flat->{$dotted};
	}
	return \%nested;
}

# }}}
# _exported - the whole subtree under a vault path, decoded, or undef {{{
#
# safe export answers the whole subtree under the path it was given, keyed by
# each entry's own path without the leading slash, so one call answers both
# what sits at the path and what sits below it.
#
# The read runs on the parent's own path, which the recording wrapper is
# deliberately kept off, so a row reading a record to assert on it never
# counts as one of the reads the run under test made.
sub _exported {
	my ($self, $path) = @_;
	$self->fixture_vault;
	my ($out, $rc) = run({env => {SAFE_TARGET => $self->{vault_target}},
			stderr => 0},
		_real_safe(), 'export', $path);
	return undef if $rc || !$out;
	return eval {JSON::PP->new->decode($out)} || undef;
}

# }}}
# _export_key - the key safe writes a path under in its export {{{
#
# safe drops the leading slash and keeps no trailing one, and a caller may
# write either, so both are taken off here rather than at each reader.
sub _export_key {
	my ($path) = @_;
	(my $key = $path) =~ s{/{2,}}{/}g;
	$key =~ s{^/}{};
	$key =~ s{/$}{};
	return $key;
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
	# The message goes in on stdin rather than through a file of a fixed
	# name, so two readers running at once cannot write over one another and
	# nothing is left standing in the scratch directory afterwards.
	my ($parsed) = run({dir => $dir, stdin => ($message // '') . "\n"},
		'git', 'interpret-trailers', '--parse');

	my %trailers;
	for my $line (split /\n/, ($parsed // '')) {
		$trailers{$1} = $2 if $line =~ /^(\S[^:]*):\s*(.*)$/;
	}
	return \%trailers;
}

# }}}
# unfolded - what a run said, put back on one line {{{
#
# A run folds what it says to the terminal's width on its way out, so a phrase
# a row is looking for can arrive with a newline and an indent somewhere in the
# middle of it.  A row reads what the operator was told rather than where the
# fold landed, so the streams it is handed are joined and their whitespace is
# collapsed before anything is matched against them.  They are joined on a
# newline, so that no phrase can match across the seam where one stream ends
# and the next begins, and an undefined stream counts as an empty one, so a
# row that captured only stderr passes what it has.
sub unfolded {
	my $said = join("\n", map {$_ // ''} @_);
	$said =~ s/\s+/ /g;
	return $said;
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

	# Nothing in the environment gets to say which repository the git below
	# runs against.  This is the harness's one entry point, so a scrub here
	# covers every helper a row reaches for afterwards.
	scrub_git_env();

	# Whatever the harness above this one armed in the parent goes back before
	# the new one arms anything of its own, so no fixture of this harness is
	# read through a variable naming the last harness's file.
	_release_env();

	my $base = helper::workdir() . sprintf('/ph-%d-%06d', $$, int(rand(1_000_000)));
	helper::mkdir_or_fail($base);
	# Every scratch path the harness writes goes under this one directory, so
	# the base holds the three repositories and nothing else and a reader can
	# tell them from the litter at a glance.
	helper::mkdir_or_fail("$base/tmp");

	my $self = bless {
		base      => $base,
		tmp       => "$base/tmp",
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
		# A chained harness names each environment's predecessor as its
		# prior_env, so the topology has the edges an ancestor hold is
		# computed from.  It is off by default, because a pipeline whose
		# environments stand beside one another is what most rows want and
		# an edge nobody asked for changes every DAG the suite builds.
		chained   => $opts{chained} // 0,
		# A fanned harness hangs every other environment off the one this
		# names, which is the shape a deploy that spawns one child for
		# several branches needs.  It is exclusive with chained, because an
		# environment has one predecessor.
		fanned    => $opts{fanned},
		# The shared files every environment declares through
		# genesis.pipeline.track_additional_files.  The harness lays each one
		# down on control as it seeds, so the declaration names a file the
		# repository actually holds.
		shared    => $opts{tracked} // [],
		mount     => $opts{exodus_mount} // $DEFAULT_EXODUS_MOUNT,
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
	helper::provide_rc() unless defined do {no warnings 'once'; $Genesis::RC};

	my $scratch = sprintf('%s/top-%06d', $self->{tmp}, int(rand(1_000_000)));
	helper::mkdir_or_fail($scratch);

	# The create points GENESIS_ROOT at the root it just built and names the
	# repository's vault in GENESIS_TARGET_VAULT and SAFE_TARGET.  Under
	# no_vault that name is the empty string, which is not the same as having
	# no target at all, so all three are guarded and GENESIS_ROOT is pointed
	# at where the root actually ends up once the guard has gone.  The guard
	# rather than a pair of reads and writes around the call, because a create
	# that dies would otherwise leave the fixture's vault names standing in the
	# parent and GENESIS_ROOT naming a scratch directory nothing will keep.
	my $made = do {
		my $guard = helper::local_env(
			GENESIS_ROOT         => $ENV{GENESIS_ROOT},
			GENESIS_TARGET_VAULT => $ENV{GENESIS_TARGET_VAULT},
			SAFE_TARGET          => $ENV{SAFE_TARGET},
		);
		Genesis::Top->create($scratch, $self->{type}, no_vault => 1)->path;
	};

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
	#
	# Each file carries the two declarations the harness was asked for, which
	# are the predecessor a chained harness names and the shared files every
	# environment tracks.  They go in here rather than in a commit of their
	# own, so that a row's first commit is the first thing the walk finds due.
	die "a harness is chained or fanned, not both\n"
		if $self->{chained} && defined $self->{fanned};
	my $prior;
	for my $env (@{$self->{envs}}) {
		my $names = defined $self->{fanned}
			? ($env eq $self->{fanned} ? undef : $self->{fanned})
			: ($self->{chained} ? $prior : undef);
		$self->write_env_file($env, commit => 0, pipeline => {
			(defined $names ? (prior_env => $names) : ()),
			(@{$self->{shared}}
				? (track_additional_files => $self->{shared}) : ()),
		});
		$prior = $env;
	}

	# A tracked file is laid down beside the environment files, because a
	# declaration naming a path the repository does not hold puts nothing in
	# the set and a row that asked for a shared file would find none.
	helper::put_file("$root/$_", "---\nshared: 0\n") for @{$self->{shared}};

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
#
# An automated provider gets the whole automated shape as well, which is the
# provider's target, the clone credential, the committer identity, and the
# shuttle, the vault, and the locker of D23.  A repository that names an
# automation and carries none of them is refused by the schema and by the
# Concourse provider's own validate_config, and both of those run on every
# load, so a row that asks for an automated provider and nothing else would
# meet them before it reached whatever it came to prove.  The blocks come
# from automation_blocks, which is the same answer the automated shape
# writes, and the target says harness because nothing here talks to a real
# Concourse.  They are written before the source-control loop rather than
# after it, so a row that names an auth type or a committer identity of its
# own lands on top of them instead of losing to them without a word.  A row
# that cares what any of the rest is writes its own through the pipeline
# hashref, which is set last.
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
	unless ($self->{provider} eq 'manual') {
		$config->set('pipeline.provider.target' => 'harness');
		$config->set('pipeline.source_control.auth.type' => 'ssh');
		$config->set('pipeline.source_control.auth.vault' => 'secret/ci/git');
		$config->set('pipeline.source_control.identity.name' => 'Genesis CI');
		$config->set('pipeline.source_control.identity.email'
			=> 'ci@genesis.example.com');
		my %blocks = automation_blocks();
		for my $block (sort keys %blocks) {
			$config->set("pipeline.$block.$_" => $blocks{$block}{$_})
				for sort keys %{$blocks{$block}};
		}
	}

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
# The name is taken as an argument as well as off the harness, because a
# second deployment root is a root of its own and its environments are loaded
# through its own dev kit.  A caller that names none falls back to the kit the
# harness was declared with, which is what the first root installs.
sub _install_kit {
	my ($self, $root, $kit) = @_;
	my $name = $kit // $self->{kit} or return $self;

	my $from = $name =~ m{/}
		? "$helper::TOPDIR/$name"
		: "$helper::TOPDIR/t/kits/$name";
	die "make_harness does not know the kit $name\n" unless -d $from;
	# The kit's contents land at dev, rather than the kit directory landing
	# inside a dev that is already there under its own name, which is what a
	# plain copy of the directory does the second time around.
	helper::mkdir_or_fail("$root/dev") unless -d "$root/dev";
	run({dir => $self->{base}, onfailure => "Failed to install the $name kit"},
		'cp', '-R', "$from/.", "$root/dev");

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

# The options are handed to Service::Git, so a row that wants a handle of a
# shape the harness does not build asks for it here rather than building one
# itself, which would be state-building outside the harness.
#
# There is one handle per copy however it is asked for.  Service::Git keeps a
# single instance per repository root and every caller naming that root is
# answered with it, so two rows holding a handle on copy A hold the same
# object and the session on it is the same session.  The harness keeps no
# cache of its own, because a cache in front of a cache can only disagree
# with it.
sub git {
	my ($self, $copy, %opts) = @_;
	$copy //= 'a';
	return Service::Git->new($self->{$copy}, %opts);
}

# The directory the fixture git sits in, so a row that reads a pre-flight
# shape itself can put it first on its own path for the length of the call.
# run_genesis already arranges that for a whole command, and a row calling
# into the library is the one caller the harness cannot arrange it for.  The
# directory is built on the first ask, so a row may reach for it before it has
# asked for a shape.
sub preflight_bin {
	my ($self) = @_;
	$self->_preflight_git;
	return "$self->{tmp}/bin";
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

	# A path this call removes hands its mode to the path this call writes
	# that ends in the same name, which is what a file moving under or out of
	# a prefix looks like from here, so an executable travels as one.
	# put_file writes a file nobody named a mode for as 0644, and a tree
	# written by a row should not quietly disagree with the tree it copied.
	my %removed;
	for my $path (grep {!defined $files->{$_}} keys %$files) {
		next unless -f "$dir/$path";
		my $mode = (stat "$dir/$path")[2] & 07777;
		$removed{$path} = $mode if $mode & 0111;
	}

	for my $path (sort keys %{$files || {}}) {
		if (defined $files->{$path}) {
			my ($from) = grep {
				"/$path" =~ m{/\Q$_\E$} || "/$_" =~ m{/\Q$path\E$}
			} sort keys %removed;
			defined $from
				? helper::put_file("$dir/$path", $removed{$from}, $files->{$path})
				: helper::put_file("$dir/$path", $files->{$path});
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
	# The checkout says so when it fails.  Without that, a copy asked to
	# commit on a branch it holds nowhere stays on the control branch and
	# commits there instead, and the push that follows publishes it.
	run({dir => $dir, onfailure => "Failed to stand copy $copy on $branch"},
		'git', 'checkout', '-q', $branch) unless $current eq $branch;

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
	# Copy B is given the branch first, as hand_commit gives it one, because
	# a deployment branch cut or delivered in copy A is a branch copy B has
	# never held and the checkout below cannot make one out of nothing.
	$self->_ensure_branch('b', $branch) if defined $branch;
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
#
# The caller names the branch the commit is on, and a call that names none is
# refused.  A fetch asks for a branch, so a guess at the control branch brings
# the wrong objects across for a commit that lives on a deployment branch, and
# the sub then says the commit is in none of the repositories when it is in
# one of them.
sub _fetch_commit {
	my ($self, $copy, $commitish, @branches) = @_;
	my $dir = $self->{$copy};
	die "_fetch_commit needs the branch $commitish is on, because a fetch "
	  . "asks for a branch and a guess brings the wrong objects across\n"
		unless @branches;

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

	my $seed = "$self->{tmp}/init-" . int(rand(1_000_000));
	helper::put_file($seed, "This branch is managed by genesis pipeline-apply.\n");

	my ($blob) = run({dir => $dir, onfailure => "Failed to write the init blob"},
		'git', 'hash-object', '-w', $seed);
	chomp $blob;

	my $index = "$self->{tmp}/idx-" . int(rand(1_000_000));
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

	$self->_fetch_commit($copy, $control, $self->{control});
	my $parent = $self->_branch_parent($copy, $branch);

	my $index = "$self->{tmp}/idx-" . int(rand(1_000_000));
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

	# The mode each path carries on control, so the mirror is a mirror.  A
	# delivery written at a fixed 100644 flipped the bit on every executable
	# file the set holds, which a kit's hooks are, and the branch then
	# differed from control in the one way no row had asked it to.
	my %mode = $self->_modes_at($dir, $control);

	my $corrupt = $opts{corrupt} || {};
	my $files   = $opts{files}   || {};
	for my $path (@set) {
		my $content = exists $corrupt->{$path} ? $corrupt->{$path}
		            : exists $files->{$path}   ? $files->{$path}
		            : undef;
		my $blob;
		if (defined $content) {
			my $tmp = "$self->{tmp}/blob-" . int(rand(1_000_000));
			helper::put_file($tmp, $content);
			($blob) = run({dir => $dir}, 'git', 'hash-object', '-w', $tmp);
		} else {
			($blob) = run({dir => $dir}, 'git', 'rev-parse', "$control:$path");
		}
		chomp $blob;
		run({dir => $dir}, 'git', 'update-index', '--add', '--cacheinfo',
			sprintf('%s,%s,%s', $mode{$path} // '100644', $blob, $path));
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
# _modes_at - every path's file mode in one commit's tree {{{
#
# A delivery mirrors the set at a control commit, so it has to carry each
# file's mode across as well as its contents.  Writing every entry at 100644
# strips the executable bit off a kit's hooks, and the branch then differs
# from control in a way no row asked for, which shows up as files the walk
# says it would propagate.
sub _modes_at {
	my ($self, $dir, $commit) = @_;
	my ($listing) = run({dir => $dir}, 'git', 'ls-tree', '-r', $commit);
	chomp $listing if defined $listing;
	my %mode;
	for my $line (split /\n/, ($listing // '')) {
		next unless $line =~ m{^(\d{6})\s+\S+\s+\S+\t(.+)$};
		$mode{$2} = $1;
	}
	return %mode;
}

# }}}
# propagation_set - the set's paths, read by the harness from a commit's tree {{{
#
# The harness computes the set itself rather than calling propagation_files,
# because a row that asserts a delivery against the product's own reader would
# be asserting the reader against itself.  A change to propagation_files must
# not silently change what the snapshot assertion compares.
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
	# The kit source under dev/ and the reaction scripts under bin/ are kinds
	# of their own, and they stand whatever the environment file's tracked
	# list says.  Genesis::Env builds its kinds independently of one another
	# and adds the tracked paths on top of them, so a reader that took the kit
	# away wherever a list was declared would read a correctly mirrored branch
	# as one that had lost its whole kit.
	push @kinds, qr{^\Q$prefix\E(?:bin|dev)/};

	# The ops files are the one kind the tracked list stands in for here,
	# because the harness runs no blueprint hook, so the list is the one
	# statement about which of them the merge consumes that the harness reads,
	# while the product also consults the blueprint the kit ships.
	# Where the file at $at declares a list, those paths are the ops files
	# that are in, and a delivery made under a wider list therefore leaves
	# behind paths the next delivery has to remove.  Where it declares none
	# the kind stands whole, which is every environment the suite writes
	# without saying otherwise.  The list is read from the tree at $at and
	# never from the working tree.
	my $tracked = $self->_tracked_files($at, "$prefix$env.yml");
	push @kinds, defined $tracked
		? (map {qr{^\Q$prefix$_\E$}} @$tracked)
		: qr{^\Q$prefix\Eops/};
	# track_additional_files joins the set git-root-relative, in one form, so
	# the walk and the writer name a tracked path the same way.
	push @kinds, map {qr{^\Q$_\E$}}
		@{$opts{extra} || ($self->{extra} || {})->{$env} || []};

	my @set = grep {my $p = $_; grep {$p =~ $_} @kinds} @all;
	return sort @set;
}

# }}}
# edited_file - the one file in an environment's set a row may safely edit {{{
#
# Two files stand a dirty tree up and read what the deploy says about it, and
# both want the same file: the environment's own, asked of the set rather
# than spelled out, so a row cannot come to be editing a file the deploy
# never looks at.  The other members are passed over on purpose, because an
# edit to .genesis/config takes the deployment root with it and an edit to an
# ops file may leave the manifest unbuildable.
#
# The last segment is what is matched, since propagation_set prefixes every
# path with the deployment root where the harness has one, and a match on the
# whole path would answer nothing there and leave a row writing to a name
# that is half empty.  Where the set carries no such file it dies naming the
# environment, rather than handing back undef for a row to write through.
sub edited_file {
	my ($self, $env, %opts) = @_;
	my ($file) = grep {m{(?:^|/)\Q$env\E\.yml$}} $self->propagation_set($env, %opts);
	die "the propagation set for $env carries no $env.yml to edit\n"
		unless defined $file;
	return $file;
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
# call and every delivery reads the set.  The cache belongs to the harness and
# not to the package, so it goes when the harness does rather than growing for
# as long as the process lives.
sub _tracked_files {
	my ($self, $at, $path) = @_;

	my ($body, $rc) = run({dir => $self->_repo_holding($at), stderr => 0},
		'git', 'show', "$at:$path");
	return undef unless defined $rc && $rc == 0 && defined $body;
	my $cached = $self->{tracked} //= {};
	return $cached->{$body} if exists $cached->{$body};

	my $tmp = "$self->{tmp}/env-" . int(rand(1_000_000)) . '.yml';
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
	return $cached->{$body} = ref $declared eq 'ARRAY' ? $declared
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
# message down into the body, which is the shape the marker reader has to
# survive.  keep_marker off is the site that lost it altogether.
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

	my $index = "$self->{tmp}/idx-" . int(rand(1_000_000));
	local $ENV{GIT_INDEX_FILE} = $index;
	run({dir => $dir}, 'git', 'read-tree', '--empty');
	my $tmp = "$self->{tmp}/blob-" . int(rand(1_000_000));
	helper::put_file($tmp, "an unrelated history\n");
	my ($blob) = run({dir => $dir}, 'git', 'hash-object', '-w', $tmp);
	chomp $blob;
	unlink $tmp;
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

	# Copy A's branch is cut before the teammate publishes anything, because
	# a branch cut afterwards starts at the teammate's tip and a call with
	# no local commits then reads in-sync rather than behind.
	$self->_ensure_branch('a', $branch) if defined $branch;

	$self->_ensure_branch('b', $branch) if defined $branch;
	$self->_commit_in('b', $branch,
		files   => {"from-b-$_.yml" => "---\nn: $_\n"},
		message => "a teammate's change $_",
		push    => 1,
	) for 1 .. $remote;

	$self->refresh('a', $branch // $self->{control}) if $remote;

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
	# The branch is moved with a checkout rather than with update-ref, so
	# copy B's working tree and its index move with the ref.  update-ref
	# leaves both where they were, and a copy that was standing on the branch
	# came back with an index that no longer matched its own HEAD, so the
	# commit made below recorded the removal of everything the branch had
	# gained since.  This is what move_on_r_at beside it already does.
	run({dir => $self->{b}}, 'git', 'fetch', '-q', 'origin', $branch);
	run({dir => $self->{b}, onfailure => "Failed to move $branch in copy B"},
		'git', 'checkout', '-q', '-B', $branch,
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

# One commit is dropped, and which one it is is the second from the tip
# unless the caller names it outright through drop.  There is no count, since
# a count only widened the window the second commit was read through and
# never changed how many commits the rebase took out.
sub rewrite_branch {
	my ($self, $branch, %opts) = @_;

	# The rewrite runs in copy B, because a rebase checks out and copy A's
	# working state is what the rows assert on.
	my $dir = $self->{b};
	run({dir => $dir}, 'git', 'fetch', '-q', 'origin', $branch);
	my ($listed) = run({dir => $dir}, 'git', 'rev-list',
		'--max-count=2', "origin/$branch");
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
# tag_branch - a tag carrying a branch name in one copy {{{
#
# A branch name is not a ref name, and `git rev-parse --verify` answers about a
# tag as readily as about a branch, so a tag that carries a deployment branch's
# name is how a loose reader comes to call a branch local when the branch is
# not there.  The divergence query has to read past that, and this helper is
# the state a row stands it in.
sub tag_branch {
	my ($self, $copy, $name, %opts) = @_;
	my $at  = $opts{at} // branch_of($self->{$copy});
	my $sha = ref_in($self->{$copy}, $at) // $at;

	run({dir => $self->{$copy}, onfailure => "Failed to tag $name in copy $copy"},
		'git', 'tag', '-f', $name, $sha);
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
	# copy is not forwarded, because the helper's name says the branch is one
	# this clone made and never published, and this clone is copy A.  A row
	# that wants the branch in copy B calls local_branch and names it.
	delete $opts{copy};
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
# second_remote - another bare repository, wired onto a copy beside origin {{{
#
# A site that clones from one remote and pushes to another has two of them,
# and which one git lists first is alphabetical rather than anything the
# operator chose.  A row proving that a command publishes to the remote its
# configuration names wants the other one to sort ahead of origin, so the
# default name is one that does.
#
# The repository is bare and empty, so a branch that turns up there turned up
# by mistake, and a row says so by reading its heads.  Nothing is fetched,
# because a row that wanted the two remotes to share history would be about
# something else.
sub second_remote {
	my ($self, %opts) = @_;
	my $name = $opts{name} // 'dev';
	my $copy = $opts{copy} // 'a';
	my $dir  = "$self->{base}/$name.git";

	run({dir => $self->{base}, onfailure => "Failed to build the $name remote"},
		'git', 'init', '-q', '--bare', $dir);
	run({dir => $self->{$copy}, onfailure => "Failed to add the $name remote"},
		'git', 'remote', 'add', $name, $dir);

	return $dir;
}

# }}}
# drop_remotes - take every remote off a copy, so it has none at all {{{
#
# A repository that has no remote is a state of its own, and it is not the
# state sever_remote arms.  There the remote is configured and unreachable,
# and a command meets a failed fetch.  Here there is nowhere to publish to at
# all, and a command has to say so before it writes anything.
#
# The copy was cloned, so its control branch tracks the origin the clone
# made, and the upstream goes with the remote.  A branch left tracking a
# remote that is gone is a state git itself would never leave behind.
sub drop_remotes {
	my ($self, %opts) = @_;
	my $copy = $opts{copy} // 'a';
	$self->set_remotes(copy => $copy, remotes => {}, upstream => 0);
	return $self;
}

# }}}
# broken_pushurl - a remote that answers a read and refuses every write {{{
#
# A row that wants to read git's own complaint about a push needs a remote
# that is still there for everything the run does before the push.  Severing
# the remote takes the refresh at the head of the run with it, and dropping
# it leaves the command with nowhere to publish and its own words for that,
# so neither shape reaches the push at all.
#
# git reads the push URL out of remote.<name>.pushurl where one is set and
# the fetch URL out of remote.<name>.url, so a pushurl naming an ordinary
# directory leaves every read of the run working and fails the one write.
#
# The directory is made rather than merely named, because git says a path
# does not appear to be a git repository whether the path exists or not, and
# a row reading that sentence should be reading it about something that is
# really there.
sub broken_pushurl {
	my ($self, %opts) = @_;
	my $copy   = $opts{copy}   // 'a';
	my $remote = $opts{remote} // 'origin';
	my $path   = "$self->{tmp}/not-a-repository";

	helper::mkdir_or_fail($path) unless -d $path;
	run({dir => $self->{$copy},
			onfailure => "Failed to point the $remote push at $path"},
		'git', 'config', "remote.$remote.pushurl", $path);

	return $path;
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
	_with_plan($self->{fault}{plan}, sub {
		$_[0]->{$opts{at} // 'push'} = {
			n      => $opts{nth} // 1,
			from   => 0,
			action => ['push', '-q', '--force', 'origin', $branch],
			in     => $self->{b},
		};
	});

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

	helper::provide_rc() unless defined do {no warnings 'once'; $Genesis::RC};

	# create points GENESIS_ROOT at the root it has just built and names the
	# repository's vault in GENESIS_TARGET_VAULT and SAFE_TARGET.  The first
	# root is the one the rows run against, so all three are guarded and go
	# back when the call is done, whether it answered or died.
	{
		my $guard = helper::local_env(map {($_ => $ENV{$_})}
			qw/GENESIS_ROOT GENESIS_TARGET_VAULT SAFE_TARGET/);
		Genesis::Top->create($self->{a}, $type, no_vault => 1, directory => $path);
	}

	# create writes no pipeline section, here as at the first root, and a
	# command run in this root reads its provider and its enabled flag out of
	# this file.  Without the section a row that runs a command in the second
	# root meets the refusal that turns away a repository with no pipeline,
	# which is never what a row asking for a second root is after.
	$self->_seed_pipeline_section("$self->{a}/$path");

	# The dev kit this root's environments are loaded through.  A root with
	# none loads no environment at all, so a row that runs a whole command in
	# it reads every environment as failed, and the kit goes in ahead of the
	# commit below so that it is part of the control branch as the first
	# root's is.
	$self->_install_kit("$self->{a}/$path", $opts{kit});

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
	my %params   = %{$opts{params}   || {}};
	$pipeline{require_pr} = 'true'
		if $self->{mode} eq 'pr' && !$opts{site};
	# One file carries one pipeline key, so entries handed in under genesis
	# fold into the pipeline block wherever a row fills both, and the pipeline
	# option wins a key the two of them name together.  Anything other than a
	# hash under genesis cannot fold, and writing it beside a pipeline block
	# would put two pipeline keys in one file, so the row hears about it by
	# name rather than reading a file no YAML reader will load.
	if (%pipeline && exists $genesis{pipeline}) {
		die "write_env_file cannot write $name.yml, because genesis.pipeline "
		  . "is not a hash and so cannot fold into the pipeline block\n"
			unless ref $genesis{pipeline} eq 'HASH';
		%pipeline = (%{delete $genesis{pipeline}}, %pipeline);
	}
	my $nested = %genesis || %pipeline;

	my $body = "---\nkit:\n  name:    dev\n  version: latest\n  features: []\n";
	$body .= "genesis:\n" if !$opts{site} || $nested;
	$body .= "  env: $name\n" unless $opts{site};
	$body .= _yaml_pair($_, $genesis{$_}, 1) for sort keys %genesis;
	if (%pipeline) {
		$body .= "  pipeline:\n";
		# The parent is named here as well, so a key refused through the
		# pipeline option is refused by the same path as the same key handed
		# in nested under genesis.
		$body .= _yaml_pair($_, $pipeline{$_}, 2, 'pipeline')
			for sort keys %pipeline;
	}
	# A top-level block of its own rather than a key under genesis, because
	# params is where a kit's own values live and a row that wants a delta
	# the walk can route wants one the environment file legitimately holds.
	if (%params) {
		$body .= "params:\n";
		$body .= _yaml_pair($_, $params{$_}, 1, 'params') for sort keys %params;
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
# due_commit - one control commit the walk will route to an environment {{{
#
# A row in pull request mode needs a control commit that is due, and the only
# file that routes to an environment is that environment's own file at the
# deployment root.  A path under the environment's name is in no propagation
# set, so a commit written there routes nowhere and leaves the row with
# nothing due at all.
#
# The file is written without a commit of its own and committed by hand
# afterwards, for two reasons.  The run reads genesis.pipeline.require_pr out
# of that very file, so a body a row composed itself and dropped the key from
# would take the whole pull request arm with it; and write_env_file's own
# commit carries a message of its own choosing, which a row asserting on a
# subject cannot name.
#
# Trailers are passed through, so a row lays a gate by giving this a
# Genesis-Stage trailer rather than by writing the file and the commit itself.
sub due_commit {
	my ($self, $env, %opts) = @_;

	my $path = $self->write_env_file($env,
		params => $opts{params}, commit => 0);

	return $self->commit_on_control(
		files    => {$path => slurp($self->{a}."/$path")},
		message  => $opts{message},
		trailers => $opts{trailers},
		push     => defined $opts{push} ? $opts{push} : 1,
	);
}

# }}}
# due_on_control - one control commit two chained environments are due {{{
#
# A deploy that hands off to a child needs exactly one commit for the child to
# carry, and that commit has to be due to both environments so that the
# certification the deploy writes is what releases the downstream one.  So the
# commit touches both environment files, and it is delivered to the upstream
# environment alone, which leaves the downstream one waiting on its
# predecessor.
#
# Both files are written without a commit of their own and committed together
# afterwards, because one commit is the whole point and write_env_file would
# otherwise lay one per file.  The paths committed are the ones write_env_file
# hands back rather than names spelled out here, so a harness that moves its
# environment files to a deployment root moves this with it.
#
# Each file is written whole, so prod's prior_env is named again here even
# though a chained seeding already laid it, because the rewrite would drop a
# key it did not restate.  A harness seeded with shared files has the same
# exposure on track_additional_files, so a row that wants both this commit
# and tracked files wants a builder that keeps them.
sub due_on_control {
	my ($self) = @_;
	# The commit is made wherever copy A is standing, so a caller standing on
	# a deployment branch would lay the control commit there and find nothing
	# due.  It is refused by name rather than checked out from under the
	# caller, because a row that stood somewhere on purpose should hear about
	# it instead of having the builder move it.
	my $on = branch_of($self->{a}) // '';
	die "due_on_control lays a commit on $self->{control} and copy A is "
	  . "standing on $on\n" unless $on eq $self->{control};

	my @paths = (
		$self->write_env_file('qa', params => {n => 2}, commit => 0),
		$self->write_env_file('prod',
			genesis => {pipeline => {prior_env => 'qa'}},
			params  => {n => 2}, commit => 0),
	);
	run({dir => $self->{a}}, 'git', 'add', '--', @paths);
	run({dir => $self->{a}, onfailure => 'Failed to commit the due change'},
		'git', 'commit', '-q', '-m', 'A change both environments are due');
	$self->push_from('a', $self->{control});

	my $control = $self->git('a')->sha($self->{control});
	$self->deliver('qa', control => $control);
	$self->refresh('a', $self->{control},
		$self->slug('qa'), $self->slug('prod'));
	return $control;
}

# }}}
# patch_calls - every PATCH a run sent, oldest first {{{
#
# A row that asserts on a pull request the run updated wants the url it named
# as well as the body it carried, and both of those are on the call record
# rather than in the double's stored state, so the whole record comes back.
sub patch_calls {
	my ($gh) = @_;
	return grep {($_->{method} // '') eq 'PATCH'} gh_calls($gh);
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
	my ($key, $value, $depth, $parent) = @_;
	my $pad  = '  ' x $depth;
	# The path the sub is standing on, so a refusal about a list names the
	# whole of it the way the hash branch already names key.inner.  A row
	# that asked for genesis.pipeline.track_additional_files should hear that
	# name rather than the leaf alone.
	my $path = defined $parent ? "$parent.$key" : $key;
	if (ref $value eq 'HASH') {
		my $block = sprintf("%s%s:\n", $pad, $key);
		for my $inner (sort keys %$value) {
			die "write_env_file cannot write $path.$inner, because a value "
			  . "nested more than one level deep is not supported\n"
				if ref $value->{$inner} && ref $value->{$inner} ne 'ARRAY';
			$block .= _yaml_pair($inner, $value->{$inner}, $depth + 1, $path);
		}
		return $block;
	}
	if (ref $value eq 'ARRAY') {
		die "write_env_file cannot write the list $path, because an entry of "
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

	# The mount is cleared whole as the fixture attaches, so a mount shorter
	# than the harness's own default is refused.  A row that named /secret/
	# would take every record the fixture vault holds with it, including the
	# ones another harness in the same file is standing on.
	die sprintf("make_harness will not clear the exodus mount %s, because "
		. "it is shorter than the default %s and the clearing takes the "
		. "whole subtree\n", $self->exodus_mount, $DEFAULT_EXODUS_MOUNT)
		if length($self->exodus_mount) < length($DEFAULT_EXODUS_MOUNT);

	my $target = helper::vault_start('genesis-propagation-harness');
	$self->{vault_target} = $target;
	$self->{vault_url}    = $helper::VAULT_URL{$target};

	run({env => {SAFE_TARGET => $target}, passfail => 1, stderr => 0},
		_real_safe(), 'rm', '-rf', $self->exodus_mount);

	$self->{vault_log}    = "$self->{tmp}/vault-reads.log";
	$self->{vault_refuse} = "$self->{tmp}/vault-refused-writes";
	my $bin = "$self->{tmp}/bin";
	helper::mkdir_or_fail($bin) unless -d $bin;
	helper::put_file("$bin/safe", 0755, <<"EOS");
#!/usr/bin/env bash
# Records a read and hands the call on to the real safe.  Only a wrapper on
# the path can see what a spawned genesis child reads.
#
# A write at or below a path break_vault_writes named is refused here rather
# than handed on, which is the one way a row can make a vault write fail while
# every read still answers.  Nothing writes the refusal file until a row arms
# it, so an unarmed harness pays one file test and hands the call straight on.
case "\$1" in
	get|read|export) echo "\$2" >> "$self->{vault_log}" ;;
	set|rm|delete|move)
		if [ -s "$self->{vault_refuse}" ]; then
			# A move is refused by either end, because a move whose
			# destination lands under a refused path writes there just as
			# surely as a set does.
			while IFS= read -r refused; do
				[ -n "\$refused" ] || continue
				for addressed in "\$2" "\$3"; do
					[ -n "\$addressed" ] || continue
					case "\$addressed" in
						"\$refused"|"\$refused"/*)
							echo >&2 "the harness vault refuses to write \$addressed"
							exit 1
							;;
					esac
				done
			done < "$self->{vault_refuse}"
		fi
		;;
esac
exec "@{[_real_safe()]}" "\$@"
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
# reaches the tool underneath rather than calling itself.  The version
# directory _fake_git_dir writes is one of those directories: a wrapper
# written while it sits first on the path would otherwise bake in the git that
# only reports a version.
sub _real_tool {
	my ($name) = @_;
	for my $dir (split /:/, ($ENV{PATH} // '')) {
		next if $dir =~ m{/ph-\d+-\d+/tmp/(?:bin|gh-bin|git-[^/]+)$};
		return "$dir/$name" if -x "$dir/$name";
	}
	return $name;
}

# }}}
# real_tool - the same answer, for a row that has to ask it too {{{
#
# A row that writes a shim of its own, or that only wants to know whether a
# tool is there at all, asks the same question the harness asks itself, and it
# has to skip the same directories.  A row reading the path for itself takes
# whatever sits first on it, which is a fixture directory whenever one is
# there, and then bakes that fixture into a shim that calls itself.
sub real_tool { return _real_tool($_[0]) }

# }}}
# _write_record - write one flat record under a vault path {{{
sub _write_record {
	my ($self, $path, %fields) = @_;
	$self->fixture_vault;
	for my $key (sort keys %fields) {
		next unless defined $fields{$key};
		run({env => {SAFE_TARGET => $self->{vault_target}},
		     onfailure => "Failed to write $path:$key"},
			_real_safe(), 'set', $path, "$key=$fields{$key}");
	}
	return $path;
}

# }}}
# _artifact_blob - the archive a deployment audit carries its artifacts in {{{
#
# The read side takes the audit's artifacts field as one base64 string,
# decodes it, gunzips it, and reads a tar out of what comes back, so a row
# that wants a deployment with artifacts has to hand over exactly that shape.
#
# No artifact map is put in the archive.  Without one the reader derives the
# types from the filenames it finds, which is the older of the two shapes it
# supports and the one that spares a caller having to know how the map is
# spelled, so a row asks for a file and names the type that file implies.
#
# The encoding is unwrapped, because the value travels as a single safe set
# argument and the line breaks the default encoding inserts would come back
# in the value.
sub _artifact_blob {
	my ($self, $files) = @_;
	return undef unless $files && keys %$files;

	require Archive::Tar;
	require IO::Compress::Gzip;
	require MIME::Base64;

	my $tar = Archive::Tar->new;
	$tar->add_data($_, $files->{$_}) for sort keys %$files;

	my $gzipped = '';
	open(my $fh, '>', \$gzipped)
		or die "the harness could not open a handle to build the artifacts\n";
	$tar->write(IO::Compress::Gzip->new(
		$fh, Level => 9, Append => 0, AutoClose => 1
	)) or die "the harness could not compress the artifacts\n";

	return MIME::Base64::encode_base64($gzipped, '');
}

# }}}
# _now - the one timestamp form a record's value takes {{{
#
# EXODUS_TIME_FORMAT under D58, which is the value form.  A path never carries
# one of these, and the two forms are kept apart on purpose.
sub _now {
	my ($self, $at, $offset) = @_;
	return $at if defined $at;
	my @t = localtime(time + ($offset // 0));
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
#
# artifacts belongs to the audit rather than to the flat record, because that
# is where the reader looks for it, and it is taken as a hash of filename to
# contents so a row says what the deploy saved rather than how the field
# stores it.  A row that names none gets an audit with no artifacts field at
# all, which is every deployment the harness wrote before this.
sub certify {
	my ($self, $env, %opts) = @_;
	# The audit below is written at a path keyed on the compact timestamp, so
	# two certifications inside one second would write one audit and the
	# second would take the first's place, leaving the environment reading as
	# though it had deployed once.  The harness counts its own certifications
	# and moves the clock on by one second for each, and it does so only
	# where the row named no time, so a row that pinned one still gets it.
	my $at   = $self->_now($opts{at}, $self->{certifications}++);
	my $path = $self->env_path($env, %opts);

	$self->_write_record($path,
		'git.commit'         => $opts{commit},
		'git.control_commit' => $opts{control_commit},
		'dated'              => $at,
		'state'              => $opts{state} // 'success',
		'dependencies_read'  => exists $opts{dependencies_read}
			? join(',', @{$opts{dependencies_read} || []}) : undef,
	);

	# The same facts as a deployment audit, because the two halves of the
	# record are read through two different readers.  last_read_dependencies
	# reads the flat record above at exodus_base, and every reader of the
	# certified commit goes through Genesis::Env::DeploymentManager, which
	# enumerates exodus_base/deployments and keys each entry on the compact
	# timestamp.  A harness that wrote only the flat record left every such
	# reader answering that the environment had never deployed.
	#
	# The audit is written whole rather than left to the reader's own
	# filling, because a record missing a field is read back as a deprecated
	# one and the reader says so on standard error for every row that has an
	# environment.
	(my $stamp = $at) =~ s/[Z ]?[+-]0000$//;
	$stamp =~ s/[^0-9]+//g;
	return $self->_write_record("$path/deployments/$stamp",
		'artifacts'          => $self->_artifact_blob($opts{artifacts}),
		'action'             => 'deploy',
		'result'             => $opts{result} // 'success',
		'completed'          => $at,
		'genesis_version'    => '3.2.0',
		'reason'             => 'the harness certified it',
		'user.shell'         => 'harness',
		'kit.id'             => 'dev/latest',
		'kit.name'           => 'dev',
		'kit.version'        => 'latest',
		'kit.is_dev'         => 1,
		'kit.features'       => '',
		'manifest.type'      => 'unredacted',
		'manifest.sha2'      => '0' x 64,
		'git.commit'         => $opts{commit},
		'git.control_commit' => $opts{control_commit},
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
# fixture_director - the exodus a BOSH director is reached through {{{
#
# A row that runs one of the BOSH commands needs an environment Genesis can
# build a director out of, and the five keys below are what
# Service::BOSH::Director::from_exodus validates before it will build one.
# The record sits beside the deployment record certify writes, at the
# environment's own exodus path, because that is where a create-env director
# publishes its own connection details and where --self reads them from.
#
# kit_name is bosh rather than dev, because from_exodus refuses a record
# whose kit is not a director unless the record says otherwise, and a row
# that wanted to say otherwise would be saying it in three places.
#
# The default url names an address no test dials, and the commands under test
# are driven through the fake bosh on GENESIS_BOSH_COMMAND rather than over
# the wire.  A row that needs the address answered passes one that is, which
# is what deployable_prod does with the port its listener took, because the
# director's status check dials the host before it runs a BOSH command.
sub fixture_director {
	my ($self, $env, %opts) = @_;
	return $self->_write_record($self->env_path($env, %opts),
		url            => $opts{url}      // 'https://10.0.0.4:25555',
		admin_username => $opts{username} // 'admin',
		admin_password => $opts{password} // 'harness-director-password',
		ca_cert        => $opts{ca_cert}
			// "-----BEGIN CERTIFICATE-----\nharness\n-----END CERTIFICATE-----\n",
		kit_name       => $opts{kit_name} // 'bosh',
	);
}

# }}}
# _sigint_snippet - the interrupt GENESIS_HARNESS_SIGINT_BEFORE_BOSH raises {{{
#
# It rides on the blueprint hook rather than on the bosh script's deploy arm,
# and the reason is Perl's own.  Genesis runs the BOSH deployment through
# system(), which ignores SIGINT in the parent for the length of the call, so
# a signal raised from inside that call is discarded and the deploy goes on to
# report an ordinary failure.  A hook is run through a pipe instead, where the
# handler bin/genesis installs does fire.  The blueprint is the hook this
# builder already owns, and it runs after the gate has switched and before any
# deployment begins, which is the window T232 is about.
#
# The signal goes to the genesis process rather than to this one, because the
# session and its handler live there.  A shell may stand between the two, so
# the parents are walked, and the embedded copy of genesis is stepped over:
# .genesis/bin/genesis is a member of the propagation set, so a parent whose
# command line named it would take a signal meant for the command under test.
#
# Where the walk finds nothing it says so and fails, rather than falling
# through to a plain failure a row would read as a refusal from the director.
sub _sigint_snippet {
	return <<'EOS';
if [ -n "${GENESIS_HARNESS_SIGINT_BEFORE_BOSH:-}" ]; then
  pid=$PPID
  target=
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ]; do
    case "$(ps -o command= -p "$pid" 2>/dev/null)" in
      *.genesis/bin/genesis*) ;;
      *bin/genesis*) target="$pid"; break ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  if [ -z "$target" ]; then
    echo >&2 "the harness found no genesis process to interrupt"
    exit 1
  fi
  kill -INT "$target"
  # Held open with this hook's own output closed, so genesis reads the end of
  # the hook and takes the signal rather than being handed a hook that merely
  # failed, and so nothing waits on a process genesis has already left.
  exec >/dev/null 2>&1
  sleep 5
  exit 1
fi
EOS
}

# fixture_bosh - the director, the bosh, and the kit a whole deploy needs {{{
#
# Every other fixture here builds state a command reads.  This one builds the
# three things a deploy has to reach before it finishes at all, because no
# row can assert what a deploy did until one of them gets that far.
#
# The first is a bosh on GENESIS_BOSH_COMMAND.  It answers env, configs, and
# config with the tables Service::BOSH::Director reads for its status, its
# configs listing, and each config's content, answers the deploy with a
# success line, and answers everything else with an empty table, so a reader
# walking the rows of one answer never reads a config row as a stemcell.
# GENESIS_HARNESS_BOSH_FAILS makes the deploy call exit non-zero instead, so
# a row can watch the bail path without breaking anything else the deploy
# asks the director for.  GENESIS_HARNESS_SIGINT_BEFORE_BOSH raises SIGINT in
# the genesis process instead, from the blueprint hook rather than from here,
# for the reason _sigint_snippet gives.  interpolate is handed to the real
# bosh, because a
# manifest carrying BOSH variables is resolved by running it and no fake
# answer would resolve anything.
#
# The second is a listener.  The director's status dials the host and port of
# the url in the exodus record before it runs a single bosh command, so a
# record naming an address nothing answers on refuses with a timeout however
# good the script is.  The listener is a loopback socket that accepts and
# echoes, which is all tcp_listening asks of it, and fixture_director's url
# is pointed at the port it took.  It lives on the harness so that it
# outlives this call and stops when the harness goes.
#
# The third is a kit.  The blueprint hook writes the manifest it names, so the
# merge has a file to read and the deploy reaches the BOSH call with a real
# manifest rather than dying on a name nothing wrote.  The hook runs with the
# kit directory as its working directory, which is where the merge looks for
# the file, so it writes there and names it relative.
#
# The variables are armed in the parent and named again in run_genesis, the
# way fault_git's are: the parent's own in-process reads need them here, and
# the child reads the environment it was handed rather than ours.
sub fixture_bosh {
	my ($self, %opts) = @_;
	my @envs = @{$opts{envs} // $self->{envs}};

	require Test::TCP;
	require IO::Socket::IP;
	my $port = Test::TCP::empty_port();
	$self->{bosh}{listener} = Test::TCP->new(
		listen     => 0,
		auto_start => 1,
		port       => $port,
		code       => sub {
			my $p = shift;
			my $sock = IO::Socket::IP->new(
				LocalAddr => '127.0.0.1',
				LocalPort => $p,
				Proto     => 'tcp',
				Listen    => 5,
				ReuseAddr => 1,
			) or die "the harness director cannot listen on $p: $!\n";
			while (my $remote = $sock->accept) {
				while (my $line = <$remote>) {
					print {$remote} $line;
					exit 0 if $line eq "quit\n";
				}
			}
		},
	);

	my $dir = "$self->{tmp}/bosh";
	helper::mkdir_or_fail($dir) unless -d $dir;

	# What a deploy handed BOSH is a fact no answer of the double carries and
	# no marker line in a manifest can show, so every call is written down as
	# it is made and bosh_runs reads the log back.  Both the log and the
	# manifests it points at outlive each run, because a row that runs twice
	# reads the second run's call against the first's.
	my $log  = $self->{bosh}{log}  = "$self->{tmp}/bosh-runs.log";
	my $runs = $self->{bosh}{runs} = "$self->{tmp}/bosh-runs";
	helper::mkdir_or_fail($runs) unless -d $runs;
	helper::put_file($log, '');

	my $command = "$dir/bosh";
	helper::put_file($command, 0755, <<"EOS");
#!/usr/bin/env bash
# The harness director.  It answers the four subcommands a deploy asks of a
# director and nothing else, and every other call is a plain success, so a
# reader can tell what this stands in for from the script alone.

# The subcommand is the first word that is not a flag, because the target and
# the credentials reach bosh through the environment rather than the command
# line.  It is worked out ahead of everything else because the recording below
# writes it down, and interpolate is still recognised by its own first word so
# that a call carrying a flag before it is handed on exactly as it was.
subcommand=
for arg in "\$@"; do
  case "\$arg" in
    -*) ;;
    *) subcommand="\$arg"; break ;;
  esac
done

# One line per call, the subcommand and then every argument, separated by tabs
# because nothing on a bosh command line here holds one.  The ordinal of the
# line is read before the line is written, and a last argument naming a file
# is copied aside under that ordinal, because the manifest a deploy hands BOSH
# is a temporary file that is gone by the time a row asks what was in it.
bosh_run_ordinal=\$(wc -l < "$log" 2>/dev/null || echo 0)
bosh_run_ordinal=\$((bosh_run_ordinal + 0))
{
  printf '%s' "\$subcommand"
  for arg in "\$@"; do printf '\\t%s' "\$arg"; done
  printf '\\n'
} >> "$log"
bosh_run_last=
for arg in "\$@"; do bosh_run_last="\$arg"; done
if [ -n "\$bosh_run_last" ] && [ -f "\$bosh_run_last" ]; then
  cp "\$bosh_run_last" "$runs/\$bosh_run_ordinal.manifest" 2>/dev/null || true
fi

if [ "\$1" = "interpolate" ]; then
  exec "@{[_real_tool('bosh')]}" "\$@"
fi

case "\$subcommand" in
deploy)
  if [ -n "\${GENESIS_HARNESS_BOSH_FAILS:-}" ]; then
    # Five lines of output before the refusal, because the failure path
    # reads the last five lines of what bosh said to decide whether the
    # operator cancelled, and a shorter answer makes it read past the end.
    echo "Task 1"
    echo "Task 1 | 00:00:00 | Preparing deployment: Preparing deployment"
    echo "Task 1 | 00:00:01 | Error: the harness director refused the deployment"
    echo "Task 1 Started"
    echo "Task 1 Failed"
    echo >&2 "the harness director refused the deployment"
    exit 1
  fi
  echo "Succeeded"
  exit 0
  ;;
env)
  cat <<'JSON'
{
  "Tables": [
    {
      "Content": "",
      "Header": {"cpi": "CPI", "name": "Name", "user": "User", "uuid": "UUID", "version": "Version"},
      "Rows": [
        {
          "cpi": "harness-cpi",
          "name": "harness-director",
          "user": "admin",
          "uuid": "00000000-0000-0000-0000-000000000000",
          "version": "999.0.0 (00000000)"
        }
      ],
      "Notes": []
    }
  ],
  "Blocks": null,
  "Lines": ["Succeeded"]
}
JSON
  exit 0
  ;;
configs)
  cat <<'JSON'
{
  "Tables": [
    {
      "Content": "configs",
      "Header": {"created_at": "Created At", "id": "ID", "name": "Name", "team": "Team", "type": "Type"},
      "Rows": [
        {
          "created_at": "2026-01-01 00:00:00 UTC",
          "id": "1*",
          "name": "default",
          "team": "",
          "type": "cloud"
        }
      ],
      "Notes": []
    }
  ],
  "Blocks": null,
  "Lines": ["Succeeded"]
}
JSON
  exit 0
  ;;
config)
  cat <<'JSON'
{
  "Tables": [
    {
      "Content": "configs",
      "Header": {"content": "Content"},
      "Rows": [{"content": "--- {}\\n"}],
      "Notes": []
    }
  ],
  "Blocks": null,
  "Lines": ["Succeeded"]
}
JSON
  exit 0
  ;;
esac

# Everything else answers an empty table, so a reader that walks the rows
# walks none rather than reading a config row as a stemcell.
case " \$* " in
  *" --json "*|*" --json")
    echo '{"Tables": [{"Content": "", "Header": {}, "Rows": [], "Notes": []}], "Blocks": null, "Lines": ["Succeeded"]}'
    exit 0
    ;;
esac

echo "Succeeded"
exit 0
EOS

	_guard_env(GENESIS_BOSH_COMMAND => $command);
	$self->{bosh}{command} = $command;

	$self->fixture_director($_, %opts, url => "https://127.0.0.1:$port")
		for @envs;

	# The operator's own clone is left holding the branch as the apply cut
	# it, because init_branch writes the root commit in copy A and every
	# delivery after that is published from the teammate's copy.  The gate
	# brings such a branch forward itself for a command that declares
	# branch_fast_forward, which the deploy does and nothing else does, so a
	# stale clone deploys while a read of the same branch is answered from
	# where the operator stands and says how far behind it is.  The catch-up
	# is what an operator who had pulled would have done, and every row that
	# is about something else wants it, rather than reading what it proves
	# through a ref move Genesis made on the way past.  A row whose subject
	# is the stale clone says catch_up => 0.
	$self->_catch_up($_) for (defined $opts{catch_up} && !$opts{catch_up})
		? () : @envs;

	# A row that brings its own kit says so, because a second dev kit in the
	# same root would be written over this one and neither would be the one
	# the row meant.
	unless (defined $opts{kit} && !$opts{kit}) {
		my $manifest = $opts{manifest} // "---\nharness: deployed\n";
		$self->fixture_kit(%opts, hooks => {
			blueprint => _sigint_snippet() . "cat > manifest.yml <<'MANIFEST'\n$manifest"
				. "MANIFEST\necho manifest.yml\n",
			%{$opts{hooks} || {}},
		});
	}

	return $self;
}

# }}}
# _catch_up - move copy A's deployment branch up to what R carries {{{
#
# Only where R is ahead and the move is a fast-forward, so a row that built a
# divergence on purpose keeps it.  The ref is written rather than checked out,
# because the fixture runs before a row has stood anywhere and a checkout here
# would move a working tree the row is about to place itself.
#
# That invariant is asserted rather than assumed, because this is a builder
# any row may call in any order.  move_on_r carries the comment about what
# a ref write does to a copy standing on the branch: the working tree and
# the index stay where they were, so the next commit records the removal of
# everything the branch had gained.  A row that has already stood on the
# branch is told to stand on it afterwards instead.
sub _catch_up {
	my ($self, $env, %opts) = @_;
	my $branch = $self->slug($env, %opts);
	die "fixture_bosh catches $branch up by writing the ref, and copy A is "
	  . "standing on it, which would leave the index behind the branch.  "
	  . "Call fixture_bosh before stand_on, or pass catch_up => 0.\n"
		if ($self->git('a')->current_branch // '') eq $branch;
	my $local  = ref_in($self->{a}, "refs/heads/$branch")   or return $self;
	my $remote = ref_in($self->{a}, "refs/remotes/origin/$branch")
		or return $self;
	return $self if $local eq $remote;
	return $self unless run({dir => $self->{a}, passfail => 1, stderr => 0},
		'git', 'merge-base', '--is-ancestor', $local, $remote);

	run({dir => $self->{a}, onfailure => "Failed to catch $branch up to origin"},
		'git', 'update-ref', "refs/heads/$branch", $remote, $local);
	return $self;
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
		my ($said, $rc) = run({env => {SAFE_TARGET => $self->{vault_target}},
				stderr => 0},
			_real_safe(), 'move', $path, $aside);
		die "break_vault could not move $path aside: " . ($said // '') . "\n"
			if $rc;
		push @{$self->{broken}}, [$path, $aside];
	}
	return $self;
}

# }}}
# break_vault_writes - make every write at or below a path refuse {{{
#
# break_vault moves a record aside, which makes a read answer nothing and
# leaves a write to the same path perfectly able to land.  A row about a write
# that fails needs the other half, and it needs the reads to go on answering,
# because a deploy whose vault stopped reading never reaches the write at all.
#
# The refusal is armed in a file the recording wrapper consults on each call,
# because the command under test runs in a child and a variable set here would
# have to be threaded through every runner to reach it.  restore_vault
# disarms it, so a row that breaks and restores in one fixture reads as one
# pair whichever half it broke.
sub break_vault_writes {
	my ($self, @paths) = @_;
	$self->fixture_vault;
	helper::put_file($self->{vault_refuse},
		join('', map {"$_\n"} @paths));
	return $self;
}

# }}}
# restore_vault - put back what break_vault moved aside {{{
sub restore_vault {
	my ($self) = @_;
	die "restore_vault needs a vault fixture, and this harness has none\n"
		unless $self->{vault_target};
	helper::put_file($self->{vault_refuse}, '') if $self->{vault_refuse};
	for my $pair (@{delete($self->{broken}) || []}) {
		my ($said, $rc) = run({env => {SAFE_TARGET => $self->{vault_target}},
				stderr => 0},
			_real_safe(), 'move', $pair->[1], $pair->[0]);
		die "restore_vault could not put $pair->[0] back: " . ($said // '')
		  . "\n" if $rc;
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
	my $exported = $self->_exported($path) or return undef;
	return $exported->{_export_key($path)};
}

# }}}
# record_keys - what the entries of a record set are called {{{
#
# A record set's entries sit one level under the set's own path, each named
# for when it happened, and a row that asserts on the form of that name has to
# read the name rather than the record.  newest_record answers one entry's
# contents off the same export, and this answers what the entries are called,
# so the two together say everything a row can ask of a set.
#
# The answer is sorted and holds the entry names alone, without the path above
# them, and a path with no entries under it answers an empty list rather than
# undef, because a set with nothing in it is a set.
sub record_keys {
	my ($self, $path) = @_;
	my $exported = $self->_exported($path) or return [];
	my $key = _export_key($path);
	return [sort map {m{^\Q$key\E/([^/]+)$} ? $1 : ()} keys %$exported];
}

# }}}
# proposed_for - the proposed record one environment is waiting on {{{
#
# The pull request a run opened is pointed at from one path, and the rows that
# watch that pointer through its life ask for it by the environment's name
# rather than composing the path themselves.  The path is the environment's
# own with proposed under it, which is where Genesis::Env writes it, so a row
# reading it back cannot name a path the product does not write.
sub proposed_for {
	my ($self, $env, %opts) = @_;
	return $self->record_at($self->env_path($env, %opts).'/proposed');
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
# bosh_runs - every call the harness director answered, in order {{{
#
# T246 asserts the argument list `bosh deploy` was given, which no answer of
# the double carries and no marker line can show, so fixture_bosh's double
# writes each call down and this reads them back.  command names the
# subcommand a row is asking about, and a row that names none is handed every
# call the director answered.
#
# Each answer holds the subcommand as command, the whole argument list as
# argv, and, where the call's last argument named a file the double could
# read, that file's content as manifest.  The content is copied aside as the
# call is made rather than read here, because the manifest a deploy hands BOSH
# is a temporary file that is gone by the time a row asks what was in it.
#
# The log is not emptied between runs, the way the vault log is, because a row
# that deploys twice asks what the second call was given and reads it against
# the first.
sub bosh_runs {
	my ($self, %opts) = @_;
	my $log = $self->{bosh} && $self->{bosh}{log} or return ();
	return () unless -f $log;

	my @runs;
	my $ordinal = -1;
	for my $line (split /\n/, (helper::get_file($log) // '')) {
		$ordinal++;
		my ($command, @argv) = split /\t/, $line, -1;
		next if defined $opts{command}
			&& (!defined $command || $command ne $opts{command});

		my $manifest = "$self->{bosh}{runs}/$ordinal.manifest";
		push @runs, {
			command => $command,
			argv    => \@argv,
			(-f $manifest ? (manifest => helper::get_file($manifest)) : ()),
		};
	}
	return @runs;
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
	# A copy already carries the seeding commit, so the no_commits shape
	# cannot be built in one.  The combination is refused rather than
	# answered with a repository that has commits and a caller that believes
	# it has none.
	die "fixture_preflight cannot build the no_commits shape in a copy, "
	  . "because both copies already carry the seeding commit\n"
		if $kind eq 'no_commits' && $opts{copy};

	my $dir = $opts{copy} ? $self->{$opts{copy}}
	        : "$self->{tmp}/preflight-$kind-" . int(rand(1_000_000));

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
	my $bin = "$self->{tmp}/bin";
	return "$bin/git" if -x "$bin/git";

	helper::mkdir_or_fail($bin) unless -d $bin;
	my $home = "$self->{tmp}/preflight-home";
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
exec "@{[_real_tool('git')]}" "\$@"
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
#
# The kit is left uncommitted by default, which is all a row needs where the
# command under test only ever renders a manifest from the working tree.  A
# row whose command walks control asks for commit, because the kit source is a
# kind of the propagation set in its own right and reading that set at a
# commit carrying no kit refuses by name, so every control commit such a row
# lays has to carry it, as a real repository's do.
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

	if ($opts{commit}) {
		# The commit is made where copy A already stands rather than by
		# checking the control branch out, because this builder runs before a
		# row has placed itself and a checkout here would move a working tree
		# the row is about to use.  Standing anywhere else is refused for the
		# reason _catch_up refuses it: the kit would land on whatever branch
		# happened to be out.
		my $on = $self->git('a')->current_branch // '';
		die "fixture_kit commits the kit on $self->{control}, and copy A is "
		  . "standing on $on.  Call it before standing anywhere else.\n"
			unless $on eq $self->{control};

		my $rel = join('/', grep {length} $root, 'dev');
		run({dir => $self->{a}}, 'git', 'add', '--', $rel);
		run({dir => $self->{a}, onfailure => "Failed to commit the dev kit"},
			'git', 'commit', '-q', '-m', "Add the $name kit");
		$self->push_from('a', $self->{control});
	}

	return $dir;
}

# }}}

# install_compiled_kit - put a compiled kit archive in the repository {{{
#
# The suite ships compiled kits as archives, and a row that wants an
# environment naming one by version needs the archive where local_kits looks
# for it, which is the deployment root's .genesis/kits.  The bytes are copied
# rather than written, because an archive is not text.
#
# The archive is named by its path under the checkout root, and it is
# committed unless the row says otherwise, so what the row gets is a control
# branch a command can read rather than a file nothing tracks.
sub install_compiled_kit {
	my ($self, $archive, %opts) = @_;
	my $root = $opts{root} // $self->{root};
	my $from = $archive =~ m{^/} ? $archive : "$helper::TOPDIR/$archive";
	die "install_compiled_kit does not know the archive $archive\n"
		unless -f $from;

	my ($file) = $from =~ m{([^/]+)$};
	my $rel = join('/', grep {length} $root, '.genesis/kits', $file);
	my $dir = join('/', grep {length} $self->{a}, $root, '.genesis/kits');
	helper::mkdir_or_fail($dir) unless -d $dir;
	run({dir => $self->{base}, onfailure => "Failed to install $file"},
		'cp', $from, "$dir/$file");

	if (defined $opts{commit} ? $opts{commit} : 1) {
		run({dir => $self->{a}}, 'git', 'add', '--', $rel);
		run({dir => $self->{a}, onfailure => "Failed to commit $rel"},
			'git', 'commit', '-q', '-m', "install the $file kit archive");
	}

	return $rel;
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
	# Guarded with // '', the way the HEAD and the directory below are, so a
	# copy standing on a detached or an unborn HEAD reports the difference
	# rather than warning about an undefined value.
	push @differed, sprintf("branch: %s, was %s",
			$now->{branch} // '(none)', $w->{branch} // '(none)')
		unless ($now->{branch} // '') eq ($w->{branch} // '');
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

	# GENESIS_LIB is not named here, because helper::import sets it for the
	# whole process and the child inherits it.  Two places owning one
	# variable is how the two come to disagree.
	my %env = (
		GENESIS_TOPDIR => $helper::TOPDIR,
		SAFE_TARGET    => $self->{vault_target},
	);
	$env{GENESIS_PIPELINE_TASK} = $opts{pipeline_task} if $opts{pipeline_task};
	$env{PATH} = join(':', $self->_path_prefix(%opts), $ENV{PATH});
	# gh_no_token is one shot.  The flag is consumed here whatever this run
	# decides, so the token is missing from this command's environment alone
	# and the run after it carries the token again.  The per-run no_token
	# option withholds it without arming anything.
	#
	# The variable is named either way, and run unsets a variable it is
	# handed as undef, so a run with no double standing carries no token at
	# all.  Without that a token exported in the operator's own shell would
	# reach a command under test and send it at the real API, which is the
	# one thing no row here may do.
	my $armed = $self->{gh} ? delete $self->{gh}{no_token} : 0;
	$env{GITHUB_AUTH_TOKEN} =
		($self->{gh} && !$opts{no_token} && !$armed) ? $self->{gh}{token} : undef;

	# The fault plan reaches a spawned command through the environment, and the
	# subclass installs itself in the child through PERL5OPT.  The child's own
	# -I has to name lib/ as well as t/, because PERL5OPT is read before
	# bin/genesis compiles and puts GENESIS_LIB on @INC itself.
	# The fixture bosh reaches the child the same way, because the command
	# under test runs the director's script out of its own environment.
	if ($self->{bosh}) {
		$env{GENESIS_BOSH_COMMAND}         = $self->{bosh}{command};
		$env{GENESIS_HARNESS_BOSH_FAILS}   = $ENV{GENESIS_HARNESS_BOSH_FAILS};
		$env{GENESIS_HARNESS_SIGINT_BEFORE_BOSH} =
			$ENV{GENESIS_HARNESS_SIGINT_BEFORE_BOSH};
	}

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
# cached instance rather than building a second one, and because that instance
# is the one the git accessor answers with, every handle onto that copy faults
# from here on.
sub fault_git {
	my ($self, %opts) = @_;
	my $copy = $opts{copy} // 'a';

	$self->{fault}{plan} //= "$self->{tmp}/git-plan.json";
	$self->{fault}{log}  //= "$self->{tmp}/git-steps.log";
	helper::put_file($self->{fault}{plan}, '{}');
	helper::put_file($self->{fault}{log}, '');

	_guard_env(
		GENESIS_HARNESS_GIT_PLAN => $self->{fault}{plan},
		GENESIS_HARNESS_GIT_LOG  => $self->{fault}{log},
	);

	require Harness::Propagation::Git;
	my $git = Harness::Propagation::Git->new($self->{$copy});
	bless $git, 'Harness::Propagation::Git';

	return $self->{"_fault_git_$copy"} = $git;
}

# }}}
# _with_plan - read, change, and write the fault plan under one lock {{{
#
# The parent arms a step through this file and every spawned child counts its
# own calls through the same file, so a read followed by a write is a window
# in which one of them writes over the other's change.  The lock is exclusive
# and it is taken on the plan file itself rather than on a file beside it, and
# one handle does the read and the write, because a second handle opened to
# truncate would land outside the lock the first one holds.
sub _with_plan {
	my ($file, $change) = @_;
	require Fcntl;
	open my $fh, '+<', $file
		or die "cannot open the fault plan $file: $!\n";
	flock($fh, Fcntl::LOCK_EX())
		or die "cannot lock the fault plan $file: $!\n";

	my $body = do {local $/; <$fh>};
	my $plan = JSON::PP->new->decode($body || '{}');
	$change->($plan);

	seek($fh, 0, 0)    or die "cannot rewind the fault plan $file: $!\n";
	truncate($fh, 0)   or die "cannot empty the fault plan $file: $!\n";
	print $fh JSON::PP->new->canonical->encode($plan);
	close $fh          or die "cannot write the fault plan $file: $!\n";

	return $plan;
}

# }}}
# run_in_child - run a snippet of perl under a spawned command's environment {{{
#
# A row that wants a git call made from another process has to stand that
# process up under the fault plan, the step log, and the subclass, which is
# the same block run_genesis composes for a whole command.  Two test files
# build it by hand today, so a change to what a spawned command needs has to
# be made in three places.
#
# The plan and the log are read off this harness rather than off the
# environment, so a file holding two harnesses runs each child against its own
# plan and not against whichever harness armed last.  The child's own -I has
# to name lib/ as well as t/, because PERL5OPT is read before anything the
# snippet uses is compiled.
#
# It answers what run answers, which is the output, the exit code, and the
# standard error, so a row weighs the child's exit rather than trapping a
# death in the parent.
#
# A PERL5OPT the parent already carries is kept and appended to, the way
# run_genesis keeps it.  The suite runs under -MCarp::Always, and a child that
# lost it answers a death with a shorter story than the same code run through
# a whole command.
sub run_in_child {
	my ($self, $code, @args) = @_;
	my $fault = $self->{fault}
		or die "run_in_child needs fault_git to have armed a plan first\n";

	return run({
			dir      => $self->{a},
			stderr   => 0,
			env      => {
				GENESIS_HARNESS_GIT_PLAN => $fault->{plan},
				GENESIS_HARNESS_GIT_LOG  => $fault->{log},
				PERL5OPT => join(' ',
					'-I' . $helper::TOPDIR . '/t',
					'-I' . $helper::TOPDIR . '/lib',
					'-MHarness::Propagation::Git', ($ENV{PERL5OPT} // ())),
			},
		}, 'perl', '-e', $code, @args);
}

# }}}
# fail_on - arm one named git step to die on its nth call {{{
sub fail_on {
	my ($git, $step, $n, %opts) = @_;
	my $file = $ENV{GENESIS_HARNESS_GIT_PLAN}
		or die "fail_on needs fault_git to have run first\n";

	_with_plan($file, sub {
		my ($plan) = @_;
		$plan->{$step} = {n => $n, from => $opts{from} ? 1 : 0,
			message => $opts{message}, kind => $opts{kind}};
	});
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

	_with_plan($file, sub {
		my ($plan) = @_;
		$plan->{$step} = {n => $n, from => $opts{from} ? 1 : 0,
			skip => 1, return => $opts{return}};
	});
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
		_with_plan($file, sub {delete $_[0]->{_counts}});
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
#
# The refresh is severed as a transport failure rather than as a death,
# because that is what the real method does with a remote it cannot reach.
# `git ls-remote` comes back with an rc, and fetch_branches turns it into a
# classified result for the caller to refuse on.  A push and a remote delete
# do die, so those two keep the death they always had.
#
# kind names which failure the remote gives, because Service::Git tells them
# apart by reading stderr and each one has a refusal of its own.  It is
# network by default, which is the shape most rows want, and auth is what
# gives the refusal that names the credentials a row to stand on.
sub sever_remote {
	my ($self, %opts) = @_;
	my $git = $self->{"_fault_git_a"} // $self->fault_git;
	my $kind = $opts{kind} // 'network';
	die "sever_remote knows the network and auth failures, not $kind\n"
		unless $kind eq 'network' || $kind eq 'auth';
	my $message = $kind eq 'auth'
		? "fatal: Authentication failed for '$self->{r}'"
		: "fatal: unable to access '$self->{r}': "
		  . "Could not resolve host: the remote is unreachable";
	fail_on($git, 'fetch_branches', $opts{after} // 1,
		from => 1, message => $message, kind => 'transport');
	fail_on($git, $_, $opts{after} // 1, from => 1, message => $message)
		for qw/push delete_remote_branch/;
	return $self;
}

# }}}
# restore_remote - disarm the remote steps again {{{
sub restore_remote {
	my ($self) = @_;
	my $file = $ENV{GENESIS_HARNESS_GIT_PLAN} or return $self;
	_with_plan($file, sub {
		delete $_[0]->{$_}
			for qw/fetch_branches push delete_remote_branch/;
	});
	return $self;
}

# }}}
# hold_session_lock - take the switch lock in a child process {{{
#
# The harness takes the flock the design fixes, on genesis-session.lock in
# the git directory, and writes the pid and the command inside for the
# refusal message to read.  The pid is the first line and the command the
# second, so a reader that splits on newline gets both whatever the command
# holds.  A row that wants the lock released by the
# kernel kills the holder rather than letting it finish.
sub hold_session_lock {
	my ($self, %opts) = @_;
	my $dir  = $self->{$opts{copy} // 'a'};
	my $lock = "$dir/.git/genesis-session.lock";

	my $pid = fork();
	die "cannot fork a lock holder: $!\n" unless defined $pid;
	unless ($pid) {
		# The file is opened for append and emptied once the lock is in
		# hand, rather than truncated by the open itself.  A holder that
		# truncated on the way in would wipe what the holder before it wrote
		# while that one still held the lock, and the pid the parent waits
		# for would be gone from a file the parent is reading.
		open my $fh, '>>', $lock or POSIX::_exit(2);
		require Fcntl;
		flock($fh, Fcntl::LOCK_EX()) or POSIX::_exit(2);
		truncate($fh, 0) or POSIX::_exit(2);
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

	$HOLDERS{$pid} = $lock;

	# Wait for the child to take the lock, watching the child as well as the
	# file.  A holder that exited will never write the file, so a wait that
	# only watched the file would run its whole length out and then hand back
	# a pid that holds nothing.  Both refusals name the holder and say which
	# of the two happened, so a row that meets a broken fixture reads a
	# complaint about the fixture rather than one about the code under test.
	#
	# What the wait watches for is this holder's own pid, and not merely a
	# file with something in it.  A lock file carrying the line an earlier
	# holder wrote would otherwise end the wait at once, and the row would be
	# handed a holder that is still blocked and holds nothing.
	for (1 .. 100) {
		return $pid if _lock_taken_by($lock, $pid);
		if (waitpid($pid, POSIX::WNOHANG()) != 0) {
			delete $HOLDERS{$pid};
			die "the lock holder $pid exited before it took $lock\n";
		}
		select undef, undef, undef, 0.05;
	}
	# The holder gives itself five minutes, so a refusal that left it running
	# would make every later row wanting the same lock wait the rest of that
	# out.  It goes down with the refusal, as the one above does.
	kill('KILL', $pid);
	waitpid($pid, 0);
	delete $HOLDERS{$pid};
	die "the lock holder $pid never took $lock\n";
}

# _lock_taken_by - has this holder written its own pid into the lock file
#
# The holder's pid is the token, because the holder writes it once it has the
# lock and never before, so a file that merely has something in it is not
# mistaken for a lock this holder took.  It sits here rather than beside a row
# because the wait above is its only caller.
sub _lock_taken_by {
	my ($lock, $pid) = @_;
	return 0 unless -s $lock;
	open my $fh, '<', $lock or return 0;
	my $first = <$fh>;
	close $fh;
	return 0 unless defined $first;
	chomp $first;
	return $first eq "$pid" ? 1 : 0;
}

# }}}
# release_session_lock - let the holder finish, or kill it outright {{{
sub release_session_lock {
	my ($self, $pid, %opts) = @_;
	kill($opts{hard} ? 'KILL' : 'TERM', $pid);
	waitpid($pid, 0);
	delete $HOLDERS{$pid};
	return $self;
}

# }}}
# fork_and_switch - open a session and switch in a process of its own {{{
#
# An flock is held by a process, so a second attempt made in this one would
# find the handle this one already holds and take the lock rather than meet
# it.  The switch therefore happens in a whole second process, and the row
# weighs that process's exit code rather than trapping a death here.
#
# The include paths are spelled absolutely through $helper::TOPDIR, because
# the child runs from a copy of the repository under test and a relative -I
# would name that copy's own lib rather than the tree's.
#
# The exit code is handed back exactly as run gives it, since run has already
# shifted $?, and shifting it a second time turns every real code into a zero.
sub fork_and_switch {
	my ($self, $branch, %opts) = @_;
	my $dir = $self->{$opts{copy} // 'a'};

	my ($out, $rc, $err) = run({dir => $dir, passfail => 0, stderr => 0},
		$^X,
		'-I' . $helper::TOPDIR . '/lib',
		'-I' . $helper::TOPDIR . '/t',
		'-e', <<'PERL', $dir, $self->{control}, $branch);
use Genesis;
use Service::Git;
my ($root, $control, $branch) = @ARGV;
my $session = Service::Git->new($root)->session(control => $control);
$session->begin;
$session->switch($branch);
$session->finish;
PERL
	return {out => $out, err => $err, exit => $rc};
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

	my $bin = "$self->{tmp}/gh-bin";
	helper::mkdir_or_fail($bin);
	my $curl = "$bin/curl";
	helper::put_file($curl, 0755, helper::get_file("$helper::TOPDIR/t/Harness/bin/curl"));

	# The readers below take the double rather than the harness, because that
	# is how a row names them, so the double carries a way back to the state
	# file it is written in terms of.
	my $gh = $self->{gh} = {
		harness    => $self,
		bin        => $bin,
		state      => "$self->{tmp}/gh-state.json",
		log        => "$self->{tmp}/gh-calls.log",
		token      => $opts{token}      // 'harness-token',
		repository => $opts{repository} // 'owner/repo',
		domain     => 'github.test',
		admin      => defined $opts{admin} ? ($opts{admin} ? 1 : 0) : 1,
	};

	$self->_gh_write({prs => [], protection => {}, rulesets => [],
		admin => $gh->{admin}, domain => $gh->{domain}});
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

# _gh_change reads the state, hands it to the caller to change, and writes it
# back under one exclusive lock on the state file itself.  The fixture curl
# takes the same lock for the whole of a call, so a create made from a spawned
# command and a change made here cannot lose each other, and the parent simply
# waits behind a call in flight.
sub _gh_change {
	my ($self, $change) = @_;
	my $file = $self->{gh}{state};
	require Fcntl;
	open my $fh, '+<', $file
		or die "cannot open the GitHub state $file: $!\n";
	flock($fh, Fcntl::LOCK_EX())
		or die "cannot lock the GitHub state $file: $!\n";

	my $body  = do {local $/; <$fh>};
	my $state = JSON::PP->new->decode($body || '{}');
	my $answer = $change->($state);

	seek($fh, 0, 0)  or die "cannot rewind the GitHub state $file: $!\n";
	truncate($fh, 0) or die "cannot empty the GitHub state $file: $!\n";
	print $fh JSON::PP->new->canonical->encode($state);
	close $fh        or die "cannot write the GitHub state $file: $!\n";

	return defined $answer ? $answer : $state;
}

# }}}
# gh_pull_request - declare an open pull request with a review state {{{
#
# An environment names the two branches the propagation flow would have used,
# so a row that cares about neither says env and no more.
#
# Every pull request the double holds carries an html_url, because that is
# what a run writes into the proposed record and what a row reads back out of
# it.  It is composed from the repository the double was stood up for, which
# is the same shape the fixture curl composes for a pull request it creates
# itself, so a declared one and a created one read alike.
sub gh_pull_request {
	my ($gh, %opts) = @_;
	my $self = $gh->{harness};
	my $env  = $opts{env};
	return $self->_gh_change(sub {
		my ($state) = @_;
		my $number = scalar(@{$state->{prs}}) + 1;
		push @{$state->{prs}}, {
			number  => $number,
			state   => 'open',
			merged  => JSON::PP::false,
			head    => {ref => $opts{head} // ($env ? $self->pr_branch($env) : '')},
			base    => {ref => $opts{base} // ($env ? $self->slug($env)      : '')},
			title   => $opts{title} // '',
			body    => $opts{body}  // '',
			html_url => $opts{url} // sprintf('https://%s/%s/pull/%d',
				$gh->{domain}, $gh->{repository}, $number),
			created_at => $opts{at} // '2026-09-13T00:00:00Z',
			reviews => [($opts{review} && $opts{review} ne 'none') ? {
				state       => uc($opts{review}),
				user        => {login => $opts{reviewer} // 'reviewer'},
				body        => $opts{review_body} // '',
				submitted_at=> $opts{at} // '2026-09-13T00:00:00Z',
			} : ()],
		};
		return $number;
	});
}

# }}}
# gh_close_pr and gh_merge_pr - the two ways a pull request leaves the open set {{{
sub gh_close_pr {
	my ($gh, $number, %opts) = @_;
	my $self = $gh->{harness};
	return $self->_gh_change(sub {
		my ($state) = @_;
		for my $pr (@{$state->{prs}}) {
			next unless $pr->{number} == $number;
			$pr->{state}  = 'closed';
			$pr->{merged} = $opts{merged} ? JSON::PP::true : JSON::PP::false;
			$pr->{merged_at} = $opts{merged}
				? ($opts{at} // '2026-09-13T00:00:00Z') : undef;
		}
		return undef;
	});
}

sub gh_merge_pr {
	my ($gh, $number, %opts) = @_;
	my $self = $gh->{harness};
	$self->_gh_change(sub {
		$_[0]->{merge_method}{$number} = $opts{method} // 'rebase';
		return undef;
	});
	gh_close_pr($gh, $number, merged => 1, at => $opts{at});
	return $self->_gh_read;
}

# }}}
# gh_protection - what the protection endpoints answer and record {{{
sub gh_protection {
	my ($gh, %opts) = @_;
	my $self = $gh->{harness};
	return $self->_gh_change(sub {
		my ($state) = @_;
		$state->{admin} = ($opts{admin} ? 1 : 0) if defined $opts{admin};
		$state->{protection}{$opts{branch}} = $opts{settings} if $opts{branch};
		return $state->{protection};
	});
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
	my $self = $gh->{harness};
	return $self->_gh_change(sub {$_[0]->{unreachable} = 1; return undef});
}

sub gh_reachable {
	my ($gh) = @_;
	my $self = $gh->{harness};
	return $self->_gh_change(sub {delete $_[0]->{unreachable}; return undef});
}

sub gh_no_token {
	my ($self) = @_;
	$self->{gh}{no_token} = 1;
	return $self;
}

# A line the decoder refuses comes back as a record of its own rather than
# taking the reader down.  Two writers landing on the log at once would leave
# half a line behind, and a read that died inside JSON::PP would stop the
# whole file where the row that asked should have failed.  The record carries
# no method and no url, so a row counting calls of a kind reads one fewer and
# fails its own assertion, and torn holds the text for the diagnostic.
sub gh_calls {
	my ($gh) = @_;
	return () unless -f $gh->{log};
	my $json = JSON::PP->new;
	return map {
		my $line = $_;
		eval {$json->decode($line)} // {torn => $line};
	} grep {/\S/} split /\n/, (helper::get_file($gh->{log}) // '');
}

# }}}
# child_recorder - watch every genesis child a command spawns {{{
#
# Some rows ask that a run spawn no second genesis process and others ask
# that it spawn exactly one, so both want the same observer and the harness
# carries one rather than two.  The wrapper is t/Harness/bin/genesis-recorder,
# copied onto the directory _path_prefix already names, and
# GENESIS_CALLBACK_BIN points at it, so a child spawned through the hook
# helper's genesis function and a child that resolves the bare name on the
# path are each recorded.
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
	my $bin  = "$self->{tmp}/bin";
	helper::mkdir_or_fail($bin) unless -d $bin;

	$self->{child_copy} = $copy;
	$self->{child_log}  = "$self->{tmp}/children.jsonl";
	$self->{child_plan} = "$self->{tmp}/child-plan.json";

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

	my $bin = "$self->{tmp}/bin";
	helper::mkdir_or_fail($bin) unless -d $bin;
	my $path = "$bin/lock-probe";
	$self->{lock_probe_log} = "$self->{tmp}/lock-probe.jsonl";

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
	my $log = "$self->{tmp}/shuttle.jsonl";
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
	push @prefix, "$self->{tmp}/gh-bin", "$self->{tmp}/bin";
	return @prefix;
}

# }}}
# shimmed_git - a git that answers one subcommand itself and passes the rest on {{{
#
# A row reaches an answer the real git will not give on demand by standing a
# shim first on the path for the length of one call.  The shim answers the
# subcommand the row names out of the body it is handed, and hands every other
# command to the git underneath, so the run still does real work on real refs.
#
# The body is shell, and it is written inside the `if`, so a body that says
# nothing about exiting falls out of the block and reaches the real git after
# whatever it did.  A body that wants to answer on its own says so with an
# exit of its own.  It is required, because an empty one renders an `if` with
# nothing between it and its `fi`, which bash refuses to parse, and the row
# would meet that as a git the shell could not run.
#
# The directory is named git-shim-... under the harness tmp, and the name
# matters: _real_tool steps over directories named that way, so a wrapper
# written while a shim sits first on the path still bakes in the git
# underneath rather than baking in the shim.
#
# name gives the directory a fixed last component instead of a random one and
# answers with an existing one rather than writing it twice, which is how the
# version fixture keeps one directory per version across a whole run.
sub shimmed_git {
	my ($self, %opts) = @_;
	my $when = $opts{when} or die "shimmed_git needs the subcommand to answer\n";
	my $body = $opts{body}
		or die "shimmed_git needs the shell body that answers $when\n";

	my $dir = "$self->{tmp}/git-shim-"
		. ($opts{name} // sprintf('%06d', int(rand(1_000_000))));
	return $dir if $opts{name} && -d $dir;

	helper::mkdir_or_fail($dir);
	helper::put_file("$dir/git", 0755, <<"EOS");
#!/usr/bin/env bash
if [ "\$1" = "$when" ]; then
$body
fi
exec "@{[_real_tool('git')]}" "\$@"
EOS
	return $dir;
}

# }}}
# _fake_git_dir - a git that reports a chosen version and passes the rest on {{{
#
# The prerequisites check asks git for its version through the shell, so a
# fixture on the path is what a row drives the floor with.  Everything else is
# handed to the real git, so the run still does real work on real refs.
sub _fake_git_dir {
	my ($self, $version) = @_;
	return $self->shimmed_git(
		when => '--version',
		body => "  echo \"git version $version\"\n  exit 0",
		name => $version,
	);
}

# }}}
# fixture_fly - a fly of a chosen version on the path, or none at all {{{
#
# The Concourse provider asks the shell whether fly is there and then asks
# fly for its version, so a row that drives the declared floor needs a fly
# that answers a version the row chose.  The shim goes into the fixture bin
# directory _path_prefix already names, which is the directory a spawned
# command sees first and the parent's own path never does.
#
# It answers every other call rather than handing it on, because no row here
# talks to a real Concourse and a fly that reached one would be doing work
# nobody asked for.
#
# absent takes the fly away instead of standing one up.  The shim is removed,
# and every directory on the parent's path that holds a real fly goes with
# it, because an operator who has fly installed would otherwise have a row
# about not having one answered by their own binary.  The path is put back by
# the same guard that puts every other fixture variable back.
sub fixture_fly {
	my ($self, %opts) = @_;

	my $bin = "$self->{tmp}/bin";
	helper::mkdir_or_fail($bin) unless -d $bin;
	my $path = "$bin/fly";

	# Nothing comes back from this arm, because there is no fly to hand a
	# path to and a caller that put the returned path on its own path
	# would put the one file this just took away back within reach.
	if ($opts{absent}) {
		unlink $path;
		_guard_env(PATH => join(':',
			grep {!-x "$_/fly"} split(/:/, ($ENV{PATH} // ''))));
		return;
	}

	my $version = $opts{version}
		or die "fixture_fly needs a version, or absent => 1\n";

	helper::put_file($path, 0755, <<"EOS");
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then
	echo "$version"
fi
exit 0
EOS
	return $path;
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
	# What each environment last read is per environment wherever the
	# topology gives them different answers, so a hashref keyed on the
	# environment is taken as well as one list for all of them.  It is taken
	# off the options the builders below are handed, because certify writes
	# the value it is given and a hashref is not one.
	my $read = delete $opts{dependencies_read};

	$self->fixture_vault;
	$self->fixture_applied(control => $control,
		provider => $opts{provider} // $self->{provider}, %opts)
		unless defined $opts{applied} && !$opts{applied};

	for my $env (@envs) {
		$self->init_branch($env, %opts);
		$self->fixture_pipeline_record($env, %opts,
			dependencies => $opts{dependencies}{$env} // []);
		$self->deliver($env, %opts, control => $control) if $delivered{$env};
		$self->certify($env, %opts, control_commit => $control,
			(defined $read
				? (dependencies_read => ref($read) eq 'HASH'
					? ($read->{$env} // []) : $read)
				: ()))
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
# load_with - commit one pipeline block on control and load a Top on it {{{
#
# Eight test files declare a sub of this name and this body, which is a state
# builder and so belongs here under the helper rule.  The body it is handed is
# the pipeline block alone, and the rest of the configuration is written round
# it, so a row says what it is proving and nothing else.
#
# Two rows in a row can ask for the same configuration, and a commit needs a
# delta to make, so each load carries a count of its own beside the file under
# test.  The count belongs to the harness rather than to the file, so two
# harnesses in one file do not share one counter.
#
# deployment_type names the type the configuration declares, because the type
# is a top-level key rather than part of the pipeline block, and a file whose
# rows vary it has nowhere in the body to say so.  It defaults to bosh, which
# is what every other caller wants.
sub load_with {
	my ($h, $body, %opts) = @_;
	require Genesis::Top;

	$h->commit_on_control(files => {
		'.genesis/config' => join("\n",
			'---', 'deployment_type: ' . ($opts{deployment_type} // 'bosh'),
			'version: "3"',
			'creator_version: 3.2.0', $body, ''),
		'.load-count' => sprintf("%d\n", ++$h->{loads}),
	});

	my $top = Genesis::Top->new($h->a, no_vault => 1);
	$top->config;
	return $top;
}

# }}}
# automated_config - the pipeline block of an automated provider {{{
#
# Three test files declare this one, and it is the block load_with is most
# often handed.  The repository is named rather than derived, because copy A
# is cloned from a bare repository at a filesystem path whose URL carries no
# GitHub owner and repo pair, and the derivation's own refusal belongs to the
# source-control rows rather than to the rows that want a valid automation.
#
# The extra lines go under the provider, indented to that depth, so a row that
# wants a target or a team on the provider says so in a word.
sub automated_config {
	my ($type, @lines) = @_;
	return join("\n", _automation_preamble($type, @lines),
		automation_block_lines());
}

# }}}
# compilable_pipeline - the repository a compile will get all the way through {{{
#
# A row that drives one of the commands that compiles has to get past the
# compile before it reaches what it came for, and a pipeline the compiler
# cannot name is one it refuses.  make_harness writes the provider block and
# the three automation blocks, and the environment files give the workflow
# its shape, so the name is the one piece left and no row should have to know
# that it is.
#
# The name defaults to the harness's own deployment type, which is what the
# schema says pipeline.name falls back to, so a row that does not care what
# the pipeline is called gets the name the repository would have anyway.
sub compilable_pipeline {
	my ($self, %opts) = @_;
	my $name = delete $opts{name};
	$self->set_repo_config('pipeline.name', $name // $self->{type}, %opts);
	return $self;
}

# }}}
# shuttle - an automated pipeline whose shuttle block a row writes {{{
#
# automated_config renders one fixed shuttle for every caller, and a row that
# proves what a backend admits has to write that block itself.  So this is
# automated_config with one of its three automation blocks written out
# instead of defaulted: the backend is named, the given lines go under
# pipeline.shuttle beside it, and the vault and the locker an automation
# requires are still rendered from the one hash they come from.
#
# The provider is concourse because the shuttle is only required where a
# provider is automated, and a row about the shuttle is not a row about
# which automation is in force.  Its target comes with it, that being a key
# Concourse requires of its own block, so a row about the shuttle is not
# refused for something the provider above it is missing.
sub shuttle {
	my ($backend, @lines) = @_;
	return join("\n", _automation_preamble('concourse', 'target: ci'),
		'  shuttle:', "    backend: $backend",
		(map {"    $_"} @lines),
		automation_block_lines(without => ['shuttle']));
}

# }}}
# _automation_preamble - the part of an automated block before the three {{{
#
# The enabled flag, the source control, and the provider, which both callers
# above want and neither wants to spell out twice.  Kept private, because a
# configuration with no shuttle, no vault, and no locker is not a fixture any
# row should be reaching for.
sub _automation_preamble {
	my ($type, @lines) = @_;
	return ('pipeline:', '  enabled: true',
		'  source_control:',
		'    repository: genesis/bosh-deployments',
		'    auth:',
		'      type: ssh',
		'      vault: secret/ci/git',
		'    identity:',
		'      name: Genesis CI',
		'      email: ci@genesis.example.com',
		'  provider:', "    type: $type",
		(map {"    $_"} @lines));
}

# }}}
# automation_blocks, automation_block_lines - what an automation requires {{{
#
# Under D23 an automated provider reaches a shuttle, a vault, and a locker,
# and the configuration schema requires all three of it, so a fixture that
# names an automation has to carry them.  Six test files write the same nine
# lines out by hand today, which means the next key an automation requires
# has to be added in six places.  This is the one answer.
#
# The hash form is for a file that builds the configuration as a structure,
# and the line form is for a file that writes it as text.  The lines come back
# indented to sit under a `pipeline:` key, without that key, so a caller puts
# them beside whatever else its own pipeline block holds.
sub automation_blocks {
	return (
		shuttle => {backend => 's3', bucket => 'pipes'},
		vault   => {url     => 'https://vault.example.com'},
		locker  => {url     => 'https://locker.example.com'},
	);
}

# without names blocks to leave out, because a row that proves what the schema
# refuses of an automation needs a configuration with one of the three missing
# and has nowhere else to get it.  The lines are rendered off the hash form, so
# the two cannot drift apart.
sub automation_block_lines {
	my (%opts) = @_;
	my %without = map {($_ => 1)} @{$opts{without} || []};
	my %blocks  = automation_blocks();

	my @lines;
	for my $block (qw/shuttle vault locker/) {
		next if $without{$block};
		push @lines, "  $block:";
		push @lines, sprintf('    %s: %s', $_, $blocks{$block}{$_})
			for sort keys %{$blocks{$block}};
	}
	return @lines;
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
	return $h->ready_envs(%opts) unless $opts{bosh};

	# bosh stands the director, the fake bosh, and the kit up before the
	# seeding rather than after it, and it takes either a true value or the
	# options fixture_bosh itself takes.  The order is the point: the kit is
	# a kind of the propagation set, so a control commit that does not carry
	# it cannot be routed at all, and a row whose command walks control needs
	# every commit from the seeding onwards to carry it.  A row that only
	# deploys and never walks calls fixture_bosh itself, afterwards.
	#
	# The catch-up waits until ready_envs has cut and delivered the branches,
	# since there is nothing to catch up before that, and a row that means to
	# keep a stale clone says catch_up => 0 the way it says it to fixture_bosh.
	my %how      = ref($opts{bosh}) eq 'HASH' ? %{$opts{bosh}} : ();
	my $catch_up = exists $how{catch_up} ? $how{catch_up} : 1;
	$h->fixture_bosh(%how, commit => 1, catch_up => 0);
	$h->ready_envs(%opts);
	$h->_catch_up($_) for $catch_up ? @{$h->{envs}} : ();
	return $h;
}

# fanned_harness is the fan-out, which is one environment several others
# hang off rather than a chain of one predecessor each.  A deploy of the
# prior environment leaves its child one commit to carry to several
# branches, which is the shape the rows about a spawned child need and which
# each of them used to build by hand, a line per record and a line per
# branch.
#
# prior names the environment the others hang off, defaulting to the first,
# and every other environment declares it as its predecessor and carries it
# as its one dependency, so the topology and the pipeline records say the
# same thing.  A row that wants other dependencies passes its own.
sub fanned_harness {
	my (%opts) = @_;
	my @envs  = @{$opts{envs} // ['qa', 'prod', 'stage']};
	my $prior = $opts{prior} // $envs[0];
	die "fanned_harness hangs every environment off $prior, which is not "
	  . "one of them\n" unless grep {$_ eq $prior} @envs;

	# The pipeline record and the certified record say the same thing about
	# each environment's dependencies, because the staleness comparison reads
	# one against the other and a fan-out whose halves disagreed would warn
	# on every run.
	my $deps = $opts{dependencies} //
		{map {($_ => $_ eq $prior ? [] : [$prior])} @envs};
	return ready_harness(%opts,
		envs              => [@envs],
		fanned            => $prior,
		dependencies      => $deps,
		dependencies_read => $opts{dependencies_read} // $deps,
	);
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
	# Both are this shape's own, so neither rides on into make_harness or
	# ready_envs, where a key nobody there reads is a key nobody there
	# refuses either.  files says what the run of commits writes, and it goes
	# to _due rather than to the seeding delivery, which takes a key of the
	# same name.
	my $count = delete $opts{count};
	my $files = delete $opts{files};
	my $h = ready_harness(%opts, envs => $opts{envs} // ['qa']);
	my @due = _due($h, $count // 2, ($files ? (files => $files) : ()));
	$h->refresh('a');
	return wantarray ? ($h, @due) : $h;
}

# gated_harness lays four control commits, of which the third carries the
# Genesis-Stage trailer, and answers in the same two shapes due_harness does.
#
# Each of the four writes the first environment's own file, because a commit
# whose content lies in no environment's propagation set routes nowhere and
# the walk skips it, and every row that stands on this shape asks the walk to
# route all four.  A row that wants otherwise passes files, which is an
# arrayref of one per-commit hashref in the shape commit_on_control takes.
sub gated_harness {
	my (%opts) = @_;
	# The files option names what these four commits write, and deliver takes
	# a key of the same name for the seeding delivery, so it is taken out of
	# the options before the shape below is built from them.
	my $files = delete $opts{files};
	die "gated_harness was given " . scalar(@$files) . " per-commit file "
	  . "sets under files, and it lays four commits\n"
		if $files && @$files < 4;
	my $h = ready_harness(%opts, envs => $opts{envs} // ['qa']);
	my $env = ($opts{envs} // ['qa'])->[0];
	my @shas;
	for my $n (1 .. 4) {
		push @shas, $h->commit_on_control(
			files    => $files ? $files->[$n - 1]
			                   : {"$env.yml" => env_body($h, $env, $n)},
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

# held_prod_delivered is the same tree with prod already delivered to and
# certified at the seeding commit, and with a kit on disk.  The hold rows want
# it because they count what a hold is blocking, and a branch carrying no
# marker is walked from the commit that introduced the environment, which puts
# the seeding commit in every count.  The kit goes with it because a run that
# walks an environment loads it.
#
# It stands beside held_prod rather than changing it, since held_prod's own
# POD promises a tree delivered to nowhere and other rows read it that way.
sub held_prod_delivered {
	my (%opts) = @_;
	return held_prod(kit => 'omega-v2.7.0',
		delivered => ['prod'], certified => ['prod'], %opts);
}

# deployable_prod is held_prod with everything a spawned `genesis deploy`
# needs to reach success, which is five things and not one: a kit that
# merges, the base domain that kit asks for, the credentials it declares, a
# director whose address something is listening on, and the fake bosh the
# commands are driven through.  The director's status check dials the host
# with tcp_listening before it runs a single BOSH command, so a record
# naming an address nobody answers is not enough.
#
# The listener and the director record are both the harness's, because the
# url has to carry the port the listener actually took and splitting the two
# across two files would leave that coupling with no home.  Test::TCP's
# DESTROY stops the child, so the object is kept on the harness and the port
# stays open for as long as the caller holds it.
#
# The secrets run is given restore => 0, so the builder builds and asserts
# nothing.  A builder that quietly emitted a row would move every caller's
# plan count with no way to see why from the count alone.
#
# kit and pipeline are both the caller's.  The kit has a default because
# every caller so far wants the same one, and the pipeline has none, because
# a pipeline-managed deploy and a plain one are two different rows and the
# helper should not decide which one is being written.
sub deployable_prod {
	my (%opts) = @_;
	my $domain = delete($opts{base_domain}) // 'example.com';

	my $h = held_prod(kit => 'omega-v2.7.0', %opts);
	$h->write_env_file('prod', params => {base_domain => $domain});

	# write_env_file commits in copy A and pushes nothing, and a control
	# branch ahead of its remote meets the pre-flight's refusal, so control
	# goes up here and a caller running with the pipeline on is not left to
	# discover that for itself.
	$h->push_from('a', $h->control);

	$h->{director} = helper::fake_bosh_director('prod');
	$h->fixture_director('prod',
		url => sprintf('https://127.0.0.1:%s', $h->{director}->port));
	helper::fake_bosh();

	my (undef, $err, $rc) = $h->run_genesis({restore => 0},
		'prod', 'add-secrets');
	die "deployable_prod could not generate prod's secrets: $err\n" if $rc;

	return $h;
}

# tracked_harness names its prerequisites positionally, because every call
# reads as a list of environment names and an options hash around two of
# them would say nothing the list does not.
sub tracked_harness {
	my (@prereqs) = @_;
	@prereqs = ('lab') unless @prereqs;
	my $h = make_harness(envs => [@prereqs, 'qa']);
	# The key goes in the pipeline block, because
	# genesis.pipeline.track_dependencies is where _declared_dependencies
	# reads it, and a list written a level above that is a list nothing ever
	# reads.
	$h->write_env_file('qa', pipeline => {
		track_dependencies => [map {$h->slug($_)} @prereqs]});
	# write_env_file commits in copy A and pushes nothing, and the commit a
	# delivery's marker names has to be on R, so control goes up before the
	# walk reads it.
	$h->push_from('a', $h->control);
	# The director, the fake bosh, and the kit, in the order ready_harness
	# stands them in and for the reasons it gives, because a row about what a
	# deploy records has to be able to deploy and every control commit the
	# delivery routes has to carry the kit.
	$h->fixture_bosh(commit => 1, catch_up => 0);
	$h->ready_envs;
	$h->_catch_up($_) for @{$h->{envs}};
	return $h;
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
	if ($opts{leaf_keys}) {
		for my $env (@{$opts{envs} // ['qa']}) {
			$h->write_env_file($env, pipeline => $opts{leaf_keys});
		}
	}
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
#
# A kit is installed by default, because every command that reports on an
# environment loads it, and an environment whose kit nothing installed reads
# as a load error and says nothing else about itself.  A row wanting another
# one names it under kit, so the promise this helper makes is true without a
# caller having to remember the kit for it.
#
# The due commit is written through due_commit, which rewrites the
# environment's own file at the deployment root and leaves that file's
# metadata standing.  A body composed here instead dropped genesis.env and
# genesis.pipeline.require_pr with it, which takes the environment out of the
# topology altogether, so a command that reads the topology was handed a
# repository with no environments in it at all and reported on none.  params
# and message steer that commit; due is ready's own option for a commit of a
# different shape and this scenario writes its own, so it is refused by name
# rather than dropped on the way to ready.
sub with_open_pr {
	my (%opts) = @_;
	my $env = $opts{env} // 'qa';
	die "with_open_pr writes its own due commit, so it takes no due option; ".
	    "steer that commit with params and message instead\n"
		if exists $opts{due};
	my $h = ready(%opts, kit => $opts{kit} // 'omega-v2.7.0',
		envs => $opts{envs} // [$env]);
	my $gh = $h->{gh};

	my $control = due_commit($h, $env,
		params  => $opts{params}  // {instances => 2},
		message => $opts{message} // 'A change due to propagate');
	$h->refresh('a');

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

	# env, file, and path are this helper's own, and the three helpers below
	# know none of them, so only the keys they do know are passed on.
	my %pass = map {exists $opts{$_} ? ($_ => $opts{$_}) : ()}
		qw/type copy push/;

	$self->fixture_vault;
	$self->init_branch($env, %pass);

	# The wider set: the extra file is tracked, and the delivery carries it.
	# The environment file is staged rather than committed on its own, so the
	# tracked list and the file it names arrive in the same control commit.
	$self->_stage_env_file($env, %pass, root => $root,
		genesis => {pipeline => {track_additional_files => [$file]}});
	my $wide = $self->commit_on_control(
		files   => {$path => "---\nextra: true\n"},
		message => 'Track an extra file',
		push    => 1,
	);
	$self->deliver($env, %pass, control => $wide);

	# The narrower set: the extra file is dropped from the tracked list and
	# stays on the branch until a delivery removes it.
	$self->_stage_env_file($env, %pass, root => $root,
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

# chain lays one control commit per environment, each writing that
# environment's own file, so a walk finds one commit due to each of them.
#
# The body is the one env_body writes rather than a flow mapping of the kit's
# name, because Genesis::Env::is_valid_env_file reads the kit's name and
# version out of a block mapping and a flow mapping of the same keys leaves
# the repository with no environments for the walk to visit at all.
sub chain {
	my ($h, %opts) = @_;
	my @envs = @{$opts{envs} // $h->{envs}};
	my $n = 0;
	return map {
		$h->commit_on_control(
			files   => {"$_.yml" => env_body($h, $_, ++$n)},
			message => "Tune $_",
			push    => 1,
		)
	} @envs;
}

# _due lays a run of undelivered control commits, and writes one
# environment's own file on each of them for the reason gated_harness does.
# A caller that wants other content passes files, one hashref per commit.
#
# The environment defaults to the first of the harness's own, which is what a
# one-environment shape wants, and a row standing several environments up
# names the one it is asking the walk about.  Without that the commits land
# on a file that is in no other environment's propagation set, every one of
# them routes nowhere, and the environment the row argues about has nothing
# due at all.
sub _due {
	my ($h, $n, %opts) = @_;
	my $env = $opts{env} // $h->{envs}[0];
	die "_due was given " . scalar(@{$opts{files}}) . " per-commit file sets "
	  . "under files, and it lays $n commits\n"
		if $opts{files} && @{$opts{files}} < $n;
	return map {
		$h->commit_on_control(
			files   => $opts{files} ? $opts{files}[$_ - 1]
			                       : {"$env.yml" => env_body($h, $env, $_)},
			message => "A change due to propagate, $_",
			push    => 1,
		)
	} 1 .. $n;
}

# env_body - the environment file the commit-laying shapes write {{{
#
# The same body write_env_file lays down, with a counter beside it.  It has
# to stay a valid environment file, because a run reads the topology out of
# these files and Genesis::Env::is_valid_env_file reads the kit's name and
# version out of a block mapping, so a flow mapping of the same two keys
# leaves the repository with no environments at all.  The counter is there
# because a commit needs a delta to make, and two commits writing one body
# would leave the second with nothing to commit.
#
# The harness comes first because the body follows its mode, the way
# write_env_file's does.  A run reads genesis.pipeline.require_pr out of the
# environment's own file, so a body written in pull request mode without the
# key delivers straight to the deployment branch and takes the pull request
# arm away from every row that laid its commit through here.
#
# It is exported, because a row that lays its own commits on control needs
# the same body and a copy of it written in a test file is a copy that can
# fall out of step with the one the shapes here write.
sub env_body {
	my ($self, $env, $n) = @_;
	my $pipeline = $self->{mode} eq 'pr'
		? "  pipeline:\n    require_pr: true\n"
		: '';
	return "---\nkit:\n  name:    dev\n  version: latest\n  features: []\n"
	     . "genesis:\n  env: $env\n" . $pipeline . "n: $n\n";
}

# }}}

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

# An automated provider does its work unattended, so the schema requires the
# clone credential and the committer identity of it, along with the shuttle,
# the vault, and the locker.  The shape writes all of them, because a row that
# asks for an automated pipeline and then loads a Genesis::Top means a
# repository that configuration is valid for.  They land in one commit, since
# only the last write commits.
sub automated {
	my ($h, %opts) = @_;
	my %blocks = automation_blocks();

	$h->set_repo_config('pipeline.provider.type',
		$opts{provider} // 'concourse', commit => 0);
	$h->set_repo_config('pipeline.source_control.auth.type',
		$opts{auth_type} // 'ssh', commit => 0);
	$h->set_repo_config('pipeline.source_control.auth.vault',
		$opts{auth_vault} // 'secret/ci/git', commit => 0);
	$h->set_repo_config('pipeline.source_control.identity.name',
		$opts{identity_name} // 'Genesis CI', commit => 0);
	$h->set_repo_config('pipeline.source_control.identity.email',
		$opts{identity_email} // 'ci@genesis.example.com', commit => 0);
	my $path;
	for my $block (sort keys %blocks) {
		for my $key (sort keys %{$blocks{$block}}) {
			$path = $h->set_repo_config("pipeline.$block.$key",
				$blocks{$block}{$key}, commit => 0);
		}
	}

	# One commit for the whole shape, because the keys are all one file and a
	# commit apiece would say nothing a reader of the log wants.  It is made
	# only where the file changed, so a row that asks for the shape twice, or
	# asks for it on a repository that already carries it, is not taken down
	# by a commit with no delta to make.
	run({dir => $h->{a}}, 'git', 'add', '--', $path);
	my $unchanged = run({dir => $h->{a}, passfail => 1},
		'git', 'diff', '--cached', '--quiet', '--', $path);
	run({dir => $h->{a}, onfailure => "Failed to write the automated shape"},
		'git', 'commit', '-q', '-m', 'configure an automated pipeline')
		unless $unchanged;

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
	# The commit option is write_env_file's, defaulting to 1, so a row can
	# put a whole configuration into the index and commit it alongside
	# whatever else that one control commit is meant to carry.
	if (defined $opts{commit} ? $opts{commit} : 1) {
		run({dir => $h->{a}, onfailure => "Failed to write $path"},
			'git', 'commit', '-q', '-m', "write $path");
	}

	return $path;
}

# }}}

1;
