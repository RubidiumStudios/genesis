#!/usr/bin/env perl
# Proves T19's judgement at the unit level: a host is judged GitHub by the
# headers on its own answers and never by its name, github.com is never judged
# or cached, an enterprise host is recorded with its version and base, a
# non-GitHub answer or a 410 is retried once and then refused at CONFIG, a 404
# that GitHub gave goes to the caller unretried, and a call that gets no
# answer is not retried (D119, noted 2026-10-13).
#
# The client's calls are answered by a curl stubbed in Service::Github, so each
# row says exactly what the host answered and counts what was asked.  The
# whole command, through the GitHub double, is in
# t/integration-tests/genesis_ci_github-host_judgement.t.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use Genesis;
use Genesis::Exit qw/CONFIG/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

use_ok 'Service::Github::Host' or BAIL_OUT('Service::Github::Host does not load');
use_ok 'Service::Github';

my $GITHUB = join("\r\n",
	'HTTP/1.1 200 OK',
	'x-github-request-id: 44F3:35330:E86661',
	'x-github-media-type: github.v3; format=json',
	'Content-Type: application/json; charset=utf-8', '');
my $ENTERPRISE = join("\r\n",
	'HTTP/1.1 200 OK',
	'X-GitHub-Request-Id: 44F3:35330:E86661',
	'X-GitHub-Media-Type: github.v3; format=json',
	'X-GitHub-Enterprise-Version: 3.15.2',
	'Content-Type: application/json; charset=utf-8', '');
my $FORGE = join("\r\n",
	'HTTP/1.1 404 Not Found',
	'Content-Type: text/html', '');

sub cache_file {"$ENV{HOME}/.genesis/cache/github-hosts.yml"}
sub clear_cache {unlink cache_file()}
sub cached {
	return undef unless -f cache_file();
	return load_yaml_file(cache_file());
}

# answering - run code with the client's curl answering from a list {{{
#
# Each answer is what Genesis::curl hands back: the status, the status line
# (which carries the code, as "404 Not Found"), the body, the headers, and
# curl's own standard error.  The calls made are
# returned beside the code's own answer, so a row can count the retry.
sub answering {
	my ($answers, $code) = @_;
	my @asked;
	no warnings qw/redefine once/;
	local *Service::Github::curl = sub {
		push @asked, [@_];
		my $next = shift @$answers or die "the row ran out of answers\n";
		return @$next;
	};
	my @got = eval {$code->()};
	return (\@asked, $@, @got);
}

# }}}

subtest 'the base is the API a host is called at' => sub {
	plan tests => 3;
	is(Service::Github::Host::base_for('github.com'), 'https://api.github.com',
		'github.com is called at api.github.com');
	is(Service::Github::Host::base_for('git.corp.example'),
		'https://git.corp.example/api/v3', 'any other host at its /api/v3');
	is(Service::Github::Host::base_for('Git.Corp.Example'),
		'https://git.corp.example/api/v3', 'with the host folded to lower case');
};

subtest "an answer is GitHub's by its headers, in any case" => sub {
	plan tests => 4;
	ok(Service::Github::Host::is_github($GITHUB),
		'lower-case headers, as HTTP/2 sends them');
	ok(Service::Github::Host::is_github("X-GitHub-Media-Type: github.v3\r\n"),
		'the media type alone');
	ok(!Service::Github::Host::is_github($FORGE), 'a page without them is not');
	ok(!Service::Github::Host::is_github(undef), 'and no headers at all is not');
};

subtest 'github.com is known, and never cached' => sub {
	plan tests => 3;
	clear_cache();
	is_deeply(Service::Github::Host::known('github.com'),
		{base => 'https://api.github.com', kind => 'github'},
		'github.com is known without being asked');
	Service::Github::Host::record('github.com', $GITHUB);
	ok(!-e cache_file(), 'and recording it writes nothing');
	is(Service::Github::Host::known('git.corp.example'), undef,
		'a host nobody has seen is not known');
};

subtest 'an enterprise host is recorded, and one host is forgotten' => sub {
	plan tests => 6;
	clear_cache();
	Service::Github::Host::record('git.corp.example', $ENTERPRISE);
	Service::Github::Host::record('git.other.example', $GITHUB);

	my $entry = (cached() || {})->{'git.corp.example'} || {};
	is($entry->{base}, 'https://git.corp.example/api/v3', 'with its base');
	is($entry->{kind}, 'enterprise', 'as enterprise');
	is($entry->{version}, '3.15.2', 'with the version it answered with');
	like($entry->{seen} // '', qr/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/,
		'and when it was seen');

	Service::Github::Host::forget('git.corp.example');
	ok(!exists((cached() || {})->{'git.corp.example'}), 'a forgotten host is gone');
	ok(exists((cached() || {})->{'git.other.example'}), 'and only that host');
};

subtest "the client is called at its repository's host" => sub {
	plan tests => 2;
	my $client = Service::Github->new(org => 'genesis', host => 'git.corp.example');
	is($client->base_url, 'https://git.corp.example/api/v3',
		'an enterprise repository is called at its own host');
	is(Service::Github->new(org => 'genesis', host => 'github.com')->base_url,
		'https://api.github.com', 'and a github.com one at api.github.com');
};

subtest "a host's first answer as GitHub records it, at no extra call" => sub {
	plan tests => 3;
	clear_cache();
	my $client = Service::Github->new(org => 'genesis', host => 'git.corp.example');
	my ($asked, $err, $sets) = answering([[200, '200 OK','[]', $ENTERPRISE, '']],
		sub {$client->list_rulesets('genesis/bosh')});

	is(scalar @$asked, 1, 'one call, and no call to ask what the host is');
	like($asked->[0][1], qr{^https://git\.corp\.example/api/v3/repos/genesis/bosh/rulesets},
		'made at the host\'s base');
	is((cached() || {})->{'git.corp.example'}{kind}, 'enterprise',
		'and the host is recorded from the answer');
};

subtest 'a non-GitHub answer is retried once, and can pass' => sub {
	plan tests => 2;
	clear_cache();
	my $client = Service::Github->new(org => 'genesis', host => 'git.corp.example');
	my ($asked, $err) = answering([
		[404, '404 Not Found','<html></html>', $FORGE, ''],
		[200, '200 OK','[]', $ENTERPRISE, ''],
	], sub {$client->list_rulesets('genesis/bosh')});

	is(scalar @$asked, 2, 'the call was made once more');
	is((cached() || {})->{'git.corp.example'}{kind}, 'enterprise',
		'and the GitHub answer the retry got is recorded');
};

subtest 'a second non-GitHub answer is refused at CONFIG' => sub {
	plan tests => 6;
	clear_cache();
	Service::Github::Host::record('forge.example', $ENTERPRISE);
	my $client = Service::Github->new(org => 'genesis', host => 'forge.example');
	my ($asked, $err) = answering([
		[404, '404 Not Found','<html></html>', $FORGE, ''],
		[404, '404 Not Found','<html></html>', $FORGE, ''],
	], sub {$client->list_rulesets('genesis/bosh')});

	is(scalar @$asked, 2, 'after one retry and no more');
	is((ref $err ? $err->{exitcode} : undef), CONFIG, 'the call is refused at CONFIG')
		or diag("raised: $err");
	my $said = ref $err ? ($err->{message} // '') : "$err";
	like($said, qr/forge\.example/, 'naming the host');
	like($said, qr{https://forge\.example/api/v3}, 'the base asked');
	like($said, qr/404 Not Found/, 'and what came back');
	ok(!exists((cached() || {})->{'forge.example'}), 'and the host is forgotten');
};

subtest 'a 410 is retried once' => sub {
	plan tests => 1;
	clear_cache();
	my $client = Service::Github->new(org => 'genesis', host => 'git.corp.example');
	my ($asked) = answering([
		[410, '410 Gone','{}', $ENTERPRISE =~ s/200 OK/410 Gone/r, ''],
		[200, '200 OK','[]', $ENTERPRISE, ''],
	], sub {$client->list_rulesets('genesis/bosh')});
	is(scalar @$asked, 2, 'the call was made once more');
};

subtest "GitHub's own 404 goes to the caller" => sub {
	plan tests => 3;
	clear_cache();
	Service::Github::Host::record('git.corp.example', $ENTERPRISE);
	my $client = Service::Github->new(org => 'genesis', host => 'git.corp.example');
	my ($asked, $err, $sets) = answering(
		[[404, '404 Not Found','{"message":"Not Found"}', $ENTERPRISE =~ s/200 OK/404 Not Found/r, '']],
		sub {$client->list_rulesets('genesis/bosh')});

	is(scalar @$asked, 1, 'unretried');
	is_deeply($sets, [], 'answered as the call answers a 404 today');
	ok(exists((cached() || {})->{'git.corp.example'}), 'and the host stays recorded');
};

subtest 'a call that gets no answer is not retried' => sub {
	plan tests => 2;
	clear_cache();
	Service::Github::Host::record('git.corp.example', $ENTERPRISE);
	my $client = Service::Github->new(org => 'genesis', host => 'git.corp.example');
	my ($asked) = answering(
		[[599, 'Error executing curl command', "curl: (7) Failed to connect\n"]],
		sub {$client->list_rulesets('genesis/bosh')});

	is(scalar @$asked, 1, 'one call');
	ok(exists((cached() || {})->{'git.corp.example'}), 'and the host stays recorded');
};

subtest 'github.com is never judged' => sub {
	plan tests => 2;
	clear_cache();
	my $client = Service::Github->new(org => 'genesis', host => 'github.com');
	my ($asked) = answering([[404, '404 Not Found','<html></html>', $FORGE, '']],
		sub {$client->list_rulesets('genesis/bosh')});

	is(scalar @$asked, 1, 'a non-GitHub answer from github.com is not retried');
	ok(!-e cache_file(), 'and nothing is cached');
};

done_testing;
