#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use lib 'lib';
use helper;

use Test::More;
use Test::Exception;

use_ok 'Service::Vault';
use_ok 'Service::Vault::Remote';
use Genesis;

# ===========================================================================
# Service::Vault::Remote re-auth ladder.
#
# Step 2a: _interactive_auth_available — pure predicate.
# Step 2b: _authenticate_interactively — prompt-driven re-auth flow.
#         Uses Genesis::UI prompts for method choice + per-method
#         credential collection, then issues the same `safe auth`
#         query the env-var path uses.
# Step 3:  authenticate() wiring — interactive fallback between
#         env-var attempts and the bail.
# Step 5:  Enriched bail — when __renewer_armed_at is set on the
#         instance (i.e. we had a renewer running earlier in the
#         session), the bail leads with "session expired" rather than
#         the generic first-time-setup message.
#
# Returns true only when:
#   - STDIN/STDOUT is a controlling terminal
#   - we're NOT running inside a Genesis kit-hook callback
#   - GENESIS_QUIET is not set
#   - GENESIS_NONINTERACTIVE is not set (new env var)
#   - GENESIS_TESTING is not set (under_test() guard)
#
# Tests redefine the imported helper functions on the
# Service::Vault::Remote namespace because the gates are
# `use`-imported (the consumer's symbol table holds the alias).
# ===========================================================================

sub make_remote {
	return Service::Vault::Remote->new(
		'https://vault.example.com:8200',
		'test-vault', 1, '', undef, '/secret/',
	);
}

# Convenience: install per-subtest gate stubs.  Defaults model
# "interactive context is fully available" — each subtest overrides
# the one gate it cares about to assert that single gate's behaviour.
sub with_gates (&%) {
	my ($block, %overrides) = @_;
	my %defaults = (
		in_controlling_terminal => sub { 1 },
		in_callback             => sub { 0 },
		envset                  => sub { 0 },
		under_test              => sub { 0 },
	);
	my %gates = (%defaults, %overrides);
	no warnings 'redefine', 'once';
	local *Service::Vault::Remote::in_controlling_terminal = $gates{in_controlling_terminal};
	local *Service::Vault::Remote::in_callback             = $gates{in_callback};
	local *Service::Vault::Remote::envset                  = $gates{envset};
	local *Service::Vault::Remote::under_test              = $gates{under_test};
	$block->();
}

# ---------- baseline: all gates open ----------

subtest 'available when all gates are open' => sub {
	plan tests => 1;
	with_gates {
		my $v = make_remote();
		ok($v->_interactive_auth_available,
			'all gates open => interactive auth is available');
	};
};

# ---------- TTY gate ----------

subtest 'unavailable when not in a controlling terminal' => sub {
	plan tests => 1;
	with_gates {
		my $v = make_remote();
		ok(!$v->_interactive_auth_available,
			'no TTY => unavailable');
	} in_controlling_terminal => sub { 0 };
};

# ---------- callback gate ----------

subtest 'unavailable when running inside a Genesis kit-hook callback' => sub {
	plan tests => 1;
	with_gates {
		my $v = make_remote();
		ok(!$v->_interactive_auth_available,
			'in_callback => unavailable');
	} in_callback => sub { 1 };
};

# ---------- env var gates ----------

subtest 'unavailable when GENESIS_QUIET is set' => sub {
	plan tests => 1;
	with_gates {
		my $v = make_remote();
		ok(!$v->_interactive_auth_available,
			'QUIET set => unavailable');
	} envset => sub { $_[0] eq 'QUIET' };
};

subtest 'unavailable when GENESIS_NONINTERACTIVE is set' => sub {
	plan tests => 1;
	with_gates {
		my $v = make_remote();
		ok(!$v->_interactive_auth_available,
			'GENESIS_NONINTERACTIVE set => unavailable');
	} envset => sub { $_[0] eq 'GENESIS_NONINTERACTIVE' };
};

# ---------- test gate ----------

subtest 'unavailable when under_test (GENESIS_TESTING) is set' => sub {
	plan tests => 1;
	with_gates {
		my $v = make_remote();
		ok(!$v->_interactive_auth_available,
			'under_test => unavailable');
	} under_test => sub { 1 };
};

# ---------- _authenticate_interactively: flow ----------

# Drive the interactive flow with canned prompt responses.  $choice is
# the auth-method key returned by new_prompt_for_choice; @lines is the
# sequence of credential strings returned by the prompt_for_line /
# prompt_for_password calls in declaration order.  $auth_ok is what
# the post-auth $self->authenticated check returns.
#
# Returns the args captured from the single $self->query call so each
# subtest can assert the right `safe auth $method` was issued and the
# right credentials were piped in.
sub drive_interactive {
	my ($v, %opts) = @_;
	my $choice  = $opts{choice};
	my @lines   = @{$opts{lines} || []};
	my $auth_ok = $opts{auth_ok} // 1;
	my @new_choice_calls;
	my @line_prompts;
	my @password_prompts;
	my @captured_query;
	no warnings 'redefine', 'once';
	local *Service::Vault::Remote::new_prompt_for_choice = sub {
		push @new_choice_calls, {@_};
		return $choice;
	};
	local *Service::Vault::Remote::prompt_for_line = sub {
		push @line_prompts, $_[1];
		return shift @lines;
	};
	local *Service::Vault::Remote::prompt_for_password = sub {
		push @password_prompts, $_[0];
		return shift @lines;
	};
	local *Service::Vault::Remote::query = sub {
		shift;   # $self
		@captured_query = @_;
		return ('', 0, '');
	};
	local *Service::Vault::Remote::authenticated = sub { $auth_ok };
	use warnings 'redefine';
	my $rv = $v->_authenticate_interactively;
	return {
		rv               => $rv,
		query_args       => [@captured_query],
		line_prompts     => [@line_prompts],
		password_prompts => [@password_prompts],
		choice_calls     => [@new_choice_calls],
	};
}

subtest 'method picker offers all four methods + abort' => sub {
	plan tests => 2;
	my $v = make_remote();
	my $r = drive_interactive($v, choice => 'abort');
	my $call = $r->{choice_calls}[0];
	ok($call, 'new_prompt_for_choice was invoked');
	my @values = map { $_->{value} } @{$call->{choices}};
	is_deeply(\@values, [qw/approle token userpass github abort/],
		'choices include all four methods plus abort');
};

subtest 'returns 0 when user aborts at the method picker' => sub {
	plan tests => 2;
	my $v = make_remote();
	my $r = drive_interactive($v, choice => 'abort');
	ok(!$r->{rv}, 'returns falsy on abort');
	is(scalar(@{$r->{query_args}}), 0, 'no safe auth query issued');
};

subtest 'AppRole: prompts for Role ID + Secret ID, runs safe auth approle' => sub {
	plan tests => 5;
	my $v = make_remote();
	my $r = drive_interactive(
		$v,
		choice => 'approle',
		lines  => ['the-role-id', 'the-secret-id'],
	);
	ok($r->{rv}, 'returns truthy on auth success');
	is_deeply($r->{line_prompts},     ['Role ID'],   'Role ID prompted in clear');
	is_deeply($r->{password_prompts}, ['Secret ID'], 'Secret ID prompted hidden');
	is($r->{query_args}[0], 'safe auth ${1} < <(echo "$2")',
		'safe auth heredoc shape matches env-var auth path');
	is($r->{query_args}[1], 'approle',
		'method arg is approle');
};

subtest 'Vault Token: prompts hidden once, runs safe auth token' => sub {
	plan tests => 4;
	my $v = make_remote();
	my $r = drive_interactive(
		$v,
		choice => 'token',
		lines  => ['hvs.example-token'],
	);
	ok($r->{rv}, 'returns truthy on auth success');
	is_deeply($r->{line_prompts}, [],
		'no clear-text prompts for token');
	is_deeply($r->{password_prompts}, ['Vault Token'],
		'token prompted hidden');
	is($r->{query_args}[1], 'token',
		'method arg is token');
};

subtest 'Username/Password: prompts for both, runs safe auth userpass' => sub {
	plan tests => 4;
	my $v = make_remote();
	my $r = drive_interactive(
		$v,
		choice => 'userpass',
		lines  => ['dennis', 'hunter2'],
	);
	ok($r->{rv}, 'returns truthy on auth success');
	is_deeply($r->{line_prompts},     ['Username'], 'Username prompted in clear');
	is_deeply($r->{password_prompts}, ['Password'], 'Password prompted hidden');
	is($r->{query_args}[1], 'userpass',
		'method arg is userpass');
};

subtest 'GitHub: prompts for PAT hidden, runs safe auth github' => sub {
	plan tests => 4;
	my $v = make_remote();
	my $r = drive_interactive(
		$v,
		choice => 'github',
		lines  => ['ghp_example'],
	);
	ok($r->{rv}, 'returns truthy on auth success');
	is_deeply($r->{line_prompts}, [],
		'no clear-text prompts for github');
	is_deeply($r->{password_prompts}, ['GitHub Personal Access Token'],
		'PAT prompted hidden');
	is($r->{query_args}[1], 'github',
		'method arg is github');
};

subtest 'returns 0 when post-auth authenticated() check fails' => sub {
	plan tests => 1;
	my $v = make_remote();
	my $r = drive_interactive(
		$v,
		choice  => 'token',
		lines   => ['bad-token'],
		auth_ok => 0,
	);
	ok(!$r->{rv}, 'returns falsy when post-auth check fails');
};

subtest 'returns 0 when user enters an empty credential (cancellation)' => sub {
	plan tests => 2;
	my $v = make_remote();
	my $r = drive_interactive(
		$v,
		choice => 'userpass',
		lines  => ['dennis', ''],   # blank password
	);
	ok(!$r->{rv}, 'returns falsy on empty cred');
	is(scalar(@{$r->{query_args}}), 0,
		'no safe auth query issued when a credential was blank');
};

# ---------- authenticate() wiring ----------

# Strip the four sets of VAULT_* env vars so the env-var loop in
# authenticate() never enters its body — we're testing the fallback
# path, not the env-var path.
sub clear_auth_env {
	delete $ENV{$_} for qw(
		VAULT_ROLE_ID VAULT_SECRET_ID
		VAULT_AUTH_TOKEN
		VAULT_USERNAME VAULT_PASSWORD
		VAULT_GITHUB_TOKEN
	);
}

subtest 'authenticate falls through to interactive when env-vars miss and TTY is available' => sub {
	plan tests => 2;
	local %ENV = %ENV;
	clear_auth_env();
	my $v = make_remote();
	my $authed = 0;
	my $interactive_called = 0;
	my $start_renewer_called = 0;
	no warnings 'redefine', 'once';
	local *Service::Vault::Remote::authenticated = sub { $authed };
	local *Service::Vault::Remote::_interactive_auth_available = sub { 1 };
	local *Service::Vault::Remote::_authenticate_interactively = sub {
		$interactive_called++;
		$authed = 1;
		return 1;
	};
	local *Service::Vault::Remote::start_token_renewer = sub {
		$start_renewer_called++;
		return undef;
	};
	use warnings 'redefine';
	my $ret = $v->authenticate;
	is($ret, $v, 'authenticate returns self after interactive success');
	is($interactive_called, 1, 'interactive flow invoked exactly once');
};

subtest 'authenticate bails when env-vars miss and interactive is unavailable' => sub {
	plan tests => 1;
	local %ENV = %ENV;
	clear_auth_env();
	my $v = make_remote();
	no warnings 'redefine', 'once';
	local *Service::Vault::Remote::authenticated = sub { 0 };
	local *Service::Vault::Remote::_interactive_auth_available = sub { 0 };
	# Spy: this MUST NOT be called when interactive is unavailable.
	local *Service::Vault::Remote::_authenticate_interactively = sub {
		die "should not have called interactive";
	};
	use warnings 'redefine';
	throws_ok { $v->authenticate }
		qr/Could not successfully authenticate/,
		'bails when no auth path succeeds and interactive is gated off';
};

subtest 'authenticate bails when interactive runs but does not yield a valid auth' => sub {
	plan tests => 2;
	local %ENV = %ENV;
	clear_auth_env();
	my $v = make_remote();
	my $interactive_called = 0;
	no warnings 'redefine', 'once';
	local *Service::Vault::Remote::authenticated = sub { 0 };
	local *Service::Vault::Remote::_interactive_auth_available = sub { 1 };
	local *Service::Vault::Remote::_authenticate_interactively = sub {
		$interactive_called++;
		return 0;  # user aborted, or post-auth check failed
	};
	use warnings 'redefine';
	throws_ok { $v->authenticate }
		qr/Could not successfully authenticate/,
		'bails when interactive does not produce a valid token';
	is($interactive_called, 1, 'interactive was tried once');
};

# ---------- bail message variants ----------

# Helper: drive authenticate() to the bail with all interactive/env-var
# paths neutralised, and capture the bail message text.
sub capture_bail {
	my (%opts) = @_;
	local %ENV = %ENV;
	clear_auth_env();
	my $v = make_remote();
	$v->{__renewer_armed_at} = $opts{armed_at} if exists $opts{armed_at};
	no warnings 'redefine', 'once';
	local *Service::Vault::Remote::authenticated = sub { 0 };
	local *Service::Vault::Remote::_interactive_auth_available = sub { 0 };
	use warnings 'redefine';
	my $msg = '';
	eval { $v->authenticate };
	$msg = "$@";
	return $msg;
}

subtest 'bail leads with expiry when __renewer_armed_at is set' => sub {
	plan tests => 2;
	my $msg = capture_bail(armed_at => time - 1000);
	like($msg, qr/expired/i,
		'bail message says the session expired');
	like($msg, qr/could not be renewed/i,
		'bail message names the renewer failure');
};

subtest 'bail uses the first-time-setup variant when never armed' => sub {
	plan tests => 2;
	my $msg = capture_bail();
	like($msg, qr/Could not successfully authenticate/,
		'first-time variant retains original heading');
	unlike($msg, qr/expired|renewed/i,
		'first-time variant does not mention expiry');
};

subtest 'bail always lists supported auth methods (recovery info)' => sub {
	plan tests => 4;
	for my $armed_at (undef, time - 100) {
		my $msg = capture_bail(armed_at => $armed_at);
		like($msg, qr/AppRole/,
			defined($armed_at)
				? 'expired variant lists AppRole'
				: 'first-time variant lists AppRole');
		like($msg, qr/VAULT_AUTH_TOKEN/,
			defined($armed_at)
				? 'expired variant lists VAULT_AUTH_TOKEN'
				: 'first-time variant lists VAULT_AUTH_TOKEN');
	}
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
