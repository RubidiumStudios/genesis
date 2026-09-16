#!perl
# Proves T30 and T28: one invalid key in the pipeline block refuses the
# same way under deploy, propagate, and pipeline-status, each naming the
# key and exiting CONFIG; a version 2 configuration errors for a pipeline
# command naming the migration; and a stale ci.yml beside a version 3
# configuration warns and lets the command carry on.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;

use Genesis;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], provider => 'manual');

subtest 'one invalid key, three commands, one refusal' => sub {
	# Nine explicit rows, and one more for each of the three runs, because
	# run_genesis asserts for itself that the working state came back.  A
	# command that refuses at configuration load has touched nothing, so
	# the row may as well say so.
	plan tests => 12;

	commit_on_control($h, files => {
		'.genesis/config' => join("\n",
			'---', 'deployment_type: bosh', 'version: "3"',
			'creator_version: 3.2.0',
			'pipeline:', '  enabled: true', '  frobnicate: yes', ''),
	});

	for my $argv (['qa', 'deploy'], ['propagate'], ['pipeline-status']) {
		my ($out, $err, $exit) = run_genesis($h, @$argv);
		my $what = join(' ', 'genesis', @$argv);
		like $err, qr/pipeline\.frobnicate: unknown configuration key/,
			"$what names the key it refused";
		is $exit, Genesis::Exit::CONFIG,
			"$what exits CONFIG";
		like $err, qr/Configuration validation failed/,
			"$what refuses in the same words as the others";
	}
};

subtest 'a version 2 configuration errors for a pipeline command' => sub {
	# Three explicit rows and one for the run's own restoration assertion.
	plan tests => 4;

	commit_on_control($h, files => {
		'.genesis/config' => join("\n",
			'---', 'deployment_type: bosh', 'version: "2"',
			'creator_version: 3.2.0', ''),
		'ci.yml' => "---\npipeline:\n  name: bosh\n",
	});

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	like $err, qr/legacy CI configuration/, 'the error names the legacy file';
	like $err, qr/migrate/i,                'the error names the migration';
	is $exit, Genesis::Exit::CONFIG,        'and it exits CONFIG';
};

subtest 'a stale ci.yml beside a version 3 pipeline only warns' => sub {
	# Three explicit rows and one for the run's own restoration assertion.
	plan tests => 4;

	commit_on_control($h, files => {
		'.genesis/config' => join("\n",
			'---', 'deployment_type: bosh', 'version: "3"',
			'creator_version: 3.2.0',
			'pipeline:', '  enabled: true',
			'  provider:', '    type: manual',
			# Copy A is cloned from a bare repository at a filesystem path,
			# so the origin URL carries no GitHub owner/repo pair and the
			# source-control block cannot derive one.
			'  source_control:', '    repository: genesis/bosh-deployments', ''),
		'ci.yml' => "---\npipeline:\n  name: bosh\n",
	});

	# --no-refresh is the shape that stops soonest once the load has let the
	# command through, so the row proves the load and not the status read.
	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--no-refresh');
	like $err, qr/Legacy\s+\S*ci\.yml\s+present alongside a v3/s,
		'the stale file warns';
	is $exit, 0, 'the warning is not a refusal';
	unlike $err, qr/Pipeline commands are unavailable/,
		'and the command carries on';
};

subtest "a provider's own rule refuses at load and exits CONFIG" => sub {
	# Four explicit rows and one for the run's own restoration assertion.
	plan tests => 5;

	# Concourse needs a fly target and this configuration names none, so
	# the refusal comes from the provider's own validate_config rather than
	# from the declarative schema above it.
	commit_on_control($h, files => {
		'.genesis/config' => join("\n",
			'---', 'deployment_type: bosh', 'version: "3"',
			'creator_version: 3.2.0',
			'pipeline:', '  enabled: true',
			'  source_control:',
			'    repository: genesis/bosh-deployments',
			'    auth:', '      type: ssh', '      vault: secret/ci/git',
			'    identity:', '      name: Genesis CI',
			'      email: ci@genesis.example.com',
			'  provider:', '    type: concourse',
			'  shuttle:', '    backend: s3', '    bucket: pipes',
			'  vault:', '    url: https://vault.example.com',
			'  locker:', '    url: https://locker.example.com', ''),
	});

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	like $err, qr/Configuration validation failed/,
		'the refusal is the one every configuration refusal carries';

	# The provider's rules are not a phase of their own under D105, so what
	# it says is gathered with every other error rather than announced
	# under a heading naming the provider a second time.
	unlike $err, qr/Invalid configuration for the/,
		"with no second heading in front of the provider's own words";
	like $err, qr/'target' is required for the Concourse provider/,
		"and quotes the provider's own words";
	is $exit, Genesis::Exit::CONFIG, 'and it exits CONFIG by name';
};

subtest "a provider whose file will not load exits CONFIG" => sub {
	# Three explicit rows and one for the run's own restoration assertion.
	plan tests => 4;

	commit_on_control($h, files => {
		'.genesis/config' => join("\n",
			'---', 'deployment_type: bosh', 'version: "3"',
			'creator_version: 3.2.0',
			'pipeline:', '  enabled: true',
			'  source_control:',
			'    repository: genesis/bosh-deployments',
			'    auth:', '      type: ssh', '      vault: secret/ci/git',
			'    identity:', '      name: Genesis CI',
			'      email: ci@genesis.example.com',
			'  provider:', '    type: concourse', '    target: ci',
			'  shuttle:', '    backend: s3', '    bucket: pipes',
			'  vault:', '    url: https://vault.example.com',
			'  locker:', '    url: https://locker.example.com', ''),
	});

	# bin/genesis puts GENESIS_LIB in front of PERL5LIB with use lib, so a
	# directory holding a shadow of the provider's file cannot win on @INC
	# alone.  PERL5OPT reaches the child before bin/genesis compiles, and
	# the module it names marks the provider's file as one that has already
	# failed, which makes the require inside the load fail the way a broken
	# provider file would.
	#
	# The file is the one holding the class the provider block is
	# dispatched to, which is also the class the capability gates behind it
	# read, because one class answers for the whole of a provider.
	my $shadow = workdir();
	put_file("$shadow/ShadowProvider.pm", join("\n",
		'package ShadowProvider;',
		"\$INC{'Genesis/CI/Provider/Concourse.pm'} = undef;",
		'1;', ''));
	local $ENV{PERL5OPT} = join(' ',
		"-I$shadow", '-MShadowProvider', ($ENV{PERL5OPT} // ()));

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	# The refusal is wrapped to the terminal before it reaches stderr, so it
	# is folded back onto one line before anything is read out of it.
	(my $flat = $err) =~ s/\s+/ /g;

	like $flat, qr/Failed to load CI provider 'concourse'/,
		'the refusal names the provider whose file would not load';
	is $exit, Genesis::Exit::CONFIG, 'and it exits CONFIG by name';
	unlike $flat, qr/Compilation failed in require at \S+ line/,
		'with the line the require failed on cut away';
};

# The bullets an operator reads are built out of a refusal caught inside the
# load, so what the cut leaves in them is worth one row through a command.
subtest "an environment block refusal carries no backtrace" => sub {
	# Four explicit rows and one for the run's own restoration assertion.
	plan tests => 5;

	# An automated provider, because the manual gate is the operator's
	# choice inside an ability a manual pipeline does not have, and the
	# capability gates would refuse the key before the schema saw what was
	# written in it.  The row above left exactly that configuration on the
	# control branch, and a harness write of a file that is already what it
	# would write has no commit to make, so this row stands on that write
	# and adds the environment the refusal is about.
	write_env_file($h, 'qa', pipeline => {manual => 'maybe'});

	# The frames the cut takes out exist only where something has loaded
	# Carp::Always, and the child loads nothing of the sort on its own, so
	# the row arms it for the one command it runs.
	local $ENV{PERL5OPT} = join(' ', '-MCarp::Always', ($ENV{PERL5OPT} // ()));

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	(my $flat = $err) =~ s/\s+/ /g;

	like $flat, qr/genesis\.pipeline\.manual: expected a boolean/,
		'the refusal names the key the environment got wrong';
	is $exit, Genesis::Exit::CONFIG, 'and it exits CONFIG';
	unlike $flat, qr/expected a boolean at \S+ line \d+/,
		'with no location left standing behind the bullet';
	unlike $flat, qr/Genesis::Config::validate/,
		'and no frame behind that';
};

done_testing;
