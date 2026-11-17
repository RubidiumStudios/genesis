#!/usr/bin/env perl
# Proves the reader half of T493: a vault read that fails is raised in the
# state that names its cause, and so with the exit code that cause earns
# (D163, D168).
#
# The reader worded a refusal, an outage and anything else differently and
# raised all three alike, with no code, so a command that did not catch the
# error exited 1 for every one of them, and one that did had to match the
# wording to tell them apart.
#
# The rows read the state and the code of what each raise dies with, and
# what a process that nobody catches it in exits with.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use Genesis;
use Genesis::Exit qw/NOPERM UNAVAILABLE/;
use Service::Vault;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

# Carp::Always, which the helper may load, appends a stack trace to a string
# die; these rows are about what the reader itself raises
local $SIG{__DIE__} = 'DEFAULT';

sub read_failing_with {
	my ($reason) = @_;
	eval {
		Service::Vault::bail_read_failure(
			'https://v:8200', 'secret/exodus/qa/bosh', $reason, 'get secret/exodus/qa/bosh');
	};
	return raised($@);
}

# What a process running this code exits with, under the handler bin/genesis
# installs, since an exit code is only a fact about a process.
sub in_a_process {
	my ($code) = @_;
	my $script = workdir('read-failure-states').'/run.pl';
	put_file($script, join("\n",
		'use strict; use warnings;',
		'use Genesis;',
		'use Service::Vault;',
		'$SIG{__DIE__} = \&Genesis::uncaught;',
		$code, ''));
	my $said = qx(NOCOLOR=1 GENESIS_OUTPUT_COLUMNS=80 $^X -Ilib $script 2>&1);
	return ($? >> 8, $said);
}

subtest 'a read the vault refused is raised as refused' => sub {
	my @reasons = (
		'Code: 403. Errors: * permission denied',
		'!! 403 Forbidden',
		'permission denied',
	);
	plan tests => 4 * @reasons;
	for my $reason (@reasons) {
		my $raised = read_failing_with($reason);
		is($raised && $raised->state, 'refused', "$reason: the state is refused");
		is($raised && $raised->exitcode, NOPERM, "$reason: which exits NOPERM");
		ok($raised && $raised->is_unreadable, "$reason: and is a read that did not finish");
		like("$@", qr/The vault refused the read/, "$reason: in the words it always had");
	}
};

subtest 'a read the vault gave no usable answer to is raised as unreachable' => sub {
	my @reasons = (
		'!! Vault is sealed',
		'dial tcp 10.0.0.1:8200: connect: connection refused',
		'Code: 503. Errors:',
		'context deadline exceeded',
	);
	plan tests => 4 * @reasons;
	for my $reason (@reasons) {
		my $raised = read_failing_with($reason);
		is($raised && $raised->state, 'unreachable', "$reason: the state is unreachable");
		is($raised && $raised->exitcode, UNAVAILABLE, "$reason: which exits UNAVAILABLE");
		ok($raised && $raised->is_unreadable, "$reason: and is a read that did not finish");
		like("$@", qr/The vault gave no usable answer/, "$reason: in the words it always had");
	}
};

subtest 'a read that failed for neither reason is raised as unread' => sub {
	my @reasons = (
		'safe exited with code 2',
		'it printed a array rather than a map of keys',
		'safe printed nothing',
	);
	plan tests => 4 * @reasons;
	for my $reason (@reasons) {
		my $raised = read_failing_with($reason);
		is($raised && $raised->state, 'unread', "$reason: the state is unread");
		is($raised && $raised->exitcode, UNAVAILABLE, "$reason: which exits UNAVAILABLE");
		ok($raised && $raised->is_unreadable, "$reason: and is a read that did not finish");
		like("$@", qr/Likely causes are/, "$reason: in the words it always had");
	}
};

# An export that is not the form Genesis reads was read, and is not a
# faithful copy of what is stored, so nothing can be said of the record.
subtest 'an export in a form Genesis does not read is raised as unread' => sub {
	my %exports = (
		'an array'          => [{'secret/a' => {key => 'value'}}],
		'a path of a list'  => {'secret/a' => ['value']},
		'a typed value'     => {'secret/a' => {key => {type => 'string', value => 'v'}}},
	);
	plan tests => 3 * keys %exports;
	for my $form (sort keys %exports) {
		eval { Service::Vault::plain_export($exports{$form}, 'secret/a') };
		my $raised = raised($@);
		is($raised && $raised->state, 'unread', "$form: the state is unread");
		is($raised && $raised->exitcode, UNAVAILABLE, "$form: which exits UNAVAILABLE");
		like("$@", qr/Cannot use the safe export of secret\/a/, "$form: in the words it always had");
	}
};

subtest 'a process nobody catches the failure in exits its code' => sub {
	plan tests => 4;

	my $read = 'Service::Vault::bail_read_failure("https://v:8200", "secret/a", "%s", "get secret/a");';

	my ($exit, $said) = in_a_process(sprintf($read, 'permission denied'));
	is($exit, NOPERM, 'a refusal exits NOPERM');
	like($said, qr/\[FATAL\] Could not read secret\/a from vault/, 'saying what it always said');

	($exit) = in_a_process(sprintf($read, 'Vault is sealed'));
	is($exit, UNAVAILABLE, 'an outage exits UNAVAILABLE');

	($exit) = in_a_process(sprintf($read, 'safe exited with code 2'));
	is($exit, UNAVAILABLE, 'and so does a read that failed for neither reason');
};

done_testing;
