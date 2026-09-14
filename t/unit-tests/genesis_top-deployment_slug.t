#!/usr/bin/env perl
# Proves T46, one builder composing the deployment slug with the names
# that render from it, and T48, two deployment roots sharing an
# environment name composing their own branches, which is the H32 shape.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Top;
use Genesis::Env;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the builder composes the slug from a name and the declared type' => sub {
	plan tests => 4;

	my $h   = make_harness(envs => ['qa'], type => 'bosh', vault => 0);
	my $top = Genesis::Top->new($h->a, no_vault => 1);

	is($top->deployment_slug_for('qa'), 'qa/bosh',
		'the slug is the environment name and the deployment type');
	is($top->deployment_slug_for('qa'), $h->slug('qa'),
		'the harness and the product agree on the slug');
	is($top->branch_for('qa'), 'qa/bosh',
		'the deployment branch is the slug');

	# A name, not an object: an environment that has no file on disk still
	# composes, which is what pipeline-apply and pipeline-status need.
	is($top->deployment_slug_for('never-created'), 'never-created/bosh',
		'the builder takes a name string and loads no environment');
};

# A refusal is wrapped for the terminal before it is raised, so a line
# break can land in the middle of any phrase.  The text is folded back onto
# one line before a row reads it.  The name is the test file's own, because
# Genesis exports a flatten of its own that means something else.
sub one_line {
	my ($text) = @_;
	$text //= '';
	$text =~ s/\s+/ /g;
	return $text;
}

subtest 'the builder refuses what it cannot compose a slug from' => sub {
	plan tests => 4;

	my $h   = make_harness(envs => ['qa'], type => 'bosh', vault => 0);
	my $top = Genesis::Top->new($h->a, no_vault => 1);

	# The guards raise through bug, which dies rather than exiting whenever
	# it is reached from inside an eval, and a test file always is.
	local $ENV{GENESIS_IGNORE_EVAL} = '';

	my $from_ref = eval {$top->deployment_slug_for(Genesis::Env->bare('qa', $top))};
	my $ref_err  = one_line($@);
	is($from_ref, undef, 'an environment object composes nothing');
	like($ref_err, qr/deployment_slug_for expects an environment name/,
		'and the refusal says a name is what it takes');

	my $from_empty = eval {$top->deployment_slug_for('')};
	my $empty_err  = one_line($@);
	is($from_empty, undef, 'an empty name composes nothing');
	like($empty_err, qr/deployment_slug_for called without an environment name/,
		'and the refusal says the name was missing');
};

subtest 'the object form delegates and the renderings agree' => sub {
	plan tests => 4;

	my $h   = make_harness(envs => ['qa'], type => 'bosh', vault => 0);
	my $top = Genesis::Top->new($h->a, no_vault => 1);
	my $env = Genesis::Env->bare('qa', $top);

	is($env->deployment_slug, 'qa/bosh', 'deployment_slug is the slug');
	is($env->deployment_slug, $top->deployment_slug_for('qa'),
		'the object form delegates to the builder');
	is($env->exodus_slug, $env->deployment_slug,
		'exodus_slug is redefined through the builder');
	is($env->deployment_name, 'qa-bosh',
		'deployment_name renders the same pair for BOSH');
};

subtest 'two roots sharing an environment name compose their own branches' => sub {
	plan tests => 4;

	my $name = 'lmelt-vsphere-canwest-1-mgmt';
	my $h = make_harness(
		envs => [$name], type => 'bosh', root => 'bosh', vault => 0,
	);
	my $vault_root = add_deployment_root($h,
		type => 'vault', envs => [$name], path => 'vault',
	);

	my $bosh_top  = Genesis::Top->new($h->a . '/bosh',        no_vault => 1);
	my $vault_top = Genesis::Top->new($h->a . "/$vault_root", no_vault => 1);

	is($bosh_top->branch_for($name),  "$name/bosh",
		"the bosh root's deployment branch carries its own type");
	is($vault_top->branch_for($name), "$name/vault",
		"the vault root's deployment branch carries its own type");
	isnt($bosh_top->branch_for($name), $vault_top->branch_for($name),
		'the two roots no longer share one branch');
	isnt($bosh_top->pr_branch_for($name), $vault_top->pr_branch_for($name),
		'and no longer share one pull request branch');
};

done_testing;
