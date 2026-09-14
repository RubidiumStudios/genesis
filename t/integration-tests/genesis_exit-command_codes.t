#!perl
# Proves T8: 1 is reserved for the fatal system error, usage and option errors
# exit 2, the prerequisites check exits 86, and no call site in the tree
# invents a code the table does not name.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;

$ENV{NOCOLOR} = 1;

sub flatten {
	my ($text) = @_;
	$text //= '';
	$text =~ s/\s+/ /g;
	return $text;
}

my $h = make_harness(envs => ['qa']);

subtest 'a fatal error exits 1' => sub {
	# The three are the restoration the run asserts for itself and the two
	# rows below it.
	plan tests => 3;

	my ($out, $err, $exit) = run_genesis($h, 'lookup', 'no-such-env', 'params.env');
	is($exit, 1, 'the fatal error exits a bare 1');
	like(flatten($err), qr/does not exist/,
		'and the message says what was missing');
};

subtest 'a usage error exits 2' => sub {
	# The three are the restoration the run asserts for itself and the two
	# rows below it.
	plan tests => 3;

	# The screen rather than the error line, because command_usage prints the
	# "was called incorrectly" line only when the process is not under test,
	# and every row here runs under test.
	my ($out, $err, $exit) = run_genesis($h, 'lookup', '--no-such-option', 'qa', 'params.env');
	is($exit, 2, 'the option error exits 2');
	like(flatten($err), qr/Usage:.*lookup/,
		'and the usage screen says how the command is called');
};

subtest 'a failed prerequisites check exits 86' => sub {
	# The three are the restoration the run asserts for itself and the two
	# rows below it.
	plan tests => 3;

	# 1.7.0 is below the floor whatever the floor is, so this row reads the
	# code rather than the version, and it stays true when the floor rises.
	my ($out, $err, $exit) = run_genesis($h, {git_version => '1.7.0'},
		'lookup', 'qa', 'params.env');
	is($exit, 86, 'the prerequisites refusal exits 86');
	like(flatten($err), qr/PRE-REQUISITES CHECKS FAILED/,
		'and the message says the checks failed');
};

# A guard rather than a row that starts red: no call site in the tree writes a
# code outside the set today, so this subtest is green the moment the file
# exists, and its job is to stay green as the steps below add refusals.  Its
# red was shown by hand before the commit, by writing one invented code into a
# file under lib/ and watching the sweep name the file and the line.
subtest 'no call site invents a code the table does not name' => sub {
	plan tests => 1;

	# 0, 1, and 2 are the process-wide codes, 86 is the prerequisites check,
	# and 4 is `lookup --defined` answering no, at Commands/Info.pm.  Anything
	# else written as a number at an exit is a code nobody can look up.
	my %allowed = map {$_ => 1} qw/0 1 2 4 86/;

	# The file list comes from the shared sweep reader, so the scan is
	# anchored on the tree rather than on the current directory and covers
	# every script under bin/ beside every module under lib/.  The option is
	# caught however it is spelled, which takes in a quoted key and an
	# assignment such as `$opts{exitcode} = 75`, and a trailing comment is
	# removed before the match so a note that names a code in prose is not
	# read as a call site.
	my $top = $ENV{GENESIS_TOPDIR};

	my @offenders;
	for my $file (sweep_files()) {
		(my $short = $file) =~ s{^\Q$top\E/}{};
		next if $short eq 'lib/Genesis/Exit.pm';
		open my $fh, '<', $file or die "cannot read $file: $!\n";
		while (my $line = <$fh>) {
			# Stop at the data section: Genesis::Helpers carries the kit
			# helper bash script in its __DATA__ block, and a shell exit
			# there is not a Perl call site the table speaks for.
			last if $line =~ /^__(?:DATA|END)__\s*$/;
			my $code_line = strip_comment($line);
			for my $code ($code_line =~ /\bexit\s*\(?\s*(\d+)\b/g,
			              $code_line =~ /\bexitcode\b['"]?\s*[\]\}]?\s*
			                             (?:=>|=(?![=~]))\s*(\d+)\b/gx) {
				push @offenders, "$short:$. exits $code" unless $allowed{$code};
			}
		}
		close $fh;
	}

	is_deeply(\@offenders, [],
		'every numbered exit in the tree is one the table names');
};

done_testing;
