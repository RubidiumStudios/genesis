#!/usr/bin/env perl
# Proves T278, T279, T280, and T282: the reading enum with its error row, the
# one canonical record --json emits, the tree that renders it in DAG order,
# and the walk shared with the run so the two cannot disagree.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use JSON::PP qw/decode_json/;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

# The environment file the broken row commits by hand.  It names a kit this
# repository does not hold, which Genesis::Env::is_valid_env_file still reads
# as an environment and Genesis::Top::load_env cannot load, so the row gets a
# per-environment failure rather than a file no YAML reader will take.  The
# tracked list rides along, because the file it replaces carried one and a row
# that quietly narrowed the set would be proving something else.
sub ghost_env_file {
	my ($env) = @_;
	return join("\n",
		'---', 'kit:', '  name:    ghost', '  version: 9.9.9',
		'  features: []', 'genesis:', "  env: $env", '  pipeline:',
		'    track_additional_files:', '    - ops/shared.yml', '');
}

# A valid environment file with a note under params, which is where a row puts
# the delta a commit needs to make.  The kit block is the one write_env_file
# lays down, because the harness installs that kit at the root's dev directory
# and a file naming another one cannot be loaded.
sub env_file_with {
	my ($env, $note) = @_;
	return join("\n", '---', 'kit:', '  name:    dev', '  version: latest',
		'  features: []', 'genesis:', "  env: $env", 'params:',
		"  note: $note", '');
}

# The moment the first row's deployment is certified at, pinned rather than
# taken from the clock, so the row can compare what --json emits against the
# exact string vault was given.
our $CERTIFIED_AT = '2026-09-18 03:48:52 +0000';

subtest 'one record carries the reading, the marker, and the routing' => sub {
	# Six assertions, and one more for the restoration run_genesis asserts
	# on the single command this row runs.
	plan tests => 7;

	my $h = make_harness(envs => ['lab'], provider => 'manual',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	init_branch($h, 'lab');

	my $c1 = commit_on_control($h, files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	deliver($h, 'lab', control => $c1);
	certify($h, 'lab', control_commit => $c1, at => $CERTIFIED_AT);
	my $c2 = commit_on_control($h, files => {'ops/shared.yml' => "---\ntwo\n"}, push => 1);
	deliver($h, 'lab', control => $c2);
	my $c3 = commit_on_control($h, files => {'ops/shared.yml' => "---\nthree\n"}, push => 1);

	fixture_applied($h, control => $c3);
	fixture_pipeline_record($h, 'lab');
	refresh($h, 'a');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--json');
	is($exit, 0, 'the command exits zero');

	my $row = env_row(decode_json($out), 'lab');
	is($row->{reading}, 'pending-deploy',
		'the certification axis reads pending-deploy');
	is($row->{merged}, $c2, 'the branch column holds the delivered control commit');
	is($row->{deployed}{control_commit}, $c1,
		'the deploy column holds the certified control commit');
	is(scalar @{$row->{pending}}, 1,
		'the routing the walk decided stands beside the reading');
	is($row->{deployed}{at}, $CERTIFIED_AT,
		'the timestamp is emitted in the form vault holds it, timezone and all');
};

subtest 'the reading enum is the four, and error sits outside it' => sub {
	# Seven assertions and one restoration.
	plan tests => 8;

	my $h = make_harness(envs => ['lab', 'qa', 'dev', 'prod', 'broken'],
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);

	# prod is given no branch at all, which is the not-propagated reading,
	# and broken is given one so that the walk reaches the load it fails.
	init_branch($h, $_) for qw/lab qa dev broken/;

	my $c1 = commit_on_control($h, files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	deliver($h, $_, control => $c1) for qw/lab qa/;
	certify($h, $_, control_commit => $c1) for qw/lab qa/;
	my $c2 = commit_on_control($h, files => {'ops/shared.yml' => "---\ntwo\n"}, push => 1);
	deliver($h, 'qa', control => $c2);

	commit_on_control($h,
		files => {'broken.yml' => ghost_env_file('broken')},
		push  => 1);
	fixture_applied($h, control => $c2);
	fixture_pipeline_record($h, $_) for qw/lab qa dev/;
	refresh($h, 'a');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--json');
	is($exit, 0, 'the command exits zero even with a row that fails to load');

	my $record = decode_json($out);
	is(env_row($record, 'lab')->{reading}, 'deployed', 'lab reads deployed');
	is(env_row($record, 'qa')->{reading}, 'pending-deploy', 'qa reads pending-deploy');
	is(env_row($record, 'dev')->{reading}, 'unseeded', 'dev reads unseeded');
	is(env_row($record, 'prod')->{reading}, 'not-propagated',
		'prod reads not-propagated');

	my $broken = env_row($record, 'broken');
	ok($broken->{error}, 'the failed row carries its error');
	is($broken->{reading}, 'not-propagated',
		'and it carries the reading the walk starts every record on');
};

subtest 'the tree renders the record in DAG order' => sub {
	# Seven assertions and one restoration.
	#
	# Six of the seven are guards over what the old renderer already did, and
	# they are here to hold it rather than to prove the change: the exit code,
	# the three indentation depths, the column heads, and the absence of the
	# word certified all passed against the topology walk this read model
	# replaced, which printed the same heads from the same format and kept its
	# own depth map.  The one assertion that could not pass against it is the
	# combined phrase below, because that renderer chose one of six mutually
	# exclusive strings and so could never say both halves of a row at once.
	plan tests => 8;

	my $h = ready_harness(envs => ['lab', 'qa', 'prod'], chained => 1,
		kit => 'omega-v2.7.0');

	# One commit due to lab and to nothing else, since an environment's own
	# file is in its own propagation set and in no other's.  lab is already
	# certified at the commit its branch carries, so its row has a settled
	# certification reading and a routing summary at the same time.
	commit_on_control($h, files => {'lab.yml' => env_file_with('lab', 'due')},
		push => 1);
	refresh($h, 'a');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	is($exit, 0, 'the command exits zero');

	# The environment rows alone, selected by the indent that opens one as
	# well as by the name.  A bare name match would take in any header line
	# that happened to name an environment, and the header above the rows
	# names every environment the pipeline has gone stale for.
	my @rows = grep { /^\s{2,}(?:lab|qa|prod)\s/ } split(/\n/, $out);
	like($rows[0], qr/^\s{2}lab\b/,    'lab sits at the root of the tree');
	like($rows[1], qr/^\s{4}qa\b/,     'qa is indented one level under lab');
	like($rows[2], qr/^\s{6}prod\b/,   'prod is indented two levels under qa');
	like($rows[0], qr/deployed; 1 pending/,
		'a row that is deployed and has a commit due says both, not one of six');
	like($out, qr/branch\s+deploy\s+status/,
		'the branch and deploy columns stand beside the status phrase');
	unlike($out, qr/certified/,
		'the word certified is a term of the design and the tree never prints it');
};

subtest 'the status reads the same walk the run reads' => sub {
	# Three assertions and one restoration for each of the two commands.
	plan tests => 5;

	my $h = make_harness(envs => ['lab', 'qa'], chained => 1,
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	init_branch($h, $_) for qw/lab qa/;

	my $c1 = commit_on_control($h, files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	deliver($h, $_, control => $c1) for qw/lab qa/;
	certify($h, $_, control_commit => $c1) for qw/lab qa/;
	my $c2 = commit_on_control($h, files => {'ops/shared.yml' => "---\ntwo\n"}, push => 1);
	deliver($h, 'lab', control => $c2);
	fixture_applied($h, control => $c2);
	fixture_pipeline_record($h, $_) for qw/lab qa/;
	refresh($h, 'a');

	my ($status) = run_genesis($h, 'pipeline-status', '--json');
	my $qa = env_row(decode_json($status), 'qa');
	is(scalar @{$qa->{pending}}, 0, 'the status holds the commit rather than pending it');
	is($qa->{held}[0]{reason}, 'ancestor-overlap',
		'the status names the ancestor overlap as the reason');

	my (undef, $dry) = run_genesis($h, 'propagate', '--dry-run', '-y');
	like($dry, qr/held by lab/,
		'the dry run withholds the same commit for the same reason');
};

subtest 'a repository with no pipeline still shows the header whole' => sub {
	# Three assertions and one restoration.
	plan tests => 4;

	# The provider accessor answers undef wherever the pipeline is switched
	# off, and the refusal that used to stand in front of this command is
	# gone, so the header has to name a provider of its own accord.
	my $h = make_harness(envs => ['lab'], pipeline => 0,
		kit => 'omega-v2.7.0');
	init_branch($h, 'lab');
	refresh($h, 'a');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	is($exit, 0, 'the command reports rather than refusing');
	like($out, qr/provider:\s*manual/,
		'no configured provider reads as manual, which is what it means');
	unlike($err, qr/uninitialized/,
		'and the header is built without a warning about an empty cell');
};

done_testing;
