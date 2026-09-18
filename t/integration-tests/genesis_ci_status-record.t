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
# as an environment and Genesis::Top::load_env cannot load, so the row gets
# the per-environment failure of D60 rather than a file no YAML reader will
# take.  The tracked list rides along, because the file it replaces carried
# one and a row that quietly narrowed the set would be proving something
# else.
sub ghost_env_file {
	my ($env) = @_;
	return join("\n",
		'---', 'kit:', '  name:    ghost', '  version: 9.9.9',
		'  features: []', 'genesis:', "  env: $env", '  pipeline:',
		'    track_additional_files:', '    - ops/shared.yml', '');
}

sub env_row {
	my ($record, $name) = @_;
	my ($row) = grep { $_->{env} eq $name } @{$record->{environments}};
	return $row;
}

subtest 'one record carries the reading, the marker, and the routing' => sub {
	# Five assertions, and one more for the restoration run_genesis asserts
	# on the single command this row runs.
	plan tests => 6;

	my $h = make_harness(envs => ['lab'], provider => 'manual',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	init_branch($h, 'lab');

	my $c1 = commit_on_control($h, files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	deliver($h, 'lab', control => $c1);
	certify($h, 'lab', control_commit => $c1);
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
	# Six assertions and one restoration.
	plan tests => 7;

	my $h = ready_harness(envs => ['lab', 'qa', 'prod'], chained => 1,
		kit => 'omega-v2.7.0');

	my ($out, $err, $exit) = run_genesis($h, 'pipeline-status');
	is($exit, 0, 'the command exits zero');

	my @rows = grep { /\b(lab|qa|prod)\b/ } split(/\n/, $out);
	like($rows[0], qr/^\s{2}lab\b/,    'lab sits at the root of the tree');
	like($rows[1], qr/^\s{4}qa\b/,     'qa is indented one level under lab');
	like($rows[2], qr/^\s{6}prod\b/,   'prod is indented two levels under qa');
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

done_testing;
