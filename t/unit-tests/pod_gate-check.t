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
