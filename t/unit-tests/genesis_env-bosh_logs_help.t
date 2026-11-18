#!/usr/bin/env perl
use strict;
use warnings;

# `genesis <env> logs --help` asks bosh for its help.  It ran bosh
# interactively, so off a terminal the watcher kept bosh's output from the
# caller, and it exited 0 whatever bosh returned.  Help is output the
# operator asked for, so it goes to stdout as bosh prints it, and bosh's
# exit status is Genesis's.

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis;
use Genesis::Env;
use Service::BOSH::Director;

fake_bosh(<<'SH');
echo "Usage: bosh logs synthetic-help-text"
exit "${FAKE_BOSH_RC:-0}"
SH

sub logs_help {
	my ($rc) = @_;
	local $ENV{FAKE_BOSH_RC} = $rc;
	pipe(my $r, my $w) or die "pipe: $!";
	my $pid = fork() // die "fork: $!";
	if (!$pid) {
		close $r;
		open(STDOUT, '>&', $w) or die;
		open(STDERR, '>', '/dev/null') or die;
		Service::BOSH->set_command($ENV{GENESIS_BOSH_COMMAND});
		my $bosh = Service::BOSH::Director->new('an-env',
			url => 'https://127.0.0.1', ca_cert => 'ca_cert', client => 'admin',
			secret => 'password', exodus_path => 'secret/exodus',
			deployment => 'some-deployment'
		);
		no warnings 'redefine';
		*Genesis::Env::bosh = sub { $bosh };
		Genesis::Env::bosh_logs(bless({}, 'Genesis::Env'), '--help');
		exit 99; # bosh_logs exits itself
	}
	close $w;
	my $out = do {local $/; <$r>};
	waitpid($pid, 0);
	return ($out, $? >> 8);
}

my ($out, $rc) = logs_help(0);
like($out, qr/synthetic-help-text/, "bosh's help reaches stdout when stdout is a pipe");
is($rc, 0, 'and a successful help exits 0');

($out, $rc) = logs_help(3);
like($out, qr/synthetic-help-text/, "bosh's help reaches stdout when bosh fails");
is($rc, 3, "and bosh's exit status is returned");

done_testing;
