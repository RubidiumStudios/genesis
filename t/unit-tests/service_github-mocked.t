use strict;
use warnings;

use lib 'lib';
use lib 't';

use File::Temp ();
use Test::More;
use Test::Exception;

BEGIN {
	use_ok 'Service::Github';
}

# ============================================================
# Mock Infrastructure
# ============================================================
#
# All curl calls in Service::Github are intercepted by the
# mock installed below. Responses are queued and dequeued in
# FIFO order. Each response is an arrayref matching the return
# signature of the real curl():
#
#   GET/POST/DELETE/PUT:
#     ($status_code, $status_msg, $body, $response_headers)
#
#   HEAD:
#     ($status_code, $status_msg, $combined)
#
# The mock returns the queued arrayref as-is, so callers can
# unpack as many elements as they need (typically 4 for
# GET/POST/DELETE/PUT and 3 for HEAD).
# ============================================================

my @curl_calls;
my @curl_responses;

# Install the curl mock once at file scope.  Every subtest below
# queues its own responses via queue_curl_response() and resets
# via reset_mocks().  The mock is permanent for this test file
# (no 'local' needed — this process only runs these tests).
{
	no warnings 'redefine';
	*Service::Github::curl = sub {
		push @curl_calls, [@_];
		my $resp = shift @curl_responses;
		unless ($resp) {
			return (500, 'No mock response queued', '', '');
		}
		return @$resp;
	};
}

# mock_curl() is retained as a no-op for readability in subtests
# that call it to signal "this test uses the global curl mock".
sub mock_curl {}

sub queue_curl_response {
	push @curl_responses, [@_];
}

sub reset_mocks {
	@curl_calls    = ();
	@curl_responses = ();
}

# Suppress all output-producing Genesis functions.  These are
# imported into the Service::Github namespace so we override
# them there.
{
	no warnings 'redefine';
	*Service::Github::info            = sub {};
	*Service::Github::error           = sub {};
	*Service::Github::trace           = sub {};
	*Service::Github::debug           = sub {};
	*Service::Github::warning         = sub {};
	*Service::Github::pretty_duration = sub { '' };
}

# ============================================================
# Helpers
# ============================================================

sub new_gh {
	my (%args) = @_;
	local $ENV{GITHUB_USER}       = delete $args{GITHUB_USER}       if exists $args{GITHUB_USER};
	local $ENV{GITHUB_AUTH_TOKEN} = delete $args{GITHUB_AUTH_TOKEN} if exists $args{GITHUB_AUTH_TOKEN};
	return Service::Github->new(%args);
}

# Build a minimal release hash as GitHub API returns
sub make_release {
	my (%opts) = @_;
	my $ver    = $opts{version}    // '1.0.0';
	my $vtag   = $opts{tag}        // "v$ver";
	return {
		tag_name     => $vtag,
		body         => $opts{body}         // "Release notes for $vtag",
		draft        => $opts{draft}        ? 1 : 0,
		prerelease   => $opts{prerelease}   ? 1 : 0,
		published_at => $opts{published_at} // "2024-01-01T00:00:00Z",
		created_at   => $opts{created_at}   // "2024-01-01T00:00:00Z",
		assets       => $opts{assets}       // [],
	};
}

sub make_asset {
	my (%opts) = @_;
	return {
		name                 => $opts{name}     // 'release.tar.gz',
		browser_download_url => $opts{url}      // 'https://example.com/release.tar.gz',
	};
}

sub encode_json_simple {
	# Minimal JSON encoder sufficient for our test payloads.
	# We use JSON::PP which is always available via Genesis.
	require JSON::PP;
	return JSON::PP->new->encode(shift);
}

# ============================================================
# 3a. check() method
# Note (GH-5): check() hard-codes skip_verify=0 in its curl call,
# ignoring the tls=skip setting.  Only get_user_ssh_keys() honors it.
# ============================================================

subtest 'check() method' => sub {
	mock_curl();

	subtest '200 response - scalar context returns undef' => sub {
		reset_mocks();
		my $gh = Service::Github->new();
		queue_curl_response(200, '200 OK', '');
		my $result = $gh->check();
		is($result, undef, 'check() returns undef in scalar context on 200');
		is(scalar @curl_calls, 1, 'one curl call made');
		is($curl_calls[0][0], 'HEAD', 'HEAD method used');
	};

	subtest '200 response - list context returns (200, undef)' => sub {
		reset_mocks();
		my $gh = Service::Github->new();
		queue_curl_response(200, '200 OK', '');
		my ($code, $status) = $gh->check();
		is($code,   200,   'check() returns 200 code in list context');
		is($status, undef, 'check() returns undef status in list context on 200');
	};

	subtest '404 response - contains "Could not find"' => sub {
		reset_mocks();
		my $gh = Service::Github->new();
		queue_curl_response(404, '404 Not Found', '');
		my $status = $gh->check();
		like($status, qr/Could not find/, '404 produces "Could not find" message');
		like($status, qr/Internet/,       '404 message mentions Internet routing');
	};

	subtest '403 response - contains throttling message' => sub {
		reset_mocks();
		my $gh = Service::Github->new();
		queue_curl_response(403, '403 Forbidden', '');
		my $status = $gh->check();
		like($status, qr/Access forbidden/, '403 produces "Access forbidden" message');
		like($status, qr/throttling/,       '403 message mentions throttling');
		like($status, qr/GITHUB_USER/,      '403 message mentions GITHUB_USER');
	};

	subtest '500 response - contains code and message' => sub {
		reset_mocks();
		my $gh = Service::Github->new();
		queue_curl_response(500, '500 Internal Server Error', '');
		my $status = $gh->check();
		like($status, qr/Could not read/,            '500 produces "Could not read" message');
		like($status, qr/500/,                       '500 code appears in message');
		like($status, qr/Internal Server Error/,     '500 message text appears in message');
	};

	subtest 'custom URL is passed to curl' => sub {
		reset_mocks();
		my $gh  = Service::Github->new(org => 'test-org');
		my $url = 'https://api.github.com/repos/test-org/cf-kit/releases';
		queue_curl_response(200, '200 OK', '');
		$gh->check($url);
		is($curl_calls[0][1], $url, 'custom URL forwarded to curl');
	};

	subtest 'custom ref used in 404 error message' => sub {
		reset_mocks();
		my $gh  = Service::Github->new();
		my $url = 'https://api.github.com/repos/test-org/cf-kit/releases';
		my $ref = 'cf-kit releases endpoint';
		queue_curl_response(404, '404 Not Found', '');
		my $status = $gh->check($url, $ref);
		like($status, qr/\Q$ref\E/, 'custom ref appears in 404 error message');
	};

	subtest 'default URL is repos_url()' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'my-org');
		queue_curl_response(200, '200 OK', '');
		$gh->check();
		is($curl_calls[0][1], $gh->repos_url(), 'default URL is repos_url()');
	};

	subtest 'credentials passed to curl' => sub {
		reset_mocks();
		local $ENV{GITHUB_AUTH_TOKEN} = 'tok123';
		local $ENV{GITHUB_USER};
		my $gh = Service::Github->new();
		queue_curl_response(200, '200 OK', '');
		$gh->check();
		is($curl_calls[0][5], 'Bearer tok123', 'Bearer token passed as 6th arg to curl');
	};
};

# ============================================================
# 3b. get_authorized_user() method
# ============================================================

subtest 'get_authorized_user() method' => sub {
	mock_curl();

	subtest 'returns undef when no credentials' => sub {
		reset_mocks();
		local $ENV{GITHUB_USER};
		local $ENV{GITHUB_AUTH_TOKEN};
		my $gh = Service::Github->new();
		my $result = $gh->get_authorized_user();
		is($result, undef, 'returns undef with no credentials');
		is(scalar @curl_calls, 0, 'no curl call made');
	};

	subtest 'returns login with Bearer token' => sub {
		reset_mocks();
		local $ENV{GITHUB_AUTH_TOKEN} = 'ghp_token';
		local $ENV{GITHUB_USER};
		my $gh   = Service::Github->new();
		my $body = encode_json_simple({ login => 'octocat', id => 1 });
		queue_curl_response(200, '200 OK', $body, '');
		my $login = $gh->get_authorized_user();
		is($login, 'octocat', 'returns login field from API response');
		like($curl_calls[0][1], qr|/user$|, 'calls /user endpoint');
		is($curl_calls[0][5], 'Bearer ghp_token', 'passes Bearer token');
	};

	subtest 'returns login with user:token format' => sub {
		reset_mocks();
		local $ENV{GITHUB_USER}       = 'alice';
		local $ENV{GITHUB_AUTH_TOKEN} = 'secret123';
		my $gh   = Service::Github->new();
		my $body = encode_json_simple({ login => 'alice', id => 2 });
		queue_curl_response(200, '200 OK', $body, '');
		my $login = $gh->get_authorized_user();
		is($login, 'alice', 'returns login with user:token format');
		is($curl_calls[0][5], 'alice:secret123', 'passes user:token credentials');
	};

	subtest 'dies on non-200 API response' => sub {
		reset_mocks();
		local $ENV{GITHUB_AUTH_TOKEN} = 'bad_token';
		local $ENV{GITHUB_USER};
		my $gh = Service::Github->new();
		queue_curl_response(401, '401 Unauthorized', '{"message":"Bad credentials"}', '');
		throws_ok {
			$gh->get_authorized_user();
		} qr/Failed to retrieve user information from Github/, 'dies on non-200';
	};

	subtest 'dies on invalid JSON response body' => sub {
		reset_mocks();
		local $ENV{GITHUB_AUTH_TOKEN} = 'tok';
		local $ENV{GITHUB_USER};
		my $gh = Service::Github->new();
		queue_curl_response(200, '200 OK', 'not-json-at-all{{{', '');
		throws_ok {
			$gh->get_authorized_user();
		} qr/Failed to read user information from Github/, 'dies on JSON parse error';
	};

	subtest 'returns empty string for unrecognized credential format' => sub {
		# Manually inject a non-Bearer, non-user:pass credential string
		reset_mocks();
		local $ENV{GITHUB_AUTH_TOKEN};
		local $ENV{GITHUB_USER};
		my $gh = Service::Github->new();
		# Directly set creds to something that won't match either regex
		$gh->{creds} = 'weirdformat';
		my $result = $gh->get_authorized_user();
		is($result, '', 'returns empty string for unrecognized credential format');
		is(scalar @curl_calls, 0, 'no curl call made for unrecognized format');
	};
};

# ============================================================
# 3c. repos() method
# ============================================================

subtest 'repos() method' => sub {
	mock_curl();

	subtest 'fetches repos and returns arrayref' => sub {
		reset_mocks();
		my $gh    = Service::Github->new(org => 'test-org');
		my $repos = [{ name => 'cf-kit' }, { name => 'bosh-kit' }];
		# HEAD for check()
		queue_curl_response(200, '200 OK', '');
		# GET page 1 — two repos
		queue_curl_response(200, '200 OK', encode_json_simple($repos), '');
		# GET page 2 — empty, stops pagination
		queue_curl_response(200, '200 OK', encode_json_simple([]), '');
		my $result = $gh->repos();
		isa_ok($result, 'ARRAY', 'returns arrayref');
		is(scalar @$result, 2, 'returns correct number of repos');
		is($result->[0]{name}, 'cf-kit',  'first repo name correct');
		is($result->[1]{name}, 'bosh-kit','second repo name correct');
	};

	subtest 'handles pagination via sequential GET calls' => sub {
		reset_mocks();
		my $gh    = Service::Github->new(org => 'test-org');
		my $page1 = [{ name => 'repo-a' }];
		my $page2 = [{ name => 'repo-b' }];
		# HEAD for check()
		queue_curl_response(200, '200 OK', '');
		# GET page 1
		queue_curl_response(200, '200 OK', encode_json_simple($page1), '');
		# GET page 2
		queue_curl_response(200, '200 OK', encode_json_simple($page2), '');
		# GET page 3 — empty, stops
		queue_curl_response(200, '200 OK', encode_json_simple([]), '');
		my $result = $gh->repos();
		is(scalar @$result, 2, 'pagination collects all repos across pages');
		is($result->[0]{name}, 'repo-a', 'first repo from page 1');
		is($result->[1]{name}, 'repo-b', 'second repo from page 2');
	};

	subtest 'caches results on subsequent calls' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		# HEAD for check() on first call
		queue_curl_response(200, '200 OK', '');
		queue_curl_response(200, '200 OK', encode_json_simple([{ name => 'cached-repo' }]), '');
		queue_curl_response(200, '200 OK', encode_json_simple([]), '');
		$gh->repos();
		my $call_count_after_first = scalar @curl_calls;
		# Second call should use cache — no new curl calls
		$gh->repos();
		is(scalar @curl_calls, $call_count_after_first, 'no new curl calls on cached call');
	};

	subtest 'refresh bypasses cache' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		# First call
		queue_curl_response(200, '200 OK', '');
		queue_curl_response(200, '200 OK', encode_json_simple([{ name => 'repo-1' }]), '');
		queue_curl_response(200, '200 OK', encode_json_simple([]), '');
		$gh->repos();
		my $first_call_count = scalar @curl_calls;
		# Refresh call — HEAD + GET again
		queue_curl_response(200, '200 OK', '');
		queue_curl_response(200, '200 OK', encode_json_simple([{ name => 'repo-refreshed' }]), '');
		queue_curl_response(200, '200 OK', encode_json_simple([]), '');
		my $result = $gh->repos(1);
		ok(scalar @curl_calls > $first_call_count, 'refresh triggers new curl calls');
		is($result->[0]{name}, 'repo-refreshed', 'refresh returns fresh data');
	};

	subtest 'dies when check() fails with 404' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		# HEAD returns 404 — check() returns error string, repos() bails
		queue_curl_response(404, '404 Not Found', '');
		throws_ok {
			$gh->repos();
		} qr/Could not find/, 'repos() dies when check() returns 404 error';
	};

	subtest 'dies on JSON parse error' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		queue_curl_response(200, '200 OK', '');
		queue_curl_response(200, '200 OK', 'not-valid-json!!!', '');
		throws_ok {
			$gh->repos();
		} qr/Failed to read repository information/, 'repos() dies on JSON parse error';
	};
};

# ============================================================
# 3d. repo_names() filter logic
# ============================================================

subtest 'repo_names() filter logic' => sub {
	# Pre-populate cache so no curl is needed
	my $gh = Service::Github->new(org => 'test-org');
	$gh->{_repos} = [
		{ name => 'cf-kit'      },
		{ name => 'bosh-kit'    },
		{ name => 'runtime-ci'  },
		{ name => 'concourse-kit'},
	];

	subtest 'returns all names without filter' => sub {
		my $names = $gh->repo_names();
		isa_ok($names, 'ARRAY', 'returns arrayref');
		is(scalar @$names, 4, 'all four repos returned');
	};

	subtest 'filters with regex' => sub {
		my $names = $gh->repo_names(qr/-kit$/);
		is(scalar @$names, 3, 'three kit repos match /-kit$/');
		ok(grep { $_ eq 'cf-kit'       } @$names, 'cf-kit matched');
		ok(grep { $_ eq 'bosh-kit'     } @$names, 'bosh-kit matched');
		ok(grep { $_ eq 'concourse-kit'} @$names, 'concourse-kit matched');
		ok(!(grep { $_ eq 'runtime-ci'  } @$names), 'runtime-ci excluded');
	};

	subtest 'returns empty arrayref when no match' => sub {
		my $names = $gh->repo_names(qr/^no-such-repo$/);
		isa_ok($names, 'ARRAY', 'still returns arrayref');
		is(scalar @$names, 0, 'empty result when nothing matches');
	};
};

# ============================================================
# 3e. releases() method
# ============================================================

subtest 'releases() method' => sub {
	mock_curl();

	subtest 'dies with "Missing repository name" on undef name' => sub {
		reset_mocks();
		my $gh = Service::Github->new();
		throws_ok {
			$gh->releases(undef);
		} qr/Missing repository name/, 'dies with correct message on undef name';
	};

	subtest '404 for non-existent repo with name not in org' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		# Pre-populate repos cache — 'cf-kit' exists, 'missing-kit' does not
		$gh->{_repos} = [{ name => 'cf-kit' }];
		# HEAD check for releases URL returns 404
		queue_curl_response(404, '404 Not Found', '');
		throws_ok {
			$gh->releases('missing-kit');
		} qr/No repository named/, 'dies with "No repository named" for missing repo';
	};

	subtest 'check failure propagates as die' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		# HEAD check returns 403 — releases() should bail
		queue_curl_response(403, '403 Forbidden', '');
		throws_ok {
			$gh->releases('cf-kit');
		} qr/Access forbidden/, 'releases() propagates check() 403 error';
	};

	subtest 'caches results on subsequent calls' => sub {
		reset_mocks();
		my $gh      = Service::Github->new(org => 'test-org');
		my $release = make_release(version => '1.0.0');
		my $body    = encode_json_simple([$release]);
		# HEAD check for releases endpoint
		queue_curl_response(200, '200 OK', '');
		# GET releases — single page (no Link header, so no pagination)
		queue_curl_response(200, '200 OK', $body, '');
		my @r1 = $gh->releases('cf-kit');
		my $call_count = scalar @curl_calls;
		# Second call — must use cache
		my @r2 = $gh->releases('cf-kit');
		is(scalar @curl_calls, $call_count, 'no new curl calls on cached releases()');
		is(scalar @r1, scalar @r2, 'same number of results from cache');
	};
};

# ============================================================
# 3f. get_release_info() — list mode
# ============================================================

subtest 'get_release_info() list mode' => sub {
	mock_curl();

	subtest 'fetches releases and returns (results, errors) list' => sub {
		reset_mocks();
		my $gh    = Service::Github->new(org => 'test-org');
		my @rels  = (make_release(version => '1.0.0'), make_release(version => '1.1.0'));
		# Single page of releases (no Link header, so no pagination)
		queue_curl_response(200, '200 OK', encode_json_simple(\@rels), '');
		my ($results, $errors) = $gh->get_release_info('cf-kit', msg => undef);
		isa_ok($results, 'ARRAY', 'results is arrayref');
		isa_ok($errors,  'ARRAY', 'errors is arrayref');
		is(scalar @$results, 2, 'two releases returned');
		is(scalar @$errors,  0, 'no errors');
	};

	subtest 'caches results; second call returns only cached ref (GH-6)' => sub {
		reset_mocks();
		my $gh   = Service::Github->new(org => 'test-org');
		my @rels = (make_release(version => '2.0.0'));
		# Single page (no Link header)
		queue_curl_response(200, '200 OK', encode_json_simple(\@rels), '');
		my ($r1, $e1) = $gh->get_release_info('my-kit', msg => undef);
		is(scalar @$r1, 1, 'first call returns 1 result');
		# Second call hits cache — returns only the arrayref, $e2 is undef (GH-6)
		my ($r2, $e2) = $gh->get_release_info('my-kit', msg => undef);
		is(scalar @$r2, 1,   'cache hit returns same results');
		is($e2,         undef,'GH-6: second call returns undef for errors (cache-only return)');
	};

	subtest 'non-200 with fatal=0 collects error, does not die' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		# Use '[]' body so load_json succeeds (empty array) and no second error is added.
		# An empty string would cause a JSON parse error and create a second error entry.
		queue_curl_response(503, '503 Service Unavailable', '[]', '');
		my ($results, $errors);
		lives_ok {
			($results, $errors) = $gh->get_release_info('cf-kit', msg => undef, suppress_errors => 1);
		} 'does not die on non-200 with fatal=0';
		is(scalar @$errors, 1, 'error recorded in errors array');
		is($errors->[0]{code}, 503, 'error contains HTTP status code');
	};

	subtest 'non-200 with fatal=1 bails' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		queue_curl_response(503, '503 Service Unavailable', 'down for maintenance', '');
		throws_ok {
			$gh->get_release_info('cf-kit', msg => undef, fatal => 1);
		} qr/Failed to retrieve release information/, 'dies with fatal=1 on non-200';
	};

	subtest 'JSON parse error with fatal=0 collects error' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		queue_curl_response(200, '200 OK', 'not-json{{{', '');
		my ($results, $errors);
		lives_ok {
			($results, $errors) = $gh->get_release_info(
				'cf-kit', msg => undef, suppress_errors => 1
			);
		} 'does not die on JSON parse error with fatal=0';
		ok(scalar @$errors > 0, 'JSON parse error collected');
		like($errors->[0], qr/Failed to read releases/, 'error message mentions parse failure');
	};

	subtest 'JSON parse error with fatal=1 bails' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		queue_curl_response(200, '200 OK', 'not-json-at-all', '');
		throws_ok {
			$gh->get_release_info('cf-kit', msg => undef, fatal => 1);
		} qr/Failed to read releases/, 'dies with fatal=1 on JSON parse error';
	};

	subtest 'non-array JSON response records error' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		# API returns a hash (unexpected), not an array
		queue_curl_response(200, '200 OK', encode_json_simple({ message => 'unexpected' }), '');
		my ($results, $errors);
		lives_ok {
			($results, $errors) = $gh->get_release_info(
				'cf-kit', msg => undef, suppress_errors => 1
			);
		} 'does not die on unexpected non-array JSON';
		ok(scalar @$errors > 0, 'error recorded for non-array response');
		like($errors->[0]{msg}, qr/non-array/, 'error message mentions non-array');
	};

	subtest 'suppress_errors suppresses error output (no die)' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		queue_curl_response(503, '503 Service Unavailable', '', '');
		# With suppress_errors=1 and fatal=0, should not die
		lives_ok {
			$gh->get_release_info('cf-kit', msg => undef, suppress_errors => 1);
		} 'suppress_errors=1 prevents die on non-200';
	};

	subtest 'msg => undef suppresses progress output' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		queue_curl_response(200, '200 OK', encode_json_simple([]), '');
		# Already suppressed info() globally, just confirm it runs cleanly
		lives_ok {
			$gh->get_release_info('cf-kit', msg => undef);
		} 'msg => undef does not cause errors';
	};

	subtest 'empty versions array triggers bug()' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		throws_ok {
			$gh->get_release_info('cf-kit', versions => [], msg => undef);
		} qr/Must specify at least one version/, 'empty versions array triggers bug()';
	};

	subtest 'pagination via Link header' => sub {
		reset_mocks();
		my $gh    = Service::Github->new(org => 'test-org');
		my $page1 = [make_release(version => '1.0.0')];
		my $page2 = [make_release(version => '2.0.0')];
		# First response includes a Link header pointing to page 2
		my $next_url = 'https://api.github.com/repos/test-org/cf-kit/releases?page=2';
		queue_curl_response(
			200, '200 OK',
			encode_json_simple($page1),
			"Link: <$next_url>; rel=\"next\""
		);
		# Second response has no Link header — pagination stops
		queue_curl_response(200, '200 OK', encode_json_simple($page2), '');
		my ($results, $errors) = $gh->get_release_info('link-kit', msg => undef);
		is(scalar @$results, 2, 'pagination collects results from both pages');
		is(scalar @$errors,  0, 'no errors during paginated fetch');
	};
};

# ============================================================
# 3g. get_release_info() — versions mode
# ============================================================

subtest 'get_release_info() versions mode' => sub {
	mock_curl();

	subtest 'fetches specific version by tag URL' => sub {
		reset_mocks();
		my $gh  = Service::Github->new(org => 'test-org');
		my $rel = make_release(version => '1.2.3', tag => 'v1.2.3');
		# First URL tried: bare version (1.2.3) — succeeds
		queue_curl_response(200, '200 OK', encode_json_simple($rel), '');
		my ($results, $errors) = $gh->get_release_info(
			'cf-kit', versions => ['1.2.3'], msg => undef
		);
		isa_ok($results, 'ARRAY', 'results is arrayref in versions mode');
		is(scalar @$results, 1, 'one result returned');
	};

	subtest 'tries v-prefixed tag on 404 fallback' => sub {
		reset_mocks();
		my $gh  = Service::Github->new(org => 'test-org');
		my $rel = make_release(version => '2.0.0', tag => 'v2.0.0');
		# First URL (bare: .../tags/2.0.0) returns 404
		queue_curl_response(404, '404 Not Found', '', '');
		# Second URL (v-prefixed: .../tags/v2.0.0) returns 200
		queue_curl_response(200, '200 OK', encode_json_simple($rel), '');
		my ($results, $errors) = $gh->get_release_info(
			'cf-kit', versions => ['2.0.0'], msg => undef
		);
		is(scalar @$results, 1, 'found via v-prefixed fallback URL');
	};

	subtest 'fatal=1 bails on non-404 error in versions mode' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		# In versions mode, 404s are silently skipped (v-prefix fallback).
		# A non-404 error with fatal=1 triggers bail immediately.
		queue_curl_response(500, '500 Server Error', 'down', '');
		throws_ok {
			$gh->get_release_info('cf-kit', versions => ['3.0.0'], fatal => 1, msg => undef);
		} qr/Failed to retrieve release information/, 'fatal=1 bails on non-404 error in versions mode';
	};

	subtest 'uses cache for already-fetched versions' => sub {
		reset_mocks();
		my $gh  = Service::Github->new(org => 'test-org');
		my $rel = make_release(version => '1.0.0', tag => 'v1.0.0');
		# Pre-populate the version cache
		$gh->{_release_versions}{'cf-kit'}{'1.0.0'} = $rel;
		# No curl responses queued — if cache works, no curl is called
		my ($results, $errors) = $gh->get_release_info(
			'cf-kit', versions => ['1.0.0'], msg => undef
		);
		is(scalar @curl_calls, 0, 'no curl call when version is cached');
		is(scalar @$results,   1, 'cached version returned in results');
	};
};

# ============================================================
# 3h. versions() method
# ============================================================

subtest 'versions() method' => sub {
	# Pre-populate the releases cache so versions() does not trigger curl
	my $gh = Service::Github->new(org => 'test-org');
	my $kit = 'cf-kit';

	my $stable_rel = {
		tag_name     => 'v1.0.0',
		body         => 'Stable release',
		draft        => 0,
		prerelease   => 0,
		published_at => '2024-01-01T00:00:00Z',
		created_at   => '2024-01-01T00:00:00Z',
		assets       => [make_asset(name => 'cf-kit', url => 'https://dl.example.com/cf-kit-1.0.0')],
	};
	my $draft_rel = {
		tag_name     => 'v1.1.0-draft',
		body         => 'Draft release',
		draft        => 1,
		prerelease   => 0,
		published_at => '2024-02-01T00:00:00Z',
		created_at   => '2024-02-01T00:00:00Z',
		assets       => [make_asset(name => 'cf-kit', url => 'https://dl.example.com/cf-kit-1.1.0')],
	};
	my $pre_rel = {
		tag_name     => 'v2.0.0-rc1',
		body         => 'Pre-release',
		draft        => 0,
		prerelease   => 1,
		published_at => '2024-03-01T00:00:00Z',
		created_at   => '2024-03-01T00:00:00Z',
		assets       => [make_asset(name => 'cf-kit', url => 'https://dl.example.com/cf-kit-2.0.0-rc1')],
	};
	my $newer_stable = {
		tag_name     => 'v1.2.0',
		body         => 'Newer stable',
		draft        => 0,
		prerelease   => 0,
		published_at => '2024-04-01T00:00:00Z',
		created_at   => '2024-04-01T00:00:00Z',
		assets       => [make_asset(name => 'cf-kit', url => 'https://dl.example.com/cf-kit-1.2.0')],
	};
	my $no_asset_rel = {
		tag_name     => 'v0.9.0',
		body         => 'Old release, no asset',
		draft        => 0,
		prerelease   => 0,
		published_at => '2023-01-01T00:00:00Z',
		created_at   => '2023-01-01T00:00:00Z',
		assets       => [],
	};
	my $named_asset_rel = {
		tag_name     => 'v3.0.0',
		body         => 'Named asset release',
		draft        => 0,
		prerelease   => 0,
		published_at => '2024-05-01T00:00:00Z',
		created_at   => '2024-05-01T00:00:00Z',
		assets       => [
			make_asset(name => 'cf-kit-3.0.0.tar.gz', url => 'https://dl.example.com/cf-kit-3.0.0.tar.gz'),
			make_asset(name => 'cf-kit',               url => 'https://dl.example.com/cf-kit-3.0.0'),
		],
	};

	$gh->{_releases}{$kit} = [
		$stable_rel, $draft_rel, $pre_rel, $newer_stable, $no_asset_rel, $named_asset_rel
	];

	subtest 'returns version descriptor hashes' => sub {
		my @vers = $gh->versions($kit);
		ok(scalar @vers > 0, 'returns at least one version');
		my $v = $vers[0];
		ok(exists $v->{version},    'has version key');
		ok(exists $v->{body},       'has body key');
		ok(exists $v->{draft},      'has draft key');
		ok(exists $v->{prerelease}, 'has prerelease key');
		ok(exists $v->{date},       'has date key');
		ok(exists $v->{url},        'has url key');
		ok(exists $v->{filename},   'has filename key');
	};

	subtest 'strips v prefix from tag_name' => sub {
		my @vers = $gh->versions($kit);
		for my $v (@vers) {
			unlike($v->{version}, qr/^v/, "version '$v->{version}' has no leading v");
		}
	};

	subtest 'excludes drafts by default' => sub {
		my @vers = $gh->versions($kit);
		ok(!(grep { $_->{draft} } @vers), 'no draft releases in default output');
	};

	subtest 'includes drafts with include_drafts=1' => sub {
		my @vers = $gh->versions($kit, include_drafts => 1);
		ok((grep { $_->{draft} } @vers), 'draft release present with include_drafts=1');
	};

	subtest 'excludes prereleases by default' => sub {
		my @vers = $gh->versions($kit);
		ok(!(grep { $_->{prerelease} } @vers), 'no prerelease in default output');
	};

	subtest 'includes prereleases with include_prereleases=1' => sub {
		my @vers = $gh->versions($kit, include_prereleases => 1);
		ok((grep { $_->{prerelease} } @vers), 'prerelease present with include_prereleases=1');
	};

	subtest 'version=latest returns newest by semver' => sub {
		my @vers = $gh->versions($kit, version => 'latest');
		is(scalar @vers, 1, 'version=latest returns exactly one result');
		is($vers[0]{version}, '3.0.0', 'latest is the highest semver stable release');
	};

	subtest 'specific version auto-includes drafts and prereleases' => sub {
		my @vers = $gh->versions($kit, version => '1.1.0-draft');
		# 1.1.0-draft is the tag_name with v stripped of 'v1.1.0-draft' = '1.1.0-draft'
		ok(scalar @vers > 0, 'specific version lookup finds draft release');
		is($vers[0]{draft}, 1, 'found release is indeed a draft');
	};

	subtest 'specific version matches with or without v prefix' => sub {
		my @with_v = $gh->versions($kit, version => 'v1.0.0');
		my @without_v = $gh->versions($kit, version => '1.0.0');
		is(scalar @with_v,    1, 'matches with v prefix');
		is(scalar @without_v, 1, 'matches without v prefix');
		is($with_v[0]{version}, $without_v[0]{version}, 'same version found either way');
	};

	subtest 'asset_filter selects correct asset' => sub {
		my @vers = $gh->versions($kit, asset_filter => qr/^cf-kit$/);
		my ($v3) = grep { $_->{version} eq '3.0.0' } @vers;
		is($v3->{filename}, 'cf-kit', 'asset_filter selects asset named "cf-kit"');
	};

	subtest 'asset_filter [#version#] placeholder replaced' => sub {
		# The [#version#] substitution works on the string form of the filter.
		# When passing a compiled qr//, the brackets get escaped in the stringified
		# form and the substitution cannot find them.  The placeholder is designed
		# for string-valued filters or patterns where [#version#] appears literally.
		# We construct a regex string and verify the version is substituted before
		# matching, so 'cf-kit-3.0.0.tar.gz' is selected for version 3.0.0.
		my $filter = qr/^cf-kit-[#version#]\.tar\.gz$/;  # [#version#] is char class here
		# After copy+substitution: [#version#] → 3.0.0, giving qr/^cf-kit-3.0.0.tar.gz$/
		# This relies on the regex character class [#version#] being replaced by the version
		# string during substitution on the regex's string representation.
		# Note: this only works because [#version#] in a regex char class matches '#','v','e',
		# etc., but after substitution on the _compiled_ regex string the literal text
		# '[#version#]' in (?^:...) is replaced.  Actual behaviour depends on Perl internals.
		#
		# The canonical use of this feature is with a string, not a qr//:
		my @vers = $gh->versions($kit, asset_filter => '^cf-kit-[#version#]\.tar\.gz$');
		my ($v3) = grep { $_->{version} eq '3.0.0' } @vers;
		is($v3->{filename}, 'cf-kit-3.0.0.tar.gz',
			'[#version#] placeholder replaced in string asset_filter');
	};

	subtest 'missing asset yields empty url and filename' => sub {
		my @vers = $gh->versions($kit);
		my ($v09) = grep { $_->{version} eq '0.9.0' } @vers;
		is($v09->{url},      '', 'url is empty string when no matching asset');
		is($v09->{filename}, '', 'filename is empty string when no matching asset');
	};
};

# ============================================================
# 3i. fetch_release() method
# ============================================================

subtest 'fetch_release() method' => sub {
	mock_curl();

	# Helper: pre-populate releases cache with a standard release.
	# The asset name is 'cf-kit' (no version) so it matches the default
	# asset_filter of qr/^cf-kit$/ used by versions().
	my $make_gh_with_releases = sub {
		my (%args) = @_;
		my $gh       = Service::Github->new(org => 'test-org');
		my $ver      = $args{version}  // '1.0.0';
		my $url      = $args{url}      // "https://dl.example.com/cf-kit-$ver.tgz";
		my $filename = $args{filename} // 'cf-kit';
		$gh->{_releases}{'cf-kit'} = [{
			tag_name     => "v$ver",
			body         => "Release $ver",
			draft        => 0,
			prerelease   => 0,
			published_at => '2024-01-01T00:00:00Z',
			created_at   => '2024-01-01T00:00:00Z',
			assets       => [{ name => $filename, browser_download_url => $url }],
		}];
		return ($gh, $ver, $url, $filename);
	};

	subtest 'downloads and returns ($name, $version, $file)' => sub {
		reset_mocks();
		my ($gh, $ver, $url, $fn) = $make_gh_with_releases->();
		my $tmpdir = File::Temp::tempdir(CLEANUP => 1);

		# curl for download
		queue_curl_response(200, '200 OK', 'binary-content-here', '');

		# Mock file-system helpers
		no warnings 'redefine';
		local *Service::Github::mkfile_or_fail = sub { 1 };
		local *Service::Github::debug          = sub { };
		use warnings 'redefine';

		my ($rname, $rver, $rfile) = $gh->fetch_release('cf-kit', '1.0.0', $tmpdir);
		is($rname, 'cf-kit',  'returned name is correct');
		is($rver,  '1.0.0',  'returned version is correct');
		is($rfile, "$tmpdir/cf-kit", 'returned file path is path/filename');
	};

	subtest 'resolves latest version when version is undef' => sub {
		reset_mocks();
		my ($gh, $ver, $url, $fn) = $make_gh_with_releases->();
		my $tmpdir = File::Temp::tempdir(CLEANUP => 1);

		queue_curl_response(200, '200 OK', 'data', '');

		no warnings 'redefine';
		local *Service::Github::mkfile_or_fail = sub { 1 };
		local *Service::Github::debug          = sub { };
		use warnings 'redefine';

		my ($rname, $rver, $rfile) = $gh->fetch_release('cf-kit', undef, $tmpdir);
		is($rver, '1.0.0', 'resolved latest version correctly');
	};

	subtest 'dies "No latest version..." when no downloadable version' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		# Release exists but asset URL is empty
		$gh->{_releases}{'no-url-kit'} = [{
			tag_name     => 'v1.0.0',
			body         => '',
			draft        => 0,
			prerelease   => 0,
			published_at => '2024-01-01T00:00:00Z',
			created_at   => '2024-01-01T00:00:00Z',
			assets       => [],
		}];
		throws_ok {
			$gh->fetch_release('no-url-kit', undef, '/tmp');
		} qr/No latest version/, 'dies when no downloadable release';
	};

	subtest 'dies "Release .../... was not found" for missing version' => sub {
		reset_mocks();
		my ($gh) = $make_gh_with_releases->(version => '1.0.0');
		throws_ok {
			$gh->fetch_release('cf-kit', '99.0.0', '/tmp');
		} qr/Release cf-kit\/99\.0\.0 was not found/, 'dies when version not in releases';
	};

	subtest 'dies when release is missing its resource url' => sub {
		reset_mocks();
		my $gh = Service::Github->new(org => 'test-org');
		# Release with no download URL
		$gh->{_releases}{'cf-kit'} = [{
			tag_name     => 'v2.0.0',
			body         => 'Release notes here',
			draft        => 0,
			prerelease   => 0,
			published_at => '2024-01-01T00:00:00Z',
			created_at   => '2024-01-01T00:00:00Z',
			assets       => [{ name => 'cf-kit.tgz', browser_download_url => '' }],
		}];
		throws_ok {
			$gh->fetch_release('cf-kit', '2.0.0', '/tmp');
		} qr/missing its resource url/, 'dies when release has no download URL';
	};

	subtest 'dies on download HTTP failure' => sub {
		reset_mocks();
		my ($gh) = $make_gh_with_releases->();
		# Download returns non-200
		queue_curl_response(503, '503 Service Unavailable', '', '');
		throws_ok {
			$gh->fetch_release('cf-kit', '1.0.0', '/tmp');
		} qr/Failed to download/, 'dies on non-200 download response';
	};

	subtest 'force=1 overwrites without prompting' => sub {
		reset_mocks();
		my ($gh, $ver, $url, $fn) = $make_gh_with_releases->();
		my $tmpdir = File::Temp::tempdir(CLEANUP => 1);
		my $file   = "$tmpdir/$fn";

		# Create a pre-existing file to trigger the overwrite path
		open my $fh, '>', $file or die "Cannot create $file: $!";
		print $fh "old content";
		close $fh;

		queue_curl_response(200, '200 OK', 'new content', '');

		no warnings 'redefine';
		local *Service::Github::mkfile_or_fail = sub { 1 };
		local *Service::Github::chmod_or_fail  = sub { 1 };
		local *Service::Github::debug          = sub { };
		use warnings 'redefine';

		my ($rname, $rver, $rfile);
		lives_ok {
			($rname, $rver, $rfile) = $gh->fetch_release('cf-kit', '1.0.0', $tmpdir, 1);
		} 'force=1 does not prompt or die on pre-existing file';
		is($rname, 'cf-kit', 'returned name correct with force');
	};
};

# ============================================================
# 3j. latest_version_of() method
# ============================================================

subtest 'latest_version_of() method' => sub {
	subtest 'dies "Missing name..." when name not provided' => sub {
		my $gh = Service::Github->new();
		throws_ok {
			$gh->latest_version_of(undef);
		} qr/Missing name for retrieving release/, 'dies on undef name';

		throws_ok {
			$gh->latest_version_of('');
		} qr/Missing name for retrieving release/, 'dies on empty string name';
	};

	subtest 'returns version string of latest with URL' => sub {
		my $gh = Service::Github->new(org => 'test-org');
		$gh->{_releases}{'cf-kit'} = [
			{
				tag_name     => 'v1.0.0',
				body         => '',
				draft        => 0,
				prerelease   => 0,
				published_at => '2024-01-01T00:00:00Z',
				created_at   => '2024-01-01T00:00:00Z',
				assets       => [make_asset(name => 'cf-kit', url => 'https://dl.example.com/cf-kit')],
			},
			{
				tag_name     => 'v0.9.0',
				body         => '',
				draft        => 0,
				prerelease   => 0,
				published_at => '2023-01-01T00:00:00Z',
				created_at   => '2023-01-01T00:00:00Z',
				assets       => [make_asset(name => 'cf-kit', url => 'https://dl.example.com/cf-kit-old')],
			},
		];
		my $ver = $gh->latest_version_of('cf-kit');
		is($ver, '1.0.0', 'returns version of newest release with URL');
	};

	subtest 'returns undef when no version has URL' => sub {
		my $gh = Service::Github->new(org => 'test-org');
		$gh->{_releases}{'empty-kit'} = [{
			tag_name     => 'v1.0.0',
			body         => '',
			draft        => 0,
			prerelease   => 0,
			published_at => '2024-01-01T00:00:00Z',
			created_at   => '2024-01-01T00:00:00Z',
			assets       => [],
		}];
		my $ver = $gh->latest_version_of('empty-kit');
		is($ver, undef, 'returns undef when no release has a download URL');
	};

	subtest 'GH-7 resolved: include_prereleases works in latest_version_of' => sub {
		# The POD documents GH-7 as a key-name mismatch (include_prerelease vs
		# include_prereleases), but the current source passes the correct plural
		# key. This test documents the actual current (fixed) behaviour.
		my $gh = Service::Github->new(org => 'test-org');
		$gh->{_releases}{'rc-kit'} = [
			{
				tag_name     => 'v2.0.0-rc1',
				body         => '',
				draft        => 0,
				prerelease   => 1,
				published_at => '2024-06-01T00:00:00Z',
				created_at   => '2024-06-01T00:00:00Z',
				assets       => [make_asset(name => 'rc-kit', url => 'https://dl.example.com/rc')],
			},
			{
				tag_name     => 'v1.0.0',
				body         => '',
				draft        => 0,
				prerelease   => 0,
				published_at => '2024-01-01T00:00:00Z',
				created_at   => '2024-01-01T00:00:00Z',
				assets       => [make_asset(name => 'rc-kit', url => 'https://dl.example.com/stable')],
			},
		];
		# Without include_prereleases: stable only
		my $stable = $gh->latest_version_of('rc-kit');
		is($stable, '1.0.0',
			'without include_prereleases, returns latest stable');

		# With include_prereleases => 1: RC is included and wins by semver
		my $with_rc = $gh->latest_version_of('rc-kit', include_prereleases => 1);
		is($with_rc, '2.0.0-rc1',
			'with include_prereleases => 1, RC is included and is the latest');
	};
};

# ============================================================
# 3k. get_user_ssh_keys() unit tests
# ============================================================

subtest 'get_user_ssh_keys() method' => sub {
	mock_curl();

	my $valid_rsa     = 'ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA test@host';
	my $valid_ed25519 = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG user@machine';
	my $invalid_key   = 'not-a-valid-ssh-key';

	subtest 'constructs correct HTTPS URL for github.com' => sub {
		reset_mocks();
		my $gh = Service::Github->new(domain => 'github.com');
		queue_curl_response(200, '200 OK', $valid_ed25519, '');
		$gh->get_user_ssh_keys('octocat');
		like($curl_calls[0][1], qr|^https://github\.com/octocat\.keys$|,
			'correct HTTPS URL constructed for github.com');
	};

	subtest 'constructs HTTP URL when tls=no' => sub {
		reset_mocks();
		my $gh = Service::Github->new(domain => 'github.com', tls => 'no');
		queue_curl_response(200, '200 OK', $valid_ed25519, '');
		$gh->get_user_ssh_keys('octocat');
		like($curl_calls[0][1], qr|^http://github\.com/octocat\.keys$|,
			'HTTP URL used when tls=no');
	};

	subtest 'passes skip_verify=1 when tls=skip (GH-5: only method that honors tls=skip)' => sub {
		# GH-5: get_user_ssh_keys is the ONLY method that checks $self->{tls}
		# to set skip_verify in the curl call.  All other API methods (check,
		# repos, get_release_info) hard-code skip_verify=0 regardless of the
		# tls setting.  This test documents the correct behavior for this
		# method; see the check() tests where skip_verify is always 0.
		reset_mocks();
		my $gh = Service::Github->new(domain => 'github.com', tls => 'skip');
		queue_curl_response(200, '200 OK', $valid_ed25519, '');
		$gh->get_user_ssh_keys('octocat');
		# Curl call args: ($method, $url, $headers, $data, $skip_verify, $creds)
		is($curl_calls[0][4], 1, 'skip_verify=1 passed when tls=skip');
	};

	subtest 'returns error on 404' => sub {
		reset_mocks();
		my $gh = Service::Github->new(domain => 'github.com');
		queue_curl_response(404, '404 Not Found', '', '');
		my ($keys, $err) = $gh->get_user_ssh_keys('no-such-user');
		is($keys, undef,         'keys is undef on 404');
		like($err, qr/not found/, '404 error mentions "not found"');
		like($err, qr/no-such-user/, '404 error mentions the username');
	};

	subtest 'returns error on 403 with rate limit message' => sub {
		reset_mocks();
		my $gh = Service::Github->new(domain => 'github.com');
		queue_curl_response(403, '403 Forbidden', '', '');
		my ($keys, $err) = $gh->get_user_ssh_keys('octocat');
		is($keys, undef,              'keys is undef on 403');
		like($err, qr/Rate limit/,    '403 error mentions rate limit');
		like($err, qr/GITHUB_AUTH_TOKEN/, '403 error mentions GITHUB_AUTH_TOKEN');
	};

	subtest 'returns error on other HTTP errors' => sub {
		reset_mocks();
		my $gh = Service::Github->new(domain => 'github.com');
		queue_curl_response(500, '500 Internal Server Error', '', '');
		my ($keys, $err) = $gh->get_user_ssh_keys('octocat');
		is($keys, undef,             'keys is undef on 500');
		like($err, qr/HTTP Error 500/, '500 error contains status code');
	};

	subtest 'filters out invalid keys' => sub {
		reset_mocks();
		my $gh   = Service::Github->new(domain => 'github.com');
		my $body = join("\n", $valid_rsa, $invalid_key, $valid_ed25519, '');
		queue_curl_response(200, '200 OK', $body, '');
		my ($keys, $err) = $gh->get_user_ssh_keys('octocat');
		is($err, undef, 'no error on success');
		is(scalar @$keys, 2, 'only valid keys returned');
		ok(grep { $_ eq $valid_rsa     } @$keys, 'valid RSA key included');
		ok(grep { $_ eq $valid_ed25519 } @$keys, 'valid ed25519 key included');
	};

	subtest 'handles empty response (no keys)' => sub {
		reset_mocks();
		my $gh = Service::Github->new(domain => 'github.com');
		queue_curl_response(200, '200 OK', '', '');
		my ($keys, $err) = $gh->get_user_ssh_keys('octocat');
		is($err,          undef, 'no error on empty response');
		isa_ok($keys,     'ARRAY', 'returns arrayref');
		is(scalar @$keys, 0,     'empty arrayref for empty response');
	};

	subtest 'dies on missing username' => sub {
		reset_mocks();
		my $gh = Service::Github->new();
		throws_ok {
			$gh->get_user_ssh_keys(undef);
		} qr/Missing username/, 'dies on undef username';

		throws_ok {
			$gh->get_user_ssh_keys('');
		} qr/Missing username/, 'dies on empty username';
	};

	subtest 'dies on invalid username format' => sub {
		reset_mocks();
		my $gh = Service::Github->new();
		throws_ok {
			$gh->get_user_ssh_keys('-starts-with-hyphen');
		} qr/Invalid username format/, 'dies on username starting with hyphen';

		throws_ok {
			$gh->get_user_ssh_keys('has spaces');
		} qr/Invalid username format/, 'dies on username with spaces';

		throws_ok {
			$gh->get_user_ssh_keys('has@at');
		} qr/Invalid username format/, 'dies on username with @ symbol';
	};
};

# ============================================================
# 3l. GitLab / Enterprise domain compatibility
# ============================================================

subtest 'GitLab and enterprise domain compatibility' => sub {
	subtest 'SSH keys URL uses gitlab.com domain correctly' => sub {
		mock_curl();
		reset_mocks();
		my $gh = Service::Github->new(domain => 'gitlab.com', org => 'my-group');
		queue_curl_response(200, '200 OK', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG user', '');
		$gh->get_user_ssh_keys('devuser');
		like($curl_calls[0][1], qr|^https://gitlab\.com/devuser\.keys$|,
			'SSH keys URL uses gitlab.com domain');
	};

	subtest 'base_url uses custom enterprise domain' => sub {
		my $gh = Service::Github->new(domain => 'github.corp.example.com', org => 'acme');
		is($gh->base_url, 'https://api.github.corp.example.com',
			'base_url uses enterprise domain');
	};

	subtest 'repos_url uses custom org on enterprise domain' => sub {
		my $gh = Service::Github->new(domain => 'github.corp.example.com', org => 'acme');
		like($gh->repos_url, qr|acme/repos$|,
			'repos_url contains custom org name');
		like($gh->repos_url, qr|api\.github\.corp\.example\.com|,
			'repos_url contains enterprise domain');
	};

	subtest 'releases_url uses custom domain and org' => sub {
		my $gh = Service::Github->new(domain => 'github.corp.example.com', org => 'acme');
		my $url = $gh->releases_url('my-kit');
		like($url, qr|api\.github\.corp\.example\.com|, 'enterprise domain in releases_url');
		like($url, qr|acme/my-kit/releases|,            'org and kit name in releases_url');
	};
};

# ============================================================
# 3m. Rate Limiting / Error Handling Cross-Cutting
# ============================================================

subtest 'Rate limiting and error handling cross-cutting' => sub {
	mock_curl();

	subtest 'check() 403 produces throttling message' => sub {
		reset_mocks();
		my $gh = Service::Github->new();
		queue_curl_response(403, '403 Forbidden', '');
		my $status = $gh->check();
		like($status, qr/throttling/,    'check() 403 mentions throttling');
		like($status, qr/GITHUB_USER/,   'check() 403 mentions GITHUB_USER');
		like($status, qr/GITHUB_AUTH_TOKEN/, 'check() 403 mentions GITHUB_AUTH_TOKEN');
	};

	subtest 'get_user_ssh_keys 403 produces rate limit message' => sub {
		reset_mocks();
		my $gh = Service::Github->new();
		queue_curl_response(403, '403 Forbidden', '', '');
		my ($keys, $err) = $gh->get_user_ssh_keys('octocat');
		like($err, qr/Rate limit/, 'get_user_ssh_keys 403 mentions rate limit');
		like($err, qr/GITHUB_AUTH_TOKEN/, 'get_user_ssh_keys 403 mentions token');
	};

	subtest 'credentials flow through to all curl calls' => sub {
		reset_mocks();
		local $ENV{GITHUB_USER}       = 'alice';
		local $ENV{GITHUB_AUTH_TOKEN} = 'mytoken';
		my $gh = Service::Github->new();

		# check() — HEAD call
		queue_curl_response(200, '200 OK', '');
		$gh->check();
		is($curl_calls[-1][5], 'alice:mytoken',
			'check() passes credentials to curl');

		# get_authorized_user() — GET /user
		queue_curl_response(200, '200 OK', encode_json_simple({ login => 'alice' }), '');
		$gh->get_authorized_user();
		is($curl_calls[-1][5], 'alice:mytoken',
			'get_authorized_user() passes credentials to curl');

		# repos() — HEAD + GET
		queue_curl_response(200, '200 OK', '');
		queue_curl_response(200, '200 OK', encode_json_simple([{ name => 'r' }]), '');
		queue_curl_response(200, '200 OK', encode_json_simple([]), '');
		$gh->repos();
		# Last curl call is a GET — should have creds
		is($curl_calls[-1][5], 'alice:mytoken',
			'repos() GET passes credentials to curl');
	};
};

done_testing;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
