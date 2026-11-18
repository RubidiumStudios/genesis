#!/usr/bin/env perl
# A hook that calls bosh with no environment file to go through runs the
# bosh command itself.  bosh's debug logging writes director requests and
# tokens to BOSH_LOG_PATH or its output, so that bosh runs in the same
# managed environment as every bosh Genesis runs: debug logging off, no
# log file, and the arguments handed over exactly as the hook gave them.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;
use File::Temp qw/tempdir/;
use JSON::PP;

use Genesis;
use Genesis::Helpers;

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/bin";
Genesis::Helpers->write("$dir/.helper");

# A fake bosh that reports what it was run with, and writes a debug log
# where BOSH_LOG_PATH points, as bosh would.
put_file("$dir/bin/fake-bosh", 0755, <<'SH');
#!/usr/bin/perl
use JSON::PP;
if (length($ENV{BOSH_LOG_PATH} // '')) {
	open my $fh, '>', $ENV{BOSH_LOG_PATH} or die; print $fh "fake debug log\n";
}
print JSON::PP->new->canonical->encode({
	argv => \@ARGV,
	level => $ENV{BOSH_LOG_LEVEL},
	path => $ENV{BOSH_LOG_PATH},
	https_proxy => $ENV{HTTPS_PROXY},
}), "\n";
exit 3;
SH

my @args = ('deployments', '--column', 'name', 'it is', "it's", '$HOME', '*', '"quoted"', '');
my ($out, $rc, $err);
{
	local %ENV = (%ENV,
		PATH => "$dir/bin:$ENV{PATH}",
		GENESIS_LIB => "$ENV{GENESIS_TOPDIR}/lib",
		GENESIS_ROOT => $dir, GENESIS_ENVIRONMENT => 'no-such-env',
		GENESIS_BOSH_COMMAND => 'fake-bosh',
		BOSH_ALIAS => 'fake-director', GENESIS_BOSH_VERIFIED => 'fake-director',
		BOSH_ENVIRONMENT => 'https://10.0.0.6:25555', BOSH_CA_CERT => 'fake-ca',
		BOSH_LOG_LEVEL => 'debug', BOSH_LOG_PATH => "$dir/bosh-debug.log",
		HTTPS_PROXY => 'http://proxy.example:3128',
	);
	delete $ENV{GENESIS_HONOR_ENV};
	($out, $rc, $err) = run(
		{dir => $dir, stderr => 0},
		'source .helper; bosh "$@"', @args
	);
}
my $seen = eval {decode_json($out)} // {};

is($rc, 3, "the hook gets bosh's exit status") or diag $out;
is_deeply($seen->{argv}, \@args, 'bosh gets the arguments exactly as the hook gave them');
is($seen->{level}, 'none', 'debug logging is off');
ok(!defined($seen->{path}), 'BOSH_LOG_PATH is unset');
ok(!-e "$dir/bosh-debug.log", 'so no debug log is written');
ok(!defined($seen->{https_proxy}), 'and HTTPS_PROXY is dropped, as it is for every bosh Genesis runs');
like($err, qr/Ignoring BOSH_LOG_LEVEL and BOSH_LOG_PATH/, 'the operator is told why their setting was ignored');

done_testing;
