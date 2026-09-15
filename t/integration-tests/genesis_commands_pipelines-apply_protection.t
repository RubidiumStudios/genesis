#!/usr/bin/env perl
# Proves T124, T125, T126, and T319: the apply derives the branch protection
# from decided state, sets rebase as the only merge method on every deployment
# branch it puts in PR mode, reports the settings a non-admin cannot grant and
# continues, and applies no dismiss-stale-approvals setting anywhere.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 120;
$ENV{NOCOLOR} = 1;

# rules_sent - the rules the run actually sent for one branch
#
# Every row here asserts about what went over the wire rather than about a
# return value, because the protection is a thing the repository is asked for
# and not a thing the command computes and keeps.  A line the call log could
# not decode carries no url at all, so the key is tested before the match
# rather than after it, and a call with no body is passed over rather than
# handed to the decoder.
sub rules_sent {
	my ($gh, $branch) = @_;
	for my $call (gh_calls($gh)) {
		next unless defined $call->{url} && $call->{url} =~ m{/rulesets};
		next unless defined $call->{body};
		my $body = eval {load_json($call->{body})} or next;
		next unless grep {$_ eq "refs/heads/$branch"}
			@{($body->{conditions}{ref_name}{include}) || []};
		return $body->{rules};
	}
	return [];
}

# rule_named - one rule out of a rule list, by its type
#
# A row asserts about one rule at a time, and finding it by type keeps the
# assertion about the rule rather than about the order the list happens to
# carry.
sub rule_named {
	my ($rules, $type) = @_;
	my ($rule) = grep {($_->{type} // '') eq $type} @$rules;
	return $rule;
}

# ruleset_calls - the calls the run made to the rulesets endpoint
#
# The method is what tells a create from a replace, so a row about whether a
# re-run accumulates asks for one method at a time.  A line the call log
# could not decode carries neither a url nor a method, and both are tested
# before they are matched.
sub ruleset_calls {
	my ($gh, $method) = @_;
	return grep {
		defined $_->{url} && $_->{url} =~ m{/rulesets}
			&& ($_->{method} // '') eq $method
	} gh_calls($gh);
}

subtest 'force pushes and non-linear history are blocked everywhere' => sub {
	# Seven rows, and one more for the run's own restoration assertion, which
	# run_genesis makes unless a row turns it off.
	plan tests => 8;

	my $h  = make_harness(envs => ['qa', 'prod'], github => 1);
	my $gh = $h->gh;
	write_env_file($h, 'prod', pipeline => {require_pr => 'true'});

	my (undef, undef, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the apply exits 0');

	for my $branch ($h->control, 'qa/bosh', 'prod/bosh') {
		my $rules = rules_sent($gh, $branch);
		ok(rule_named($rules, 'non_fast_forward'),
			"$branch blocks force pushes");
		ok(rule_named($rules, 'required_linear_history'),
			"$branch requires linear history")
			if $branch ne $h->control;
	}

	ok(rule_named(rules_sent($gh, $h->control), 'required_linear_history'),
		'control requires linear history');
};

subtest 'a pull request is required exactly where the state says so' => sub {
	# Five rows, and one more for each of the two runs' restoration
	# assertions.
	plan tests => 7;

	my $h  = make_harness(envs => ['qa', 'prod', 'staging'], github => 1);
	my $gh = $h->gh;
	write_env_file($h, 'prod', pipeline => {require_pr => 'true'});
	# The schema takes no as a legal spelling of false, and a reader that
	# weighed plain Perl truth would read the string as true and protect the
	# branch in a mode propagation never runs it in.  The quotes are in the
	# file, so the value reaches the reader as a string rather than as a YAML
	# boolean.
	write_env_file($h, 'staging', pipeline => {require_pr => '"no"'});

	run_genesis($h, 'pipeline-apply');

	my $prod = rule_named(rules_sent($gh, 'prod/bosh'), 'pull_request');
	is($prod->{parameters}{required_approving_review_count}, 1,
		'the PR-mode environment requires a pull request before merging');

	my $qa = rule_named(rules_sent($gh, 'qa/bosh'), 'pull_request');
	is($qa, undef,
		'the direct-mode environment gets no pull request rule, so it can '.
		'still be pushed to directly');

	my $staging = rule_named(rules_sent($gh, 'staging/bosh'), 'pull_request');
	is($staging, undef,
		'an environment whose require_pr reads no gets no pull request rule '.
		'either');

	my $control = rule_named(rules_sent($gh, $h->control), 'pull_request');
	is($control, undef, 'control requires no pull request by default');

	my $h2  = make_harness(envs => ['qa'], github => 1,
		source_control => {control_requires_pr => 1});
	my $gh2 = $h2->gh;
	run_genesis($h2, 'pipeline-apply');
	ok(rule_named(rules_sent($gh2, $h2->control), 'pull_request'),
		'control requires one when control_requires_pr is true');
};

subtest 'a deployment branch in PR mode merges by rebase only' => sub {
	# Two rows, and one more for the run's own restoration assertion.
	plan tests => 3;

	# The setting lives inside the pull request rule, which only a PR-mode
	# branch is given, so the environment here is in PR mode.
	my $h  = make_harness(envs => ['qa'], github => 1,
		source_control => {control_requires_pr => 1});
	my $gh = $h->gh;
	write_env_file($h, 'qa', pipeline => {require_pr => 'true'});

	run_genesis($h, 'pipeline-apply');

	# The rule is defaulted to an empty hash before it is read through,
	# because a missing rule is what this row is here to catch and a
	# dereference of nothing would take the whole file down rather than
	# failing the one assertion that asked.
	is_deeply((rule_named(rules_sent($gh, 'qa/bosh'), 'pull_request') || {})
			->{parameters}{allowed_merge_methods},
		['rebase'],
		'rebase is the only merge method into the deployment branch');

	is_deeply((rule_named(rules_sent($gh, $h->control), 'pull_request') || {})
			->{parameters}{allowed_merge_methods},
		['squash', 'rebase'],
		'control keeps squash or rebase at the merger\'s choice');
};

subtest 'a non-admin gets the list and the run carries on' => sub {
	# Four rows, and one more for the run's own restoration assertion.
	plan tests => 5;

	my $h = make_harness(envs => ['qa'], github => 1);
	# The second build is what puts the double in its non-admin state, since
	# make_harness builds one with admin standing and takes no say in it.
	my $gh = github_double($h, admin => 0);

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-apply');
	my $said = unfolded($out, $err);

	is($exit, 0, 'the run carries on and exits 0');
	like($said, qr{qa/bosh}, 'the report names the branch');
	like($said, qr/non_fast_forward/,
		'the report names the setting that could not be granted');
	have_secret($h->applied_path . ':control_commit',
		'the applied record was still written');
};

subtest 'approvals are left standing' => sub {
	# Two rows, and one more for the run's own restoration assertion.
	plan tests => 3;

	my $h  = make_harness(envs => ['qa'], github => 1);
	my $gh = $h->gh;

	run_genesis($h, 'pipeline-apply');

	my @bodies = map {$_->{body} // ''} gh_calls($gh);
	unlike(join("\n", @bodies), qr/dismiss_stale_reviews/,
		'no dismiss-stale-reviews setting is sent');
	unlike(join("\n", @bodies), qr/dismiss_stale_approvals/,
		'no dismiss-stale-approvals setting is sent either');
};

subtest 'a run with no token asks the repository for nothing' => sub {
	# Three rows, and one more for the run's own restoration assertion.
	plan tests => 4;

	my $h  = make_harness(envs => ['qa'], github => 1);
	my $gh = $h->gh;

	my ($out, $err, $exit) = run_genesis($h, {no_token => 1}, 'pipeline-apply');
	my $said = unfolded($out, $err);

	is($exit, 0, 'the run carries on and exits 0');
	like($said, qr/GITHUB_AUTH_TOKEN/,
		'the skip names the variable the stage wanted');
	is(scalar(gh_calls($gh)), 0, 'and the run asked the API for nothing');
};

subtest 'a second run replaces the ruleset the first one wrote' => sub {
	# Three rows, and one more for each of the two runs' restoration
	# assertions.
	plan tests => 5;

	my $h  = make_harness(envs => ['qa'], github => 1);
	my $gh = $h->gh;

	run_genesis($h, 'pipeline-apply');
	my (undef, undef, $exit) = run_genesis($h, 'pipeline-apply');
	is($exit, 0, 'the second run exits 0');

	my @replaced = grep {
		my $body = eval {load_json($_->{body} // '{}')} || {};
		grep {$_ eq 'refs/heads/qa/bosh'}
			@{($body->{conditions}{ref_name}{include}) || []};
	} ruleset_calls($gh, 'PUT');
	is(scalar @replaced, 1,
		'the second run replaced the ruleset the first one wrote');

	# Two branches, which are control and the one deployment branch, and one
	# create each.  A run that stopped listing first and always created would
	# leave four here and a repository carrying two rulesets per branch.
	is(scalar(ruleset_calls($gh, 'POST')), 2,
		'and created nothing the first run had already created');
};

done_testing;
