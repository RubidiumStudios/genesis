use strict;
use warnings;

use lib 'lib';
use lib 't';

use Test::More;
use Test::Exception;

BEGIN {
	use_ok 'Service::Github';
}

# ============================================================
# Mock Infrastructure (same pattern as service_github-mocked.t)
# ============================================================

my @curl_calls;
my @curl_responses;

{
	no warnings 'redefine';
	*Service::Github::curl = sub {
		push @curl_calls, [@_];
		my $resp = shift @curl_responses;
		return (500, 'No mock response queued', '', '') unless $resp;
		return @$resp;
	};
}

sub queue_curl_response { push @curl_responses, [@_] }
sub reset_mocks         { @curl_calls = (); @curl_responses = () }

{
	no warnings 'redefine';
	*Service::Github::info    = sub {};
	*Service::Github::error   = sub {};
	*Service::Github::trace   = sub {};
	*Service::Github::debug   = sub {};
	*Service::Github::warning = sub {};
}

sub new_gh {
	my (%args) = @_;
	local $ENV{GITHUB_USER}       = delete $args{GITHUB_USER}       if exists $args{GITHUB_USER};
	local $ENV{GITHUB_AUTH_TOKEN} = delete $args{GITHUB_AUTH_TOKEN} if exists $args{GITHUB_AUTH_TOKEN};
	return Service::Github->new(%args);
}

require JSON::PP;
sub encode_json { JSON::PP->new->encode(shift) }
sub decode_json { JSON::PP->new->decode(shift) }

sub make_pr {
	my (%opts) = @_;
	return {
		number   => $opts{number}   // 1,
		title    => $opts{title}    // 'Test PR',
		body     => $opts{body}     // '',
		state    => $opts{state}    // 'open',
		html_url => $opts{html_url} // 'https://github.com/org/repo/pull/1',
		head     => { ref => $opts{head_ref} // 'propagate/myenv/abc1234' },
		base     => { ref => $opts{base_ref} // 'myenv' },
	};
}

# ============================================================
# pulls_url
# ============================================================

subtest 'pulls_url' => sub {
	plan tests => 3;

	my $gh = Service::Github->new(org => 'myorg');

	is(
		$gh->pulls_url('myorg/myrepo'),
		'https://api.github.com/repos/myorg/myrepo/pulls',
		'list endpoint'
	);

	is(
		$gh->pulls_url('myorg/myrepo', 42),
		'https://api.github.com/repos/myorg/myrepo/pulls/42',
		'single-PR endpoint with number'
	);

	is(
		$gh->pulls_url('myorg/myrepo', 0),
		'https://api.github.com/repos/myorg/myrepo/pulls/0',
		'number 0 is included (defined check)'
	);
};

# ============================================================
# list_prs
# ============================================================

subtest 'list_prs' => sub {
	plan tests => 7;

	subtest 'returns arrayref of PRs on 200' => sub {
		plan tests => 4;
		reset_mocks();
		my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
		my @prs = (make_pr(number => 1), make_pr(number => 2));
		queue_curl_response(200, '200 OK', encode_json(\@prs), '');

		my $result = $gh->list_prs('org/repo');
		is(ref($result), 'ARRAY', 'returns arrayref');
		is(scalar(@$result), 2, 'two PRs returned');
		is($result->[0]{number}, 1, 'first PR number');
		is($result->[1]{number}, 2, 'second PR number');
	};

	subtest 'default state is open' => sub {
		plan tests => 1;
		reset_mocks();
		my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
		queue_curl_response(200, '200 OK', encode_json([]), '');
		$gh->list_prs('org/repo');
		like($curl_calls[0][1], qr/state=open/, 'URL includes state=open by default');
	};

	subtest 'filters by base branch' => sub {
		plan tests => 1;
		reset_mocks();
		my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
		queue_curl_response(200, '200 OK', encode_json([]), '');
		$gh->list_prs('org/repo', base => 'myenv');
		like($curl_calls[0][1], qr/base=myenv/, 'URL includes base filter');
	};

	subtest 'filters by head branch with owner prefix' => sub {
		plan tests => 1;
		reset_mocks();
		my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
		queue_curl_response(200, '200 OK', encode_json([]), '');
		$gh->list_prs('myorg/repo', head => 'propagate/myenv/abc1234');
		like($curl_calls[0][1], qr/head=myorg%3Apropagate.*abc1234|head=myorg:propagate.*abc1234/,
			'URL includes head filter with owner prefix');
	};

	subtest 'follows Link header pagination' => sub {
		plan tests => 4;
		reset_mocks();
		my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');

		my $page1 = [make_pr(number => 1), make_pr(number => 2)];
		my $page2 = [make_pr(number => 3)];
		my $next_url = 'https://api.github.com/repos/org/repo/pulls?page=2&state=open';

		# Page 1: returns Link header with rel="next"
		queue_curl_response(200, '200 OK', encode_json($page1),
			"Link: <$next_url>; rel=\"next\", <https://api.github.com/repos/org/repo/pulls?page=1>; rel=\"first\"\r\n");
		# Page 2: no Link header
		queue_curl_response(200, '200 OK', encode_json($page2), '');

		my $result = $gh->list_prs('org/repo');
		is(scalar(@curl_calls), 2,           'two curl calls made (two pages)');
		is($curl_calls[1][1],   $next_url,   'second call uses next URL from Link header');
		is(scalar(@$result),    3,           'all three PRs returned');
		is($result->[2]{number}, 3,          'last PR from page 2 included');
	};

	subtest 'bails on non-200 response' => sub {
		plan tests => 1;
		reset_mocks();
		my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
		queue_curl_response(403, 'Forbidden', '{}', '');
		dies_ok { $gh->list_prs('org/repo') } 'bails on 403';
	};

	subtest 'bails when owner_repo missing' => sub {
		plan tests => 1;
		reset_mocks();
		my $gh = Service::Github->new();
		dies_ok { $gh->list_prs('') } 'bails with empty owner_repo';
	};
};

# ============================================================
# create_pr
# ============================================================

subtest 'create_pr' => sub {
	plan tests => 6;

	subtest 'creates PR and returns PR object' => sub {
		plan tests => 5;
		reset_mocks();
		my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
		my $pr = make_pr(number => 7, title => 'my title', html_url => 'https://github.com/o/r/pull/7');
		queue_curl_response(201, 'Created', encode_json($pr), '');

		my $result = $gh->create_pr('org/repo',
			head  => 'propagate/myenv/abc1234',
			base  => 'myenv',
			title => 'my title',
			body  => 'some body',
		);
		is(ref($result), 'HASH',                'returns hashref');
		is($result->{number},   7,              'PR number');
		is($result->{title},    'my title',     'PR title');
		is($result->{html_url}, 'https://github.com/o/r/pull/7', 'PR url');

		is($curl_calls[0][0], 'POST', 'uses POST method');
	};

	subtest 'payload includes required fields' => sub {
		plan tests => 4;
		reset_mocks();
		my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
		queue_curl_response(201, 'Created', encode_json(make_pr()), '');

		$gh->create_pr('org/repo',
			head  => 'propagate/env/abc',
			base  => 'env',
			title => 'the title',
			body  => 'the body',
		);
		my $payload = decode_json($curl_calls[0][3]);
		is($payload->{head},  'propagate/env/abc', 'head in payload');
		is($payload->{base},  'env',               'base in payload');
		is($payload->{title}, 'the title',         'title in payload');
		is($payload->{body},  'the body',          'body in payload');
	};

	subtest 'bails when head missing' => sub {
		plan tests => 1;
		my $gh = Service::Github->new();
		dies_ok {
			$gh->create_pr('org/repo', base => 'env', title => 'T')
		} 'bails without head';
	};

	subtest 'bails when base missing' => sub {
		plan tests => 1;
		my $gh = Service::Github->new();
		dies_ok {
			$gh->create_pr('org/repo', head => 'branch', title => 'T')
		} 'bails without base';
	};

	subtest 'bails when title missing' => sub {
		plan tests => 1;
		my $gh = Service::Github->new();
		dies_ok {
			$gh->create_pr('org/repo', head => 'branch', base => 'env')
		} 'bails without title';
	};

	subtest 'bails on non-201 response' => sub {
		plan tests => 1;
		reset_mocks();
		my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
		queue_curl_response(422, 'Unprocessable', '{"message":"validation failed"}', '');
		dies_ok {
			$gh->create_pr('org/repo',
				head => 'branch', base => 'env', title => 'T')
		} 'bails on 422';
	};
};

# ============================================================
# update_pr
# ============================================================

subtest 'update_pr' => sub {
	plan tests => 5;

	subtest 'updates PR and returns updated object' => sub {
		plan tests => 4;
		reset_mocks();
		my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
		my $updated = make_pr(number => 3, title => 'new title');
		queue_curl_response(200, 'OK', encode_json($updated), '');

		my $result = $gh->update_pr('org/repo', 3,
			title => 'new title',
			body  => 'new body',
		);
		is(ref($result), 'HASH',        'returns hashref');
		is($result->{number}, 3,        'PR number');
		is($result->{title}, 'new title', 'updated title');
		is($curl_calls[0][0], 'PATCH',  'uses PATCH method');
	};

	subtest 'PATCH URL contains PR number' => sub {
		plan tests => 1;
		reset_mocks();
		my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
		queue_curl_response(200, 'OK', encode_json(make_pr(number => 99)), '');
		$gh->update_pr('org/repo', 99, title => 'T');
		like($curl_calls[0][1], qr{/pulls/99$}, 'URL ends with /pulls/99');
	};

	subtest 'only sends provided fields' => sub {
		plan tests => 2;
		reset_mocks();
		my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
		queue_curl_response(200, 'OK', encode_json(make_pr()), '');
		$gh->update_pr('org/repo', 1, title => 'just title');
		my $payload = decode_json($curl_calls[0][3]);
		ok(exists $payload->{title},  'title included');
		ok(!exists $payload->{body},  'body omitted when not provided');
	};

	subtest 'bails when owner_repo missing' => sub {
		plan tests => 1;
		my $gh = Service::Github->new();
		dies_ok { $gh->update_pr('', 1, title => 'T') } 'bails with empty owner_repo';
	};

	subtest 'bails on non-200 response' => sub {
		plan tests => 1;
		reset_mocks();
		my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
		queue_curl_response(404, 'Not Found', '{}', '');
		dies_ok { $gh->update_pr('org/repo', 999, title => 'T') } 'bails on 404';
	};
};

# ============================================================
# open vs update dispatch (what sync_pull_request chooses between)
# ============================================================

subtest 'idempotency: open new PR when none exists' => sub {
	plan tests => 3;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');

	# list_prs returns empty → create_pr is called
	queue_curl_response(200, 'OK', encode_json([]), '');
	queue_curl_response(201, 'Created', encode_json(make_pr(number => 5)), '');

	# Call list_prs then create_pr by hand, which is the open half of the
	# dispatch Genesis::CI::PullRequest::sync_pull_request makes.
	my $prs = $gh->list_prs('org/repo', head => 'propagate/env/abc', base => 'env');
	my ($existing) = grep { $_->{head}{ref} eq 'propagate/env/abc' } @$prs;
	ok(!$existing, 'no existing PR found');

	my $pr = $gh->create_pr('org/repo',
		head  => 'propagate/env/abc',
		base  => 'env',
		title => '[pipeline] propagate control@abc to env',
		body  => 'some body',
	);
	is($pr->{number}, 5,      'new PR number returned');
	is($curl_calls[1][0], 'POST', 'POST used to create');
};

subtest 'idempotency: update existing PR when head matches' => sub {
	plan tests => 3;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');

	my $existing_pr = make_pr(
		number   => 12,
		head_ref => 'propagate/env/abc1234',
		base_ref => 'env',
	);
	# list_prs returns the existing PR
	queue_curl_response(200, 'OK', encode_json([$existing_pr]), '');
	# update_pr response
	queue_curl_response(200, 'OK', encode_json(make_pr(number => 12, title => 'updated')), '');

	my $prs = $gh->list_prs('org/repo',
		head => 'propagate/env/abc1234', base => 'env');
	my ($found) = grep { $_->{head}{ref} eq 'propagate/env/abc1234' } @$prs;
	ok($found, 'existing PR found');

	my $pr = $gh->update_pr('org/repo', $found->{number},
		title => 'updated',
		body  => 'updated body',
	);
	is($pr->{number}, 12,     'existing PR number returned');
	is($curl_calls[1][0], 'PATCH', 'PATCH used to update');
};

# ============================================================
# a number already in hand skips the list_prs call
# ============================================================

subtest 'a number already in hand skips list_prs' => sub {
	plan tests => 3;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');

	my $existing = make_pr(number => 7, head_ref => 'propagate/env/abc');
	# Only one curl call should be made (update_pr PATCH), no list_prs GET
	queue_curl_response(200, 'OK', encode_json(make_pr(number => 7, title => 'updated')), '');

	# The update half of that dispatch, taken where the caller already holds
	# the pull request's number and has nothing to look up.
	my $pr = $gh->update_pr('org/repo', $existing->{number},
		title => 'updated title',
		body  => 'updated body',
	);
	is(scalar(@curl_calls), 1,    'only one curl call (no list_prs)');
	is($curl_calls[0][0], 'PATCH', 'PATCH used directly');
	is($pr->{number}, 7,           'correct PR number');
};

subtest 'pagination: two-page list with Link header' => sub {
	plan tests => 3;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');

	my $page1 = [make_pr(number => 10), make_pr(number => 11)];
	my $page2 = [make_pr(number => 12)];
	my $next  = 'https://api.github.com/repos/org/repo/pulls?state=open&page=2';
	queue_curl_response(200, 'OK', encode_json($page1),
		"Link: <$next>; rel=\"next\"\r\n");
	queue_curl_response(200, 'OK', encode_json($page2), '');

	my $result = $gh->list_prs('org/repo', state => 'open');
	is(scalar(@curl_calls), 2,   'two pages fetched');
	is(scalar(@$result),    3,   'all three PRs from both pages');
	is($result->[2]{number}, 12, 'last PR from page 2 present');
};

# ======================================================================
# open_prs - list open PRs against a base branch (head optional)
# ----------------------------------------------------------------------
# Lower-level primitive for the rolling-branch PR propagation flow.
# Caller decides what 0/1/many means; this method just returns the
# filtered list with state=open enforced.
#
#   $gh->open_prs($owner_repo, $base)           # all open PRs targeting $base
#   $gh->open_prs($owner_repo, $base, $head)    # filtered to PRs from $head
#
# Returns an arrayref.  Filter by head is the GitHub API filter when
# provided (server-side), with a defensive grep on the response (in
# case the API surfaces unrelated results).
#
# Every pull request that survives the filter is then asked for its
# reviews, because D51 has the caller act on what a reviewer decided and
# open_prs attaches that rather than leaving each caller to fetch it.  So
# each row below queues one reviews response per surviving pull request,
# after the listing response.
# ======================================================================

subtest 'open_prs - lists all open PRs against base when head omitted' => sub {
	plan tests => 2;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
	my @prs = (
		make_pr(number => 1, head_ref => 'pr/staging',   base_ref => 'staging'),
		make_pr(number => 2, head_ref => 'hotfix/asap',  base_ref => 'staging'),
		make_pr(number => 3, head_ref => 'feat/banner',  base_ref => 'staging'),
	);
	queue_curl_response(200, 'OK', encode_json(\@prs), '');
	queue_curl_response(200, 'OK', encode_json([]), '') for 1 .. 3;

	my $result = $gh->open_prs('org/repo', 'staging');
	is(scalar(@$result), 3, 'returns all open PRs against staging');
	is_deeply [sort map { $_->{number} } @$result], [1, 2, 3],
		'all three PRs present regardless of head';
};

subtest 'open_prs - filters to head when provided' => sub {
	plan tests => 2;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
	# Even if the API returns multiple, we want only those matching
	# the head filter (defensive grep on top of server-side filter).
	my @prs = (
		make_pr(number => 1, head_ref => 'pr/staging',  base_ref => 'staging'),
		make_pr(number => 2, head_ref => 'hotfix/asap', base_ref => 'staging'),
	);
	queue_curl_response(200, 'OK', encode_json(\@prs), '');
	queue_curl_response(200, 'OK', encode_json([]), '');

	my $result = $gh->open_prs('org/repo', 'staging', 'pr/staging');
	is(scalar(@$result), 1, 'only the head=pr/staging PR survives the filter');
	is($result->[0]{number}, 1, 'correct PR returned');
};

subtest 'open_prs - empty result when no open PRs' => sub {
	plan tests => 1;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
	queue_curl_response(200, 'OK', encode_json([]), '');

	my $result = $gh->open_prs('org/repo', 'staging');
	is_deeply $result, [],
		'empty arrayref when no open PRs are targeting the base';
};

subtest 'open_prs - issues state=open and base=<base> in the GET URL' => sub {
	plan tests => 2;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
	queue_curl_response(200, 'OK', encode_json([]), '');

	$gh->open_prs('org/repo', 'staging');

	my $url = $curl_calls[0][1];   # second arg to curl is the URL
	like $url, qr/state=open/, 'GET URL includes state=open';
	like $url, qr/base=staging/, 'GET URL includes base=staging';
};

subtest 'open_prs - includes head filter in GET URL when provided' => sub {
	plan tests => 1;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
	queue_curl_response(200, 'OK', encode_json([]), '');

	$gh->open_prs('org/repo', 'staging', 'pr/staging');

	my $url = $curl_calls[0][1];
	# GitHub requires owner:branch format for head filter
	like $url, qr{head=org:pr/staging},
		'GET URL includes owner-prefixed head=org:pr/staging';
};

# ======================================================================
# pr_reviews - the reviews on one pull request, oldest first
# ----------------------------------------------------------------------
# The integration rows reach this method down the happy path alone, so
# the two argument refusals, the non-200 refusal, and the fallback that
# answers an empty list where the API gives something that is not one
# are all covered here and nowhere else.
# ======================================================================

subtest 'pr_reviews - refuses without an owner/repo or a number' => sub {
	plan tests => 2;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');

	throws_ok {$gh->pr_reviews(undef, 7)} qr/Missing owner\/repo/,
		'a missing owner/repo is named';
	throws_ok {$gh->pr_reviews('org/repo', undef)} qr/Missing PR number/,
		'and so is a missing number';
};

subtest 'pr_reviews - refuses a status that is not 200' => sub {
	plan tests => 1;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
	queue_curl_response(404, 'Not Found', '', '');

	throws_ok {$gh->pr_reviews('org/repo', 7)}
		qr/Failed to read the review state of pull request #7/,
		'the refusal names the pull request it could not read';
};

subtest 'pr_reviews - answers the list, and an empty one for a non-list' => sub {
	plan tests => 4;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
	queue_curl_response(200, 'OK', encode_json([
		{state => 'COMMENTED', user => {login => 'ann'}, body => 'a thought'},
		{state => 'APPROVED',  user => {login => 'bob'}, body => 'ship it'},
	]), '');

	my $reviews = $gh->pr_reviews('org/repo', 7);
	is(scalar(@$reviews), 2, 'every review comes back');
	is($reviews->[0]{user}{login}, 'ann',
		'in the order the API gave them, which is oldest first');
	like($curl_calls[0][1], qr{/pulls/7/reviews\?per_page=100},
		'read from the reviews endpoint, a page at a time');

	# GitHub answers an object rather than a list for some error shapes,
	# and a caller iterating that would die on a hash.
	reset_mocks();
	queue_curl_response(200, 'OK', encode_json({message => 'Not Found'}), '');
	is_deeply($gh->pr_reviews('org/repo', 7), [],
		'an answer that is not a list reads as no reviews');
};

subtest 'pr_reviews - follows the Link header to the end' => sub {
	plan tests => 4;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');

	# The endpoint answers oldest first and the attachment keeps the last
	# decisive review it sees, so a pull request with more than one page of
	# reviews would have the run act on an older decision than the one that
	# stands.  Under the rebuild rule that decision chooses between
	# rebuilding a pull request branch and freezing it.
	my $next = 'https://api.github.com/repos/org/repo/pulls/7/reviews?page=2';
	queue_curl_response(200, 'OK', encode_json([
		{state => 'APPROVED', user => {login => 'ann'}, body => 'looks fine'},
	]), "Link: <$next>; rel=\"next\"\r\n");
	queue_curl_response(200, 'OK', encode_json([
		{state => 'CHANGES_REQUESTED', user => {login => 'bob'}, body => 'wait'},
	]), '');

	my $reviews = $gh->pr_reviews('org/repo', 7);
	is(scalar(@$reviews), 2, 'both pages come back');
	is($reviews->[1]{user}{login}, 'bob',
		'with the newer page last, so the newest decision is the one that stands');
	is(scalar(@curl_calls), 2, 'the walk made two requests');
	is($curl_calls[1][1], $next, 'the second reading the URL the header named');
};

# ======================================================================
# closed_prs - the closed pull requests for a branch
# ----------------------------------------------------------------------
# The supersedes list, the rejection text, and the recovery all read
# this, and the double the integration rows use filters on state alone,
# so the head filter below is exercised nowhere else.
# ======================================================================

subtest 'closed_prs - refuses without an owner/repo or a base' => sub {
	plan tests => 2;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');

	throws_ok {$gh->closed_prs(undef, 'staging')} qr/Missing owner\/repo/,
		'a missing owner/repo is named';
	throws_ok {$gh->closed_prs('org/repo', '')} qr/Missing base branch/,
		'and so is a missing base branch';
};

subtest 'closed_prs - asks for the closed ones and filters to head' => sub {
	plan tests => 3;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');
	my @prs = (
		make_pr(number => 4, state => 'closed',
			head_ref => 'pr/staging',  base_ref => 'staging'),
		make_pr(number => 5, state => 'closed',
			head_ref => 'hotfix/asap', base_ref => 'staging'),
	);
	$prs[0]{merged_at} = '2026-09-01T00:00:00Z';
	queue_curl_response(200, 'OK', encode_json(\@prs), '');

	my $result = $gh->closed_prs('org/repo', 'staging', 'pr/staging');
	like($curl_calls[0][1], qr/state=closed/, 'the listing asks for closed');
	is(scalar(@$result), 1, 'only the pull request from this head survives');
	is($result->[0]{merged_at}, '2026-09-01T00:00:00Z',
		'and it carries merged_at, which the recovery reads');
};

subtest 'closed_prs - only an unmerged entry is worth a review request' => sub {
	plan tests => 5;
	reset_mocks();
	my $gh = new_gh(GITHUB_AUTH_TOKEN => 'tok');

	# The pull request branch is reused for every delivery, so the closed
	# list is every pull request ever opened on it and a request apiece
	# would make one propagate run cost as much as the repository's whole
	# history.  A merged entry is read for its marker and its merged_at and
	# never for its review, so only the rejected ones earn the call.
	my @prs = map {
		my $pr = make_pr(number => $_, state => 'closed',
			head_ref => 'pr/staging', base_ref => 'staging');
		$pr->{merged_at} = $_ < 9 ? '2026-09-01T00:00:00Z' : undef;
		$pr;
	} (6, 7, 8, 9);
	queue_curl_response(200, 'OK', encode_json(\@prs), '');
	queue_curl_response(200, 'OK', encode_json([
		{state => 'CHANGES_REQUESTED', user => {login => 'ann'},
		 body => 'not yet', submitted_at => '2026-09-02T00:00:00Z'},
	]), '');

	my $result = $gh->closed_prs('org/repo', 'staging', 'pr/staging');
	is(scalar(@$result), 4, 'every closed pull request comes back');
	is(scalar(@curl_calls), 2,
		'the listing and one review request, not one per entry');
	like($curl_calls[1][1], qr{/pulls/9/reviews},
		'and the request is for the entry nobody merged');

	my ($unmerged) = grep {!$_->{merged_at}} @$result;
	is($unmerged->{review}{state}, 'changes requested',
		'the rejected entry carries the decisive review the text quotes');
	is_deeply([map {$_->{review}} grep {$_->{merged_at}} @$result],
		[undef, undef, undef],
		'and a merged entry carries none, because nothing reads one');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
