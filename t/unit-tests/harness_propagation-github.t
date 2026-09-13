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
