#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;

use Genesis;
use_ok 'Service::Git';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# override_inspections installs its stubs on the package rather than on an
# instance, and it does not put them back, so the one row that drives the
# real reader keeps a copy of it from before anything is overridden.
my $real_checked_out = \&Service::Git::checked_out_branch;

# Build a Service::Git instance pointed at any path (we never invoke the
# real git subprocess; run() is stubbed per-test).
sub make_git {
	my $root = workdir();
	mkdir_or_fail($root) unless -d $root;
	# Minimal blessed object that matches Service::Git's internals
	bless { root => $root, _branch_cache => {} }, 'Service::Git';
}

# Stub Service::Git::run to capture each call and return queued tuples.
# Tests prime @run_results with [$out, $rc, $err] tuples; each call to
# run() pops the next one.
our @run_calls;
our @run_results;

sub install_run_stub {
	no warnings qw(redefine once);
	*Service::Git::run = sub {
		push @run_calls, [@_];
		# A row queues one result per read the sub performs, in the order
		# it performs them.  Answering an empty success where a row ran
		# short would let a drift between the queue and the reads come
		# back green, so the shortfall is named where it happens.
		my $r = shift @run_results or die sprintf(
			"the run stub has no result queued for read %d: %s\n",
			scalar(@run_calls),
			join(' ', grep {!ref} @_)
		);
		return @$r;
	};
}

sub reset_stub { @run_calls = (); @run_results = (); }

# fetch_branches probes the remote with ls-remote before fetching, so
# every test queues that probe's output first.  Pass the branch names the
# remote is pretending to have.
sub queue_heads {
	my @names = @_;
	push @run_results, [
		join("\n", map {sprintf "%040d\trefs/heads/%s", 1, $_} @names),
		0, ''
	];
}

# The local heads the refresh reads to decide which refspec each branch
# takes.  Queued after the probe and before the fetch.  Pass the branch
# names this clone is pretending to hold.
sub queue_local_heads {
	my @names = @_;
	push @run_results, [join("\n", @names), 0, ''];
}

# What the refs hold once the fetch has run.  The refresh re-reads both
# namespaces rather than trusting the probe, so every row that asserts
# fetched or created queues these two.  Local heads first, then the
# remote-tracking refs, in the order the refresh reads them.
sub queue_after {
	my (%opts) = @_;
	push @run_results, [join("\n", @{$opts{local}    // []}), 0, ''];
	push @run_results, [join("\n", @{$opts{tracking} // []}), 0, ''];
}

# Command line of the Nth captured run() call, minus the opts hashref.
sub run_argv { my ($n) = @_; my @a = @{$run_calls[$n]}; shift @a; return \@a; }

# Also stub the checked-out branch and the default remote on this instance
# — both normally consult git via run, but we want deterministic test
# values.  The refresh reads the branch it is standing on through the
# private reader rather than through current_branch, because current_branch
# cannot name an unborn branch.
sub override_inspections {
	my (%opts) = @_;
	no warnings qw(redefine once);
	*Service::Git::checked_out_branch = sub { $opts{checked_out} };
	*Service::Git::default_remote      = sub { $opts{default_remote} };
}

# ======================================================================
# fetch_branches - return shape and classification
# ======================================================================

subtest 'fetch_branches - success returns ($self, kind=success)' => sub {
	plan tests => 5;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	queue_heads(qw(qa lab));
	queue_local_heads();                        # neither is here yet
	push @run_results, ['Fetching origin', 0, '']; # fetch
	queue_after(local => [qw(qa lab)], tracking => []);

	my $git = make_git();
	my ($returned, $result) = $git->fetch_branches([qw(qa lab)], 'origin');

	is $returned, $git, 'returns $self as first list element';
	is $result->{ok},   1,         'ok=1 on success';
	is $result->{kind}, 'success', 'kind=success on rc=0';
	cmp_deeply $result->{fetched}, [qw(qa lab)], 'both branches reported fetched';
	cmp_deeply $result->{absent},  [],           'nothing absent';
};

# ======================================================================
# Remote-authoritative existence
#
# A refspec naming a branch the remote does not have aborts the whole
# fetch (git: "couldn't find remote ref"), taking every other branch down
# with it.  So the remote is probed first, and absence is reported rather
# than raised.
# ======================================================================

subtest 'fetch_branches - probes the remote with fully-qualified refs' => sub {
	plan tests => 2;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	queue_heads(qw(qa lab));
	queue_local_heads();                # no local branches
	push @run_results, ['', 0, ''];     # fetch
	queue_after(local => [qw(qa lab)], tracking => []);

	my $git = make_git();
	$git->fetch_branches([qw(qa lab)], 'origin');

	# refs/heads/qa, not qa: ls-remote patterns match the tail of a ref,
	# so a bare "qa" also matches refs/heads/team/qa.
	cmp_deeply run_argv(0),
		[qw(git ls-remote --heads origin refs/heads/qa refs/heads/lab)],
		'probe runs first, with fully-qualified ref patterns';
	# Which branches are already local decides whether each one updates a
	# local head or only its remote-tracking ref, so they are enumerated
	# between the probe and the fetch.  Both namespaces are read again
	# afterwards, because what the result reports is what the refs hold
	# rather than what the probe said a round trip earlier.
	is scalar @run_calls, 5,
		'probe, read the local heads, fetch, then read both namespaces back';
};

subtest 'fetch_branches - fetches only the branches the remote has' => sub {
	plan tests => 4;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	queue_heads(qw(qa prod));           # lab is absent on the remote
	queue_local_heads();                # neither is local yet
	push @run_results, ['', 0, ''];     # fetch
	queue_after(local => [qw(qa prod)], tracking => []);

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(qa lab prod)], 'origin');

	is $result->{ok}, 1, 'ok=1 — an absent branch is not an error';
	# Neither branch exists locally here, so both are materialised as local
	# heads; the split refspec is covered in its own subtest below.
	cmp_deeply run_argv(2), [
		'git', 'fetch', 'origin',
		'+refs/heads/qa:refs/heads/qa',
		'+refs/heads/prod:refs/heads/prod',
	], 'refspec omits the branch the remote lacks';
	cmp_deeply $result->{fetched}, [qw(qa prod)], 'fetched lists what was refreshed';
	cmp_deeply $result->{absent},  [qw(lab)],     'absent lists what the remote lacks';
};

subtest 'fetch_branches - no fetch at all when the remote has none of them' => sub {
	plan tests => 3;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	queue_heads();                      # remote has nothing

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(qa lab)], 'origin');

	is $result->{ok}, 1, 'ok=1';
	is scalar @run_calls, 1, 'probed, but never fetched';
	cmp_deeply $result->{absent}, [qw(qa lab)], 'both reported absent';
};

subtest 'fetch_branches - caches fetched branches, not absent ones' => sub {
	plan tests => 2;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	queue_heads(qw(qa));
	queue_local_heads();                # qa is not here yet
	push @run_results, ['', 0, ''];     # fetch
	queue_after(local => [qw(qa)], tracking => []);

	my $git = make_git();
	$git->fetch_branches([qw(qa lab)], 'origin');

	is $git->{_branch_cache}{qa}, 1, 'fetched branch is known to exist';
	# Absent on the remote does not mean absent locally, because a person
	# can cut a branch by hand and never push it.  Poisoning the cache
	# with 0 would make branch_exists lie about local state.
	ok !exists $git->{_branch_cache}{lab},
		'branch absent on the remote leaves the local cache untouched';
};

subtest 'fetch_branches - probe failure is classified and reported' => sub {
	plan tests => 3;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	push @run_results, ['', 128, 'fatal: Authentication failed for https://example/x.git'];

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(qa)], 'origin');

	is $result->{ok},   0,      'ok=0';
	is $result->{kind}, 'auth', 'probe failure classified like a fetch failure';
	is scalar @run_calls, 1, 'no fetch attempted after a failed probe';
};

subtest 'fetch_branches - fetch failure after a good probe is classified' => sub {
	plan tests => 2;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	queue_heads(qw(qa));
	queue_local_heads();                # for-each-ref
	push @run_results, ['', 128, 'fatal: unable to access: Could not resolve host: example'];

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(qa)], 'origin');

	is $result->{ok},   0,         'ok=0';
	is $result->{kind}, 'network', 'classified from the fetch stage error';
};

subtest 'fetch_branches - a branch already local only updates its tracking ref' => sub {
	# The remote is authoritative for which branches exist, not for what
	# they contain.  Writing refs/heads for a branch we already have would
	# discard unpushed commits on it -- a propagation held back for review,
	# most often.  Only branches we lack are materialised locally.
	plan tests => 2;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	queue_heads(qw(qa lab));
	queue_local_heads(qw(qa control));  # qa is here already
	push @run_results, ['', 0, ''];     # fetch
	queue_after(local => [qw(qa control lab)], tracking => [qw(qa)]);

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(qa lab)], 'origin');

	cmp_deeply run_argv(2), [
		'git', 'fetch', 'origin',
		'+refs/heads/qa:refs/remotes/origin/qa',
		'+refs/heads/lab:refs/heads/lab',
	], 'local branch updates tracking only; missing one becomes a local head';
	cmp_deeply $result->{created}, [qw(lab)],
		'and created names the one local ref this refresh had to write';
};

subtest 'fetch_branches - network failure classified' => sub {
	plan tests => 3;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	push @run_results, ['', 128, 'fatal: unable to access: Could not resolve host: github.com'];

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(qa)], 'origin');

	is $result->{ok},   0,         'ok=0 on rc!=0';
	is $result->{kind}, 'network', 'classified as network when err matches "Could not resolve host"';
	like $result->{err}, qr/Could not resolve host/, 'err is passed through';
};

subtest 'fetch_branches - auth failure classified' => sub {
	plan tests => 2;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	push @run_results, ['', 128, 'fatal: Authentication failed for https://github.com/foo/bar.git'];

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(qa)], 'origin');

	is $result->{ok},   0,      'ok=0';
	is $result->{kind}, 'auth', 'classified as auth';
};

subtest 'fetch_branches - terminal-prompts-disabled also classified as auth' => sub {
	plan tests => 1;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	push @run_results, ['', 128, 'fatal: could not read Username for ...: terminal prompts disabled'];

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(qa)], 'origin');

	is $result->{kind}, 'auth', 'terminal-prompts-disabled bucketed as auth';
};

subtest 'fetch_branches - unknown failure classified' => sub {
	plan tests => 2;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	push @run_results, ['', 1, 'something weird went wrong'];

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(qa)], 'origin');

	is $result->{ok},   0,         'ok=0';
	is $result->{kind}, 'unknown', 'unmatched err lands in unknown bucket';
};

subtest 'fetch_branches - no-op when no remote returns success' => sub {
	plan tests => 3;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => undef);

	my $git = make_git();
	my ($returned, $result) = $git->fetch_branches([qw(qa)]);

	is $returned, $git, 'returns $self';
	is $result->{ok}, 1, 'ok=1 (no-op)';
	is scalar @run_calls, 0, 'run was never invoked';
};

subtest 'fetch_branches - the checked-out branch is refreshed like any other' => sub {
	# The refresh used to drop the branch the working tree stood on, and
	# control is usually that branch, so a run read whatever the clone
	# already held for it.  It takes the tracking refspec instead, so git
	# is never asked to write the ref HEAD points at.
	plan tests => 3;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	queue_heads(qw(control));
	queue_local_heads(qw(control));     # control is here already
	push @run_results, ['', 0, ''];     # fetch
	queue_after(local => [qw(control)], tracking => [qw(control)]);

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(control)], 'origin');

	cmp_deeply $result->{fetched}, [qw(control)], 'the branch is refreshed, not skipped';
	cmp_deeply run_argv(2), [
		'git', 'fetch', 'origin',
		'+refs/heads/control:refs/remotes/origin/control',
	], 'and it updates its tracking ref alone';
	cmp_deeply $result->{created}, [], 'nothing was created for a branch already here';
};

subtest 'fetch_branches - one name asked for twice is one branch' => sub {
	# The refresh is handed the control branch and the deployment branches
	# together, and control can already be in that list, so the caller is
	# not made to check.  A duplicate left in would be reported twice and
	# would put the same refspec on the command line twice.
	plan tests => 4;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	queue_heads(qw(control qa));
	# control is the checked-out branch here, so it has to be a branch this
	# clone holds.  Were it absent it would take the forced refspec onto
	# the ref HEAD points at, which git refuses outright, and the row would
	# then assert a command line the product could never run.
	queue_local_heads(qw(control));
	push @run_results, ['', 0, ''];     # fetch
	queue_after(local => [qw(control qa)], tracking => [qw(control)]);

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(control qa control)], 'origin');

	cmp_deeply run_argv(0),
		[qw(git ls-remote --heads origin refs/heads/control refs/heads/qa)],
		'the probe asks for each name once';
	cmp_deeply run_argv(2), [
		'git', 'fetch', 'origin',
		'+refs/heads/control:refs/remotes/origin/control',
		'+refs/heads/qa:refs/heads/qa',
	], 'and the fetch carries one refspec per branch';
	cmp_deeply $result->{fetched}, [qw(control qa)], 'the report names it once';
	cmp_deeply $result->{created}, [qw(qa)], 'and created names it once too';
};

subtest 'fetch_branches - an unborn checked-out branch takes the tracking refspec' => sub {
	# An unborn branch is the one checked-out branch for-each-ref does not
	# list, because nothing under refs/heads points at it yet.  Read off
	# that list alone it looks like a branch this clone lacks, so it would
	# take the forced refspec onto the ref HEAD points at, and git refuses
	# that write and fails the whole fetch with it.
	plan tests => 3;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'newbranch', default_remote => 'origin');
	queue_heads(qw(newbranch qa));
	queue_local_heads(qw(qa));          # newbranch is unborn, so it is not here
	push @run_results, ['', 0, ''];     # fetch
	queue_after(local => [qw(qa)], tracking => [qw(newbranch qa)]);

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(newbranch qa)], 'origin');

	cmp_deeply run_argv(2), [
		'git', 'fetch', 'origin',
		'+refs/heads/newbranch:refs/remotes/origin/newbranch',
		'+refs/heads/qa:refs/remotes/origin/qa',
	], 'no refspec writes the ref HEAD points at';
	cmp_deeply $result->{fetched}, [qw(newbranch qa)], 'both are still refreshed';
	cmp_deeply $result->{created}, [],
		'and nothing is claimed created, because no local ref was written';
};

subtest 'fetch_branches - the report is read off the refs, not off the probe' => sub {
	# The probe and the fetch are two round trips, so what the remote had
	# when it was asked is not what the refs hold when the fetch is done.
	# Here the probe confirms both branches and only one ref arrives, and
	# the result names the one that is here.
	plan tests => 2;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	queue_heads(qw(qa lab));
	queue_local_heads();                # neither is here yet
	push @run_results, ['', 0, ''];     # fetch
	queue_after(local => [qw(qa)], tracking => []);

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(qa lab)], 'origin');

	cmp_deeply $result->{fetched}, [qw(qa)],
		'the branch whose ref is here is the branch reported fetched';
	cmp_deeply $result->{created}, [qw(qa)],
		'and created says the same, because the probe does not write refs';
};

subtest 'checked_out_branch - symbolic-ref, because rev-parse cannot say' => sub {
	# current_branch runs `git rev-parse --abbrev-ref HEAD`, which fails on
	# an unborn branch, so current_branch answers undefined there and cannot
	# name the branch a fresh orphan checkout stands on.  symbolic-ref names
	# it, and says nothing at all on a detached HEAD.
	plan tests => 3;
	reset_stub();
	install_run_stub();
	no warnings qw(redefine once);
	local *Service::Git::checked_out_branch = $real_checked_out;
	push @run_results, ["newbranch\n", 0, ''];

	my $git = make_git();
	is $git->checked_out_branch, 'newbranch', 'the unborn branch is named';
	cmp_deeply run_argv(0), [qw(git symbolic-ref --short -q HEAD)],
		'and it is symbolic-ref that names it';

	reset_stub();
	install_run_stub();
	push @run_results, ['', 1, ''];
	is make_git()->checked_out_branch, undef, 'a detached HEAD names nothing';
};

subtest 'fetch_branches - a local-head read that failed is raised, not assumed' => sub {
	# A read that failed and answered an empty set would make every branch
	# look absent locally, and every one of them would then take the forced
	# refspec onto refs/heads and discard the unpushed commits this sub
	# exists to protect.  A clone we cannot enumerate is raised instead.
	plan tests => 2;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	queue_heads(qw(qa));
	push @run_results, ['', 128, 'fatal: not a git repository'];   # for-each-ref

	local $ENV{GENESIS_IGNORE_EVAL} = '';
	my $git = make_git();
	throws_ok {$git->fetch_branches([qw(qa)], 'origin')}
		qr{Failed to list\s+refs/heads/},
		'the failed read refuses rather than answering an empty set';
	is scalar @run_calls, 2, 'and no fetch followed it';
};

subtest 'fetch_branches - GIT_TERMINAL_PROMPT=0 when non-interactive' => sub {
	plan tests => 1;
	reset_stub();
	install_run_stub();
	override_inspections(checked_out => 'control', default_remote => 'origin');
	push @run_results, ['', 0, ''];

	# Override in_controlling_terminal to false so we exercise the
	# non-interactive path.
	no warnings qw(redefine once);
	local *Service::Git::in_controlling_terminal = sub { 0 };

	my $git = make_git();
	$git->fetch_branches([qw(qa)], 'origin');

	my $call_opts = $run_calls[0][0];
	is $call_opts->{env}{GIT_TERMINAL_PROMPT}, '0',
		'GIT_TERMINAL_PROMPT=0 injected in non-interactive context';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
