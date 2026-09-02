#!/usr/bin/env perl
# Strongbox has three states, not two: on, off, and nobody ever said.
#
# safe encodes the flag in ~/.saferc under two different keys depending on
# its vintage, and each vintage omits the key for its own default.  Builds
# up to v1.10.0 write no_strongbox only when Strongbox is disabled; builds
# from v1.20.0 write strongbox only when it is enabled.  An absent key
# therefore means opposite things in the two eras, and `safe targets --json`
# reports only the conclusion its own default produced -- never whether
# anyone stated it.
#
# Reading that conclusion as though it were an intent is what let a safe
# upgrade silently disarm Strongbox on targets that had it, and what made
# Genesis refuse to resolve a vault over a flag that does not affect which
# secrets are readable.  So the intent is read from the file, honouring
# either key, and absence is preserved as absence rather than defaulted.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;

use_ok 'Service::Vault';

# Each case gets its own HOME so a stray .saferc cannot leak between them.
sub with_saferc {
	my ($body, $alias) = @_;
	my $home = workdir;
	local $ENV{HOME} = $home;
	open my $fh, '>', "$home/.saferc" or die "cannot write test .saferc: $!";
	print $fh $body;
	close $fh;
	return Service::Vault::strongbox_intent($alias // 'ops');
}

sub saferc_with {
	my ($keys) = @_;
	return <<"RC";
version: 1
current: ops
vaults:
  ops:
    url: https://vault.example.com
    token: "s.abc123"
    skip_verify: true
$keys
RC
}

subtest 'the current key is honoured in both polarities' => sub {
	plan tests => 2;

	# v1.20.0+ writes `strongbox` and only when it is on.
	is(with_saferc(saferc_with("    strongbox: true")), 1,
		'strongbox: true reads as enabled');

	# It can still appear as false if written by hand or by a future safe
	# that stops omitting it; an explicit false is a statement, not silence.
	is(with_saferc(saferc_with("    strongbox: false")), 0,
		'strongbox: false reads as explicitly disabled');
};

subtest 'the legacy key is honoured, inverted' => sub {
	plan tests => 2;

	# v1.4.0 through v1.10.0 wrote no_strongbox, and only when off.
	is(with_saferc(saferc_with("    no_strongbox: true")), 0,
		'no_strongbox: true reads as disabled');

	is(with_saferc(saferc_with("    no_strongbox: false")), 1,
		'no_strongbox: false reads as enabled');
};

subtest 'silence is preserved, not defaulted' => sub {
	plan tests => 3;

	# This is the case that matters.  Every target written by a safe older
	# than v1.20.0 with Strongbox ON looks exactly like this, because that
	# era omitted the key for its own default.  Answering 1 here would
	# re-invent the old default; answering 0 would adopt the new one.  The
	# honest answer is that the file does not say.
	is(with_saferc(saferc_with("")), undef,
		'neither key present reads as unspecified');

	is(with_saferc(saferc_with(""), 'not-a-target'), undef,
		'an alias absent from the file reads as unspecified');

	my $home = workdir;
	local $ENV{HOME} = $home;   # no .saferc at all
	is(Service::Vault::strongbox_intent('ops'), undef,
		'a missing .saferc reads as unspecified, not as an error');
};

subtest 'the current key wins over the legacy key' => sub {
	plan tests => 1;

	# safe's own migration rewrites no_strongbox into strongbox, so a file
	# can carry both mid-upgrade.  The current key is the migrated intent.
	is(with_saferc(saferc_with("    strongbox: true\n    no_strongbox: true")), 1,
		'strongbox takes precedence when both keys appear');
};

subtest 'a malformed .saferc does not take the run down' => sub {
	plan tests => 1;

	# The file belongs to safe, not to us.  If it cannot be parsed there is
	# nothing to report about intent, and dying here would break every
	# command over a diagnostic flag.
	is(with_saferc("this: is: not: valid: yaml:\n\t- and neither is this\n"), undef,
		'unparseable .saferc reads as unspecified');
};

subtest 'new() keeps an unstated strongbox unstated' => sub {
	plan tests => 3;

	# Previously new() coerced undef to 1, which is precisely how safe's
	# old default became indistinguishable from a deliberate choice.
	my $unstated = Service::Vault->new(
		'https://vault.example.com', 'ops', 1, '', undef, '/secret/'
	);
	is($unstated->strongbox, undef, 'undef strongbox stays undef');

	my $on = Service::Vault->new(
		'https://vault.example.com', 'ops', 1, '', 1, '/secret/'
	);
	is($on->strongbox, 1, 'an explicit 1 is preserved');

	my $off = Service::Vault->new(
		'https://vault.example.com', 'ops', 1, '', 0, '/secret/'
	);
	is($off->strongbox, 0, 'an explicit 0 is preserved');
};

subtest 'the descriptor does not turn silence into a disable' => sub {
	plan tests => 3;

	# build_descriptor feeds BOSH_EXODUS_VAULT and the vault descriptor
	# handed to kits and CI, and the parser on the other end reads a
	# no-strongbox clause as an explicit disable.  Emitting one for a
	# target that merely never stated the flag would propagate an opinion
	# nobody holds into every downstream consumer.
	my $unstated = Service::Vault->new(
		'https://vault.example.com', 'ops', 1, '', undef, '/secret/'
	);
	unlike($unstated->build_descriptor, qr/no-strongbox/,
		'an unstated strongbox emits no no-strongbox clause');

	my $off = Service::Vault->new(
		'https://vault.example.com', 'ops', 1, '', 0, '/secret/'
	);
	like($off->build_descriptor, qr/no-strongbox/,
		'an explicit disable still emits one');

	my $on = Service::Vault->new(
		'https://vault.example.com', 'ops', 1, '', 1, '/secret/'
	);
	unlike($on->build_descriptor, qr/no-strongbox/,
		'an explicit enable does not');
};

done_testing;
