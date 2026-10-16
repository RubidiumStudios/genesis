#!perl
# Proves T370 on the Concourse provider: each operator's fly target is
# resolved where fly is needed, by the provider's own fly, never read from
# the committed configuration (D86, noted 2026-10-15).  A flag wins, then the
# clone's own pin, then the one ~/.flyrc target whose API and team are the
# configuration's.
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
use Genesis qw/mkfile_or_fail mkdir_or_fail run slurp/;
use Genesis::Exit;

use_ok 'Genesis::Config';
provide_rc();
use_ok 'Genesis::CI::Provider::Concourse';
require Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# A scratch home holding a ~/.flyrc, a clone to pin in, and a fly that logs
# the arguments it was run with.  Targets for other Concourses and teams sit
# beside the one a row expects to match.
# --global writes $HOME/.gitconfig, which is this scratch home's, because
# scrub_git_env clears GIT_CONFIG_GLOBAL.
my $home = workdir('concourse-target-home');
local $ENV{HOME} = $home;
mkfile_or_fail("$home/.gitconfig", '');

my $log = "$home/fly.log";
mkdir_or_fail("$home/bin");
mkfile_or_fail("$home/bin/fly", 0755, "#!/bin/sh\necho \"\$*\" >> '$log'\n");
local $ENV{GENESIS_FLY_BIN} = "$home/bin/fly";

sub flyrc {
	my (%targets) = @_;
	mkfile_or_fail("$home/.flyrc", "targets:\n" . join('', map {
		"  $_:\n    api: $targets{$_}{api}\n    team: $targets{$_}{team}\n"
	} sort keys %targets));
}

sub clone {
	my ($name) = @_;
	scrub_git_env();
	my $dir = workdir($name);
	run({dir => $dir}, 'git', 'init', '-q');
	return Service::Git->new($dir);
}

sub provider {
	my (%opts) = @_;
	return Genesis::CI::Provider::Concourse->new(
		type => 'concourse', url => 'https://ci.example.com/', team => 'main', %opts);
}

my %usual = (
	'other'   => {api => 'https://other.example.com', team => 'main'},
	'ci-dev'  => {api => 'https://ci.example.com',    team => 'dev'},
	'ci-main' => {api => 'https://ci.example.com',    team => 'main'},
);

subtest 'the one .flyrc target with the configuration\'s url and team is matched' => sub {
	plan tests => 2;

	flyrc(%usual);
	my $found = provider(clone => clone('target-matched'))->target_found;
	is($found->{target}, 'ci-main', 'the target whose api and team match');
	is($found->{how}, 'matched', 'found by matching, the url compared without its trailing slash');
};

subtest 'a flag names the target for one run' => sub {
	plan tests => 2;

	flyrc(%usual);
	my $found = provider(clone => clone('target-flagged'), target => 'other')->target_found;
	is($found->{target}, 'other', 'the flag wins');
	is($found->{how}, 'flagged', 'and says so');
};

subtest "the clone's own pin names the target" => sub {
	plan tests => 2;

	flyrc(%usual);
	my $git = clone('target-pinned');
	run({dir => $git->root}, 'git', 'config', '--local', 'genesis.fly-target', 'pinned');
	my $found = provider(clone => $git)->target_found;
	is($found->{target}, 'pinned', 'the pin wins over the match');
	is($found->{how}, 'pinned', 'and says so');
};

subtest 'a pin set only outside the clone is ignored, and says so' => sub {
	plan tests => 3;

	flyrc(%usual);
	my $git = clone('target-pin-global');
	run({dir => $git->root}, 'git', 'config', '--global', 'genesis.fly-target', 'pinned');
	my $found;
	my $err = stderr_from { $found = provider(clone => $git)->target_found };
	run({}, 'git', 'config', '--global', '--unset', 'genesis.fly-target');

	is($found->{target}, 'ci-main', 'the match is used, not the global pin');
	like($err, qr/genesis\.fly-target/, 'a warning names the pin');
	like($err, qr/git config --local genesis\.fly-target pinned/, 'and gives the --local form');
};

subtest 'two matching targets are refused, naming both and the pin' => sub {
	plan tests => 3;

	flyrc(%usual, 'ci-main-2' => {api => 'https://ci.example.com/', team => 'main'});
	my $found = provider(clone => clone('target-two'))->target_found;
	like($found->{refusal} // '', qr/ci-main\b.*ci-main-2|ci-main-2.*ci-main\b/s, 'naming both');
	like($found->{refusal} // '', qr/git config genesis\.fly-target/, 'and the pin that chooses');
	is($found->{target}, undef, 'with no target chosen');
};

subtest 'no matching target is refused with the login that makes one' => sub {
	plan tests => 2;

	flyrc(other => $usual{other});
	my $found = provider(clone => clone('target-none'))->target_found;
	like($found->{refusal} // '', qr/fly login -t \S+ -c https:\/\/ci\.example\.com -n main/,
		'with the exact fly login, the url without its trailing slash');
	is($found->{target}, undef, 'and no target chosen');
};

subtest "the provider's fly resolves the target where fly needs one" => sub {
	plan tests => 3;

	flyrc(%usual);
	unlink $log;
	my $p = provider(clone => clone('target-fly'));
	$p->fly({stderr => 0}, 'pause-pipeline', '-p', 'bosh');
	$p->fly({stderr => 0}, '--version');
	my @calls = split /\n/, (-f $log ? slurp($log) : '');

	like($calls[0] // '', qr/-t ci-main .*pause-pipeline -p bosh/, 'a command that takes a target is given the resolved one');
	unlike($calls[1] // '', qr/-t /, 'and one that takes none is given none');
	is(scalar(@calls), 2, 'and nothing else is run');
};

subtest "the provider's fly refuses where no target can be found" => sub {
	plan tests => 2;

	flyrc(other => $usual{other});
	unlink $log;
	local $ENV{GENESIS_IGNORE_EVAL} = 1;
	my $code;
	my $err = stderr_from { $code = exit_code {
		provider(clone => clone('target-fly-none'))->fly({stderr => 0}, 'pause-pipeline', '-p', 'bosh')
	} };
	is($code, Genesis::Exit::CONFIG, 'refused at the configuration exit');
	like($err, qr/fly login -t \S+ -c https:\/\/ci\.example\.com -n main/, 'with the login that makes one');
};

done_testing;
