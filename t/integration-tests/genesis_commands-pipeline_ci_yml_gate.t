#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Output;
use Test::Exit;
use Cwd qw/getcwd/;
use Genesis;

# Coverage for the PIPELINE-group dispatch gate in Genesis::Commands.
#
# The gate refuses to run any command whose function_group.module is
# 'Pipelines' when the loaded repo carries a legacy ci.yml.  It must
# NOT interfere with non-pipeline commands, and it must NOT trigger
# on repos with no ci.yml (or with an env-shaped ci.yml).  Also, it
# must remain quiet when the command has no repo/env scope (e.g.
# help, version, ping) so those keep working outside a repo.

use_ok 'Genesis::Config';
provide_rc();
use_ok 'Genesis::Top';
use_ok 'Genesis::Commands';
Genesis::Init();

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

sub reset_commands_state {
	no warnings 'once';
	$Genesis::Commands::COMMAND = undef;
	$Genesis::Commands::CALLED = undef;
	%Genesis::Commands::RUN = ();
	%Genesis::Commands::PROPS = ();
	%Genesis::Commands::GENESIS_COMMANDS = ();
	@Genesis::Commands::COMMANDS = ();
	$Genesis::Commands::COMMAND_OPTIONS = {};
	@Genesis::Commands::COMMAND_ARGS = ();
	$Genesis::Commands::END_HOOKS = [];
}

sub make_repo {
	my (%o) = @_;
	my $tmp = workdir($o{name});
	system("rm -rf $tmp && mkdir -p $tmp/.genesis") == 0
		or die "make_repo setup failed";
	mkfile_or_fail("$tmp/.genesis/config", <<EOF);
---
version: $o{version}
creator_version: "3.1.0"
deployment_type: testkit
EOF
	if ($o{version} == 3) {
		open my $fh, '>>', "$tmp/.genesis/config" or die $!;
		print $fh "manifest_store: exodus\n";
		close $fh;
	}
	if (defined $o{ci_yml}) {
		mkfile_or_fail("$tmp/ci.yml", $o{ci_yml});
	}
	return $tmp;
}

my $legacy_pipeline_yml = <<EOF;
---
pipeline:
  name: legacy-repo
  git:
    branch: main
EOF

# Helper: register a command with a given function_group + scope,
# activate it as $COMMAND, chdir into the given repo, and run the
# gate.  Returns whatever exception was raised (from bail via die),
# or undef if the gate returned quietly.
sub run_gate_in {
	my ($repo, %opts) = @_;
	reset_commands_state();
	define_command('fake-pipeline-cmd', {
		summary        => 'stand-in for a PIPELINE-group command',
		scope          => $opts{scope} // 'repo',
		no_vault       => 1,
		function_group => $opts{function_group}
			// Genesis::Commands::PIPELINE(),
	}, sub { 1 });
	$Genesis::Commands::COMMAND = 'fake-pipeline-cmd';
	$Genesis::Commands::CALLED  = 'fake-pipeline-cmd';

	my $orig_cwd = getcwd();
	chdir($repo) or die "chdir $repo: $!";
	my $err;
	eval { Genesis::Commands::_gate_pipeline_on_legacy_ci_yml(); 1 }
		or $err = $@;
	chdir($orig_cwd);
	return $err;
}

subtest 'PIPELINE command in a repo with legacy ci.yml -> bail' => sub {
	my $tmp = make_repo(name => 'gate-v2-legacy', version => 2,
		ci_yml => $legacy_pipeline_yml);
	my $err = run_gate_in($tmp);
	ok($err, 'gate refused to let the command run');
	# \s+ rather than literal spaces: the bail text is wrapped for the
	# terminal, so any phrase asserted here can arrive split across lines.
	like($err // '', qr/legacy\s+CI\s+configuration/i,
		'bail message names the legacy CI configuration');
	like($err // '', qr/genesis\s+config\s+--set\s+ci\.enabled/,
		'bail message hands the user a concrete migration command');
	like($err // '', qr/ci\.provider\.type/,
		'and names the other key the gate checks');
};

subtest 'PIPELINE command in a v3 repo with no ci.yml -> passes cleanly' => sub {
	my $tmp = make_repo(name => 'gate-v3-clean', version => 3);
	my $err = run_gate_in($tmp);
	is($err, undef,
		'gate returned quietly -- no ci.yml means nothing to gate on');
};

subtest 'PIPELINE command in a v2 repo with no ci.yml -> passes cleanly' => sub {
	my $tmp = make_repo(name => 'gate-v2-clean', version => 2);
	my $err = run_gate_in($tmp);
	is($err, undef, 'gate returned quietly for a clean v2 repo');
};

subtest 'non-PIPELINE command in a legacy-ci.yml repo -> passes cleanly' => sub {
	my $tmp = make_repo(name => 'gate-non-pipeline', version => 2,
		ci_yml => $legacy_pipeline_yml);
	my $err = run_gate_in($tmp,
		function_group => Genesis::Commands::ENVIRONMENT());
	is($err, undef,
		'gate ignores non-PIPELINE-group commands -- deploy/check/etc keep working');
};

subtest 'PIPELINE command with no repo scope -> passes cleanly' => sub {
	# Emulates `genesis help`, `genesis version`, etc: PIPELINE group
	# association is irrelevant when the command has no repo context
	# to load a Top from.
	my $tmp = make_repo(name => 'gate-no-scope', version => 2,
		ci_yml => $legacy_pipeline_yml);
	my $err = run_gate_in($tmp, scope => 'any');
	is($err, undef,
		'gate returned quietly when scope is not repo/env');
};

done_testing;
