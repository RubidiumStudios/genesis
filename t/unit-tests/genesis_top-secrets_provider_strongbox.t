#!perl
# Re-pointing a repository's secrets provider must not quietly change its
# Strongbox setting.
#
# set_vault rebuilds the whole secrets_provider block from the vault object,
# so an edit that only meant to change the alias and url also rewrites
# strongbox from whatever safe happens to report at that moment.  While safe
# defaulted Strongbox on that was invisible.  Since safe made it opt-in, a
# target that never stated the flag reports it as off, and a re-point turns
# Strongbox off in the config for a vault that genuinely runs one -- with no
# prompt, no warning, and no mention in the output.
#
# An unstated flag is not a statement that it is off.  When the vault does
# not say, the value already recorded in the repository is the better
# evidence and has to survive.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

# Explicit import: Genesis also exports workdir(), which would shadow the
# helper's and break every fixture below.
use Genesis qw/mkfile_or_fail/;

use_ok 'Genesis::Config';
provide_rc();
use_ok 'Genesis::Top';
use_ok 'Service::Vault::Remote';

$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{NOCOLOR} = 1;

# A repository whose secrets_provider is already recorded, optionally with a
# strongbox value.  $strongbox is the literal text to emit, or undef to omit
# the key entirely.
sub repo_with {
	my ($strongbox) = @_;
	my $tmp = workdir();
	system("mkdir -p $tmp/.genesis");
	my $sb = defined($strongbox) ? "  strongbox: $strongbox\n" : "";
	mkfile_or_fail("$tmp/.genesis/config", <<EOF);
---
version: 2
creator_version: 3.1.0
deployment_type: test
secrets_provider:
  url: https://old.example.com
  insecure: true
  namespace: ""
${sb}  alias: old-target
EOF
	return Genesis::Top->new($tmp, no_vault => 1);
}

# A vault object as all_vaults would build it: $strongbox undef means no
# safe target ever stated the flag.
sub vault_with {
	my ($strongbox) = @_;
	return Service::Vault::Remote->new(
		'https://new.example.com', 'new-target', 1, '', $strongbox, '/secret/'
	);
}

sub strongbox_after_repoint {
	my ($recorded, $vault_says) = @_;
	my $top = repo_with($recorded);
	$top->set_vault(vault => vault_with($vault_says));
	return $top->config->get('secrets_provider.strongbox');
}

subtest 'a stated flag is written through' => sub {
	plan tests => 2;

	ok(strongbox_after_repoint('false', 1),
		'a vault stating strongbox records it as enabled');

	my $off = strongbox_after_repoint('true', 0);
	ok(defined($off) && !$off,
		'a vault stating no strongbox records it as disabled');
};

subtest 'an unstated flag leaves the recorded value alone' => sub {
	plan tests => 2;

	# The regression.  Previously this wrote FALSE, silently disarming
	# Strongbox for a vault that runs one.
	ok(strongbox_after_repoint('true', undef),
		'a recorded true survives a re-point by a vault that does not say');

	my $off = strongbox_after_repoint('false', undef);
	ok(defined($off) && !$off,
		'a recorded false survives too -- preservation, not a bias to on');
};

subtest 'nothing recorded and nothing stated records nothing' => sub {
	plan tests => 1;

	# With neither side saying anything there is nothing to preserve and
	# nothing to assert.  Inventing a value here is how the ambiguity got
	# baked into every repository in the first place.
	is(strongbox_after_repoint(undef, undef), undef,
		'no strongbox key is written when neither side states one');
};

subtest 'the rest of the block still re-points' => sub {
	plan tests => 3;

	# Preserving strongbox must not accidentally pin the fields the
	# re-point was actually for.
	my $top = repo_with('true');
	$top->set_vault(vault => vault_with(undef));
	is($top->config->get('secrets_provider.url'), 'https://new.example.com',
		'url is updated');
	is($top->config->get('secrets_provider.alias'), 'new-target',
		'alias is updated');
	ok(strongbox_after_repoint('true', undef),
		'while strongbox is preserved');
};

done_testing;
