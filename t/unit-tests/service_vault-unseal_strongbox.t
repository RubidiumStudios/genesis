#!/usr/bin/env perl
# safe unseal only reaches the whole cluster when Strongbox is on.
#
# With Strongbox enabled, safe asks it for every node's seal state and
# unseals each sealed one.  Without it, safe falls back to the single
# address it is targeting, and says so on stderr:
#
#   Strongbox is off for this target: only the targeted address was
#   checked, not the whole cluster.
#
# unseal called query in list context but kept only ($out, $rc), so that
# line went nowhere.  The caller then re-checks status -- which also only
# sees the targeted node -- finds it unsealed, and reports success.  On a
# multi-node vault whose target lost its Strongbox flag to safe's opt-in
# change, that is a silent partial unseal: Genesis says it worked, most of
# the cluster is still sealed, and the one message that explained it was
# discarded.
#
# So: keep safe's stderr, and say what Strongbox has to do with it -- on
# failure, where it is the likely cause, and on success, where the result
# is not what the operator thinks it is.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;

use_ok 'Service::Vault';

$ENV{GENESIS_OUTPUT_COLUMNS} = 200;
$ENV{NOCOLOR} = 1;

# safe's actual wording, so a change upstream shows up here.
my $SAFE_HINT = "Strongbox is off for this target: only the targeted address ".
                "was checked, not the whole cluster. Enable it with --strongbox ".
                "on safe target.\n";

sub vault_with {
	my (%args) = @_;
	my $v = Service::Vault->new(
		'https://vault.example.com', 'ops', 1, '', $args{strongbox}, '/secret/'
	);
	$v->{unseal_keys} = [qw/key-one key-two key-three/];
	return $v;
}

# Drive unseal with a canned query result, capturing anything written to
# stderr along the way.
sub unseal_with {
	my (%args) = @_;
	my $vault = vault_with(strongbox => $args{strongbox});

	no warnings 'redefine';
	local *Service::Vault::query = sub {
		return ($args{out} // '', $args{rc} // 0, $args{err} // '');
	};
	use warnings 'redefine';

	my ($stderr, @result) = ('');
	{
		local *STDERR;
		open STDERR, '>', \$stderr or die "cannot capture stderr: $!";
		@result = $vault->unseal;
	}
	return (@result, $stderr);
}

subtest "safe's own explanation survives a failure" => sub {
	plan tests => 2;

	my ($out, $rc, $err, $stderr) = unseal_with(
		strongbox => undef, rc => 1, out => 'unseal failed', err => $SAFE_HINT
	);

	ok($rc, 'the failure is still reported as a failure');
	like($err.$stderr, qr/only the targeted address/,
		"safe's stderr reaches the caller instead of being dropped");
};

subtest 'an unstated strongbox is named as a probable cause' => sub {
	plan tests => 1;

	my ($out, $rc, $err, $stderr) = unseal_with(
		strongbox => undef, rc => 1, out => 'unseal failed'
	);

	# Even with safe silent, Genesis knows the target never stated the flag
	# and that this is the failure it produces.
	like($err.$stderr, qr/strongbox/i,
		'the error explains that strongbox is not enabled for this target');
};

subtest 'strongbox is not blamed when it is enabled' => sub {
	plan tests => 2;

	my ($out, $rc, $err, $stderr) = unseal_with(
		strongbox => 1, rc => 1, out => 'unseal failed: bad key'
	);

	ok($rc, 'still a failure');
	unlike($err.$stderr, qr/strongbox/i,
		'no strongbox theory is offered when strongbox is already on');
};

subtest 'a success without strongbox is qualified, not celebrated' => sub {
	plan tests => 2;

	# The dangerous case.  rc is 0 and the targeted node is unsealed, so
	# every existing check says this worked.
	my ($out, $rc, $err, $stderr) = unseal_with(
		strongbox => 0, rc => 0, out => 'Vault is now unsealed'
	);

	is($rc, 0, 'the unseal is still reported as successful');
	like($stderr, qr/targeted|cluster/i,
		'but the operator is told only one node was reached');
};

subtest 'a success with strongbox says nothing extra' => sub {
	plan tests => 2;

	my ($out, $rc, $err, $stderr) = unseal_with(
		strongbox => 1, rc => 0, out => 'Vault is now unsealed'
	);

	is($rc, 0, 'successful');
	unlike($stderr, qr/strongbox|cluster/i,
		'with no caveat, because the whole cluster was covered');
};

subtest 'the pre-flight key checks are untouched' => sub {
	plan tests => 2;

	my $no_keys = Service::Vault->new(
		'https://vault.example.com', 'ops', 1, '', 1, '/secret/'
	);
	my ($out, $rc) = $no_keys->unseal;
	ok($rc, 'no stored keys is still an error');

	$no_keys->{unseal_keys} = ['only-one'];
	(undef, $rc) = $no_keys->unseal;
	ok($rc, 'too few keys is still an error');
};

done_testing;
