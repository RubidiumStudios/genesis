#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use Test::More;
use Test::Deep;

use_ok 'Genesis::CI::Propagation';

# DAG topology used across most tests:
#
#   mgmt (root)
#     └── lab
#           └── qa
#                 ├── np1 → prod1
#                 └── np2 → prod2

my @dag_order = qw(mgmt lab qa np1 np2 prod1 prod2);
my %parent_of = (
	lab   => 'mgmt',
	qa    => 'lab',
	np1   => 'qa',
	np2   => 'qa',
	prod1 => 'np1',
	prod2 => 'np2',
);

sub propagate {
	my (%env_changed) = @_;
	return Genesis::CI::Propagation::compute_propagation_targets(
		dag_order   => \@dag_order,
		parent_of   => \%parent_of,
		env_changed => \%env_changed,
	);
}

sub propagate_scoped {
	my ($scope, %env_changed) = @_;
	return Genesis::CI::Propagation::compute_propagation_targets(
		dag_order   => \@dag_order,
		parent_of   => \%parent_of,
		env_changed => \%env_changed,
		scope       => $scope,
	);
}

# =========================================================================
# Scenario 1: Pure shared change
# A change to a shared file (used by all) should only target the root.
# =========================================================================
subtest 'scenario 1: pure shared change targets root only' => sub {
	my $targets = propagate(
		mgmt  => ['lmelt.yml'],
		lab   => ['lmelt.yml'],
		qa    => ['lmelt.yml'],
		np1   => ['lmelt.yml'],
		np2   => ['lmelt.yml'],
		prod1 => ['lmelt.yml'],
		prod2 => ['lmelt.yml'],
	);

	cmp_deeply $targets, {
		mgmt => bag('lmelt.yml'),
	}, "only mgmt is an entry point for shared file";
};

# =========================================================================
# Scenario 2: Pure leaf change
# A file used only by a non-root env goes directly to that env.
# =========================================================================
subtest 'scenario 2: pure leaf change targets leaf directly' => sub {
	my $targets = propagate(
		lab => ['lmelt-vsphere-canwest-1-lab.yml'],
	);

	cmp_deeply $targets, {
		lab => bag('lmelt-vsphere-canwest-1-lab.yml'),
	}, "lab is direct entry point for its own leaf file";
};

# =========================================================================
# Scenario 3: Mixed shared + leaf in one commit
# Shared file overlap blocks the leaf env — must wait for cascade.
# =========================================================================
subtest 'scenario 3: mixed shared + leaf blocks downstream' => sub {
	my $targets = propagate(
		mgmt => ['lmelt.yml'],
		lab  => ['lmelt.yml', 'lmelt-vsphere-canwest-1-lab.yml'],
	);

	cmp_deeply $targets, {
		mgmt => bag('lmelt.yml'),
	}, "lab is blocked because lmelt.yml overlaps with mgmt";
};

# =========================================================================
# Scenario 4: Independent changes to different tiers
# No overlap between the entry points — both propagate simultaneously.
# =========================================================================
subtest 'scenario 4: independent changes create parallel entry points' => sub {
	my $targets = propagate(
		mgmt => ['lmelt-vsphere-canwest-1-mgmt.yml'],
		qa   => ['ops/prod-extras.yml'],
	);

	cmp_deeply $targets, {
		mgmt => bag('lmelt-vsphere-canwest-1-mgmt.yml'),
		qa   => bag('ops/prod-extras.yml'),
	}, "mgmt and qa are independent entry points";
};

# =========================================================================
# Scenario 5: New commit while previous in-flight (after mgmt caught up)
# mgmt already has the shared file (diff empty), lab gets both.
# =========================================================================
subtest 'scenario 5: lab unblocked when mgmt is caught up' => sub {
	# mgmt was already propagated — diff is empty
	# lab still needs lmelt.yml (from earlier commit) + lab.yml (new commit)
	my $targets = propagate(
		lab => ['lmelt.yml', 'lmelt-vsphere-canwest-1-lab.yml'],
	);

	cmp_deeply $targets, {
		lab => bag('lmelt.yml', 'lmelt-vsphere-canwest-1-lab.yml'),
	}, "lab is entry point when mgmt has no changes (already caught up)";
};

# =========================================================================
# Scenario 6: Superseded propagation
# New propagation overwrites previous — latest desired state wins.
# =========================================================================
subtest 'scenario 6: superseded propagation targets same env' => sub {
	# mgmt's diff shows lmelt.yml changed (new version superseding old)
	my $targets = propagate(
		mgmt  => ['lmelt.yml'],
		lab   => ['lmelt.yml'],
		qa    => ['lmelt.yml'],
	);

	cmp_deeply $targets, {
		mgmt => bag('lmelt.yml'),
	}, "mgmt receives superseding change, downstream blocked";
};

# =========================================================================
# Scenario 7: The "lost no-op" — lab.yml only change with shared pending
# When using HEAD: mgmt is caught up, lab gets everything.
# =========================================================================
subtest 'scenario 7: no-op commit picked up on next propagation' => sub {
	# State: mgmt already has lmelt.yml (propagated earlier)
	# lab.yml changed in a later commit
	# lab still needs lmelt.yml (never propagated to lab)
	# Using HEAD: mgmt diff is empty (caught up), lab gets both
	my $targets = propagate(
		lab => ['lmelt.yml', 'lmelt-vsphere-canwest-1-lab.yml'],
	);

	cmp_deeply $targets, {
		lab => bag('lmelt.yml', 'lmelt-vsphere-canwest-1-lab.yml'),
	}, "lab gets both files when mgmt is caught up";
};

# =========================================================================
# Scenario 8: Rapid-fire commits
# Multiple commits accumulated — single propagation captures all.
# =========================================================================
subtest 'scenario 8: rapid-fire commits handled correctly' => sub {
	# Commit A: lmelt.yml
	# Commit B: lab.yml
	# Commit C: lmelt.yml again
	# Single propagation at HEAD (C):
	my $targets = propagate(
		mgmt => ['lmelt.yml'],
		lab  => ['lmelt.yml', 'lmelt-vsphere-canwest-1-lab.yml'],
		qa   => ['lmelt.yml'],
	);

	cmp_deeply $targets, {
		mgmt => bag('lmelt.yml'),
	}, "only mgmt targeted — lab/qa blocked by shared lmelt.yml overlap";
};

# =========================================================================
# After mgmt deploys (rapid-fire follow-up)
# =========================================================================
subtest 'scenario 8b: after mgmt deploys, lab gets all accumulated changes' => sub {
	# mgmt caught up (diff empty), lab still needs both files
	my $targets = propagate(
		lab => ['lmelt.yml', 'lmelt-vsphere-canwest-1-lab.yml'],
		qa  => ['lmelt.yml'],
	);

	cmp_deeply $targets, {
		lab => bag('lmelt.yml', 'lmelt-vsphere-canwest-1-lab.yml'),
	}, "lab is entry point, qa blocked by lmelt.yml overlap with lab";
};

# =========================================================================
# Scoped propagation (simulating cascade from env branch)
# After mgmt deploys: scope is mgmt's children and descendants only.
# =========================================================================
subtest 'scoped propagation: cascade after mgmt deploy' => sub {
	my $targets = propagate_scoped(
		[qw(lab qa np1 np2 prod1 prod2)],
		lab  => ['lmelt.yml', 'lmelt-vsphere-canwest-1-lab.yml'],
		qa   => ['lmelt.yml'],
		np1  => ['lmelt.yml'],
		np2  => ['lmelt.yml'],
	);

	cmp_deeply $targets, {
		lab => bag('lmelt.yml', 'lmelt-vsphere-canwest-1-lab.yml'),
	}, "lab is entry point within scope, qa/np blocked by overlap";
};

# =========================================================================
# Deep chain: change only affects prod1
# =========================================================================
subtest 'deep chain: leaf change at prod1 skips all intermediates' => sub {
	my $targets = propagate(
		prod1 => ['lmelt-vsphere-canwest-1-prod1.yml'],
	);

	cmp_deeply $targets, {
		prod1 => bag('lmelt-vsphere-canwest-1-prod1.yml'),
	}, "prod1 is direct entry point, all intermediates skipped";
};

# =========================================================================
# Fan-out: change affects both np branches independently
# =========================================================================
subtest 'fan-out: independent changes to np1 and np2' => sub {
	my $targets = propagate(
		np1 => ['lmelt-vsphere-canwest-1-np1.yml'],
		np2 => ['lmelt-vsphere-canwest-1-np2.yml'],
	);

	cmp_deeply $targets, {
		np1 => bag('lmelt-vsphere-canwest-1-np1.yml'),
		np2 => bag('lmelt-vsphere-canwest-1-np2.yml'),
	}, "np1 and np2 are independent entry points (different parents)";
};

# =========================================================================
# No changes at all
# =========================================================================
subtest 'no changes: empty result' => sub {
	my $targets = propagate();
	cmp_deeply $targets, {}, "no changes → no targets";
};

# =========================================================================
# Overlap through grandparent (not just direct parent)
# =========================================================================
subtest 'grandparent overlap: qa blocked by mgmt via shared file' => sub {
	my $targets = propagate(
		mgmt => ['lmelt.yml'],
		qa   => ['lmelt.yml', 'lmelt-vsphere-canwest-1-qa.yml'],
	);

	# qa's ancestor chain: qa → lab → mgmt
	# mgmt has lmelt.yml, qa has lmelt.yml → overlap
	cmp_deeply $targets, {
		mgmt => bag('lmelt.yml'),
	}, "qa blocked by grandparent mgmt through lmelt.yml overlap";
};

# =========================================================================
# Partial overlap: some files overlap, some don't — still blocked
# =========================================================================
subtest 'partial overlap: any shared file blocks the env' => sub {
	my $targets = propagate(
		mgmt => ['lmelt.yml'],
		lab  => ['lmelt.yml', 'ops/lab-only.yml'],
	);

	cmp_deeply $targets, {
		mgmt => bag('lmelt.yml'),
	}, "lab blocked even though ops/lab-only.yml is independent — lmelt.yml overlaps";
};

done_testing;
