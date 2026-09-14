#!/usr/bin/env perl
# The GitHub double answers and records, so the pull request rows of M16 can
# declare a review state, close and merge, and read every call back.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use JSON::PP;

use Genesis;
use Service::Github;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the double answers a pull request listing' => sub {
	plan tests => 4;

	my $h  = make_harness(envs => ['prod'], vault => 0, github => 1);
	my $gh = $h->gh;

	my $number = gh_pull_request($gh,
		env    => 'prod',
		head   => $h->pr_branch('prod'),
		base   => $h->slug('prod'),
		title  => '[pipeline] control@abcdef012345 -> prod',
		review => 'approved',
	);

	local $ENV{PATH} = join ':', $gh->{bin}, $ENV{PATH};
	local $ENV{GITHUB_AUTH_TOKEN} = $gh->{token};

	my $client = Service::Github->new(domain => $gh->{domain}, tls => 'no');
	my $prs = $client->list_prs($gh->{repository}, state => 'open');

	is(scalar @$prs, 1, 'one open pull request');
	is($prs->[0]{number}, $number, 'it carries the number the double gave');
	like($prs->[0]{title}, qr/control\@abcdef012345/, 'and the marker title');

	my @calls = gh_calls($gh);
	is(scalar(grep {$_->{method} eq 'GET'} @calls), 1, 'one read was recorded');
};

subtest 'a merged pull request and an unreachable API' => sub {
	plan tests => 3;

	my $h  = make_harness(envs => ['prod'], vault => 0, github => 1);
	my $gh = $h->gh;
	my $number = gh_pull_request($gh, env => 'prod', review => 'approved');
	gh_merge_pr($gh, $number, method => 'rebase');

	local $ENV{PATH} = join ':', $gh->{bin}, $ENV{PATH};
	local $ENV{GITHUB_AUTH_TOKEN} = $gh->{token};
	my $client = Service::Github->new(domain => $gh->{domain}, tls => 'no');

	my $open = $client->list_prs($gh->{repository}, state => 'open');
	is(scalar @$open, 0, 'the merged pull request is no longer open');

	gh_unreachable($gh);
	my ($code) = Genesis::curl('GET', $client->pulls_url($gh->{repository}));
	is($code, 599, 'an unreachable API reads as a failed curl');

	gh_reachable($gh);
	my ($again) = Genesis::curl('GET', $client->pulls_url($gh->{repository}));
	is($again, 200, 'and it answers again once it is back');
};

subtest 'a closed request and the protection endpoints' => sub {
	plan tests => 4;

	my $h  = make_harness(envs => ['prod'], vault => 0, github => 1);
	my $gh = $h->gh;
	my $number = gh_pull_request($gh, env => 'prod', review => 'none');
	gh_close_pr($gh, $number);

	local $ENV{PATH} = join ':', $gh->{bin}, $ENV{PATH};
	local $ENV{GITHUB_AUTH_TOKEN} = $gh->{token};
	my $client = Service::Github->new(domain => $gh->{domain}, tls => 'no');

	is(scalar @{$client->list_prs($gh->{repository}, state => 'open')}, 0,
		'a closed pull request has left the open set');
	is(scalar @{$client->list_prs($gh->{repository}, state => 'closed')}, 1,
		'and is there when the closed set is asked for');

	my $branch   = $h->slug('prod');
	my $settings = gh_protection($gh, branch => $branch,
		settings => {required_approving_review_count => 2});
	is($settings->{$branch}{required_approving_review_count}, 2,
		'the declared protection settings read back');

	gh_protection($gh, admin => 0);
	# Service::Github renders no protection url of its own, so the row that
	# reads the endpoint spells it out.
	my ($code) = Genesis::curl('GET', sprintf('%s/repos/%s/branches/%s/protection',
		$client->base_url, $gh->{repository}, $branch));
	is($code, 403, 'a token without admin is refused the protection endpoint');
};

subtest 'a review reads back as a review' => sub {
	plan tests => 3;

	my $h  = make_harness(envs => ['prod'], vault => 0, github => 1);
	my $gh = $h->gh;
	my $number = gh_pull_request($gh, env => 'prod',
		review => 'approved', reviewer => 'someone');

	local $ENV{PATH} = join ':', $gh->{bin}, $ENV{PATH};
	local $ENV{GITHUB_AUTH_TOKEN} = $gh->{token};
	my $client = Service::Github->new(domain => $gh->{domain}, tls => 'no');

	my ($code, undef, $data) = Genesis::curl('GET',
		$client->pulls_url($gh->{repository}, $number) . '/reviews');
	is($code, 200, 'the reviews endpoint answers');

	my $reviews = JSON::PP->new->decode($data);
	is(scalar @$reviews, 1,
		'one review, and not the listing the collection would have given');
	is($reviews->[0]{state}, 'APPROVED', 'in the state the row declared');
};

subtest 'a created pull request is there when the collection is listed' => sub {
	plan tests => 4;

	my $h  = make_harness(envs => ['prod'], vault => 0, github => 1);
	my $gh = $h->gh;

	local $ENV{PATH} = join ':', $gh->{bin}, $ENV{PATH};
	local $ENV{GITHUB_AUTH_TOKEN} = $gh->{token};
	my $client = Service::Github->new(domain => $gh->{domain}, tls => 'no');

	my $pr = $client->create_pr($gh->{repository},
		head  => $h->pr_branch('prod'),
		base  => $h->slug('prod'),
		title => '[pipeline] control@abcdef012345 -> prod',
		body  => 'the aggregate this branch is owed',
	);
	ok($pr->{number}, 'the create answered a number');

	my $open = $client->list_prs($gh->{repository}, state => 'open');
	is(scalar @$open, 1, 'and the listing after it sees what was made');
	is($open->[0]{number}, $pr->{number}, 'under the number the create gave');

	my ($post) = grep {$_->{method} eq 'POST'} gh_calls($gh);
	like($post->{body}, qr/control\@abcdef012345/,
		'and the POST was recorded with its body');
};

subtest 'a call that names a file gets the body there' => sub {
	plan tests => 4;

	my $h  = make_harness(envs => ['prod'], vault => 0, github => 1);
	my $gh = $h->gh;

	local $ENV{PATH} = join ':', $gh->{bin}, $ENV{PATH};
	local $ENV{GITHUB_AUTH_TOKEN} = $gh->{token};
	my $client = Service::Github->new(domain => $gh->{domain}, tls => 'no');

	# This is the shape the real curl takes when it is handed a file, and
	# the one Genesis::curl reads back, so the double has to take it too.
	my $into = "$h->{tmp}/the-user.json";
	my ($code, undef, $answered) = Genesis::curl(
		{method => 'GET', file => $into}, $client->base_url . '/user');

	is($code, 200, 'the call answers');
	is($answered, $into, 'and hands back the file it was told to write');
	ok(-f $into, 'which the double created');
	like(helper::get_file($into), qr/"login"/,
		'and wrote the body into rather than onto stdout');
};

subtest 'six calls at once keep every change and every line' => sub {
	plan tests => 3;

	my $h  = make_harness(envs => ['prod'], vault => 0, github => 1);
	my $gh = $h->gh;

	local $ENV{PATH} = join ':', $gh->{bin}, $ENV{PATH};
	local $ENV{GITHUB_AUTH_TOKEN} = $gh->{token};
	my $client = Service::Github->new(domain => $gh->{domain}, tls => 'no');
	my $url    = $client->pulls_url($gh->{repository});

	# Six creates from six processes, which is how a spawned command reaches
	# the double.  Each rewrites the state file whole and appends a line to
	# the call log, so both are read, changed, and written under a lock of
	# their own or the six lose one another.
	my $script = <<'SCRIPT';
for n in 1 2 3 4 5 6 ; do
  curl -sSL -X POST -D /dev/null -d "{\"title\":\"pull request $n\"}" \
    "$1" >/dev/null 2>&1 &
done
wait
SCRIPT
	run({}, 'bash', '-c', $script, 'six-creates', $url);

	my $open = $client->list_prs($gh->{repository}, state => 'open');
	is(scalar @$open, 6, 'every one of the six creates is in the state file');
	is_deeply([sort map {$_->{title}} @$open],
		[map {"pull request $_"} 1 .. 6], 'each under the title it sent');

	# Every line is decoded on the way back, so a line another call tore in
	# half would take this read down rather than pass unnoticed.
	my @posts = grep {$_->{method} eq 'POST'} gh_calls($gh);
	is(scalar @posts, 6, 'and every one of the six lines is in the call log');
};

subtest 'a torn line in the log fails a row and not the file' => sub {
	plan tests => 3;

	my $h  = make_harness(envs => ['prod'], vault => 0, github => 1);
	my $gh = $h->gh;
	gh_pull_request($gh, env => 'prod', review => 'approved');

	local $ENV{PATH} = join ':', $gh->{bin}, $ENV{PATH};
	local $ENV{GITHUB_AUTH_TOKEN} = $gh->{token};
	my $client = Service::Github->new(domain => $gh->{domain}, tls => 'no');
	$client->list_prs($gh->{repository}, state => 'open');

	# Half a line, which is what the row above would read if two writers
	# ever landed on the log at once.  A reader that died inside the decoder
	# would take this file down where the row that asked should have failed.
	helper::put_file($gh->{log}, helper::get_file($gh->{log})
		. '{"method":"POST","url":"https://api.github.te');

	my @calls;
	ok(eval {@calls = gh_calls($gh); 1},
		'the reader answers rather than dying inside the decoder');
	is(scalar(grep {($_->{method} // '') eq 'GET'} @calls), 1,
		'the whole lines still read back as themselves');
	is(scalar(grep {$_->{torn}} @calls), 1,
		'and the half line is one record a row can fail on');
};

subtest 'a token withheld from one run and back for the next' => sub {
	# Two of the six are the restoration each run asserts for itself.
	plan tests => 6;

	my $h  = make_harness(envs => ['qa'], vault => 0, github => 1);
	my $gh = $h->gh;

	gh_no_token($h);
	run_genesis($h, 'update', '--check');

	my @withheld = gh_calls($gh);
	ok(scalar(@withheld), 'the withheld run still reached the fixture curl');
	ok(!(grep {defined $_->{token}} @withheld),
		'and every call it made carried no token');

	run_genesis($h, 'update', '--check');

	my @after = gh_calls($gh);
	my @next  = @after[scalar(@withheld) .. $#after];
	ok(scalar(@next), 'the next run reached it too');
	is(scalar(grep {($_->{token} // '') eq $gh->{token}} @next), scalar(@next),
		'and every call it made carried the token again');
};

done_testing;
