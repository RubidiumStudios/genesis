#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::Output;
use Test::Exit;

use Genesis::Commands;
use PadWalker qw/closed_over/;
use Genesis;

# Initialize the Genesis environment
$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

subtest 'bin/genesis' => sub {

	require_ok './bin/genesis';

	# TODO: Add tests to make sure all the defined commands are valid in their definitions in general (ie: specify existing function groups, correct format of options, etc)

};

# Proves T323: one sweep reads the whole flag-carrying surface, so each
# command asserts the options its registration declares and the class
# marker it carries, and the retired seeding command is absent.
subtest 'the flag-carrying pipeline surface' => sub {

	my %surface = (
		# The deploy joins the sweep with the class it now declares, and with
		# the --force the provider gate reads.  The flag takes no short form,
		# because -f is what every other command spells force with and a
		# deploy is not a command to give a one-letter break-glass to.
		'deploy' => {
			class        => Genesis::Commands::DEPLOYED_STATE,
			options      => [qw/dry-run|n yes|y no-propagate force redeploy/],
			absent       => [qw/pull no-fetch no-refresh/],
			fast_forward => 1,
		},
		# The other two commands of the deployed-state class are here for
		# one attribute apiece.  They share the deploy's gate, and the gate
		# moves a ref for the command that declares the move, so a step that
		# gave either of them the attribute would have a read writing to the
		# repository it was asked to read.  Their flags are not swept: the
		# bosh command passes its options through to the bosh cli, so the
		# set it declares is not the set it accepts.
		'info' => {
			class   => Genesis::Commands::DEPLOYED_STATE,
			options => [qw/as-deployed/],
			absent  => [qw/no-fetch no-refresh/],
		},
		'bosh' => {
			class   => Genesis::Commands::DEPLOYED_STATE,
			options => [qw/as-deployed/],
			absent  => [qw/no-fetch no-refresh/],
		},
		'create' => {
			class   => Genesis::Commands::PRE_DEPLOY,
			options => [qw/prior-env=s require-pr manual no-commit reason=s/],
			# Green on arrival, and a guard rather than a proof: a step that
			# gave genesis new a flag to skip the control refresh would put
			# the ancestry check back on a stale tracking ref.
			absent  => [qw/no-fetch no-refresh/],
		},
		# propagate is the one command in the sweep whose whole registration
		# is read, rather than its flags alone.  D36 retired its argument,
		# D44 and D40 retired three of its flags, and D83 gave -y a new
		# meaning, so an option or an argument that came back would be a
		# decision reversed and not a flag added.  The four keys below are
		# read only where a command declares them.
		'propagate' => {
			class        => Genesis::Commands::PRE_DEPLOY,
			options      => [qw/dry-run|n yes|y force/],
			absent       => [qw/no-fetch no-refresh no-push commit=s/],
			exactly      => 3,
			arguments    => [],
			scope        => 'repo',
			group        => Genesis::Commands::PIPELINE,
			option_group => Genesis::Commands::REPO_OPTIONS,
		},
		'pipeline-status' => {
			class   => Genesis::Commands::PRE_DEPLOY,
			options => [qw/no-refresh/],
			absent  => [qw/no-fetch/],
		},
		'pipeline-apply' => {
			class   => Genesis::Commands::PRE_DEPLOY,
			options => [qw/dry-run|n yes|y/],
			absent  => [qw/platform|provider|p=s no-fetch/],
		},
		'pipeline-describe' => {
			class   => Genesis::Commands::PRE_DEPLOY,
			options => [],
			absent  => [qw/no-fetch no-refresh/],
		},
		# The four secrets commands are in the sweep for one flag apiece.
		# D87 gives the deployed commit exactly two selections, and this is
		# the spelling six of the seven commands take, so a step that gave
		# one of them a third spelling of its own is what these rows catch.
		# Their other flags are not swept, because what they declare is a
		# matter for the secrets surface and not for this one.  The
		# registration and branch-class rows of the four were green on
		# arrival, because those classes are already declared, and they
		# stand as guards on those declarations rather than as proof of
		# anything here.
		'check-secrets' => {
			class   => Genesis::Commands::PRE_DEPLOY,
			options => [qw/as-deployed/],
		},
		'add-secrets' => {
			class   => Genesis::Commands::PRE_DEPLOY,
			options => [qw/as-deployed/],
		},
		'rotate-secrets' => {
			class   => Genesis::Commands::PRE_DEPLOY,
			options => [qw/as-deployed/],
		},
		'remove-secrets' => {
			class   => Genesis::Commands::PRE_DEPLOY,
			options => [qw/as-deployed/],
		},
	);

	for my $cmd (sort keys %surface) {
		ok(has_command($cmd), "$cmd is registered");
		my %opts = @{command_properties($cmd)->{options} || []};
		ok(exists $opts{$_}, "$cmd declares $_")
			for @{$surface{$cmd}{options}};
		ok(!exists $opts{$_}, "$cmd does not declare $_")
			for @{$surface{$cmd}{absent}};
		is(command_properties($cmd)->{branch_class}, $surface{$cmd}{class},
			"$cmd carries the $surface{$cmd}{class} marker");
		# Read for every command in the sweep rather than where it is
		# declared, because the fact worth pinning is which one command
		# moves a ref and not that the deploy does.
		is(command_properties($cmd)->{branch_fast_forward} ? 1 : 0,
			$surface{$cmd}{fast_forward} // 0,
			$surface{$cmd}{fast_forward}
				? "$cmd brings its deployment branch forward"
				: "$cmd moves no ref of its own");

		is(scalar(keys %opts), $surface{$cmd}{exactly},
			"$cmd declares only the options read above")
			if exists $surface{$cmd}{exactly};
		cmp_deeply(command_properties($cmd)->{arguments},
			$surface{$cmd}{arguments},
			"$cmd takes the positional arguments it declares")
			if exists $surface{$cmd}{arguments};
		is(command_properties($cmd)->{scope}, $surface{$cmd}{scope},
			"$cmd is $surface{$cmd}{scope}-scoped")
			if exists $surface{$cmd}{scope};
		is(command_properties($cmd)->{function_group}, $surface{$cmd}{group},
			"$cmd belongs to the group it declares")
			if exists $surface{$cmd}{group};
		is(command_properties($cmd)->{option_group},
			$surface{$cmd}{option_group},
			"$cmd takes the option group it declares")
			if exists $surface{$cmd}{option_group};
	}

	# The seeding command is retired under D41, so it is not part of the
	# surface this sweep reads.  Green on arrival, and a guard against a
	# step that revives it.
	ok(!has_command('pipeline-prepare')
		|| command_properties('pipeline-prepare')->{retired},
		'the retired seeding command is absent from the flag-carrying set');
};

# The deployed-commit flag on the bosh command is the one flag whose place on
# the command line decides whether Genesis reads it at all, and nothing said
# so where a change could be caught.
subtest 'where --as-deployed has to sit on a bosh command line' => sub {
	plan tests => 4;

	my $bosh = command_properties('bosh');
	my %opts = @{$bosh->{options} || []};
	ok(exists $opts{'as-deployed'},
		'the bosh command declares the deployed-commit flag');

	# The two properties together are what makes the position matter.  Option
	# parsing stops at the first argument that is not an option, which is the
	# bosh subcommand, and everything after it is passed to the bosh cli
	# untouched, so a flag written after the subcommand reaches bosh rather
	# than Genesis and bosh refuses an option it does not know.
	ok($bosh->{option_require_order},
		'it stops parsing options at the bosh subcommand');
	ok($bosh->{option_passthrough},
		'and hands everything after that subcommand to the bosh cli');

	like($bosh->{description}, qr/must come BEFORE any bosh command/,
		'and the command says so where an operator reads it');
};

done_testing;
