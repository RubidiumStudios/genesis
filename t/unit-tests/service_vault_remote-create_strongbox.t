#!/usr/bin/env perl
# create builds the `safe target` command for a target Genesis is
# provisioning itself, and it only ever knew how to say --no-strongbox.
#
# That was sufficient while safe defaulted Strongbox on: saying nothing
# meant on.  Since safe made it opt-in, saying nothing means off, so Genesis
# could no longer create a target with Strongbox enabled at all -- and the
# vault object it returned coerced an unstated flag to enabled, so it
# claimed a setting the target did not have.
#
# Both flags are era-appropriate on either safe: --strongbox is ignored by
# builds that default it on (they omit the key for that state anyway), and
# --no-strongbox is ignored by builds that default it off.  Passing the one
# that matches the intent is correct against both.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;

use_ok 'Service::Vault';
use_ok 'Service::Vault::Remote';

$ENV{GENESIS_OUTPUT_COLUMNS} = 200;
$ENV{NOCOLOR} = 1;

# Run create with everything external stubbed, returning the safe command
# it built and the vault object it produced.
sub create_with {
	my (%opts) = @_;
	my @captured;

	no warnings 'redefine';
	local *Service::Vault::default = sub {undef};   # no target to restore
	local *Service::Vault::Remote::run = sub {
		my @args = @_;
		shift @args if ref($args[0]) eq 'HASH';
		# The restore-previous-target call is not the one under test.
		push(@captured, [@args]) if $args[1] && $args[1] eq 'target' && @args > 2;
		return ('', 0, '');
	};
	use warnings 'redefine';

	my $vault = Service::Vault::Remote->create(
		'https://vault.example.com', 'ops', %opts
	);
	return ($captured[0] // [], $vault);
}

subtest 'an enabled strongbox is asked for explicitly' => sub {
	plan tests => 2;

	my ($cmd, $vault) = create_with(strongbox => 1);
	ok(scalar(grep {$_ eq '--strongbox'} @$cmd),
		'safe target is given --strongbox');
	is($vault->strongbox, 1, 'and the vault object records it as enabled');
};

subtest 'a disabled strongbox still says so' => sub {
	plan tests => 2;

	my ($cmd, $vault) = create_with(strongbox => 0);
	ok(scalar(grep {$_ eq '--no-strongbox'} @$cmd),
		'safe target is given --no-strongbox');
	is($vault->strongbox, 0, 'and the vault object records it as disabled');
};

subtest 'no opinion asks for neither' => sub {
	plan tests => 3;

	# Genesis has nothing to say, so it must not make safe say anything
	# either -- whichever way that build happens to default.
	my ($cmd, $vault) = create_with();
	ok(!scalar(grep {$_ eq '--strongbox'} @$cmd), 'no --strongbox');
	ok(!scalar(grep {$_ eq '--no-strongbox'} @$cmd), 'no --no-strongbox');
	is($vault->strongbox, undef, 'and the vault object stays unstated');
};

subtest 'the legacy no_strongbox option still works' => sub {
	plan tests => 2;

	# attach and other callers passed no_strongbox before this change.
	my ($cmd, $vault) = create_with(no_strongbox => 1);
	ok(scalar(grep {$_ eq '--no-strongbox'} @$cmd),
		'no_strongbox => 1 still produces --no-strongbox');
	is($vault->strongbox, 0, 'and records the vault as disabled');
};

subtest 'the other target options are unaffected' => sub {
	plan tests => 2;

	my ($cmd) = create_with(skip_verify => 1, namespace => 'ns1', strongbox => 1);
	ok(scalar(grep {$_ eq '-k'} @$cmd), 'skip_verify still passes -k');
	ok(scalar(grep {$_ eq 'ns1'} @$cmd), 'namespace is still passed');
};

done_testing;
