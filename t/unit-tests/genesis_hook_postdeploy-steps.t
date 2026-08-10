#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Output qw(stderr_from);
use Genesis qw(bail);
use Cwd qw(abs_path);

$ENV{GENESIS_CALLBACK_BIN} ||= abs_path('bin/genesis');
$ENV{GENESIS_LIB} ||= abs_path('lib');
# The logger hard-wraps everything it emits at this width; 200 keeps each
# assertion's phrase on one line so the regexes below stay readable.
# (Alternative repo idiom: \s+ between every word -- see 458218c0.)
$ENV{GENESIS_OUTPUT_COLUMNS} = 200;
$ENV{NOCOLOR} = 1;

# ---------------------------------------------------------------------------
# Load the module under test
# ---------------------------------------------------------------------------
require_ok 'Genesis::Hook::PostDeploy';

# ---------------------------------------------------------------------------
# Test subclass - class name matches Genesis::Hook::<Type>::<KitName>
# convention required by label() in the base class.  Step methods are
# scripted through $self->{step_returns} and record their invocations in
# $self->{step_calls}; they return exactly what was scripted, including
# an explicit undef for "nothing to do".
# ---------------------------------------------------------------------------
{
	package Genesis::Hook::PostDeploy::step_test;
	use parent -norequire, 'Genesis::Hook::PostDeploy';

	sub perform {
		my ($self) = @_;
		$self->done(1);
	}

	for my $m (qw/step_a step_b step_c step_d/) {
		no strict 'refs';
		*{__PACKAGE__."::$m"} = sub {
			my ($self, @args) = @_;
			push @{$self->{step_calls}}, [$m, @args];
			return $self->{step_returns}{$m};
		};
	}
}

# ---------------------------------------------------------------------------
# Shared mock objects (conventions from genesis_hook_postdeploy-core.t)
# ---------------------------------------------------------------------------

my $test_seq = 0;

my $kit = mock "Genesis::Kit" => {
	name                => 'test-kit',
	version             => '1.0.0',
	genesis_version_min => '3.1.0-rc.10',
	id                  => sub { return $_[0]->name . '/' . $_[0]->version },
	kit_bug => sub {
		my ($self, $msg, @args) = @_;
		Genesis::bail("Throwing a kit bug: " . $msg, @args);
	},
	path => sub { return "/mock/kit/path/$_[1]" },
	metadata => { supports => ['aws'] },
	get_hook_module => sub { return undef },
};

sub mock_env {
	$test_seq++;
	my $seq = $test_seq;
	mock "Genesis::Env" => {(
		name            => "test-env-$seq",
		type            => 'test',
		kit             => $kit,
		use_create_env  => 0,
		iaas            => 'aws',
		is_ocfp         => 0,
		lookup          => sub { return $_[2] },
		path            => sub { return "/mock/env/path/$_[1]" },
		# Scalar return on purpose: the real method returns a LIST in list
		# context, and the renderer must be written to call it in scalar
		# context (see the renderer subtests).
		get_call_path_with_env => sub { return 'genesis test-env' },
		file            => 'test-env.yml',
	), @_};
}

sub make_hook {
	my %args = (
		env     => mock_env(),
		rc      => 0,
		returns => {},
		@_,
	);
	my $hook = Genesis::Hook::PostDeploy::step_test->init(
		env => $args{env}, rc => $args{rc},
	);
	$hook->{step_returns} = $args{returns};
	$hook->{step_calls}   = [];
	return $hook;
}

sub called {
	my ($hook) = @_;
	return map { $_->[0] } @{$hook->{step_calls}};
}

# Convenience: build step hashrefs with defaults so tests only spell out
# what they are about.
sub steps {
	return [map {
		my %s = %$_;
		$s{label}  //= "label-$s{id}";
		$s{method} //= "step_$s{id}";
		$s{retry}  //= "%s retry-$s{id}";
		\%s;
	} @_];
}

$Genesis::VERSION = '3.1.0-rc.10';
$ENV{GENESIS_CALL_BIN} = 'genesis';
$ENV{GENESIS_KIT_HOOK} = 'post-deploy';
$ENV{GENESIS_CALL_ENV} = 'genesis test-env';

# ---------------------------------------------------------------------------
# Runner: success path
# ---------------------------------------------------------------------------
subtest 'all steps succeed: run in order, clean report' => sub {
	plan tests => 7;

	my $hook = make_hook(returns => {step_a => 1, step_b => 1});
	my $report = $hook->run_post_deploy_steps(steps(
		{id => 'a'},
		{id => 'b', needs => {a => 'skip'}},
	));

	is_deeply([called($hook)], ['step_a', 'step_b'], 'both steps run in order');
	is_deeply($report->{failed},  [], 'no failures');
	is_deeply($report->{skipped}, [], 'no skips');
	is_deeply($report->{notes},   [], 'no notes');
	ok(!$report->{aborted}, 'not aborted');
	is_deeply($report->{status}, {a => 'ok', b => 'ok'}, 'status map all ok');
	cmp_ok($report->{durations}{a}, '>=', 0, 'invoked steps record a duration');
};

# ---------------------------------------------------------------------------
# Runner: skip policy
# ---------------------------------------------------------------------------
subtest 'skip: failed prerequisite blocks the dependent' => sub {
	plan tests => 6;

	my $hook = make_hook(returns => {step_a => 0, step_c => 1});
	my $report = $hook->run_post_deploy_steps(steps(
		{id => 'a'},
		{id => 'b', needs => {a => 'skip'}},
		{id => 'c'},
	));

	is_deeply([called($hook)], ['step_a', 'step_c'],
		'blocked step does not run; unrelated later step still does');
	is_deeply([map {$_->{id}} @{$report->{failed}}], ['a'], 'a failed');
	is($report->{skipped}[0]{id}, 'b', 'b skipped');
	is($report->{skipped}[0]{reason}, 'blocked', 'reason is blocked');
	is($report->{skipped}[0]{blocked_by}, 'a', 'blocked_by names the step');
	is($report->{status}{b}, 'skipped', 'status map records the skip');
};

subtest 'skip propagates transitively with the root cause carried' => sub {
	plan tests => 4;

	my $hook = make_hook(returns => {step_a => 0});
	my $report = $hook->run_post_deploy_steps(steps(
		{id => 'a'},
		{id => 'b', needs => {a => 'skip'}},
		{id => 'c', needs => {b => 'skip'}},
	));

	is_deeply([called($hook)], ['step_a'], 'only the root step runs');
	is_deeply([map {$_->{id}} @{$report->{skipped}}], ['b', 'c'],
		'both dependents skipped');
	is($report->{skipped}[1]{blocked_by}, 'b', 'immediate blocker recorded');
	is($report->{skipped}[1]{root_cause}, 'a', 'root cause carried forward');
};

# ---------------------------------------------------------------------------
# Runner: noop convention
# ---------------------------------------------------------------------------
subtest 'noop (undef) is not a failure and never blocks' => sub {
	plan tests => 4;

	my $hook = make_hook(returns => {step_a => undef, step_b => 1});
	my $report = $hook->run_post_deploy_steps(steps(
		{id => 'a'},
		{id => 'b', needs => {a => 'skip'}},
	));

	is_deeply([called($hook)], ['step_a', 'step_b'], 'noop does not block');
	is_deeply($report->{failed}, [], 'noop is not a failure');
	is_deeply($report->{skipped}, [], 'nothing skipped');
	is($report->{status}{a}, 'noop', 'status map records noop');
};

# ---------------------------------------------------------------------------
# Runner: run policy
# ---------------------------------------------------------------------------
subtest 'run: soft dependency runs with a note' => sub {
	plan tests => 4;

	my $hook = make_hook(returns => {step_a => 0, step_b => 1});
	my $report = $hook->run_post_deploy_steps(steps(
		{id => 'a'},
		{id => 'b', needs => {a => 'run'}},
	));

	is_deeply([called($hook)], ['step_a', 'step_b'], 'step runs anyway');
	is($report->{notes}[0]{id}, 'b', 'note records the step');
	is($report->{notes}[0]{blocked_by}, 'a', 'note names the prerequisite');
	is_deeply($report->{skipped}, [], 'notes and skipped are disjoint');
};

# ---------------------------------------------------------------------------
# Runner: edge precedence (strongest wins, id order irrelevant)
# ---------------------------------------------------------------------------
subtest 'multiple triggered edges: abort beats skip regardless of id order' => sub {
	plan tests => 4;

	for my $edges ({aaa => 'skip', zzz => 'abort'}, {aaa => 'abort', zzz => 'skip'}) {
		my $hook = make_hook(returns => {step_a => 0, step_b => 0});
		my $report = $hook->run_post_deploy_steps(steps(
			{id => 'aaa', method => 'step_a'},
			{id => 'zzz', method => 'step_b'},
			{id => 'c',   method => 'step_c', needs => {%$edges}},
			{id => 'd',   method => 'step_d'},
		));
		is($report->{aborted}, 'c', 'abort edge fires');
		ok(!(grep {$_ eq 'step_d'} called($hook)), 'nothing runs after abort');
	}
};

# ---------------------------------------------------------------------------
# Runner: abort policy
# ---------------------------------------------------------------------------
subtest 'abort: runner stops with a complete report' => sub {
	plan tests => 7;

	my $hook = make_hook(returns => {step_a => 0});
	my $report = $hook->run_post_deploy_steps(steps(
		{id => 'a'},
		{id => 'b', needs => {a => 'abort'}},
		{id => 'c'},
		{id => 'd'},
	));

	is_deeply([called($hook)], ['step_a'], 'nothing runs after the abort fires');
	is($report->{aborted}, 'b', 'aborted names the tripping step');
	is_deeply([map {$_->{id}} @{$report->{skipped}}], ['b', 'c', 'd'],
		'tripping step and tail reported unrun');
	is($report->{skipped}[0]{reason}, 'aborted', 'tripping step reason');
	is($report->{skipped}[0]{blocked_by}, 'a',
		'tripping step still names its failed prerequisite');
	is_deeply([map {$_->{id}} @{$report->{failed}}], ['a'],
		'root failure still reported');
	is_deeply($report->{status},
		{a => 'failed', b => 'skipped', c => 'unrun', d => 'unrun'},
		'status map covers every declared step');
};

# ---------------------------------------------------------------------------
# Runner: exceptions
# ---------------------------------------------------------------------------
subtest 'a plain die is a step failure, not a runner failure' => sub {
	plan tests => 4;

	my $hook = make_hook(returns => {step_c => 1});
	my $report = $hook->run_post_deploy_steps(steps(
		{id => 'a', method => sub { die "boom went the step\n" }},
		{id => 'b', needs => {a => 'skip'}},
		{id => 'c'},
	));

	is_deeply([called($hook)], ['step_c'], 'later steps still run');
	is($report->{status}{a}, 'failed', 'dying step is failed, not noop');
	like($report->{failed}[0]{error}, qr/boom went the step/,
		'error captured');
	unlike($report->{failed}[0]{error}, qr/\n./,
		'error normalized to a single line');
};

subtest 'bail() inside a step propagates - Genesis fatals are not captured' => sub {
	plan tests => 1;

	my $hook = make_hook();
	throws_ok {
		$hook->run_post_deploy_steps(steps(
			{id => 'a', method => sub { bail("director unreachable") }},
		));
	} qr/director\s+unreachable/, 'bail escapes the runner unchanged';
};

# ---------------------------------------------------------------------------
# Runner: coderef steps with args
# ---------------------------------------------------------------------------
subtest 'coderef step receives $self and args' => sub {
	plan tests => 3;

	my @got;
	my $hook = make_hook();
	my $report = $hook->run_post_deploy_steps(steps(
		{id => 'a', method => sub { @got = @_; return 1 }, args => ['x', 42]},
	));

	is($got[0], $hook, 'first argument is the hook object');
	is_deeply([@got[1..$#got]], ['x', 42], 'args passed through');
	is($report->{status}{a}, 'ok', 'result convention honoured');
};

subtest 'method-name step receives args too' => sub {
	plan tests => 1;

	my $hook = make_hook(returns => {step_a => 1});
	$hook->run_post_deploy_steps(steps(
		{id => 'a', args => ['y']},
	));
	is_deeply($hook->{step_calls}[0], ['step_a', 'y'],
		'named method invoked with args');
};

# ---------------------------------------------------------------------------
# Runner: conditional lists (absent-id needs)
# ---------------------------------------------------------------------------
subtest 'needs referencing an id absent from the list is satisfied' => sub {
	plan tests => 2;

	my $hook = make_hook(returns => {step_a => 1});
	my $report = $hook->run_post_deploy_steps(steps(
		{id => 'a', needs => {'feature-gated-step' => 'skip'}},
	));
	is_deeply([called($hook)], ['step_a'], 'step runs');
	is($report->{status}{a}, 'ok', 'not blocked by a never-declared step');
};

# ---------------------------------------------------------------------------
# Runner: deploy_successful gate
# ---------------------------------------------------------------------------
subtest 'failed deploy: nothing runs unless opted in' => sub {
	plan tests => 4;

	my $hook = make_hook(rc => 1, returns => {step_a => 1});
	my $report = $hook->run_post_deploy_steps(steps({id => 'a'}));
	is_deeply([called($hook)], [], 'no step invoked after a failed deploy');
	is_deeply($report->{status}, {a => 'unrun'}, 'steps reported unrun');

	my $hook2 = make_hook(rc => 1, returns => {step_a => 1});
	$hook2->run_post_deploy_steps(steps({id => 'a'}), even_if_failed => 1);
	is_deeply([called($hook2)], ['step_a'], 'even_if_failed opts in');
	pass('gate is runner-owned, not kit-remembered');
};

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
subtest 'malformed step lists die as developer errors' => sub {
	plan tests => 5;

	my $hook = make_hook();

	throws_ok { $hook->validate_post_deploy_steps(steps(
		{id => 'a'}, {id => 'b', needs => {c => 'skip'}}, {id => 'c'},
	)) } qr/\bb\b.*\blater\b|\blater\b.*\bb\b/s,
		'needs referencing a later id names the step';

	throws_ok { $hook->validate_post_deploy_steps(steps(
		{id => 'a'}, {id => 'b', needs => {a => 'maybe'}},
	)) } qr/\bpolicy\b/s, 'unknown policy rejected';

	throws_ok { $hook->validate_post_deploy_steps(steps(
		{id => 'a'}, {id => 'a', method => 'step_b'},
	)) } qr/\bduplicate\b/is, 'duplicate ids rejected';

	throws_ok { $hook->validate_post_deploy_steps(steps(
		{id => 'a', method => 'no_such_method_here'},
	)) } qr/no_such_method_here/s,
		'method name the hook cannot resolve is rejected at validation';

	throws_ok { $hook->validate_post_deploy_steps([{id => 'a', method => 'step_a'}]) }
		qr/\bretry\b|\blabel\b/s, 'missing required keys rejected';
};

# ---------------------------------------------------------------------------
# Renderer
# ---------------------------------------------------------------------------
subtest 'renderer: clean report returns 1 silently' => sub {
	plan tests => 2;

	my $hook = make_hook(returns => {step_a => 1});
	my $report = $hook->run_post_deploy_steps(steps({id => 'a'}));

	my $ok;
	my $err = stderr_from { $ok = $hook->report_post_deploy_results($report) };
	is($ok, 1, 'clean report adjudicates success');
	is($err, '', 'nothing rendered');
};

subtest 'renderer: failures and blocks named once each, with retry commands' => sub {
	plan tests => 7;

	my $hook = make_hook(returns => {step_a => 0, step_c => 1});
	my $report = $hook->run_post_deploy_steps(steps(
		{id => 'a', label => 'release upload',    retry => '%s deploy'},
		{id => 'b', label => 'dns runtime config', retry => '%s do rc dns -y',
			needs => {a => 'skip'}},
		{id => 'c', label => 'stemcell upload',    retry => 'bosh upload-stemcell'},
	));

	my $ok;
	my $err = stderr_from { $ok = $hook->report_post_deploy_results($report) };
	is($ok, 0, 'failures adjudicate as 0');
	like($err, qr/release upload/, 'failed step named');
	like($err, qr/genesis test-env deploy/,
		'retry command carries the env name (scalar-context call path)');
	like($err, qr/dns runtime config.*blocked by.*release upload/s,
		'blocked step names its blocker by label');
	like($err, qr/genesis test-env do rc dns -y/,
		'blocked step keeps its retry command');
	my $count = () = $err =~ /release upload/g;
	is($count, 2, 'failed label appears once as failure, once as blocker');
	unlike($err, qr/stemcell/, 'successful steps not rendered');
};

subtest 'renderer: notes rendered, intro/outro literals honoured' => sub {
	plan tests => 3;

	my $hook = make_hook(returns => {step_a => 0, step_b => 1});
	my $report = $hook->run_post_deploy_steps(steps(
		{id => 'a', label => 'first thing'},
		{id => 'b', label => 'second thing', needs => {a => 'run'}},
	));

	my $err = stderr_from { $hook->report_post_deploy_results($report,
		intro => 'Custom intro line, verbatim, 100% literal.',
		outro => 'Custom outro line.',
	) };
	like($err, qr/second thing.*first thing/s,
		'note about the run-policy step is rendered');
	like($err, qr/Custom intro line, verbatim, 100% literal\./,
		'intro used verbatim (no format-string interpretation)');
	like($err, qr/Custom outro line\./, 'outro used verbatim');
};

subtest 'renderer: default wording is kit-neutral' => sub {
	plan tests => 2;

	my $hook = make_hook(returns => {step_a => 0});
	my $report = $hook->run_post_deploy_steps(steps({id => 'a'}));
	my $err = stderr_from { $hook->report_post_deploy_results($report) };
	like($err, qr/deployment\s+succeeded/i, 'default intro present');
	unlike($err, qr/director/i, 'no director-specific wording in the base class');
};

# ---------------------------------------------------------------------------
# Retry template edge cases
# ---------------------------------------------------------------------------
subtest 'retry templates without the token and with literal % are safe' => sub {
	plan tests => 3;

	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };

	my $hook = make_hook(returns => {step_a => 0, step_b => 0});
	my $report = $hook->run_post_deploy_steps(steps(
		{id => 'a', retry => 'bosh clean-up --all'},
		{id => 'b', retry => 'retry at 100% capacity: %s deploy'},
	));
	my $err = stderr_from { $hook->report_post_deploy_results($report) };
	like($err, qr/bosh clean-up --all/, 'token-less template rendered as-is');
	like($err, qr/100% capacity: genesis test-env deploy/,
		'literal % survives; token still substituted');
	is_deeply(\@warnings, [], 'no sprintf warnings emitted');
};

# ---------------------------------------------------------------------------
# interactive accessor
# ---------------------------------------------------------------------------
subtest 'interactive accessor' => sub {
	plan tests => 2;

	my $hook = make_hook();
	is($hook->interactive, 0, 'defaults to 0');
	$hook->{interactive} = 1;
	is($hook->interactive, 1, 'reflects the stored flag');
};

# ---------------------------------------------------------------------------
# Base step methods honour the result convention
# ---------------------------------------------------------------------------
subtest 'upload_runtime_configs returns a plain boolean, not done()' => sub {
	plan tests => 2;

	# bosh-configs.runtime absent -> nothing to do -> noop (undef), and
	# crucially NOT $self->done(1), which would mutate completion state.
	my $hook = make_hook();
	my $result = $hook->upload_runtime_configs;
	ok(!defined($result) || $result == 1, 'result follows the convention');
	ok(!$hook->completed, 'running the step does not mark the hook complete');
};

done_testing;
