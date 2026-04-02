#!perl
use strict;
use warnings;

use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/mkpath/;
use lib 'lib';

$ENV{GENESIS_TESTING} = "yes";
$ENV{GENESIS_LIB}     ||= 'lib';

### ============================================================ ###
### Phase C — pipeline metadata injection helpers                ###
### ============================================================ ###
#
# Genesis::Commands::Env::create() is entangled with vault, kit hooks,
# and secret generation — we cannot unit-test the full command without
# a full integration harness.
#
# Instead we test:
#   (a) the YAML injection logic in isolation
#   (b) the ci.provider detection via Genesis::Config
#   (c) that Genesis::Config->has / ->get work as expected for dotted keys

use_ok 'Genesis::Config';

### ------------------------------------------------------------ ###
### Helper: replicate the injection regex from Commands::Env     ###
### ------------------------------------------------------------ ###

sub _inject_pipeline {
	my ($contents, $prior_env, %opts) = @_;
	return $contents unless length($prior_env);   # blank = entrypoint, no section written
	my $pipeline_yaml = "  pipeline:\n";
	$pipeline_yaml .= "    prior_env: $prior_env\n";
	$pipeline_yaml .= "    require_pr: true\n" if $opts{require_pr};
	$pipeline_yaml .= "    manual: true\n"     if $opts{manual};
	unless ($contents =~ /^  pipeline:/m) {
		$contents =~ s/^(  env:\s+\S[^\n]*\n)/$1$pipeline_yaml/m;
	}
	return $contents;
}

### ------------------------------------------------------------ ###

subtest 'pipeline YAML injection — prior_env + require_pr' => sub {
	my $env_file = <<'YAML';
---
genesis:
  env: my-deployment-nonprod
kit:
  name: cf
  version: 2.0.0
YAML

	my $result = _inject_pipeline($env_file, 'my-deployment-lab', require_pr => 1);

	like   $result, qr/  env: my-deployment-nonprod/,    "env key preserved";
	like   $result, qr/  pipeline:/,                     "pipeline block injected";
	like   $result, qr/    prior_env: my-deployment-lab/,"prior_env correct";
	like   $result, qr/    require_pr: true/,             "require_pr written";
	unlike $result, qr/    manual:/,                      "manual omitted when false";
	like   $result, qr/  env: my-deployment-nonprod\n  pipeline:/, "pipeline follows env:";
};

subtest 'pipeline YAML injection — blank prior_env = entrypoint, no section written' => sub {
	my $env_file = "---\ngenesis:\n  env: my-deployment-lab\nkit:\n  name: cf\n  version: 2.0.0\n";

	my $result = _inject_pipeline($env_file, '', require_pr => 1, manual => 1);

	unlike $result, qr/  pipeline:/,  "no pipeline block for entrypoint";
	unlike $result, qr/prior_env:/,   "no prior_env key";
	unlike $result, qr/require_pr:/,  "no require_pr key";
	unlike $result, qr/manual:/,      "no manual key";
	is     $result, $env_file,        "env file unchanged for entrypoint";
};

subtest 'pipeline YAML injection — all gates true' => sub {
	my $env_file = "---\ngenesis:\n  env: prod\nkit:\n  name: cf\n  version: 2.0.0\n";

	my $result = _inject_pipeline($env_file, 'staging', require_pr => 1, manual => 1);

	like $result, qr/    prior_env: staging/, "prior_env written";
	like $result, qr/    require_pr: true/,   "require_pr written";
	like $result, qr/    manual: true/,       "manual written";
};

subtest 'pipeline YAML injection — env file with extra genesis keys' => sub {
	my $env_file = <<'YAML';
---
genesis:
  env: my-env
  use_create_env: false
  bosh_env: my-env
kit:
  name: bosh
  version: 1.0.0
YAML

	my $result = _inject_pipeline($env_file, 'lab');

	like $result, qr/  env: my-env\n  pipeline:/, "pipeline injected after env: even with other genesis keys";
	like $result, qr/use_create_env: false/,       "other genesis keys preserved";
};

subtest 'pipeline YAML injection — does not double-inject' => sub {
	my $env_file = "---\ngenesis:\n  env: my-env\nkit:\n  name: cf\n  version: 2.0.0\n";

	my $once  = _inject_pipeline($env_file, 'lab', require_pr => 1);
	my $twice = _inject_pipeline($once,     'lab', require_pr => 1);

	my @count = ($twice =~ /  pipeline:/g);
	is scalar(@count), 1, "pipeline block not duplicated on second inject";
};

subtest 'Genesis::Config has/get for dotted ci.provider key' => sub {
	my $tmp = tempdir(CLEANUP => 1);
	my $config_path = "$tmp/.genesis/config";
	mkpath("$tmp/.genesis");

	# Write a config file with ci.provider set
	open my $fh, '>', $config_path or die "Cannot write $config_path: $!";
	print $fh "deployment_type: cf\nci:\n  provider: concourse\n";
	close $fh;

	my $config = Genesis::Config->new($config_path);
	ok  $config->has('ci.provider'),                     "has('ci.provider') true when set";
	is  $config->get('ci.provider'), 'concourse',        "get('ci.provider') returns correct value";
	ok !$config->has('ci.target'),                       "has('ci.target') false when absent";
};

subtest 'Genesis::Config ci.provider absent — has returns false' => sub {
	my $tmp = tempdir(CLEANUP => 1);
	my $config_path = "$tmp/.genesis/config";
	mkpath("$tmp/.genesis");

	open my $fh, '>', $config_path or die "Cannot write $config_path: $!";
	print $fh "deployment_type: cf\n";
	close $fh;

	my $config = Genesis::Config->new($config_path);
	ok !$config->has('ci.provider'), "has('ci.provider') false when not configured";
};

done_testing;
