#!perl
# Proves T9 and T10: the declared git floor is 2.34.1, Genesis refuses a git
# below it naming what it found and what it needs, the refusal exits 86, and
# the declaration is one list that every command reads rather than a floor
# each command carries for itself.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;

use File::Find;

$ENV{NOCOLOR} = 1;

sub flatten {
	my ($text) = @_;
	$text //= '';
	$text =~ s/\s+/ /g;
	return $text;
}

my $h = make_harness(envs => ['qa']);

subtest 'a pipeline command refuses a git below the floor' => sub {
	# The five are the restoration the run asserts for itself and the four
	# rows below it.
	plan tests => 5;

	# 1.7.0 is below both the old floor and the new one, so the command is
	# refused either way and never runs: the row reads the shape of the
	# refusal, and the floor it names, without a real propagation command
	# doing anything to the tree on the way.
	my ($out, $err, $exit) = run_genesis($h, {git_version => '1.7.0'},
		'pipeline-describe');
	my $said = flatten($err);

	is($exit, 86, 'the refusal exits 86');
	like($said, qr/git v1\.7\.0 is installed/, 'it names the version it found');
	like($said, qr/at least 2\.34\.1/, 'and the version it requires');
	unlike($said, qr/at least 1\.8\.0/, 'and the old floor is gone');
};

subtest 'a command outside the pipeline group refuses identically' => sub {
	# The four are the restoration the run asserts for itself and the three
	# rows below it.
	plan tests => 4;

	# 2.30.0 clears the old floor and falls short of the new one, so this is
	# the row that moves when the declaration does, and `lookup` is a command
	# the old floor would have let through harmlessly.
	my ($out, $err, $exit) = run_genesis($h, {git_version => '2.30.0'},
		'lookup', 'qa', 'params.env');
	my $said = flatten($err);

	is($exit, 86, 'the same code');
	like($said, qr/git v2\.30\.0 is installed/, 'the same message');
	like($said, qr/at least 2\.34\.1/, 'and the same floor');
};

subtest 'a git at the floor is accepted' => sub {
	# The three are the restoration the run asserts for itself and the two
	# rows below it.
	plan tests => 3;

	# Exactly the floor, because a comparison that asked for more than the
	# version it names would refuse this run and every row above it would
	# still be green.  The command is the one the row above drives, so the
	# only thing that differs between them is the git.
	my ($out, $err, $exit) = run_genesis($h, {git_version => '2.34.1'},
		'lookup', 'qa', 'params.env');
	my $said = flatten($err);

	isnt($exit, 86, 'the prerequisites check does not refuse it');
	unlike($said, qr/at least 2\.34\.1/,
		'and nothing asks for a git it already has');
};

subtest 'the floor is declared once, for every command' => sub {
	plan tests => 3;

	require_ok './bin/genesis';

	my @carrying;
	for my $cmd (Genesis::Commands::commands()) {
		my $props = Genesis::Commands::command_properties($cmd);
		push @carrying, "$cmd: $_"
			for grep {/version|floor/i} sort keys %$props;
	}
	is_deeply(\@carrying, [],
		'no command registration carries a version of its own');

	# The file rather than the line, because the line moves the moment
	# anything above it does, and a guard that fails on an unrelated edit
	# gets deleted rather than fixed.
	my @declarations;
	my @files;
	find(sub {push @files, $File::Find::name if -f && /\.pm$/}, 'lib');
	push @files, 'bin/genesis';
	for my $file (sort @files) {
		open my $fh, '<', $file or die "cannot read $file: $!\n";
		while (my $line = <$fh>) {
			push @declarations, $file if $line =~ /["']2\.34\.1["']/;
		}
		close $fh;
	}
	is_deeply(\@declarations, ['lib/Genesis/Commands.pm'],
		'the floor is written in exactly one place');
};

done_testing;
