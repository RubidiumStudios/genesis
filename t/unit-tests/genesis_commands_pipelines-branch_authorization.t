#!perl
#
# Propagation may repair a missing environment branch instead of merely
# refusing to run.  Creating a branch is not something to do silently
# during an operation whose purpose is something else, so it has to be
# authorized: explicitly with -y, or by answering a prompt.
#
# The three outcomes are kept in one helper because the interesting part
# is the decision, not the creation.  Reaching the creation needs a
# working tree, a vault and a git repository; reaching the decision needs
# only an options hash.
#
use strict;
use warnings;

use lib 'lib';
use lib 't';
use Test::More;
use Test::Exception;

$ENV{GENESIS_TESTING} = 'yes';
$ENV{GENESIS_LIB}   ||= 'lib';
$ENV{NOCOLOR}         = 1;

use_ok 'Genesis::Commands::Pipelines';

# in_controlling_terminal and prompt_for_boolean are imported INTO
# Genesis::Commands::Pipelines, so the symbols to override live there
# rather than in Genesis::Term / Genesis::UI.
our (@prompts, @shown);
sub set_terminal {
	my ($interactive, $answer) = @_;
	no warnings qw(redefine once);
	*Genesis::Commands::Pipelines::in_controlling_terminal = sub { $interactive };
	*Genesis::Commands::Pipelines::prompt_for_boolean = sub {
		push @prompts, $_[0];
		return $answer;
	};
	# The environment list is shown before the question rather than
	# crammed into it, so what the operator sees is both together.
	*Genesis::Commands::Pipelines::info = sub {
		my ($fmt, @args) = @_;
		push @shown, sprintf($fmt, @args);
	};
}

sub seen { return join("\n", @shown, @prompts) }

sub authorize {
	my ($opts, @missing) = @_;
	@missing = ('np1') unless @missing;
	return Genesis::Commands::Pipelines::_authorize_branch_creation(
		$opts, \@missing, 'control'
	);
}

# ======================================================================
# -y is the explicit authorization
# ======================================================================

subtest '-y authorizes creation without asking' => sub {
	plan tests => 2;
	@prompts = ();
	set_terminal(1, 0);   # interactive, and would decline if asked

	ok authorize({yes => 1}), 'authorized';
	is scalar @prompts, 0,
		'-y means the question is already answered -- asking anyway would be noise';
};

subtest '-y authorizes outside a terminal too' => sub {
	plan tests => 1;
	@prompts = ();
	set_terminal(0, 0);

	ok authorize({yes => 1}),
		'automation can authorize without a terminal to be asked in';
};

# ======================================================================
# The prompt is the other way to authorize
# ======================================================================

subtest 'an interactive run is asked, and yes authorizes' => sub {
	plan tests => 3;
	(@prompts, @shown) = ((), ());
	set_terminal(1, 1);

	ok authorize({}), 'accepting the prompt authorizes creation';
	is scalar @prompts, 1, 'asked exactly once for the whole set';
	like seen(), qr/np1/,
		'the environment is named, not just counted';
};

subtest 'declining the prompt stops the run' => sub {
	plan tests => 1;
	set_terminal(1, 0);

	# Continuing past a declined prompt would propagate against a branch
	# the operator just refused to create, which is the silent no-op the
	# guard exists to prevent.
	throws_ok {authorize({})} qr/./,
		'declining bails rather than continuing without the branch';
};

subtest 'every missing environment is named before the question' => sub {
	plan tests => 3;
	(@prompts, @shown) = ((), ());
	set_terminal(1, 1);

	authorize({}, qw(lab np1));
	like seen(), qr/lab/, 'first environment named';
	like seen(), qr/np1/, 'second environment named';
	# Approving a list you cannot see is not consent.
	is scalar @prompts, 1, 'still one question for the whole set';
};

# ======================================================================
# Without either, the run refuses -- and says how to proceed
# ======================================================================

subtest 'a non-interactive run without -y refuses' => sub {
	plan tests => 3;
	@prompts = ();
	set_terminal(0, 1);   # would accept, but cannot be asked

	throws_ok {authorize({})} qr/np1/,
		'names the environment whose branch is missing';
	is scalar @prompts, 0,
		'no prompt attempted where there is no one to answer it';

    # A refusal that does not say how to proceed is the rudeness this
    # ticket exists to remove.
	throws_ok {authorize({})} qr/-y|--yes/,
		'offers -y as the way through';
};

subtest 'the refusal still points at pipeline-prepare' => sub {
	plan tests => 1;
	set_terminal(0, 1);

	# pipeline-prepare remains the deliberate path; -y is the shortcut
	# for an operator who is already here.
	throws_ok {authorize({})} qr/pipeline-prepare/,
		'the explicit command is still offered alongside the flag';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
