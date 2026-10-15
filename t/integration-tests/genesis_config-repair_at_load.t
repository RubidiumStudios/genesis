#!perl
# Proves T363 through the command an operator types: a configuration every
# other command refuses at load, because it carries the rc builds' ci: block,
# is repaired by genesis config --unset, and once the repair is committed the
# next command loads it.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;

use Genesis qw/slurp/;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], provider => 'manual');

subtest 'genesis config --unset repairs what the load refuses' => sub {
	# Four explicit rows, and one for the second run's own restoration
	# assertion.  The repair run writes the working tree on purpose, so it
	# is not asked to leave it as it found it.
	plan tests => 5;

	# The configuration the stale ci.yml row in
	# genesis_pipeline_config-validation_at_load.t loads, with the block
	# the rc builds wrote beside it.
	commit_on_control($h, files => {
		'.genesis/config' => join("\n",
			'---', 'deployment_type: bosh', 'version: "3"',
			'creator_version: 3.2.0', 'minimum_version: 3.2.0',
			'ci:', '  enabled: true',
			'pipeline:', '  enabled: true',
			'  provider:', '    type: manual',
			# Copy A is cloned from a bare repository at a filesystem path,
			# so the origin URL carries no GitHub owner/repo pair and the
			# source-control block cannot derive one.
			'  source_control:', '    repository: genesis/bosh-deployments', ''),
	});

	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'config', '--unset', 'ci');
	is $exit, 0, 'genesis config --unset ci is not refused by the key it removes';

	my $repaired = slurp($h->a.'/.genesis/config');
	unlike $repaired, qr/^ci:/m, 'and the block is gone from the file';

	SKIP: {
		# A repair that changed nothing leaves the harness no commit to make,
		# and the rows after it would report the harness rather than the
		# command.
		skip 'the repair left the file as it was, so there is nothing to commit', 3
			if $repaired =~ /^ci:/m;

		# Committed as an operator would, so the next command reads the
		# repair from control rather than from a dirty working tree.
		commit_on_control($h, files => {'.genesis/config' => $repaired});

		($out, $err, $exit) = run_genesis($h, 'pipeline-status', '--no-refresh');
		unlike $err, qr/unknown configuration key/,
			'the next command loads the repaired file';
		is $exit, 0, 'and carries on';
	}
};

done_testing;
