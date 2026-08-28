#!/usr/bin/env perl
# A deploy job that commits manifests to the branch it triggers on is a
# feedback loop.  `ignore_paths` on the env-branch resource stops the
# retrigger, but the deploy is still a second writer to a branch the
# propagate job also advances, so the contention remains.
#
# Setting manifest_store to exodus removes the deploy as a git writer
# entirely.  This warns when an automated provider is paired with a store
# that still writes manifests to the repository -- a warning rather than a
# bail, so existing hybrid repos keep compiling while the policy question
# is settled separately.
use strict;
use warnings;
use utf8;

use lib 't';
use lib 'lib';
use helper;
use Test::More;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

use_ok 'Genesis::CI::Compiler::Validator';

# A double for Genesis::Top carrying just the two config keys the check
# reads.  `get` honours the caller's default, as Genesis::Config does.
my $seq = 0;
sub top_with {
	my (%values) = @_;
	$seq++;
	my $config = mock "Test::Config::MS$seq" => {
		get => sub {
			my ($self, $key, $default) = @_;
			return exists $values{$key} ? $values{$key} : $default;
		},
		has => sub {
			my ($self, $key) = @_;
			return exists $values{$key} ? 1 : 0;
		},
	};
	return mock "Test::Top::MS$seq" => {config => $config};
}

# The smallest parse result that reaches the end of validate().  Other
# sections may raise their own complaints; this file only ever inspects
# warnings about the manifest store, never the total.
sub parsed {
	return {
		_source_format => 'multi-file',
		pipeline       => {name => 'test-pipeline'},
		targets        => {},
		integrations   => {},
		environments   => {},
	};
}

sub store_warnings {
	my ($top) = @_;
	my $v = Genesis::CI::Compiler::Validator->new(top => $top);
	$v->validate(parsed());
	return [grep {/manifest|exodus/i} @{$v->warnings}];
}

sub errors_from {
	my ($top) = @_;
	my $v = Genesis::CI::Compiler::Validator->new(top => $top);
	$v->validate(parsed());
	return $v->errors;
}

subtest 'an automated provider writing manifests to git is warned about' => sub {
	plan tests => 2;

	my $w = store_warnings(top_with(
		'ci.provider.type' => 'concourse',
		'manifest_store'   => 'hybrid',
	));
	is scalar(@$w), 1, 'concourse + hybrid raises exactly one warning';
	like $w->[0], qr/manifest_store|exodus/,
		'and the message names the setting that resolves it';
};

subtest 'exodus removes the contention, so nothing is said' => sub {
	plan tests => 1;

	my $w = store_warnings(top_with(
		'ci.provider.type' => 'concourse',
		'manifest_store'   => 'exodus',
	));
	is_deeply $w, [], 'concourse + exodus is silent';
};

subtest 'the manual provider has no second writer to contend with' => sub {
	plan tests => 1;

	# Nothing advances the branch on its own under the manual provider, so
	# a git-writing deploy is not competing with anything.
	my $w = store_warnings(top_with(
		'ci.provider.type' => 'manual',
		'manifest_store'   => 'hybrid',
	));
	is_deeply $w, [], 'manual + hybrid is silent';
};

subtest 'the store defaults to hybrid when unset' => sub {
	plan tests => 1;

	# Genesis::Env reads manifest_store with a 'hybrid' default; an unset
	# key therefore means git writes are happening, not that they are not.
	my $w = store_warnings(top_with('ci.provider.type' => 'concourse'));
	is scalar(@$w), 1, 'an absent manifest_store warns like an explicit hybrid';
};

subtest 'it is a warning, never an error' => sub {
	plan tests => 1;

	# Existing hybrid repos must keep compiling; the policy call belongs
	# to the manifest_store/require_pr ticket, not to this check.
	my $e = errors_from(top_with(
		'ci.provider.type' => 'concourse',
		'manifest_store'   => 'hybrid',
	));
	is_deeply [grep {/manifest|exodus/i} @$e], [],
		'no error is raised about the manifest store';
};

subtest 'a validator with no top does not explode' => sub {
	plan tests => 1;

	# Compiler always passes one, but the constructor does not require it.
	my $v = Genesis::CI::Compiler::Validator->new();
	eval {$v->validate(parsed())};
	is $@, '', 'validate() survives a missing top';
};

done_testing;
