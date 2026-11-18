#!/usr/bin/env perl
# The logger's scrubber is the backstop for any credential a call site
# misses, so it has to reach every part of what is written: a stack line
# names a file, a multi-line credential such as a private key can be
# logged one line at a time, and a backtrace from Carp, which development
# mode turns on for every die, quotes each caller's arguments.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Genesis;
use Genesis::Log;

my $dir = tempdir(CLEANUP => 1);

subtest 'a stack line is scrubbed too' => sub {
	my $secret = fake_secret('stack');
	make_path("$dir/$secret");
	put_file("$dir/$secret/caller.pl", 0644, "sub call_trace { Genesis::trace('hello from a file') } 1;\n");
	require "$dir/$secret/caller.pl";
	my $log = capture_trace {
		my ($logger) = @_;
		$logger->register_secret($secret, 'stack-test');
		main::call_trace();
	};
	like($log, qr/hello from a file/, 'the line is logged');
	like($log, qr/caller\.pl/, 'with the stack line naming its file');
	unlike($log, qr/\Q$secret\E/, 'whose path is scrubbed');
};

subtest 'each line of a multi-line credential is scrubbed on its own' => sub {
	my @body = map {fake_secret("key-line-$_")} 1..3;
	my $key = join("\n", '-----BEGIN RSA PRIVATE KEY-----', @body, '-----END RSA PRIVATE KEY-----')."\n";
	my $log = capture_trace {
		my ($logger) = @_;
		$logger->register_secret($key, 'private-key');
		trace("line: %s", $_) for split /\n/, $key;
	};
	unlike($log, qr/\Q$_\E/, 'a line of the key is absent') for @body;
	like($log, qr/BEGIN RSA PRIVATE KEY/, 'while its armor, which is not secret, is left readable');
};

subtest 'a Carp backtrace shows each argument by its length' => sub {
	my $secret = fake_secret('carp-arg');
	my $inner = sub { local $Carp::Verbose = 1; Carp::confess("refused") };
	my $outer = sub { $inner->(@_) };
	eval { $outer->($secret, [1], undef) };
	my $error = $@;
	like($error, qr/refused/, 'the error is kept');
	like($error, qr/called at/, 'with its backtrace');
	unlike($error, qr/\Q$secret\E/, 'which does not quote the argument');
	like($error, qr/<\d+ bytes>/, 'but gives its length');
};

subtest 'so does the backtrace Carp::Always adds to a die' => sub {
	my $secret = fake_secret('carp-always-arg');
	require Carp::Always;
	my $die = sub { die "refused\n" };
	my $error;
	{
		local $SIG{__DIE__} = $SIG{__DIE__};
		Carp::Always->import();
		eval { $die->($secret) };
		$error = $@;
		Carp::Always->unimport();
	}
	unlike($error, qr/\Q$secret\E/, 'the argument is not quoted');
};

done_testing;
