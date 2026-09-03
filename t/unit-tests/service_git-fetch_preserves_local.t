#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use Genesis;
use_ok 'Service::Git';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Real repositories and a real remote: the defect is in the refspec handed to
# git fetch, which a stubbed run() cannot exercise.
sub make_pair {
	my $base = workdir() . '/fp-' . $$ . '-' . int(rand(1_000_000));
	mkdir_or_fail($base);
	my $origin = "$base/origin.git";
	my $work   = "$base/work";

	run({ dir => $base }, 'git', 'init', '-q', '--bare', $origin);
	run({ dir => $base }, 'git', 'init', '-q', '-b', 'main', $work);
	run({ dir => $work }, 'git', 'config', 'user.email', 'test@example.com');
	run({ dir => $work }, 'git', 'config', 'user.name',  'Test');
	run({ dir => $work }, 'git', 'remote', 'add', 'origin', $origin);

	put_file("$work/seed", "seed\n");
	run({ dir => $work }, 'git', 'add', '-A');
	run({ dir => $work }, 'git', 'commit', '-q', '-m', 'seed');

	# env-local: exists both places, and will gain an unpushed local commit.
	# env-remote: pushed, then deleted locally, so only the remote has it.
	run({ dir => $work }, 'git', 'branch', 'env-local');
	run({ dir => $work }, 'git', 'branch', 'env-remote');
	run({ dir => $work }, 'git', 'push', '-q', 'origin', 'main', 'env-local', 'env-remote');
	run({ dir => $work }, 'git', 'branch', '-q', '-D', 'env-remote');

	return ($work, $origin);
}

subtest 'a fetch does not discard unpushed local commits' => sub {
	# Propagation commits to an environment branch and leaves it local for
	# review.  The next deploy fetches before doing anything else; if that
	# fetch force-writes local refs, the propagation is destroyed silently
	# and the deploy fails with an unrelated-looking error.
	plan tests => 3;

	my ($work, $origin) = make_pair();
	my $git = Service::Git->new($work);

	# Commit to env-local without pushing, then return to main so the
	# branch is eligible for fetching (the current branch is skipped).
	run({ dir => $work }, 'git', 'checkout', '-q', 'env-local');
	put_file("$work/propagated.yml", "---\nfrom: propagation\n");
	run({ dir => $work }, 'git', 'add', '-A');
	run({ dir => $work }, 'git', 'commit', '-q', '-m', 'propagated');
	my ($local_sha) = run({ dir => $work }, 'git', 'rev-parse', 'env-local');
	chomp $local_sha;
	run({ dir => $work }, 'git', 'checkout', '-q', 'main');

	my (undef, $result) = $git->fetch_branches(['env-local', 'env-remote'], 'origin');
	ok($result->{ok}, 'fetch reported success') or diag(explain($result));

	my ($after) = run({ dir => $work }, 'git', 'rev-parse', 'env-local');
	chomp $after;
	is($after, $local_sha, 'the unpushed local commit survived the fetch');

	my ($files) = run({ dir => $work }, 'git', 'ls-tree', '--name-only', 'env-local');
	like($files, qr/propagated\.yml/, 'its content is still on the branch');
};

subtest 'a branch only on the remote becomes locally known' => sub {
	# The remote is authoritative for which branches exist, which is why
	# branches only it has are still materialised.  That must survive the
	# fix.
	plan tests => 2;

	my ($work, $origin) = make_pair();
	my $git = Service::Git->new($work);

	my ($before) = run({ dir => $work, passfail => 1 },
		'git', 'show-ref', '--verify', '--quiet', 'refs/heads/env-remote');
	ok(!$before, 'sanity: env-remote is not local to start with');

	$git->fetch_branches(['env-local', 'env-remote'], 'origin');
	ok($git->branch_exists('env-remote'),
		'env-remote is known after the fetch');
};

done_testing;
