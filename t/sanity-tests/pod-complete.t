#!perl
# Every module in lib/ carries POD that is present, complete, correctly
# filed, and parseable -- or is listed in t/pod-gate-exclusions.txt with a
# reason.
#
# A sanity test rather than a build step so it runs wherever `make test`
# runs: locally before a push, and in CI. The POD is published with the
# release now, so an omission here ships.

use strict;
use warnings;

use lib 'lib';
use lib 't';
use Test::More;
use File::Find;

# Missing PPI fails rather than skips.  A gate that turns itself off when
# a dependency is absent reports success on exactly the run that most
# needs to fail -- a fresh CI image where nothing has been checked at all.
unless (eval {require PPI; 1}) {
	fail("PPI is required by the POD gate -- run `make test-deps`");
	done_testing;
	exit 0;
}

use PodGate::Check qw/check_module load_exclusions module_name_for/;

my $MANIFEST = 't/pod-gate-exclusions.txt';

my $excluded = eval {load_exclusions($MANIFEST)};
BAIL_OUT("$MANIFEST could not be read: $@") if $@;

my @modules;
find(sub {push @modules, $File::Find::name if /\.pm$/}, 'lib');
@modules = sort @modules;
BAIL_OUT("no modules found under lib/") unless @modules;

my %deferred;
for my $pm (@modules) {
	my $module = module_name_for($pm);

	if (my $x = $excluded->{$module}) {
		$deferred{$module} = $x if $x->{kind} eq 'deferred';
		next;
	}

	my $result = check_module($pm);
	unless (ok($result->{ok}, $module)) {
		diag(sprintf("    %-18s %s", $_->{check}, $_->{detail}))
			for @{$result->{failures}};
	}
}

# Announced, not asserted.  These are known gaps with a recorded reason;
# the point is that nobody gets to forget they are still open.
if (%deferred) {
	diag(sprintf("%d module(s) deferred and still undocumented; see %s",
		scalar keys %deferred, $MANIFEST));
}

done_testing;
