#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;

use PodGate::Check qw/check_module load_exclusions/;

my $FIXTURES = 't/src/pod-gate';

sub failures_of {
	my ($result, $check) = @_;
	return [sort map {$_->{method} // ''}
	        grep {$_->{check} eq $check} @{$result->{failures}}];
}

sub advisories_of {
	my ($result, $check) = @_;
	return [sort map {$_->{method} // ''}
	        grep {$_->{check} eq $check} @{$result->{advisory}}];
}

subtest 'a clean module passes' => sub {
	my $r = check_module("$FIXTURES/Sample.pm");
	ok($r->{ok}, "Sample reports ok")
		or diag explain $r->{failures};
	is(scalar @{$r->{failures}}, 0, "with no failures");
};

subtest 'coverage failures' => sub {
	my $r = check_module("$FIXTURES/Faulty.pm");

	ok(!$r->{ok}, "Faulty does not pass");
	cmp_deeply(failures_of($r, 'has_pod'), ['undocumented'],
		"a sub with no =head2 is reported");
	cmp_deeply(failures_of($r, 'orphaned_pod'), ['orphan_in_api_section'],
		"a =head2 in an api section with no sub is reported");
};

subtest 'placement failures' => sub {
	my $r = check_module("$FIXTURES/Faulty.pm");

	cmp_deeply(failures_of($r, 'private_placement'),
		['_private_but_public_section'],
		"a private sub documented in a public section is reported");
	cmp_deeply(failures_of($r, 'public_placement'),
		['public_but_internal_section'],
		"a public sub filed under INTERNAL METHODS is reported");
};

subtest 'a module with no .pod at all' => sub {
	my $r = check_module("$FIXTURES/Undocumented.pm");

	ok(!$r->{ok}, "does not pass");
	is(scalar @{failures_of($r, 'missing_pod')}, 1, "reported once");
	# One clear failure, not one per undocumented sub: the fix is a file,
	# not forty edits, and forty lines of output hides that.
	is(scalar @{$r->{failures}}, 1, "and does not also list every sub");
};

subtest 'unparseable POD fails the module' => sub {
	# The reference validator reports syntax separately from its failure
	# count, so a module with unparseable POD can read as passing --
	# Store::Credhub and Compiler::Providers::Concourse both do.  One
	# verdict, or the gate lets exactly the worst cases through.
	my $r = check_module("$FIXTURES/BadSyntax.pm");

	ok(!$r->{ok}, "does not pass despite every sub being documented");
	ok(scalar @{failures_of($r, 'pod_syntax')} >= 1,
		"the syntax error is a failure like any other");
};

subtest 'contract failures' => sub {
	my $r = check_module("$FIXTURES/Contract.pm");

	ok(!$r->{ok}, "Contract does not pass");

	cmp_deeply(failures_of($r, 'errors_documented'), ['raises_undocumented'],
		"a sub that dies with no Errors block is reported");

	cmp_deeply(failures_of($r, 'has_examples'), ['takes_args_without_examples'],
		"a sub with documented parameters and no example is reported");

	cmp_deeply(failures_of($r, 'examples_show_output'), [],
		"whether an example states its outcome is not gated -- see Check.pm");

	cmp_deeply(failures_of($r, 'signature_arity'), ['wrong_arity'],
		"a documented arity the code cannot accept is reported");

	# Advisory, not fatal: the tree carries a backlog of these from the
	# comment-to-POD migration, so the check reports without failing until
	# that is cleared.  It still has to fire.
	cmp_deeply(advisories_of($r, 'stale_error_quote'), ['stale_error_quote'],
		"an Errors block quoting a string the code cannot emit is reported");
	cmp_deeply(failures_of($r, 'stale_error_quote'), [],
		"and does not fail the module while it is advisory");
};

subtest 'error accuracy is only checked where it is decidable' => sub {
	# Sample::raises documents its errors in prose, quoting fragments
	# rather than whole messages.  That is legitimate, and undecidable --
	# the check must stand down rather than guess at the wording.
	my $r = check_module("$FIXTURES/Sample.pm");
	cmp_deeply(advisories_of($r, 'stale_error_quote'), [],
		"a quoted fragment that does appear in the code is accepted");
};

subtest 'contract checks stay quiet where they do not apply' => sub {
	# Sample is fully documented; every one of these must pass on it, or
	# the check is really a style preference wearing a gate's clothes.
	my $r = check_module("$FIXTURES/Sample.pm");

	for my $check (qw/errors_documented has_examples examples_show_output
	                  signature_arity/) {
		cmp_deeply(failures_of($r, $check), [], "$check clean on Sample");
	}
};

subtest 'arity tolerates the way optional parameters are written' => sub {
	# Perl marks optional parameters in the body, not the parameter list,
	# so a call documented with fewer arguments is correct documentation
	# rather than a contradiction.  Sample::optional_second documents both
	# arities; failing that rejects the idiom across most of the tree.
	my $r = check_module("$FIXTURES/Sample.pm");
	cmp_deeply(failures_of($r, 'signature_arity'), [],
		"documenting fewer arguments than the sub declares is not a defect");
};

subtest 'section vocabulary' => sub {
	# Perl has no syntax separating a method from a function; the heading
	# is the only record of which one a module provides, and copying
	# another module's skeleton is how it goes wrong.
	my $f = check_module("$FIXTURES/FunctionsAsMethods.pm");
	cmp_deeply(failures_of($f, 'section_vocabulary'), [''],
		"subs that take no invocant filed under METHODS are reported");
	like($f->{failures}[0]{detail}, qr/functions/,
		"and the report says which way round it is");

	my $m = check_module("$FIXTURES/MethodsAsFunctions.pm");
	cmp_deeply(failures_of($m, 'section_vocabulary'), [''],
		"subs that all take an invocant filed under FUNCTIONS are reported");
	like($m->{failures}[0]{detail}, qr/methods/,
		"and likewise");
};

subtest 'section vocabulary stands down where it cannot tell' => sub {
	# A class that also exports a few helpers legitimately carries both
	# headings, and a module with two subs can go either way.  Guessing
	# in those cases produces failures nobody can act on.
	my $r = check_module("$FIXTURES/Sample.pm");
	cmp_deeply(failures_of($r, 'section_vocabulary'), [],
		"a module whose headings match its shape passes");

	my $d = check_module("$FIXTURES/Decoys.pm");
	cmp_deeply(failures_of($d, 'section_vocabulary'), [],
		"a module with too few subs to infer intent is not judged");
};

subtest 'exclusion manifest' => sub {
	my $x = load_exclusions('t/pod-gate-exclusions.txt');

	is($x->{'UUID::Tiny'}{kind}, 'vendored',   "vendored entry read");
	is($x->{'Genesis::CI'}{kind}, 'deferred',  "deferred entry read");
	is($x->{'Genesis::Env::Secrets::Store::Credhub'}{kind}, 'placeholder',
		"placeholder entry read");
	like($x->{'UUID::Tiny'}{reason}, qr/\S/, "reasons are captured");

	ok(!exists $x->{'Genesis::CI::Propagation'},
		"a clean module in a deferred namespace is not excluded");
	ok(!exists $x->{'Genesis::CI::Legacy'},
		"nor one that was fixed rather than deferred");
};

subtest 'an entry with no reason is a manifest error' => sub {
	# An exclusion nobody can justify is one nobody will ever remove.
	my $tmp = "t/tmp/pod-gate-noreason.txt";
	mkdir 't/tmp' unless -d 't/tmp';
	open my $fh, '>', $tmp or die $!;
	print $fh "[deferred]\nSome::Module\n";
	close $fh;

	eval {load_exclusions($tmp)};
	like($@, qr/Some::Module/, "names the entry that lacks a reason");
	unlink $tmp;
};

done_testing;
