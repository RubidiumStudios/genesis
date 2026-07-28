#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use JSON::PP qw/decode_json/;
use POSIX ();

use_ok 'Service::Vault::Local';
use Genesis;

# Concurrent local vaults, all sharing one HOME and therefore one ~/.saferc --
# the arrangement AC3 describes and the one both underlying races break.
#
# Children fork so each gets its own pid, which is what _generate_alias keys
# the alias on.  Each reports the port it landed on back through a pipe; the
# parent asserts every child succeeded and no two landed on the same port.

my $WORKERS = 4;

my $home = workdir."/home";
mkdir_or_fail $home;
put_file "$home/.vault_token", '';
local $ENV{HOME} = $home;
local $ENV{SAFE_TARGET} = undef;

pipe(my $reader, my $writer) or BAIL_OUT("could not create pipe: $!");

my @pids;
for my $i (1..$WORKERS) {
	my $pid = fork();
	BAIL_OUT("fork failed: $!") unless defined $pid;

	if ($pid == 0) {
		close($reader);
		my $result = eval {
			my $vault = Service::Vault::Local->create("concurrent-$i");
			sprintf("%d ok %s %s", $i, $vault->port // 'none', $vault->name);
		} || sprintf("%d fail %s", $i, ($@ // 'unknown') =~ s/\s+/ /gr);
		print $writer "$result\n";
		close($writer);
		# _exit past END blocks and DESTROY: the parent reaps the vaults, and
		# a child tearing down its own would race the others' .saferc writes.
		POSIX::_exit(0);
	}

	push @pids, $pid;
}

close($writer);
my @lines = <$reader>;
close($reader);
waitpid($_, 0) for @pids;

chomp @lines;
is(scalar(@lines), $WORKERS, "all $WORKERS workers reported back")
	or diag("got: ", join("; ", @lines));

my @failed = grep { / fail / } @lines;
is(scalar(@failed), 0, 'no worker failed to create its local vault')
	or diag(join("\n", @failed));

my @ports = map { (split / /)[2] } grep { / ok / } @lines;
my %seen; $seen{$_}++ for @ports;
my @dupes = grep { $seen{$_} > 1 } keys %seen;
is(scalar(@dupes), 0, 'every worker bound a distinct port')
	or diag("ports: @ports");

ok(!grep({ $_ eq 'none' } @ports), 'every vault reports the port it bound')
	or diag("ports: @ports");

# Every target should still be present: safe's unlocked whole-file rewrite of
# ~/.saferc drops entries when invocations overlap, so this is the assertion
# that the startup lock is doing its job.
my $targets = eval {
	decode_json(qx{safe targets --json 2>/dev/null} || '[]')
} || [];
my @local_targets = grep { $_->{name} =~ /^local_vault_concurrent-/ } @$targets;
is(scalar(@local_targets), $WORKERS,
	"all $WORKERS targets survive in the shared .saferc")
	or diag("targets: ", join(", ", map { $_->{name} } @$targets));

# Reap: the children deliberately left their vaults running.
for my $t (@local_targets) {
	my ($port) = $t->{url} =~ /:(\d+)/;
	next unless $port;
	for my $pid (split /\s+/, qx{pgrep -f "vault server -config" 2>/dev/null} || '') {
		next unless $pid;
		kill 'TERM', $pid if qx{lsof -a -p $pid -iTCP:$port -sTCP:LISTEN -nP 2>/dev/null};
	}
}
for my $pid (split /\s+/, qx{pgrep -f "safe local -m --as local_vault_concurrent-" 2>/dev/null} || '') {
	kill 'TERM', $pid if $pid;
}

done_testing;
