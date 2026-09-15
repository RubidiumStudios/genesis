#!/usr/bin/env perl
# Proves T108: a refresh of one branch that L already holds moves T alone,
# and the forced single-branch helper that could overwrite L is gone.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::Exception;

use Genesis;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'one named branch that L holds moves only its tracking ref' => sub {
	plan tests => 4;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $slug = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $slug);

	my $before_l = ref_in($h->a, "refs/heads/$slug");
	my $before_t = ref_in($h->a, "refs/remotes/origin/$slug");
	ok($before_l, 'copy A holds the branch locally');

	my $published = hand_commit($h, $slug, copy => 'b', push => 1,
		files => {'qa.yml' => "---\nfrom: the teammate\n"});
	isnt($published, $before_t, 'the teammate moved the branch on R');

	my ($git, $result) = $h->git('a')->fetch_branches([$slug]);

	is(ref_in($h->a, "refs/heads/$slug"), $before_l,
		'L stayed exactly where it was');
	is(ref_in($h->a, "refs/remotes/origin/$slug"), $published,
		'T moved to what R holds');
};

subtest 'the forced single-branch helper is gone' => sub {
	plan tests => 3;

	ok(!Service::Git->can('fetch_branch'),
		'Service::Git no longer carries fetch_branch');

	my $src = slurp('lib/Service/Git.pm');
	unlike($src, qr{\+refs/heads/[^:\s]+:refs/heads/\$branch},
		'no forced refspec writes a named local branch');

	my $callers = join('', map { slurp($_) }
		qw(lib/Genesis/CI/Propagation.pm lib/Genesis/Env.pm
		   lib/Genesis/Commands/Pipelines.pm lib/Genesis/Commands/Env.pm));
	unlike($callers, qr{->fetch_branch\(}, 'no caller reaches the helper');
};

subtest 'a branch only on the remote is still created from the remote' => sub {
	plan tests => 2;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $slug = $h->slug('qa');

	# init_branch writes the local ref in copy A on its way to pushing it,
	# so the local ref goes before the row can ask about a branch that only
	# the remote has.
	init_branch($h, 'qa');
	delete_local($h, 'a', $slug);
	is(ref_in($h->a, "refs/heads/$slug"), undef, 'copy A lacks the branch');

	$h->git('a')->fetch_branches([$slug]);
	is(ref_in($h->a, "refs/heads/$slug"), ref_in($h->r, $slug),
		'the local ref is created from the remote, which I2 permits');
};

subtest 'a refresh that reports a failure is a bail, not a fetched' => sub {
	plan tests => 3;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $slug = $h->slug('qa');

	# A branch R holds and this clone lacks is the one path through
	# resolve_branch that refreshes anything.  A local ref named for the
	# slug's first segment makes git refuse to write refs/heads/qa/bosh
	# under it, so the refresh comes back reporting a failure exactly as
	# it does for an unreachable remote, and the row can ask what
	# resolve_branch does with a report it used to throw away.
	init_branch($h, 'qa');
	delete_local($h, 'a', $slug);
	local_branch($h, 'qa');

	my $git = $h->git('a');
	throws_ok {$git->resolve_branch($slug)} qr/Failed to fetch/,
		'a failed refresh refuses rather than answering fetched';
	like($@, qr/origin/, 'and the refusal names the remote it could not get');
	is(ref_in($h->a, "refs/heads/$slug"), undef,
		'and no local ref stands for a branch we never got');
};

done_testing;
