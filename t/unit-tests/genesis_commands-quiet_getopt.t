#!/usr/bin/env perl
# Getopt::Long warns with the value it refused, and an option's value can
# be a credential.  A parser outside the top-level one, such as a Perl
# addon's, captures those warnings and reports each by the kind of
# problem it was, in the words the top-level parser uses.  The kit and CI
# providers parse with pass_through, under which Getopt::Long never warns.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;

use Genesis;
use Genesis::Commands;

my $secret = fake_secret('getopt');

subtest 'get_options_quietly reports problems by kind' => sub {
	my ($log, $stderr) = capture_trace {
		Getopt::Long::Configure(qw(no_ignore_case bundling no_pass_through));
		my ($ok, @problems) = Genesis::Commands::get_options_quietly(
			['--count', $secret, '--other'], {}, 'count=i'
		);
		ok(!$ok, 'the parse fails');
		is_deeply(\@problems, [
			'option --count was given a value of the wrong type',
			'an unknown option was given',
		], 'and each problem is named in fixed words');
	};
	unlike($log.$stderr, qr/\Q$secret\E/, 'the refused value reaches no log or stream');
	unlike($stderr, qr/Unknown option|invalid for option/, "and Getopt::Long's own words are not printed");
};

done_testing;
