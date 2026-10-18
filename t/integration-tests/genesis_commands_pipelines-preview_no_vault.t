#!perl
# Proves T401: pipeline-describe and pipeline-graph read the repository's
# files and nothing in the vault, so a secrets provider no one can reach does
# not stand in front of them (runbook finding 17).  Each opened its root with
# the vault dialled, so a machine without the vault met the vault first, and a
# broken configuration on it was reported as the vault.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis::Exit;
provide_rc();

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# Nothing listens on the discard port, so a dial is refused at once.
my $UNREACHABLE = 'http://127.0.0.1:9';

subtest 'a preview reads no vault' => sub {
	# Two rows per command, and one restoration assertion for each run.
	plan tests => 6;

	my $h = make_harness(envs => ['qa'], provider => 'concourse', vault => 0);
	$h->set_repo_config('secrets_provider.url', $UNREACHABLE);
	for my $argv (['pipeline-describe'], ['pipeline-graph']) {
		my ($out, $err, $exit) = run_genesis($h, @$argv);
		my $said = unfolded($out, $err);
		is($exit, 0, "`genesis @$argv` answers with the vault out of reach") or diag($said);
		unlike($said, qr/127\.0\.0\.1:9|vault/i, 'and never mentions the vault');
	}
};

subtest 'a broken configuration is reported as itself' => sub {
	# Two rows per command, and one restoration assertion for each run.
	plan tests => 6;

	my $h = make_harness(envs => ['qa'], provider => 'concourse', vault => 0);
	$h->set_repo_config('secrets_provider.url', $UNREACHABLE);
	write_env_file($h, 'qa', pipeline => {prior_env => 'qa'}, commit => 0);
	for my $argv (['pipeline-describe'], ['pipeline-graph']) {
		my ($out, $err, $exit) = run_genesis($h, @$argv);
		my $said = unfolded($out, $err);
		is($exit, Genesis::Exit::CONFIG, "`genesis @$argv` refuses at CONFIG");
		like($said, qr/prior_env/, 'naming the configuration, not the vault');
	}
};

done_testing;
