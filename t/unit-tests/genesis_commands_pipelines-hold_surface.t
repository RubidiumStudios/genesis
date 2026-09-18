#!perl
# Proves T308, that the two hold commands register with the pipeline group and
# the pre-deploy branch class, that they take the group's disowned refusal,
# that the record path and the readers the earlier steps left reachable still
# resolve, and that the command reference records the boundary D59 asks for.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Commands qw/known_commands/;
use Genesis::Exit;
use Genesis::Env;
use Genesis::CI::Walk;
provide_rc();

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# The two commands are declared in bin/genesis rather than in a module, so
# nothing in the process knows them until that file is loaded.
require_ok './bin/genesis';

subtest 'both commands register' => sub {
	plan tests => 6;

	my %commands = map {$_ => 1} known_commands();
	for my $command (qw(pipeline-hold pipeline-release)) {
		ok($commands{$command}, "$command is a known command");
		is(Genesis::Commands::command_properties($command)->{function_group},
			Genesis::Commands::PIPELINE, "$command sits in the pipeline group");
		is(Genesis::Commands::command_properties($command)->{branch_class},
			Genesis::Commands::PRE_DEPLOY, "$command is a pre-deploy command");
	}
};

subtest 'both commands take the pipeline group refusal' => sub {
	# Four rows, and one more for each of the two runs' own restoration
	# assertions.  A repository with an applied record and the pipeline
	# disabled is the disowned state D64 names.
	plan tests => 6;

	for my $command (qw(pipeline-hold pipeline-release)) {
		my $h = make_harness(envs => ['prod'], pipeline => 0);
		fixture_applied($h, control => $h->git('a')->sha($h->control));

		my ($out, $err, $exit) = run_genesis($h, 'prod', $command, 'a reason');
		is($exit, Genesis::Exit::CONFIG, "$command exits CONFIG on a disowned pipeline");
		like(unfolded($out, $err), qr/pipeline\.enabled/,
			"$command names the key the refusal turns on");
	}
};

subtest 'the points the earlier steps left reachable resolve' => sub {
	# Every row here is green on arrival, which is what T308 asks of them.
	# They are guards over the claim that the two commands were added on top
	# of what the MVP already had, so each one catches an implementation
	# that reached the same behaviour by building a second mechanism: a
	# reader renamed or dropped, the record moved out from under
	# exodus_base, or the held qualifier rendered a second time in the
	# command file instead of read off the one renderer in the report.
	plan tests => 5;

	can_ok('Genesis::Env', qw(hold_record_path hold_record set_hold clear_hold));
	can_ok('Genesis::CI::Walk', qw(gate_state));

	my $env_source = get_file('lib/Genesis/Env.pm');
	like($env_source, qr{exodus_base\s*\.\s*'/hold'},
		'the hold hangs off exodus_base as a sibling of the deployments');

	my $report = get_file('lib/Genesis/CI/Report.pm');
	like($report, qr/needs clearing/,
		'the needs-clearing qualifier is the one the walk already printed');

	# Whole-line comments come out first.  The command file carries one
	# comment that names the qualifier in order to say where it is rendered,
	# and that sentence is evidence for this row rather than against it.
	# What the row refuses is the phrase in code, which is the shape a
	# second renderer would take.
	my $pipelines = get_file('lib/Genesis/Commands/Pipelines.pm');
	$pipelines =~ s/^\s*#.*$//mg;
	unlike($pipelines, qr/needs clearing/,
		'and no second renderer of it grew in the command file');
};

subtest 'the command reference records the boundary' => sub {
	plan tests => 3;

	my $doc = get_file('docs/ci/user/cli-commands.md');
	like($doc, qr/genesis pipeline-hold/, 'the hold command is documented');
	like($doc, qr/genesis pipeline-release/, 'the release command is documented');
	like($doc, qr/after the MVP/,
		'and the reference says the two arrived after the MVP');
};

done_testing;
