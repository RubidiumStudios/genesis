#!perl
#
# The control branch is a name the repository chooses, not a constant.
# It is declared at pipeline.source_control.control_branch and read back
# through Genesis::Top::ci_control_branch, so a repository that calls its
# control branch anything other than the schema default must still be
# understood by the commands that work from it.
#
# Every row here runs against a repository whose control branch is named
# `trunk`, which is deliberately not the default, so a reader that fell
# back to the constant answers `control` and is caught.
#
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;

provide_rc();

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

use_ok 'Genesis::Commands::Pipelines';

# No vault: every row here is answered before a command reaches one.
my $h = make_harness(envs => ['qa'], control => 'trunk', vault => 0);

# Somewhere that is neither the configured control branch nor the
# constant, so a refusal has to name one of the two and cannot name both.
Harness::Propagation::run(
	{dir => $h->a, onfailure => 'Failed to cut the off-branch'},
	'git', 'checkout', '-q', '-b', 'elsewhere');

subtest 'propagate refuses by the configured name' => sub {
	plan tests => 2;

	my (undef, $err) = $h->run_genesis({restore => 0}, 'propagate');
	like $err, qr/must be run from the trunk branch/,
		'the refusal names the branch the repository declared';
	unlike $err, qr/must be run from the control branch/,
		'and not the schema default it fell back to';
};

subtest 'pipeline-prepare refuses by the configured name' => sub {
	plan tests => 2;

	my (undef, $err) = $h->run_genesis({restore => 0}, 'pipeline-prepare');
	like $err, qr/must be run from the trunk branch/,
		'the refusal names the branch the repository declared';
	unlike $err, qr/must be run from the control branch/,
		'and not the schema default it fell back to';
};

subtest 'pipeline-status resolves the configured branch head' => sub {
	plan tests => 2;

	# There is no branch called `control` in this repository, so reading
	# the constant asks git for a revision that does not exist and the
	# header carries git's complaint instead of a sha.
	my ($out) = $h->run_genesis({restore => 0}, 'pipeline-status');
	unlike $out, qr/Needed a single revision/,
		'the header resolves a real branch rather than failing to';
	my ($head) = Harness::Propagation::run(
		{dir => $h->a}, 'git', 'rev-parse', '--short', 'trunk');
	chomp $head;
	like $out, qr/\Q$head\E/,
		"the header shows trunk's head";
};

# Stands in for Service::Git for the one helper that takes the control
# branch as an argument: it records what merge_base was asked about.
{
	package FakeGit;
	sub new { return bless {seen => []}, $_[0] }
	sub log_subjects { return () }
	sub merge_base {
		my ($self, @args) = @_;
		push @{$self->{seen}}, [@args];
		return 'deadbeef';
	}
}

subtest 'the propagation base is taken from the branch it is given' => sub {
	plan tests => 2;

	# An env branch with no propagation marker falls back to the merge
	# base with control, which is where a wrong control branch would
	# silently change what the diff is computed against.
	my $git = FakeGit->new;
	my ($base) = Genesis::Commands::Pipelines::_resolve_propagation_base(
		'qa', $git, 'trunk');
	is $base, 'deadbeef', 'the merge base is what comes back';
	is_deeply $git->{seen}, [['trunk', 'qa']],
		'and it was taken against the control branch passed in';
};

done_testing;
