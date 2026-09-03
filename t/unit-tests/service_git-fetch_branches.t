#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;

use Genesis;
use_ok 'Service::Git';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

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
		my $r = shift @run_results;
		$r //= ['', 0, ''];   # default to success on under-queue
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

# Command line of the Nth captured run() call, minus the opts hashref.
sub run_argv { my ($n) = @_; my @a = @{$run_calls[$n]}; shift @a; return \@a; }

# Also stub current_branch and default_remote on this instance — both
# normally consult git via run, but we want deterministic test values.
sub override_inspections {
	my (%opts) = @_;
	no warnings qw(redefine once);
	*Service::Git::current_branch = sub { $opts{current_branch} };
	*Service::Git::default_remote = sub { $opts{default_remote} };
}

# ======================================================================
# fetch_branches - return shape and classification
# ======================================================================

subtest 'fetch_branches - success returns ($self, kind=success)' => sub {
	plan tests => 5;
	reset_stub();
	install_run_stub();
	override_inspections(current_branch => 'control', default_remote => 'origin');
	queue_heads(qw(qa lab));
	push @run_results, ['Fetching origin', 0, ''];

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
	override_inspections(current_branch => 'control', default_remote => 'origin');
	queue_heads(qw(qa lab));
	push @run_results, ['', 0, ''];     # for-each-ref: no local branches
	push @run_results, ['', 0, ''];     # fetch

	my $git = make_git();
	$git->fetch_branches([qw(qa lab)], 'origin');

	# refs/heads/qa, not qa: ls-remote patterns match the tail of a ref,
	# so a bare "qa" also matches refs/heads/team/qa.
	cmp_deeply run_argv(0),
		[qw(git ls-remote --heads origin refs/heads/qa refs/heads/lab)],
		'probe runs first, with fully-qualified ref patterns';
	# Which branches are already local decides whether each one updates a
	# local head or only its remote-tracking ref, so they are enumerated
	# between the probe and the fetch.
	is scalar @run_calls, 3, 'probe, enumerate local heads, then fetch';
};

subtest 'fetch_branches - fetches only the branches the remote has' => sub {
	plan tests => 4;
	reset_stub();
	install_run_stub();
	override_inspections(current_branch => 'control', default_remote => 'origin');
	queue_heads(qw(qa prod));           # lab is absent on the remote
	push @run_results, ['', 0, ''];     # for-each-ref: neither is local yet
	push @run_results, ['', 0, ''];     # fetch

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
	override_inspections(current_branch => 'control', default_remote => 'origin');
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
	override_inspections(current_branch => 'control', default_remote => 'origin');
	queue_heads(qw(qa));
	push @run_results, ['', 0, ''];

	my $git = make_git();
	$git->fetch_branches([qw(qa lab)], 'origin');

	is $git->{_branch_cache}{qa}, 1, 'fetched branch is known to exist';
	# Absent on the remote does not mean absent locally: pipeline-prepare
	# creates env branches before anything pushes them.  Poisoning the
	# cache with 0 would make branch_exists lie about local state.
	ok !exists $git->{_branch_cache}{lab},
		'branch absent on the remote leaves the local cache untouched';
};

subtest 'fetch_branches - probe failure is classified and reported' => sub {
	plan tests => 3;
	reset_stub();
	install_run_stub();
	override_inspections(current_branch => 'control', default_remote => 'origin');
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
	override_inspections(current_branch => 'control', default_remote => 'origin');
	queue_heads(qw(qa));
	push @run_results, ['', 0, ''];     # for-each-ref
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
	plan tests => 1;
	reset_stub();
	install_run_stub();
	override_inspections(current_branch => 'control', default_remote => 'origin');
	queue_heads(qw(qa lab));
	push @run_results, ["qa\ncontrol\n", 0, ''];   # for-each-ref: qa is local
	push @run_results, ['', 0, ''];                # fetch

	my $git = make_git();
	$git->fetch_branches([qw(qa lab)], 'origin');

	cmp_deeply run_argv(2), [
		'git', 'fetch', 'origin',
		'+refs/heads/qa:refs/remotes/origin/qa',
		'+refs/heads/lab:refs/heads/lab',
	], 'local branch updates tracking only; missing one becomes a local head';
};

subtest 'fetch_branches - network failure classified' => sub {
	plan tests => 3;
	reset_stub();
	install_run_stub();
	override_inspections(current_branch => 'control', default_remote => 'origin');
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
	override_inspections(current_branch => 'control', default_remote => 'origin');
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
	override_inspections(current_branch => 'control', default_remote => 'origin');
	push @run_results, ['', 128, 'fatal: could not read Username for ...: terminal prompts disabled'];

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(qa)], 'origin');

	is $result->{kind}, 'auth', 'terminal-prompts-disabled bucketed as auth';
};

subtest 'fetch_branches - unknown failure classified' => sub {
	plan tests => 2;
	reset_stub();
	install_run_stub();
	override_inspections(current_branch => 'control', default_remote => 'origin');
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
	override_inspections(current_branch => 'control', default_remote => undef);

	my $git = make_git();
	my ($returned, $result) = $git->fetch_branches([qw(qa)]);

	is $returned, $git, 'returns $self';
	is $result->{ok}, 1, 'ok=1 (no-op)';
	is scalar @run_calls, 0, 'run was never invoked';
};

subtest 'fetch_branches - no-op when all input is current branch' => sub {
	plan tests => 2;
	reset_stub();
	install_run_stub();
	override_inspections(current_branch => 'qa', default_remote => 'origin');

	my $git = make_git();
	my (undef, $result) = $git->fetch_branches([qw(qa)], 'origin');

	is $result->{ok}, 1, 'ok=1';
	is scalar @run_calls, 0, 'run not invoked (all branches were current)';
};

subtest 'fetch_branches - GIT_TERMINAL_PROMPT=0 when non-interactive' => sub {
	plan tests => 1;
	reset_stub();
	install_run_stub();
	override_inspections(current_branch => 'control', default_remote => 'origin');
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
