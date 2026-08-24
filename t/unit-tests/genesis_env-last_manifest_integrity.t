#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Exception;

use Genesis;
use_ok 'Genesis::Config';
# Initialize $Genesis::RC for tests that consult global config
provide_rc();

use_ok 'Genesis::Top';
use_ok 'Genesis::Env';

# The integrity check guards `bosh create-env` against deploying with a state
# file that belongs to a different manifest than the one about to be deployed.
# It compares the sha1 recorded in exodus against the sha1 of the manifest in
# the local repository, both of which last_deployed_manifest already provides.

sub last_manifest {
	my (%overrides) = @_;
	return {
		source        => 'repository',
		manifest_sha1 => 'a' x 40,
		manifest      => {
			source => 'repository',
			path   => '/repo/.genesis/manifests/test-env.yml',
			sha1   => 'a' x 40,
		},
		state => {
			source => 'repository',
			path   => '/repo/.genesis/manifests/test-env-state.json',
			sha1   => 'b' x 40,
		},
		%overrides,
	};
}

# ===========================================================================
# _last_manifest_integrity_issue - matching sha1s raise no issue
# ===========================================================================
subtest 'matching sha1s raise no issue' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	is($env->_last_manifest_integrity_issue(last_manifest()), undef,
		"no issue when the repository manifest matches the exodus sha1");

	done_testing;
};

# ===========================================================================
# _last_manifest_integrity_issue - a JSON state file is not a manifest
#
# Regression: the check used to derive the manifest path by substituting
# `-state.yml` for `.yml`. create-env writes `-state.json`, so the
# substitution never fired and the check hashed the state file instead of
# the manifest, reporting a mismatch on every deploy.
# ===========================================================================
subtest 'json state file does not trigger a false mismatch' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	my $manifest = last_manifest(
		state => {
			source => 'repository',
			path   => '/repo/.genesis/manifests/test-env-state.json',
			sha1   => 'b' x 40,
		}
	);

	is($env->_last_manifest_integrity_issue($manifest), undef,
		"a create-env environment with a JSON state file reports no issue");

	done_testing;
};

# ===========================================================================
# _last_manifest_integrity_issue - genuine mismatch is reported
# ===========================================================================
subtest 'mismatched sha1s report a stale repository manifest' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	my $manifest = last_manifest(manifest_sha1 => 'c' x 40);

	my $issue = $env->_last_manifest_integrity_issue($manifest);
	ok(defined($issue), "an issue is reported when the sha1s differ");
	like($issue, qr/does not match the manifest in the local repository/,
		"the issue names the mismatch");

	done_testing;
};

# ===========================================================================
# _last_manifest_integrity_issue - missing exodus sha1 is reported
# ===========================================================================
subtest 'missing exodus sha1 is reported' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	for my $missing (undef, '') {
		my $issue = $env->_last_manifest_integrity_issue(
			last_manifest(manifest_sha1 => $missing)
		);
		ok(defined($issue), "an issue is reported when the exodus sha1 is missing");
		like($issue, qr/sha1 sum missing from exodus data/,
			"the issue names the missing sha1");
	}

	done_testing;
};

# ===========================================================================
# _last_manifest_integrity_issue - exodus-sourced manifests are not checked
#
# Deployment archives carry their own manifest, so there is no local copy
# that could have drifted.
# ===========================================================================
subtest 'exodus-sourced manifests skip the check' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	my $manifest = last_manifest(
		source        => 'exodus-deployments',
		manifest_sha1 => 'c' x 40,
	);

	is($env->_last_manifest_integrity_issue($manifest), undef,
		"no issue for a manifest retrieved from the deployment archive");

	done_testing;
};

# ===========================================================================
# _last_manifest_integrity_issue - nothing to check without a local manifest
# ===========================================================================
subtest 'absent local manifest skips the check' => sub {
	local $ENV{GENESIS_TESTING} = 1;

	my $env = make_env_with_kit('t/src/simple', 'test-env');

	is($env->_last_manifest_integrity_issue({not_found => 1}), undef,
		"no issue when no previous manifest was found");
	is($env->_last_manifest_integrity_issue(undef), undef,
		"no issue when no manifest data is supplied at all");

	done_testing;
};

done_testing;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
