#!/usr/bin/env perl
# Proves T19 through whole commands: a host is judged GitHub by its answers and
# not its name, asking costs no call of its own, github.com is called at
# api.github.com and never cached, an enterprise repository's calls go to its
# own host's /api/v3 and the host is cached, a host that answers but not as
# GitHub is retried once and refused at CONFIG by pipeline-apply and by a
# propagate that opens a pull request, the manual provider loads and reports
# on such a repository without calling it, and a host that does not answer is
# refused at UNAVAILABLE without a retry (D119, noted 2026-10-13).
#
# The judgement of one answer, the retry that passes, a 410, and GitHub's own
# 404 are proved at the unit level, in t/unit-tests/service_github-host.t.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit qw/CONFIG UNAVAILABLE/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $CORP  = 'https://git.corp.example/genesis/bosh-deployments';
my $FORGE = 'https://forge.example/genesis/bosh-deployments';

sub cache_file {"$ENV{HOME}/.genesis/cache/github-hosts.yml"}
sub cached {
	return {} unless -f cache_file();
	return load_yaml_file(cache_file()) || {};
}
sub urls {map {$_->{url} // ''} gh_calls($_[0])}

# A pull request environment with one commit due, on the host a row names.
sub due_pr {
	my (%opts) = @_;
	unlink cache_file();
	my $h = ready(kit => 'omega-v2.7.0',
		($opts{repository} ? (source_control => {repository => $opts{repository}}) : ()));
	gh_host($h->{gh}, $opts{host}, kind => $opts{kind},
		(defined $opts{version} ? (version => $opts{version}) : ())) if $opts{host};
	due_commit($h, 'prod', params => {instances => 2},
		message => 'Raise the cf instance count');
	return $h;
}

# Both environments on the host a row names, with prod's protection asking
# for pull requests, ready for pipeline-apply.
sub to_apply {
	my (%opts) = @_;
	unlink cache_file();
	my $h = make_harness(envs => ['qa', 'prod'], github => 1,
		source_control => {repository => $opts{repository}});
	gh_host($h->gh, $opts{host}, kind => $opts{kind},
		(defined $opts{version} ? (version => $opts{version}) : ()));
	write_env_file($h, 'prod', pipeline => {require_pr => 'true'});
	push_from($h, 'a', $h->control);
	return $h;
}

subtest 'github.com is called at api.github.com, and never cached' => sub {
	my $h = due_pr();
	my (undef, undef, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run succeeded');

	my @urls = urls($h->{gh});
	cmp_ok(scalar @urls, '>', 0, 'it reached the API');
	is(scalar(grep {!m{^https://api\.github\.com/}} @urls), 0,
		'and every call went to api.github.com');
	is(scalar(grep {m{/meta\b}} @urls), 0,
		'with no call made only to ask what the host is');
	ok(!-e cache_file(), 'and nothing was cached');
};

subtest "an enterprise repository's pull requests go to its own host" => sub {
	my $h = due_pr(repository => $CORP,
		host => 'git.corp.example', kind => 'enterprise', version => '3.15.2');
	my (undef, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, 0, 'the run succeeded') or diag($err);

	my @urls = urls($h->{gh});
	cmp_ok(scalar @urls, '>', 0, 'it reached the API');
	is(scalar(grep {!m{^https://git\.corp\.example/api/v3/}} @urls), 0,
		'and every call went to the host\'s /api/v3, none to api.github.com')
		or diag(join "\n", @urls);
	is(scalar(grep {m{/meta\b}} @urls), 0,
		'with no call made only to ask what the host is');

	my $entry = cached()->{'git.corp.example'} || {};
	is($entry->{kind}, 'enterprise', 'the host is cached as enterprise');
	is($entry->{version}, '3.15.2', 'with its version');
	is($entry->{base}, 'https://git.corp.example/api/v3', 'and its base');
};

subtest "an enterprise repository's protection goes to its own host" => sub {
	my $h = to_apply(repository => $CORP,
		host => 'git.corp.example', kind => 'enterprise', version => '3.15.2');
	my (undef, $err, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the apply exits 0') or diag($err);

	my @rulesets = grep {m{/rulesets}} urls($h->gh);
	cmp_ok(scalar @rulesets, '>', 0, 'the protection was applied');
	is(scalar(grep {!m{^https://git\.corp\.example/api/v3/repos/genesis/bosh-deployments/rulesets}} @rulesets),
		0, 'at the host\'s /api/v3, not at api.github.com')
		or diag(join "\n", @rulesets);
};

subtest 'pipeline-apply refuses a host that does not answer as GitHub' => sub {
	my $h = to_apply(repository => $FORGE, host => 'forge.example', kind => 'other');
	my (undef, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = unfolded('', $err);

	is($exit, CONFIG, 'the apply is refused at CONFIG');
	like($said, qr/forge\.example/, 'naming the host');
	like($said, qr{https://forge\.example/api/v3}, 'the base asked');
	like($said, qr/404 Not Found/, 'and what came back');

	my @urls = urls($h->gh);
	is(scalar @urls, 2, 'after the one call and its one retry');
	is($urls[0], $urls[1] // '', 'of the same request');
	ok(!exists cached()->{'forge.example'}, 'and nothing is cached for the host');
};

subtest 'a propagate that opens a pull request refuses it too' => sub {
	my $h = due_pr(repository => $FORGE, host => 'forge.example', kind => 'other');
	my (undef, $err, $exit) = run_genesis($h, 'propagate', '-y');
	my $said = unfolded('', $err);

	is($exit, CONFIG, 'the run is refused at CONFIG');
	like($said, qr/forge\.example/, 'naming the host');
	like($said, qr{https://forge\.example/api/v3}, 'and the base asked');
	ok(!exists cached()->{'forge.example'}, 'and nothing is cached for the host');
};

subtest 'the manual provider reports on it without calling the host' => sub {
	unlink cache_file();
	my $h = make_harness(envs => ['qa'], provider => 'manual', github => 1,
		source_control => {repository => $FORGE});
	gh_host($h->gh, 'forge.example', kind => 'other');
	$h->ready_envs;

	my (undef, $err, $exit) = run_genesis($h, 'pipeline-status');
	is($exit, 0, 'pipeline-status loads and runs') or diag($err);
	is(scalar(gh_calls($h->gh)), 0, 'without a call to the host');
};

subtest 'a host that does not answer is refused at UNAVAILABLE, unretried' => sub {
	my $h = due_pr(repository => $CORP, host => 'git.corp.example', kind => 'silent');
	my (undef, $err, $exit) = run_genesis($h, 'propagate', '-y');
	is($exit, UNAVAILABLE, 'the run is refused at UNAVAILABLE') or diag($err);

	my @urls = urls($h->{gh});
	cmp_ok(scalar @urls, '>', 0, 'after asking the host');
	my %times;
	$times{$_}++ for @urls;
	is(scalar(grep {$times{$_} > 1} keys %times), 0, 'and asking nothing twice')
		or diag(join "\n", @urls);
	ok(!exists cached()->{'git.corp.example'}, 'and nothing is cached for the host');
};

done_testing;
