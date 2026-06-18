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
	plan tests => 3;
	reset_stub();
	install_run_stub();
	override_inspections(current_branch => 'control', default_remote => 'origin');
	push @run_results, ['Fetching origin', 0, ''];

	my $git = make_git();
	my ($returned, $result) = $git->fetch_branches([qw(qa lab)], 'origin');

	is $returned, $git, 'returns $self as first list element';
	is $result->{ok},   1,         'ok=1 on success';
	is $result->{kind}, 'success', 'kind=success on rc=0';
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
