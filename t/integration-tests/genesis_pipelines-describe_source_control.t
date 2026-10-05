#!perl
# Proves T57: the remote is the clone's remote that points at the
# repository, never the first entry of git remote, repository parses
# owner/repo from an https and an ssh URL alike, and pipeline-describe shows
# each resolved value and how it resolved (D29 as D118 revises it).
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
provide_rc();

use Genesis::Top;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the remote is the one pointing at the repository' => sub {
	plan tests => 2;

	# dev sorts ahead of origin and control tracks it, and it points at
	# another repository, so neither git's order nor the upstream may choose
	# it.  The urls are here to be read and never to be talked to, so the
	# remotes go in without a fetch and the row stays on this machine.
	my $h = make_harness(envs => ['qa'], vault => 0,
		source_control => {repository => 'fivetwenty-io/lmelt'});
	set_remotes($h,
		remotes  => {
			origin => 'https://github.com/fivetwenty-io/lmelt.git',
			dev    => 'https://github.com/fivetwenty-io/dev-side.git',
		},
		upstream => 'dev',
		fetch    => 0,
	);
	my $top = Genesis::Top->new($h->a, no_vault => 1);

	is($top->source_control_remote, 'origin',
		'the remote that points at the repository is the one used');
	isnt($top->source_control_remote, 'dev',
		'and dev wins neither on alphabetical order nor by being tracked');
};

subtest 'repository parses owner and repo from either url shape' => sub {
	plan tests => 3;

	for my $url (
		'https://github.com/fivetwenty-io/lmelt.git',
		'git@github.com:fivetwenty-io/lmelt.git',
		'https://github.com/fivetwenty-io/lmelt',
	) {
		# The harness seeds a repository of its own, because copy A is cloned
		# from a bare repository at a filesystem path and nearly every row
		# needs a pair the derivation cannot read.  These three rows are the
		# derivation itself, so they take that override away again.
		my $h = make_harness(
			envs           => ['qa'],
			vault          => 0,
			source_control => {repository => undef},
		);
		# The url is here to be parsed and never to be talked to, so the
		# remote goes in without a fetch and the row stays on this
		# machine.
		set_remotes($h, remotes => {origin => $url}, upstream => 'origin',
			fetch => 0);
		my $top = Genesis::Top->new($h->a, no_vault => 1);

		is($top->source_control_repository, 'fivetwenty-io/lmelt',
			"owner/repo parses from $url");
	}
};

subtest 'pipeline-describe shows what resolved and how' => sub {
	# The five are the restoration the run asserts for itself and the four
	# rows below it.
	plan tests => 5;

	# The repository is written, and the two defaulted keys are taken away,
	# so one run carries all three tiers: an override the operator wrote, a
	# value git answered for, and a key nobody set at all.
	my $h = make_harness(
		envs           => ['qa'],
		source_control => {
			control_branch => undef,
			pr_prefix      => undef,
			repository     => 'fivetwenty-io/mirror',
		},
	);
	# The repository is the override, so nothing here has to read the url
	# and the harness's own bare repository serves as the remote.
	set_remotes($h, remotes => {origin => $h->r}, upstream => 'origin');

	my ($out, undef, $exit) = run_genesis($h, 'pipeline-describe');

	is($exit, 0, 'the command succeeds');
	like($out, qr{remote\s+derived\s+origin},
		'the derived remote shows how it resolved');
	like($out, qr{repository\s+explicit\s+fivetwenty-io/mirror},
		'the override shows as explicit and wins over the derivation');
	like($out, qr{control_branch\s+default\s+control},
		'and an unset key shows as default');
};

subtest 'a long url cannot carry its tier off the line' => sub {
	# The five are the restoration the run asserts for itself and the four
	# rows below it.
	plan tests => 5;

	# Fifty-five characters, which is an ordinary length for a remote url
	# and more than what is left of an eighty-column line once the key and
	# the tier have had their columns.
	my $uri = 'https://github.com/fivetwenty-io/genesis-deployments.git';

	my $h = make_harness(
		envs           => ['qa'],
		source_control => {
			control_branch => undef,
			pr_prefix      => undef,
			repository     => undef,
		},
	);
	set_remotes($h, remotes => {origin => $uri}, upstream => 'origin',
		fetch => 0);

	my ($out, undef, $exit) = run_genesis($h, 'pipeline-describe');

	is($exit, 0, 'the command succeeds');
	like($out, qr{\Q$uri\E}, 'the url is shown whole');
	like($out, qr{^ +uri +derived *$}m,
		'the key and the tier it resolved from share a line');
	unlike($out, qr{^ *(?:explicit|derived|unset|default) *$}m,
		'and no tier is left standing on a line with nothing to name it');
};

done_testing;
