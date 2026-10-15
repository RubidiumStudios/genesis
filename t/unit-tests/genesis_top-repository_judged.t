#!perl
# Proves T365 on Genesis::Top: the repository a pipeline lives in is judged
# where what each check needs is to hand (D118, noted 2026-10-15).  Its
# syntax needs only the value, so the load judges it as the schema's own
# rule for the key.  Whether the clone is a git checkout with a remote that
# points at the repository needs the clone, so it is asked when a command
# first uses the source control, and the load no longer refuses on it.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Output;
use Test::Exit;

# Explicit import: Genesis also exports workdir(), which would shadow the
# helper's and break every fixture below.
use Genesis qw/mkfile_or_fail mkdir_or_fail run/;
use Genesis::Exit;

use_ok 'Genesis::Config';
provide_rc();
use_ok 'Genesis::Top';

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# A version 3 repository with a manual pipeline turned on.  $git says what
# the directory is: 'none' for no git at all, 'bare' for a fresh git init
# with no remote, which is a repository that has not been pushed anywhere
# yet.  Extra lines go into the pipeline block as written.
sub repo {
	my ($name, %opts) = @_;
	scrub_git_env();
	my $dir = workdir($name);
	mkdir_or_fail("$dir/.genesis");
	my $extra = join('', map {"  $_\n"} @{$opts{pipeline} || []});
	mkfile_or_fail("$dir/.genesis/config", <<EOF);
---
creator_version: 3.2.0
deployment_type: test-kit
manifest_store: exodus
pipeline:
  enabled: true
  provider:
    type: manual
$extra  source_control:
    repository: $opts{repository}
version: 3
EOF
	run({dir => $dir}, 'git', 'init', '-q') unless ($opts{git} // 'bare') eq 'none';
	return $dir;
}

# Runs a block that may refuse, and reports how it ended and what it said.
sub refused (&) {
	my ($block) = @_;
	local $ENV{GENESIS_IGNORE_EVAL} = 1;
	my ($code, $err);
	$err = stderr_from { $code = exit_code { $block->() } };
	return ($code, $err);
}

subtest "a repository that does not parse is the schema's own problem" => sub {
	plan tests => 3;

	# A second problem in the same file shows the refusal is the schema's
	# gathered list, not a separate check that ends the load on its own.
	my $dir = repo('judged-syntax',
		repository => "'not a repo'", pipeline => ['frobnicate: yes']);

	my ($code, $err) = refused { Genesis::Top->new($dir, no_vault => 1)->config };

	is($code, Genesis::Exit::CONFIG, 'the load refuses at the configuration exit');
	like($err, qr/pipeline\.source_control\.repository/, 'naming the repository');
	like($err, qr/pipeline\.frobnicate/, 'in the same list as the other problem');
};

subtest 'a clone with no remote loads, and is refused where the remote is used' => sub {
	plan tests => 4;

	my $dir = repo('judged-no-remote', repository => 'org/repo');
	my $top = Genesis::Top->new($dir, no_vault => 1);

	my ($code, $err) = refused { $top->config };
	is($code, undef, 'the load does not refuse a pipeline whose remote does not exist yet');
	is($err, '', 'and says nothing about it');

	($code, $err) = refused { $top->source_control_remote };
	is($code, Genesis::Exit::CONFIG, 'the first use of the remote refuses');
	like($err, qr/This clone has no git remote/, 'in the words the load used to refuse with');
};

subtest 'a directory outside git loads, and is refused where git is used' => sub {
	plan tests => 3;

	my $dir = repo('judged-no-git', repository => 'org/repo', git => 'none');
	my $top = Genesis::Top->new($dir, no_vault => 1);

	my ($code, $err) = refused { $top->config };
	is($code, undef, 'the load does not refuse a pipeline outside git');

	($code, $err) = refused { $top->source_control_remote };
	is($code, Genesis::Exit::CONFIG, 'the first use of the remote refuses');
	like($err, qr/is not a git checkout/, 'saying a pipeline needs a repository under git');
};

subtest 'the resolved report says what is missing rather than refusing' => sub {
	plan tests => 3;

	my $dir = repo('judged-report', repository => 'org/repo');
	my $top = Genesis::Top->new($dir, no_vault => 1);

	my $rows;
	my ($code, $err) = refused { $rows = $top->source_control_resolved };
	is($code, undef, 'the report is not refused');

	my ($remote) = grep {$_->{key} eq 'remote'} @{$rows || []};
	like($remote->{value} // '', qr/no remote points at org\/repo/i,
		'the remote row says no remote points at the repository');
	my ($repository) = grep {$_->{key} eq 'repository'} @{$rows || []};
	is($repository->{value} // '', 'org/repo', 'and the written repository is still shown');
};

done_testing;
