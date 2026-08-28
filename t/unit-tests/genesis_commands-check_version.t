#!perl
#
# Genesis::Commands::check_version
#
# A tool built from source reports a version with no ordinal in it -- safe
# builds report `safe vdev/<branch>/<sha>` -- so the version cannot be
# compared against a minimum.  check_version accepts such a build outright,
# which is right for a tool whose minimum is only a floor, and wrong for one
# where a later feature is being gated: there, "cannot tell" and "new enough"
# are different answers.
#
# A caller that knows which release a dev build must postdate declares it,
# and the comparison happens against that instead of being skipped.

use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use_ok 'Genesis::Commands';
use Genesis;

$ENV{NOCOLOR} = 1;

# The real safe writes its banner to stderr on older builds and stdout on
# newer ones, and the prereq entry captures both; the fake writes to stdout,
# which the same capture reads.
sub fake_tool {
	my ($name, $output) = @_;
	my $bin = workdir();
	open my $fh, '>', "$bin/$name" or die "cannot write fake $name: $!";
	print $fh "#!/bin/sh\nprintf '%s\\n' '$output'\n";
	close $fh;
	chmod 0755, "$bin/$name";
	return $bin;
}

sub check_with {
	my ($opts, $min, $output) = @_;
	my $bin = fake_tool('safe', $output);
	local $ENV{PATH} = "$bin:/usr/bin:/bin";
	my @args = ('safe', $min, 'safe -v 2>&1', qr(safe v(\S+)), 'http://example.com');
	unshift @args, $opts if $opts;
	return Genesis::Commands::check_version(@args) // '';
}

subtest 'a dev build with no declared equivalent is accepted' => sub {
	# Unchanged behaviour: the minimum is a floor, and a build from source is
	# assumed to clear it.
	is check_with(undef, '1.6.1', 'safe vdev/perf-improvements/d6a138d'), '',
		'the dev build passes without a version to compare';
};

subtest 'a declared equivalent is compared, not skipped' => sub {
	is check_with({dev_version => '1.20.1'}, '1.6.1',
		'safe vdev/perf-improvements/d6a138d'), '',
		'a dev build clears a minimum below its declared equivalent';

	my $err = check_with({dev_version => '1.20.1'}, '2.0.0',
		'safe vdev/perf-improvements/d6a138d');
	like $err, qr/at least 2\.0\.0/,
		'and is refused by a minimum above it, rather than accepted blindly';
};

subtest 'a real version ignores the declared equivalent' => sub {
	# The declaration speaks only for builds that report no ordinal; a build
	# that reports one is compared on what it says.
	my $err = check_with({dev_version => '1.20.1'}, '1.20.0', 'safe v1.9.0');
	like $err, qr/at least 1\.20\.0/,
		'1.9.0 is still too old even though the dev equivalent would pass';

	is check_with({dev_version => '1.20.1'}, '1.20.0', 'safe v1.20.0'), '',
		'and a version that clears the minimum still passes';
};

done_testing;
