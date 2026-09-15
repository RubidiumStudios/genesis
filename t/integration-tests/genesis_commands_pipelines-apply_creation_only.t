#!/usr/bin/env perl
# Proves T134: branch creation belongs to pipeline-apply alone, so
# pipeline-prepare is gone from the command set and genesis new writes the
# environment file without cutting a deployment branch of its own.
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

# _only_control_stands - control is the one branch the clone holds
#
# A branch is cut in the clone the command ran in and nothing pushes it, so
# the question these rows ask is what copy A's own refs hold rather than what
# reached the bare repository.  The whole set is named rather than the one
# branch being looked for, because a row that asked only about the name it
# expected would pass a run that cut a branch under some other name.
sub _only_control_stands {
	my ($h, $said) = @_;
	my $refs = refs_in($h->a, prefix => 'refs/heads');
	my @names = sort map {substr($_, length 'refs/heads/')} keys %$refs;
	is_deeply(\@names, [$h->control], $said);
}

subtest 'pipeline-prepare is gone from the command set' => sub {
	# Three rows, and one more for each of the two runs' own restoration
	# assertions, which run_genesis makes unless a row turns it off.
	plan tests => 5;

	my $h = make_harness(envs => ['qa']);

	# The command list is written to standard error, where everything
	# Genesis says about itself goes, so the listing comes back in the
	# second value rather than the first.
	my (undef, $help) = run_genesis($h, 'help');
	unlike($help, qr/pipeline-prepare/, 'the command is not listed');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-prepare');
	isnt($exit, 0, 'invoking it fails');
	like("$out$err", qr/pipeline-prepare/,
		'the failure names the command it does not know');
};

subtest 'genesis new still runs with the branch helper gone' => sub {
	# Three rows.  The run takes restore => 0 because the command commits
	# the environment file onto control, so the working state it leaves is
	# deliberately not the one it found.
	plan tests => 3;

	# The third caller of the branch helper goes in the same commit as the
	# helper, so this row is the one that would catch a step shipping a
	# genesis new that calls a method the tree no longer has.  What the
	# command writes is M12's to assert; what it must do here is run.
	my $h = make_harness(envs => ['qa']);
	# The new hook writes the environment file the command asks it for,
	# and the blueprint hook names the one manifest the environment is
	# built from, so the kit is one the command will work with and the run
	# reaches the end of its work rather than stopping partway.
	fixture_kit($h, hooks => {
		new => <<'EOS',
cat > "$GENESIS_ROOT/$GENESIS_ENVIRONMENT.yml" <<YAML
---
kit:
  name:    dev
  version: latest
  features: []
genesis:
  env: $GENESIS_ENVIRONMENT
YAML
EOS
		blueprint => "echo manifest.yml\n",
	});

	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'new', 'lab');
	is($exit, 0, 'the command succeeds');
	_only_control_stands($h, 'it created no deployment branch');
	like("$out$err", qr/propagate/,
		'and it says when the environment reaches its branch');
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
