#!/usr/bin/env perl
use strict;
use warnings;

# The network claims lock around the deploy path's cloud config check: a dry
# run reads the claims without taking the lock, and warns rather than stops
# when someone else holds it; a real deploy takes the lock and stops when
# someone else holds it; a stale lock is cleared only with --yes or a
# confirmed answer at a terminal; and the release helper clears only a lock
# this process holds.

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Output;

use Genesis;
use_ok 'Genesis::Commands::Env';
use Service::BOSH::Director;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

my @calls;   # what the helpers asked the director to do
my $status;  # what check_network_lock reports
my $held;    # whether this process holds the lock
my @writes;  # what was written to the director's vault

sub make_env {
	my (%overrides) = @_;
	@calls = ();
	@writes = ();
	$held = 0;
	my $vault = mock "Mock::NetworkLock::Vault" => {
		get_path_strict => sub { return {} },
		set_path        => sub { my ($self, @args) = @_; push @calls, 'set_path'; push @writes, [@args]; 1 },
	};
	my $director = mock "Mock::NetworkLock::Director" => {
		alias => 'parent',
		exodus_path       => 'secret/exodus/parent/bosh',
		network_lock_path => 'secret/exodus/parent/bosh/network-claim-lock',
		vault             => sub { $vault },
		check_network_lock => sub {
			push @calls, 'check';
			return {status => $status, description => 'about 11 minutes ago by ubuntu@bastion (env: ocf, pid: 229665)'};
		},
		acquire_network_lock => sub { push @calls, 'acquire'; $held = 1; 1 },
		clear_network_lock   => sub { push @calls, 'clear';   my $was = $held; $held = 0; $was },
		network_locked_by_me => sub { push @calls, 'mine';    $held },
		# The real ones, which work through the calls above
		ensure_network_lock_held => \&Service::BOSH::Director::ensure_network_lock_held,
		release_network_lock     => \&Service::BOSH::Director::release_network_lock,
		%overrides,
	};
	return mock "Mock::NetworkLock::Env" => {
		name   => 'test-env',
		bosh   => $director,
		notify => sub { 1 },
	};
}

sub lock_for {
	my ($env, %opts) = @_;
	my ($result, $out, $err);
	($out, $err) = output_from { $result = Genesis::Commands::Env::_deploy_network_claims_lock($env, %opts) };
	return ($result, $out.$err);
}

subtest 'dry run with the lock available takes no lock' => sub {
	plan tests => 3;
	$status = 'unlocked';
	my ($result, $text) = lock_for(make_env(), dryrun => 1, yes => 0);
	is($result, 0, 'reports that no lock is held');
	is_deeply(\@calls, ['check'], 'the director is only asked about the lock');
	like($text, qr/without taking the lock/, 'says the dry run reads without the lock');
};

subtest 'dry run with a stale lock leaves it in place' => sub {
	plan tests => 4;
	$status = 'stale';
	my ($result, $text) = lock_for(make_env(), dryrun => 1, yes => 0);
	is($result, 0, 'reports that no lock is held');
	is_deeply(\@calls, ['check'], 'the stale lock is neither cleared nor replaced');
	like($text, qr/locked \(stale\)/, 'the stale lock is reported');
	unlike($text, qr/\[y\|n\]/, 'nothing is asked');
};

subtest 'dry run with a live lock warns and carries on' => sub {
	plan tests => 5;
	$status = 'locked';
	my ($result, $text) = lock_for(make_env(), dryrun => 1, yes => 0);
	is($result, 0, 'reports that no lock is held');
	is_deeply(\@calls, ['check'], 'the live lock is neither cleared nor replaced');
	like($text, qr/Another deploy holds the network claims lock/, 'says another deploy holds the lock');
	like($text, qr/can change those claims while this dry run is reading them/, 'says the claims may change under the dry run');
	unlike($text, qr/cannot proceed with deployment/, 'the dry run is not stopped');
};

subtest 'real deploy with a live lock stops' => sub {
	plan tests => 2;
	$status = 'locked';
	throws_ok { lock_for(make_env(), dryrun => 0, yes => 1) } qr/currently locked/, 'a live lock stops a real deploy';
	is_deeply(\@calls, ['check'], 'nothing else is done to the lock');
};

subtest 'real deploy with the lock available takes it' => sub {
	plan tests => 2;
	$status = 'unlocked';
	my ($result) = lock_for(make_env(), dryrun => 0, yes => 0);
	is($result, 1, 'reports that the lock is held');
	is_deeply(\@calls, ['check', 'acquire'], 'the lock is acquired');
};

subtest 'real deploy with --yes clears a stale lock without asking' => sub {
	plan tests => 3;
	$status = 'stale';
	my ($result, $text) = lock_for(make_env(), dryrun => 0, yes => 1);
	is($result, 1, 'reports that the lock is held');
	is_deeply(\@calls, ['check', 'clear', 'acquire'], 'the stale lock is cleared, then the lock is acquired');
	unlike($text, qr/\[y\|n\]/, 'nothing is asked');
};

subtest 'real deploy without --yes and without a terminal fails fast' => sub {
	plan tests => 2;
	no warnings 'redefine';
	local *Genesis::Commands::Env::in_controlling_terminal = sub { 0 };
	$status = 'stale';
	throws_ok { lock_for(make_env(), dryrun => 0, yes => 0) } qr/Rerun with --yes/, 'explains how to clear the stale lock';
	is_deeply(\@calls, ['check'], 'the stale lock is left alone');
};

subtest 'real deploy at a terminal asks before clearing a stale lock' => sub {
	plan tests => 4;
	no warnings 'redefine';
	local *Genesis::Commands::Env::in_controlling_terminal = sub { 1 };
	$status = 'stale';

	set_stdin("y\n");
	my ($result, $text) = lock_for(make_env(), dryrun => 0, yes => 0);
	reset_stdin();
	is($result, 1, 'reports that the lock is held after a yes');
	is_deeply(\@calls, ['check', 'clear', 'acquire'], 'a yes clears the stale lock and acquires');

	set_stdin("n\n");
	throws_ok { lock_for(make_env(), dryrun => 0, yes => 0) } qr/Aborted by user/, 'a no aborts';
	reset_stdin();
	is_deeply(\@calls, ['check'], 'a no leaves the stale lock alone');
};

subtest 'release clears only a lock this process holds' => sub {
	plan tests => 4;
	$status = 'unlocked';
	my $env = make_env();
	$held = 1;
	my $result;
	output_from { $result = Genesis::Commands::Env::_deploy_release_network_claims_lock($env) };
	is($result, 1, 'a held lock is released');
	is_deeply(\@calls, ['mine', 'clear'], 'the lock is cleared after confirming it is ours');

	$env = make_env();
	output_from { $result = Genesis::Commands::Env::_deploy_release_network_claims_lock($env) };
	is($result, 0, 'nothing is released when the lock is not ours');
	is_deeply(\@calls, ['mine'], 'the director is only asked whose lock it is');
};

# ---------------------------------------------------------------------------
# the deploy's hold on the lock
# ---------------------------------------------------------------------------

sub under_lock {
	my ($env, $code, %opts) = @_;
	my ($out, $err) = output_from {
		Genesis::Commands::Env::_deploy_under_network_claims_lock($env, $code, dryrun => 0, yes => 0, %opts)
	};
	return $out.$err;
}

subtest 'a lock written by an acquire that then fails is still released' => sub {
	$status = 'unlocked';
	my $env = make_env(acquire_network_lock => sub { push @calls, 'acquire'; $held = 1; die "Hung up\n" });
	my $ran = 0;
	throws_ok { under_lock($env, sub { $ran = 1 }) } qr/^Hung up\b/, 'the failure is passed on as it came';
	ok(!$ran, 'the work under the lock never ran');
	ok(grep({$_ eq 'clear'} @calls), 'the lock the acquire wrote is released') or diag explain \@calls;
	ok(!$held, 'so none of ours is left on the director');
};

subtest 'a signal that lands while the lock is being taken still releases it' => sub {
	$status = 'unlocked';
	for my $signal (qw/INT TERM HUP QUIT/) {
		my $env = make_env(acquire_network_lock => sub { push @calls, 'acquire'; $held = 1; kill $signal => $$; 1 });
		my $ran = 0;
		throws_ok { under_lock($env, sub { $ran = 1 }) } qr/^(?:Interrupted by user|Terminated|Hung up|Quit)\b/,
			"$signal stops the deploy";
		ok(!$ran, "$signal: the work under the lock never ran");
		ok(!$held, "$signal: and the lock is released");
	}
};

subtest 'a dry run takes no lock and so releases none' => sub {
	$status = 'unlocked';
	my $env = make_env();
	my $ran = 0;
	under_lock($env, sub { $ran = 1 }, dryrun => 1);
	ok($ran, 'the work runs');
	ok(!grep({$_ eq 'acquire' || $_ eq 'clear' || $_ eq 'mine'} @calls), 'with no lock taken, asked about, or released')
		or diag explain \@calls;
};

subtest 'a release that fails does not hide the error that stopped the deploy' => sub {
	$status = 'unlocked';
	my $env = make_env(clear_network_lock => sub { push @calls, 'clear'; die "Could not write the lock: Vault is sealed\n" });
	my $err;
	my ($out, $stderr) = output_from {
		eval {
			Genesis::Commands::Env::_deploy_under_network_claims_lock(
				$env, sub { die "the cloud config upload failed\n" }, dryrun => 0, yes => 0
			);
			1;
		} or $err = $@;
	};
	like($err // '', qr/^the cloud config upload failed\b/, 'the error that stopped the deploy is the one passed on');
	like($out.$stderr, qr/could not be released.*Vault is sealed/s, 'and the failed release is logged, with why');
	like($out.$stderr, qr/network-claim-lock/, 'naming where the lock is stored');
};

# A signal that arrives once the work under the lock has ended, and before
# the release has finished, cannot be aimed at the gap between the two, so it
# is sent from inside the release itself: the handlers are the same ones the
# gap runs under, since they stay installed until the function returns.
subtest 'a signal that lands during the release is held back until the release has finished' => sub {
	$status = 'unlocked';
	for my $signal (qw/INT TERM HUP QUIT/) {
		my $finished = 0;
		my $env = make_env(clear_network_lock => sub {
			push @calls, 'clear';
			kill $signal => $$;
			# Work that follows the signal, as the vault calls in a real release do
			$held = 0;
			$finished = 1;
			return 1;
		});
		my $ran = 0;
		throws_ok { under_lock($env, sub { $ran = 1 }) } qr/^(?:Interrupted by user|Terminated|Hung up|Quit)\b/,
			"$signal: the deploy still stops with the signal once the release is done";
		ok($ran, "$signal: the work under the lock ran");
		ok($finished, "$signal: the release ran to its end");
		ok(!$held, "$signal: and the lock is not left on the director");
	}
};

subtest 'a signal that lands during the release does not replace the error that stopped the deploy' => sub {
	$status = 'unlocked';
	my $finished = 0;
	my $env = make_env(clear_network_lock => sub {
		push @calls, 'clear';
		kill TERM => $$;
		$held = 0;
		$finished = 1;
		return 1;
	});
	my $err;
	output_from {
		eval { Genesis::Commands::Env::_deploy_under_network_claims_lock(
			$env, sub { $held = 1; die "the cloud config upload failed\n" }, dryrun => 0, yes => 0
		); 1 } or $err = $@;
	};
	like($err // '', qr/^the cloud config upload failed\b/, 'the error that stopped the deploy is the one passed on');
	ok($finished, 'the release ran to its end');
	ok(!$held, 'and the lock is not left on the director');
};

subtest 'the signal handlers are put back when the deploy returns' => sub {
	$status = 'unlocked';
	my %before = map { $_ => $SIG{$_} } qw/INT TERM HUP QUIT/;
	my $env = make_env();
	under_lock($env, sub { 1 });
	is($SIG{$_}, $before{$_}, "\$SIG{$_} is as it was") for qw/INT TERM HUP QUIT/;
};

subtest 'a deploy that lost its lock while it waited writes no claims' => sub {
	$status = 'locked';
	my $env = make_env();   # holds no lock: another process took it over
	throws_ok {
		output_from { Genesis::Commands::Env::_deploy_submit_network_claims($env, {subnets => {}}) }
	} qr/Cannot write the network claims.*parent.*no longer holds.*ubuntu\@bastion/s,
		'the write is refused, naming who holds the lock now';
	ok(!grep({$_ eq 'set_path'} @calls), 'and nothing is written') or diag explain \@calls;
	ok(!grep({$_ eq 'clear'} @calls), 'and the other process\'s lock is left alone');
};

subtest 'the release after the claims are written reports what it did' => sub {
	$status = 'locked';
	my $env = make_env();
	$held = 1;
	my ($out, $err) = output_from { Genesis::Commands::Env::_deploy_submit_network_claims($env, {subnets => {}}) };
	is(scalar(@writes), 1, 'the claims are written while the lock is held');
	like($out.$err, qr/\(lock removed\)/, 'and the release that removed the lock says so');

	$env = make_env(clear_network_lock => sub { push @calls, 'clear'; 0 });
	$held = 1;
	($out, $err) = output_from { Genesis::Commands::Env::_deploy_submit_network_claims($env, {subnets => {}}) };
	unlike($out.$err, qr/\(lock removed\)/, 'a release that removed nothing does not claim it did');
	like($out.$err, qr/lock was not removed/, 'and says the lock was not removed');
};

# ---------------------------------------------------------------------------
# every acquire sits under the same signal coverage
# ---------------------------------------------------------------------------
# The deploy path holds the lock across an eval whose release runs on every
# exit, and the signals that would otherwise kill the process mid-hold are
# turned into errors so they unwind through that release.  The coverage is
# only as good as the next lock site that gets written, so this reads the
# tree rather than one function: a file that takes the lock and does not
# localize all four signals is the defect this catches.
#
# HUP and QUIT are in the list for the bastion.  Genesis deploys are run over
# ssh, a dropped session hangs up every process in it, and a lock left on the
# director then outlives the process that took it -- which is exactly the
# stale lock an operator finds and cannot safely clear.
subtest 'every file that takes the network claims lock covers INT, TERM, HUP, and QUIT' => sub {
	my @takers;
	for my $pm (sort glob('lib/Genesis/Commands/*.pm')) {
		open my $fh, '<', $pm or die "cannot read $pm: $!";
		my $src = do {local $/; <$fh>};
		close $fh;
		push @takers, [$pm, $src] if $src =~ /->acquire_network_lock\b/;
	}

	plan tests => 1 + 5 * scalar(@takers);
	ok(scalar(@takers), 'at least one command takes the network claims lock');

	for my $taker (@takers) {
		my ($pm, $src) = @$taker;
		for my $signal (qw/INT TERM HUP QUIT/) {
			like($src, qr/local \$SIG\{\Q$signal\E\}/,
				"$pm localizes \$SIG{$signal} around the lock");
		}
		like($src, qr/->clear_network_lock\b/,
			"$pm releases the lock it takes");
	}
};

done_testing;
