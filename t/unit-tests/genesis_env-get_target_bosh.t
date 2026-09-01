#!/usr/bin/env perl
# get_target_bosh's failure message named one of three possible causes,
# and picked the wrong one.  It bails when $bosh is falsy, which happens
# when the exodus read errored, when the read succeeded but carried no
# usable connection details, or when the fallback to a local BOSH alias
# found nothing.  Reporting all three as "may be due to not having read
# access" sent operators to check permissions they already had.
#
# It also discarded the underlying error: the read is wrapped in a bare
# eval whose $@ was never inspected, so a genuine vault failure produced
# no explanation anywhere except the trace log.
use strict;
use warnings;
use utf8;

use lib 't';
use lib 'lib';
use helper;
use Test::More;
use Test::Exception;

$ENV{GENESIS_OUTPUT_COLUMNS} = 200;
$ENV{NOCOLOR} = 1;
$ENV{GENESIS_IGNORE_EVAL} = '';

use_ok 'Genesis::Env';
provide_rc();

# A create-env director, so get_target_bosh takes the 'self' branch
# without needing a controlling terminal to disambiguate.
sub env_with {
	my (%opts) = @_;
	my $vault = mock "Test::Vault::GTB$opts{n}" => {
		get => $opts{vault_get},
		url => 'https://vault.example.com',
	};
	my $env = bless {name => 'test-director'}, 'Genesis::Env';
	return ($env, $vault);
}

sub bail_from {
	my (%opts) = @_;
	my ($env, $vault) = env_with(%opts);

	no warnings 'redefine';
	local *Genesis::Env::is_bosh_director = sub {1};
	local *Genesis::Env::use_create_env   = sub {1};
	local *Genesis::Env::exodus_base      = sub {'/secret/exodus/test-director/bosh'};
	local *Genesis::Env::vault            = sub {$vault};
	local *Genesis::Env::name             = sub {'test-director'};
	local *Service::BOSH::Director::from_alias  = sub {$opts{alias}};
	local *Service::BOSH::Director::from_exodus = sub {'BOSH-OBJECT'};
	use warnings 'redefine';

	my $result = eval {$env->get_target_bosh({self => 1})};
	return ($result, $@);
}

subtest 'a vault read that fails says so, and says what failed' => sub {
	plan tests => 3;

	# The read died.  Previously the eval swallowed it and the operator
	# was told to check read access, with no sign of the actual error.
	my ($r, $err) = bail_from(
		n => 1,
		vault_get => sub {die "connection refused at vault.example.com\n"},
		alias     => undef,
	);
	ok(!$r, 'no director is returned');
	like($err, qr/connection refused/,
		'the underlying error reaches the operator');
	unlike($err, qr/not having read access/,
		'and it is not misreported as a permissions problem');
};

subtest 'a read that returns nothing usable says the data is absent' => sub {
	plan tests => 3;

	# The read worked; the record has no url/admin_password.  For a
	# create-env director that means the state was never uploaded, which
	# is a different problem from being unable to read it.
	my ($r, $err) = bail_from(
		n => 2,
		vault_get => sub {return {}},
		alias     => undef,
	);
	ok(!$r, 'no director is returned');
	like($err, qr/it is empty/,
		'the message says the record is empty');
	like($err, qr/may not have been deployed yet/,
		'and offers the likely reason rather than blaming access');
};

subtest 'an incomplete record is distinguished from an empty one' => sub {
	plan tests => 2;

	# Half a record is its own failure: something wrote here, but not
	# what is needed to connect.
	my ($r, $err) = bail_from(
		n => 3,
		vault_get => sub {return {url => 'https://10.0.0.1:25555'}},
		alias     => undef,
	);
	like($err, qr/it is incomplete: missing admin_password/,
		'the message names exactly which key was missing');
	unlike($err, qr/it is empty/,
		'and does not confuse a partial record with an absent one');
};

subtest 'the vault path is still reported in every case' => sub {
	plan tests => 2;

	# It is the one piece of the old message that was always right.
	for my $case ([4, sub {die "boom\n"}], [5, sub {return {}}]) {
		my ($r, $err) = bail_from(n => $case->[0], vault_get => $case->[1], alias => undef);
		like($err, qr{/secret/exodus/test-director/bosh},
			"the path is named (case $case->[0])");
	}
};

subtest 'a good read still returns a director' => sub {
	plan tests => 1;

	my ($r, $err) = bail_from(
		n => 6,
		vault_get => sub {return {url => 'https://10.0.0.1:25555', admin_password => 'pw'}},
		alias     => undef,
	);
	is($r, 'BOSH-OBJECT', 'a complete exodus record resolves to a director');
};

done_testing;
