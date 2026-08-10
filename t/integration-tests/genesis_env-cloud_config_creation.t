#!perl
#
# can_build_cloud_configs design matrix (currently a SCAFFOLD; this
# file is intentionally registered commented-out in t/test-manifest.txt
# until the function's semantics are finalised).
#
# The capability check Genesis::Env::can_build_cloud_configs answers
# "can this env build a cloud-config itself, vs. relying on one
# supplied externally?".  Today, OCFP is the only strategy that
# produces cloud-configs from genesis; future strategies (plain kit-
# hook driven, custom directives, etc.) may extend the set.
#
# The matrix below enumerates every interaction we want covered.
# Each row gets its own subtest so failures point at a single cell.
# Subtests are marked TODO where the source-side semantic is not yet
# decided: two rows of the matrix depend on whether a cloud-config
# supplied externally should count as buildable, which is undecided.

use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Exception;

use_ok 'Genesis::Config';
provide_rc();

use_ok 'Genesis::Env';
use Genesis::Top;
use Genesis;

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# Build a Top + env with the given knobs.
#
#   features          arrayref of kit.features (e.g. ['ocfp'])
#   kit_path          path to a kit fixture (default: t/src/simple)
#   min_version       repo + env min_version (default: '3.1.0-rc.20')
#   manage_cc         optional 0/1 for genesis.manage-cloud-configs
#
# Caller is responsible for the kit fixture having (or not having) a
# 'cloud-config' hook in t/src/<kit>/hooks/cloud-config.
sub make_cc_env {
	my (%opts) = @_;
	my $name        = $opts{name}     // 'cc-test';
	my $features    = $opts{features} // [];
	my $kit_path    = $opts{kit_path} // 't/src/simple';
	my $min_version = $opts{min_version} // '3.1.0-rc.20';

	my $top = make_top(name => $name, minimum_version => $min_version, no_vault => 1);
	$top->link_dev_kit($kit_path);

	my $feature_yaml = @$features
		? "  features:\n" . join('', map { "    - $_\n" } @$features)
		: "";
	my $manage_yaml = exists $opts{manage_cc}
		? "  manage-cloud-configs: " . ($opts{manage_cc} ? 'true' : 'false') . "\n"
		: "";

	put_file($top->path("$name.yml"), <<EOF);
---
kit:
  name:    dev
  version: latest
$feature_yaml
genesis:
  env: $name
  min_version: $min_version
$manage_yaml
EOF
	return $top->load_env($name);
}

# ===========================================================================
# Matrix axes:
#   (a) env has OCFP feature       -- via kit.features: [ocfp]
#   (b) kit has a cloud-config hook -- via fixture kit choice
#   (c) genesis.manage-cloud-configs flag  -- absent/true/false
#   (d) effective minimum_version  -- >= 3.1.0-rc.9 (passes) vs older
# ===========================================================================

# --- below-feature-floor: always NO ------------------------------------
subtest 'below feature floor (min_version < 3.1.0-rc.9) -> false' => sub {
	local $TODO = 'matrix scaffold; behaviour not yet pinned';
	plan tests => 1;
	my $env = make_cc_env(min_version => '3.0.0', features => ['ocfp']);
	is($env->can_build_cloud_configs, 0,
		'no strategy is available when running below the feature floor');
};

# --- opt-out: always NO ------------------------------------------------
subtest 'manage-cloud-configs: false -> false even with ocfp' => sub {
	local $TODO = 'matrix scaffold; behaviour not yet pinned';
	plan tests => 1;
	my $env = make_cc_env(features => ['ocfp'], manage_cc => 0);
	is($env->can_build_cloud_configs, 0,
		'opt-out wins over any strategy availability');
};

# --- non-ocfp kit, no cc hook -- today: NO -----------------------------
subtest 'non-ocfp kit, no cloud-config hook -> false' => sub {
	local $TODO = 'matrix scaffold; behaviour not yet pinned';
	plan tests => 1;
	my $env = make_cc_env();   # no features, simple kit has no cc hook
	is($env->can_build_cloud_configs, 0,
		'no strategy is available without OCFP or a kit cc hook');
};

# --- ocfp env, no cc hook on kit -- DESIGN: yes or no? -----------------
subtest 'ocfp env, kit without cloud-config hook -> ?' => sub {
	local $TODO = 'matrix scaffold; behaviour not yet pinned';
	plan tests => 1;
	my $env = make_cc_env(features => ['ocfp']);
	is($env->can_build_cloud_configs, 1,
		'ocfp strategy provides cloud-config generation without kit hook');
};

# --- ocfp env, kit WITH cc hook -- DESIGN: probably yes ----------------
subtest 'ocfp env + kit with cloud-config hook -> yes' => sub {
	local $TODO = 'matrix scaffold; needs a kit fixture with cc hook';
	plan tests => 1;
	# my $env = make_cc_env(features => ['ocfp'], kit_path => 't/src/<kit-with-cc-hook>');
	# is($env->can_build_cloud_configs, 1, 'both strategies available');
	ok(0, 'pending: requires a kit fixture that ships a cloud-config hook');
};

# --- non-ocfp env, kit WITH cc hook -- DESIGN: yes or no? --------------
subtest 'non-ocfp env, kit with cloud-config hook -> ?' => sub {
	local $TODO = 'matrix scaffold; behaviour not yet pinned';
	plan tests => 1;
	# my $env = make_cc_env(kit_path => 't/src/<kit-with-cc-hook>');
	# This is the case the source needs a design decision on -- a
	# non-OCFP kit that provides a cc hook today produces nothing,
	# because can_build_cloud_configs hard-gates on is_ocfp.  Once a
	# kit-hook strategy is a first-class option, this should flip to 1.
	ok(0, 'pending: design decision on kit-hook strategy outside OCFP');
};

# --- ocfp env, manage-cc explicitly true -> yes (sanity) --------------
subtest 'ocfp env, manage-cloud-configs: true (explicit) -> yes' => sub {
	local $TODO = 'matrix scaffold; behaviour not yet pinned';
	plan tests => 1;
	my $env = make_cc_env(features => ['ocfp'], manage_cc => 1);
	is($env->can_build_cloud_configs, 1,
		'explicit manage-cloud-configs:true matches the default');
};

done_testing;
