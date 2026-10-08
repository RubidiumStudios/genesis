#!/usr/bin/env perl
# Proves D115's one refusal: every problem a run found is named in a single
# refusal, its code is the highest-ranked problem's under D106 as noted on
# 2026-10-07 (CONFIG, NOPERM, DATAERR, UNAVAILABLE, TEMPFAIL), a run with one
# problem reads as that refusal read before, and a gate that left questions
# unasked names them and why.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Genesis::Exit qw/CONFIG NOPERM DATAERR UNAVAILABLE TEMPFAIL/;
use Genesis::CI::Preflight;

$ENV{NOCOLOR} = 1;

# What refuse_once raised, its options and its words, read as it composed
# them rather than as a terminal wrapped them.
sub refused {
	my (%opts) = @_;
	my @raised;
	no warnings qw/once redefine/;
	local *Genesis::CI::Preflight::bail = sub {
		push @raised, [@_];
		die "refused\n";
	};
	my $returned = eval {Genesis::CI::Preflight::refuse_once(%opts)};
	return {returned => $returned, raised => \@raised};
}

sub words {
	my ($raised) = @_;
	my (undef, $format, @args) = @{$raised};
	return sprintf($format, @args);
}

sub problem { Genesis::CI::Preflight::problem(@_) }

subtest 'the code is the highest-ranked problem\'s' => sub {
	plan tests => 6;
	my $code = sub {Genesis::CI::Preflight::exit_code_for(map {problem($_, 'x')} @_)};
	is($code->(DATAERR, TEMPFAIL), DATAERR, 'the repository state over a transient fault');
	is($code->(TEMPFAIL, UNAVAILABLE), UNAVAILABLE, 'an unavailable service over a transient fault');
	is($code->(DATAERR, NOPERM), NOPERM, 'a permission over the repository state');
	is($code->(NOPERM, CONFIG), CONFIG, 'configuration over a permission');
	is($code->(TEMPFAIL, UNAVAILABLE, DATAERR, NOPERM, CONFIG), CONFIG,
		'and configuration over everything');
	is($code->(TEMPFAIL), TEMPFAIL, 'one problem is its own code');
};

subtest 'nothing found is nothing refused' => sub {
	plan tests => 2;
	my $r = refused(problems => [], action => 'propagate',
		outcome => 'Nothing was written.');
	is($r->{returned}, 1, 'the run proceeds');
	is(scalar @{$r->{raised}}, 0, 'and nothing was raised');
};

subtest 'one problem reads as its refusal read before' => sub {
	plan tests => 3;
	my $r = refused(action => 'propagate', outcome => 'Nothing was written.',
		problems => [problem(CONFIG,
			'The pipeline has never been applied.  Run #C{genesis pipeline-apply}.')]);
	is(scalar @{$r->{raised}}, 1, 'one refusal');
	is($r->{raised}[0][0]{exitcode}, CONFIG, 'at the problem\'s own code');
	is(words($r->{raised}[0]),
		'Refusing to propagate.  The pipeline has never been applied.  '.
		'Run #C{genesis pipeline-apply}.  Nothing was written.',
		'in the words it had');
};

subtest 'several problems are named in one refusal' => sub {
	plan tests => 5;
	my $r = refused(action => 'propagate', outcome => 'Nothing was written.',
		problems => [
			problem(DATAERR, 'The working tree has uncommitted changes.'),
			problem(CONFIG,  'The pipeline has never been applied.'),
		]);
	is(scalar @{$r->{raised}}, 1, 'one refusal for both');
	is($r->{raised}[0][0]{exitcode}, CONFIG, 'at the highest-ranked code');
	my $said = words($r->{raised}[0]);
	like($said, qr/uncommitted changes.*never been applied/s, 'naming each, in order');
	like($said, qr/\A Refusing \s to \s propagate\./x, 'framed once');
	is(() = $said =~ /Nothing was written/g, 1, 'with the outcome said once');
};

subtest 'a gate names the questions it left unasked' => sub {
	plan tests => 3;
	my $r = refused(action => 'propagate', outcome => 'Nothing was written.',
		problems => [
			problem(DATAERR, 'The working tree has uncommitted changes.'),
			problem(DATAERR, 'The control branch control has diverged from origin/control.'),
		],
		not_checked => {
			because => 'control has diverged from origin',
			checks  => ['the pull request prefix', 'the illegal branches'],
		});
	my $said = words($r->{raised}[0]);
	like($said, qr/uncommitted changes/, 'the problems asked before the gate are named');
	like($said, qr/Not checked, because control has diverged from origin: the pull request prefix and the illegal branches\./,
		'and the questions the gate left unasked, with why');
	is($r->{raised}[0][0]{exitcode}, DATAERR, 'at the code of what was found');
};

subtest 'a percent sign in a problem is not read as a format' => sub {
	plan tests => 1;
	my $r = refused(action => 'propagate', outcome => 'Nothing was written.',
		problems => [problem(DATAERR, 'The branch qa/100%done is behind.')]);
	like(words($r->{raised}[0]), qr{qa/100%done}, 'the name arrives whole');
};

done_testing;
