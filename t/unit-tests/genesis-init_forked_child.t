#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use lib 'lib';
use helper;

use Test::More;
use Test::Exception;

use_ok 'Genesis';
use_ok 'Genesis::Commands';

# ===========================================================================
# Genesis::init_forked_child
#
# Defensive setup run inside the child branch immediately after fork() in
# any Genesis-spawned helper process (token renewer, future background
# tasks).
#
# What it does:
#   1. Empties $Genesis::Commands::END_HOOKS so accidental `exit` paths
#      don't run the parent's at_exit callbacks.
#   2. Closes STDIN so the child doesn't compete for terminal input.
#   3. Installs TERM/INT/HUP handlers that exit via POSIX::_exit, so
#      signal-driven termination also bypasses END / DESTROY.
#
# What it does NOT need to do:
#   - Wipe Service::Vault caches: Service::Vault::Local::shutdown
#     already self-guards by comparing the encoded parent PID against $$,
#     so DESTROY chains in the child are no-ops.
# ===========================================================================

subtest 'empties Genesis::Commands::END_HOOKS' => sub {
	plan tests => 2;
	local $Genesis::Commands::END_HOOKS = [sub { die 'parent hook' }, sub { 1 }];
	is(scalar(@$Genesis::Commands::END_HOOKS), 2, 'precondition: 2 hooks registered');
	Genesis::init_forked_child();
	is(scalar(@$Genesis::Commands::END_HOOKS), 0, 'END_HOOKS empty after init_forked_child');
};

subtest 'detaches STDIN from terminal input' => sub {
	plan tests => 2;
	# Save and restore STDIN around the test so subsequent test
	# infrastructure (Test2's IPC driver, etc.) isn't affected.
	open(my $stdin_backup, '<&=', fileno(STDIN)) or die "save STDIN: $!";
	Genesis::init_forked_child();
	ok(defined(fileno(STDIN)),
		'STDIN still has an fd (not closed; bound to a benign source)');
	# A read from /dev/null returns EOF immediately, which is the
	# behaviour we actually care about: the renewer can't accidentally
	# block on or pull terminal input from the parent.
	my $line = <STDIN>;
	is($line, undef, 'STDIN reads return EOF (no terminal contention)');
	# Restore for any subsequent subtest
	open(STDIN, '<&=', fileno($stdin_backup)) or die "restore STDIN: $!";
};

subtest 'installs TERM/INT/HUP handlers that bypass END/DESTROY' => sub {
	plan tests => 6;
	my %saved;
	@saved{qw/TERM INT HUP/} = @SIG{qw/TERM INT HUP/};
	# Reset to the literal 'DEFAULT' sentinel so we can assert the slot
	# changed.  Perl >= 5.20 caches anonymous subs without lexical
	# captures, so init_forked_child returns the same coderef across
	# calls; identity-based assertions would be unreliable.  We assert
	# the property we actually care about: the slot is a coderef after
	# init_forked_child, not the kernel default disposition.
	$SIG{TERM} = 'DEFAULT';
	$SIG{INT}  = 'DEFAULT';
	$SIG{HUP}  = 'DEFAULT';
	Genesis::init_forked_child();
	is(ref($SIG{TERM}), 'CODE', 'TERM is a coderef');
	is(ref($SIG{INT}),  'CODE', 'INT is a coderef');
	is(ref($SIG{HUP}),  'CODE', 'HUP is a coderef');
	isnt($SIG{TERM}, 'DEFAULT', 'TERM handler is not the kernel default');
	isnt($SIG{INT},  'DEFAULT', 'INT handler is not the kernel default');
	isnt($SIG{HUP},  'DEFAULT', 'HUP handler is not the kernel default');
	@SIG{qw/TERM INT HUP/} = @saved{qw/TERM INT HUP/};
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
