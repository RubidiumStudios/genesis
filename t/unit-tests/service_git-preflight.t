#!/usr/bin/env perl
# Proves T72: the pre-flight names each of the three failures it can
# classify, and begin and genesis new reach them through the same helper.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Genesis;
use Genesis::Exit qw/CONFIG DATAERR/;
use_ok 'Service::Git';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'a working tree git refuses under safe.directory' => sub {
	plan tests => 4;

	my $h    = make_harness(envs => ['qa']);
	my $path = fixture_preflight($h, 'safe_directory');
	my $git  = Service::Git->new($path);
	my $root = $git->root;

	# The fixture marks the repository and leaves the rest to the harness
	# git, which turns the marker into the ownership git refuses on.  That
	# git has to be first on the path for as long as the call runs, which
	# is what the helper's own comment asks a row reading a shape to do.
	local $ENV{PATH} = $h->preflight_bin . ":$ENV{PATH}";

	my ($err, $exit) = bail_from(sub { $git->preflight });
	like($err, qr/dubious ownership|safe\.directory/,
		'the message names the condition git refused on');
	like($err, qr/git config --global --add safe\.directory \Q$root\E/,
		'the message names the fix as a command the operator can run');
	unlike($err, qr/Failed to checkout/,
		"the generic checkout message H20 names is not what the operator sees");
	is($exit, CONFIG, 'it exits CONFIG, the misconfigured environment');
};

subtest 'a process with no committer identity' => sub {
	plan tests => 3;

	my $h    = make_harness(envs => ['qa']);
	my $path = fixture_preflight($h, 'no_identity');
	my $git  = Service::Git->new($path);

	local $ENV{PATH} = $h->preflight_bin . ":$ENV{PATH}";

	my ($err, $exit) = bail_from(sub { $git->preflight });
	like($err, qr/no committer identity/,
		'the message names the missing identity');
	like($err, qr/git config user\.name.*git config user\.email/s,
		'the message names both halves of the fix');
	is($exit, CONFIG, 'it exits CONFIG');
};

subtest 'a repository with no commits' => sub {
	plan tests => 3;

	my $h    = make_harness(envs => ['qa']);
	my $path = fixture_preflight($h, 'no_commits');
	my $git  = Service::Git->new($path);

	local $ENV{PATH} = $h->preflight_bin . ":$ENV{PATH}";

	my ($err, $exit) = bail_from(sub { $git->preflight });
	like($err, qr/has no commits/,
		'the message names the empty repository');
	like($err, qr/git commit/,
		'the message names the fix');
	is($exit, DATAERR, "it exits DATAERR, since the repository's state is the input");
};

subtest 'a healthy working tree passes and returns the handle' => sub {
	plan tests => 2;

	my $h   = make_harness(envs => ['qa']);
	my $git = $h->git('a');

	my $returned = $git->preflight;
	is($returned, $git, 'the helper returns the handle so callers can chain');
	ok($git->is_clean, 'and it changed nothing about the working tree');
};

subtest 'genesis new, which opens no session, calls the same helper' => sub {
	plan tests => 2;

	# One helper, two callers.  D80 keeps the pre-flight in begin and shares
	# it rather than giving genesis new a second copy, so H20 closes in the
	# session for every switching command and here for the one that does not.
	# The begin half of this row is asserted where begin lands.
	my $new_pm = get_file('lib/Genesis/Commands/Env.pm');
	like($new_pm, qr/->preflight\b/,
		'genesis new calls the shared helper, as D80 says it does');
	unlike($new_pm, qr/dubious ownership|safe\.directory/,
		'and classifies nothing of its own');
};

# One local helper, because an assertion helper lives beside its test.  bail
# dies rather than exits whenever it is reached from inside an eval, which a
# test file always is, so there is no exit code in this process to read.  The
# refusal is caught where the code raises it instead, and the code it would
# have exited with is read off the arguments it was composed with, which is
# the same way the pull request branch's refusal is read.
sub bail_from {
	my ($code) = @_;

	my @raised;
	{
		no warnings 'redefine';
		local *Service::Git::bail = sub { push @raised, [@_]; die "refused\n" };
		eval { $code->(); 1 };
	}
	return ('', undef) unless @raised;

	my @args = @{$raised[0]};
	my $opts = ref($args[0]) eq 'HASH' ? shift(@args) : {};
	my ($format, @rest) = @args;

	return (sprintf($format, @rest), $opts->{exitcode});
}

done_testing;
