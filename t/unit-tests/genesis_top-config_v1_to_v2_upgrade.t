#!perl
use strict;
use warnings;
use utf8;

# Explicit coverage for the v1 -> v2 deployment-repo config auto-
# upgrade path at lib/Genesis/Top.pm:1266-1276.  Previously this code
# path was only exercised as a side-effect of various tests loading
# legacy fixtures under t/repos/, which dirtied those fixtures on
# every test run (they got rewritten as v2).  This test uses fresh
# generated directories so the upgrade is exercised hygienically.
#
# A v1 config is detected when:
#   - the `version:` key is absent (defaults to 1), OR
#   - the `version:` value matches a semver pattern (older format
#     stored the genesis version that wrote the config).
#
# The upgrade is automatic when $Genesis::RC has
# `automatic_config_upgrade` set to 'yes' or 'silent' (the latter
# also suppresses the "preparing to upgrade" diff banner).

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;
use File::Path qw/make_path/;

use_ok 'Genesis::Top';
use_ok 'Genesis::Config';

provide_rc();
# Enable automatic upgrade in silent mode so the test doesn't bail
# on `unless in_controlling_terminal` (Top.pm:1273) and doesn't try
# to show the upgrade diff (Top.pm:1384).
$Genesis::RC->set('automatic_config_upgrade', 'silent');

# Helper: build a fresh deployment repo dir with a v1-style config
# and return its absolute path.
sub make_v1_repo {
	my ($subdir, $content) = @_;
	my $repo = workdir($subdir);
	make_path("$repo/.genesis");
	open my $fh, '>', "$repo/.genesis/config"
		or die "cannot open $repo/.genesis/config: $!";
	print $fh $content;
	close $fh;
	return $repo;
}

# Slurp the on-disk config for shape assertions
sub slurp_config {
	my ($repo) = @_;
	open my $fh, '<', "$repo/.genesis/config"
		or die "cannot read $repo/.genesis/config: $!";
	local $/;
	my $c = <$fh>;
	close $fh;
	return $c;
}

# ---------------------------------------------------------------------------
# Case A: v1 via ABSENT version field (the most common legacy case)
# ---------------------------------------------------------------------------

subtest 'v1 (no version field) -> v2 auto-upgrade' => sub {
	plan tests => 8;

	my $repo = make_v1_repo('v1-absent', "deployment_type: bosh\n");
	local $Genesis::VERSION = '3.2.0-rc.1';

	my $top = Genesis::Top->new($repo);
	# Touch ->type to force config validation (which triggers the
	# upgrade path at Top.pm:1262 _validate_config).
	is($top->type, 'bosh', 'type accessor reflects preserved deployment_type');

	is($top->config->get('version'),         2,                'in-memory: version bumped to 2');
	is($top->config->get('deployment_type'), 'bosh',           'in-memory: deployment_type preserved');
	is($top->config->get('creator_version'), 'Unknown',        'in-memory: creator_version is the Unknown sentinel');
	is($top->config->get('updater_version'), '3.2.0-rc.1',     'in-memory: updater_version is current $Genesis::VERSION');

	# Re-read from disk to confirm the upgrade was persisted
	my $disk = slurp_config($repo);
	like($disk, qr/version:\s*2/,             'on-disk: version: 2');
	like($disk, qr/deployment_type:\s*bosh/,  'on-disk: deployment_type preserved');
	like($disk, qr/updater_version:\s*3\.2\.0-rc\.1/, 'on-disk: updater_version recorded');
};

# ---------------------------------------------------------------------------
# Case B: v1 via SEMVER value in version field
# (older configs stored the genesis version that wrote them as
#  the `version` value; that pattern is treated as v1 too)
# ---------------------------------------------------------------------------

subtest 'v1 (semver as version) -> v2 auto-upgrade preserves source version' => sub {
	plan tests => 5;

	my $repo = make_v1_repo('v1-semver', <<'EOF');
deployment_type: cf
version: 2.7.1
EOF
	local $Genesis::VERSION = '3.2.0-rc.1';

	my $top = Genesis::Top->new($repo);
	is($top->type, 'cf', 'type accessor');

	is($top->config->get('version'),         2,            'version normalised to integer 2');
	is($top->config->get('creator_version'), '2.7.1',      'creator_version captured from the original semver "version" field');
	is($top->config->get('updater_version'), '3.2.0-rc.1', 'updater_version is current $Genesis::VERSION');

	my $disk = slurp_config($repo);
	like($disk, qr/creator_version:\s*2\.7\.1/, 'on-disk: creator_version persisted');
};

# ---------------------------------------------------------------------------
# Case C: idempotency -- loading a v2 config does NOT trigger another
# upgrade (verifies we don't double-upgrade or rewrite the timestamp
# every load).
# ---------------------------------------------------------------------------

subtest 'v2 config loads idempotently (no re-upgrade)' => sub {
	plan tests => 3;

	# First load: v1 -> v2 upgrade fires
	my $repo = make_v1_repo('v2-idempotent', "deployment_type: shield\n");
	local $Genesis::VERSION = '3.2.0-rc.1';
	Genesis::Top->new($repo);   # triggers upgrade

	# Capture the disk state after the upgrade
	my $after_upgrade = slurp_config($repo);
	like($after_upgrade, qr/version:\s*2/, 'first load upgraded to v2');

	# Second load: should NOT trigger another upgrade (config already v2)
	# We pin $Genesis::VERSION to a DIFFERENT value -- if a re-upgrade
	# fired, it would overwrite updater_version with the new value.
	{
		local $Genesis::VERSION = '999.999.999';
		Genesis::Top->new($repo);
	}

	my $after_second = slurp_config($repo);
	unlike($after_second, qr/updater_version:\s*999\.999\.999/,
		'second load did NOT re-upgrade (updater_version not bumped to 999)');
	like($after_second, qr/updater_version:\s*3\.2\.0-rc\.1/,
		'updater_version still reflects the first (upgrade) load');
};

# ---------------------------------------------------------------------------
# Case D: explicit creator_version in source is preserved (vs Unknown sentinel)
# ---------------------------------------------------------------------------

subtest 'v1 with explicit creator_version is preserved' => sub {
	plan tests => 2;

	my $repo = make_v1_repo('v1-explicit-creator', <<'EOF');
deployment_type: bosh
creator_version: 2.5.0
EOF
	local $Genesis::VERSION = '3.2.0-rc.1';

	my $top = Genesis::Top->new($repo);
	is($top->type, 'bosh', 'type accessor');
	is($top->config->get('creator_version'), '2.5.0',
		'explicit creator_version preserved (not overwritten by Unknown sentinel)');
};

done_testing;
