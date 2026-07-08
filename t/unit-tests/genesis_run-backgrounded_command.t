#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Output;

use Genesis;

# Genesis::run wraps commands in `{ CMD ; } 2>...` to make sure a
# leading-input-redirect failure is captured in the err file.  When
# CMD ends in `&` (backgrounded, as Service::Vault::Local::create
# and other in-tree callers use), bash rejects `& ;` -- the ampersand
# cannot be followed by a semicolon.  The wrap must use a newline
# separator instead so `{ CMD & }` remains a valid group.
#
# This regression bit us during kit-validator (FWT-1019) integration
# testing: safe local -m never actually started, then the logfile-
# slurp bailed with "failed to open <path> for reading".

subtest 'run("cmd &") -- backgrounded command must not blow up shell wrap' => sub {
	my $marker = workdir()."/bg-marker-$$";
	unlink $marker if -e $marker;

	# Fork a very cheap background process that touches a marker file
	# and exits.  If Genesis::run's wrap is broken, bash errors before
	# ever launching this, and the marker never appears.
	Genesis::run("touch '$marker' &");

	# Give the backgrounded process a moment to complete.  If wrap is
	# broken, this sleep is wasted but harmless; if wrap works, the
	# marker appears within a few ms.
	for (1..40) {
		last if -f $marker;
		select undef, undef, undef, 0.05;
	}

	ok(-f $marker, 'backgrounded touch actually ran (shell wrap accepted "&")')
		or diag "Genesis::run's { CMD ; } wrap likely mis-quotes trailing & -- see Genesis.pm sub run";
	unlink $marker if -f $marker;
};

subtest 'run("cmd") -- non-backgrounded command still fine' => sub {
	# Regression: make sure the fix for backgrounded commands doesn't
	# break the ordinary case.
	my $out = Genesis::run("echo hello-run");
	like $out, qr/hello-run/, 'foreground command still captured stdout';
};

done_testing;
