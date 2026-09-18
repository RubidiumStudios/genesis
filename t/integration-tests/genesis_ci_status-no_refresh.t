#!/usr/bin/env perl
# Proves T284: --no-refresh writes nothing, fetches nothing through the gate
# either, marks every cell that rests on the remote-tracking refs, prints a
# stale header, and is declared at the registration the gate reads.
#
# The marking is deliberately narrow.  A word written onto every component
# would leave worst_class answering wrong for every row, so the colour an
# operator reads the report by would carry no information at all.  What
# carries the word is the routing summary, which is the component that rests
# on the refresh, the divergence cell, which carries it as its state, and the
# header, which says the whole report is stale.
#
# Three readings that a stale report has no business stating as fact are read
# here as well: the remedy for a branch the remote appears not to have, the
# staleness of a pipeline whose applied commit this clone never fetched, and
# the breach report, which rests entirely on refs nobody refreshed.
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
use Genesis::Commands qw/command_properties/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

sub plain {
	# The tree with every SGR sequence taken out, which is what the words of
	# a line are asserted against.  NOCOLOR is set above and the renderer
	# honours it, so this ordinarily changes nothing.  It is here because a
	# colour escape ends in the letter m, so a word boundary can never hold
	# in front of a coloured name, and a line that met one would fail for a
	# reason that had nothing to do with the words.
	my ($tree) = @_;
	$tree =~ s/\e\[[0-9;]*m//g;
	return $tree;
}

sub env_line {
	# The one rendered row an environment's name opens, selected by the
	# indent that opens a row as well as by the name, because the header
	# above the table names environments too.
	my ($tree, $name) = @_;
	my ($line) = grep { plain($_) =~ /^\s{2,}\Q$name\E\s/ } split(/\n/, $tree);
	return plain($line // '');
}

subtest 'the stale form marks every cell that rests on a refresh' => sub {
	# Eleven assertions, one of which is this row's own restoration, and one
	# more for the restoration run_genesis asserts on the second command.
	plan tests => 12;

	my $h = make_harness(envs => ['lab'], kit => 'omega-v2.7.0',
		tracked => ['ops/shared.yml', 'ops/extra.yml']);
	fixture_vault($h);
	init_branch($h, 'lab');
	my $c1 = commit_on_control($h, files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	deliver($h, 'lab', control => $c1);
	certify($h, 'lab', control_commit => $c1);
	fixture_applied($h, control => $c1);
	fixture_pipeline_record($h, 'lab');

	# A second control commit nobody has delivered, so the row carries a
	# routing summary and the marking has a component to ride on.  Without
	# one the only word in the whole report would be the header's own.
	commit_on_control($h, files => {'ops/extra.yml' => "---\nextra\n"}, push => 1);
	refresh($h, 'a');

	# A teammate moves control on R, which only a refresh would see, and the
	# branch-class gate is the one that would fetch it.
	my $ahead = move_on_r($h, $h->control);

	# The remote-tracking ref as this clone holds it going in, which is the
	# one ref a fetch would move and the one the row below compares against.
	my $tracking = $h->git('a')->sha('refs/remotes/origin/' . $h->control);
	# The capture has to be a commit for the comparison below to say
	# anything.  A ref this clone does not hold answers nothing here and
	# nothing after the command either, so the two readings would agree with
	# each other over a ref that was never there and the row would pass
	# without having watched a fetch at all.
	like($tracking, qr/^[0-9a-f]{40}$/,
		'the tracking ref going in is a commit this clone holds');

	my $before = snapshot_w($h);
	my ($out, $err, $exit) = run_genesis($h,
		{restore => 0}, 'pipeline-status', '--no-refresh');
	# A guard.  Every assertion below it reads standard output, and a
	# command that had come to refuse the flag would print nothing there and
	# fail each of them for a reason that had nothing to do with the marking.
	is($exit, 0, 'the stale form still reports');
	is($err, '', 'and says nothing on standard error');
	assert_w_restored($before, 'the stale form leaves working state alone');

	like(plain($out), qr/the report is stale/, 'a header says the report is stale');
	like(env_line($out, 'lab'), qr/1 pending \[unverifiable\]/,
		'the routing summary, which is the cell that rests on a refresh, carries the word');
	# The one the whole flag rests on, and it is read off the ref rather than
	# off the report.  A fetch moves the remote-tracking ref alone for a
	# branch this clone already holds, and every word of the report is read
	# from the local branch, so a gate or a command that fetched under the
	# flag would leave the whole of the output standing and show up nowhere
	# in it.  Nothing else in the suite can see that fetch: the restoration
	# assertion reads the branch, HEAD, the working directory, the status,
	# and the index, and no ref under refs/remotes.
	is($h->git('a')->sha('refs/remotes/origin/' . $h->control), $tracking,
		'neither the gate nor the command fetched, so the tracking ref stands');
	# A guard on the fixture.  The teammate's commit has to be somewhere this
	# clone could reach it for the row above to mean anything, and a move
	# that quietly landed on the tracking ref would leave that row green over
	# a comparison of a commit against itself.
	isnt($tracking, $ahead,
		'and the commit a teammate made on R was never this clone\'s to read');

	my ($json) = run_genesis($h, 'pipeline-status', '--no-refresh', '--json');
	my $record = decode_json($json || '{}');
	# Read off the encoded text rather than the decoded value, because the
	# walk writes the flag as a number and the marking writes it as the
	# encoder's own boolean.  A number reads false to a Perl caller either
	# way, so only the text says which of the two forms wrote the record,
	# and --json emits one shape whichever form of the command ran.
	like($json, qr/"refreshed"\s*:\s*false/,
		'the record says it was not refreshed, in the encoder\'s own boolean');
	is($record->{environments}[0]{divergence}{state}, 'unverifiable',
		'the divergence cell carries the flag rather than a state it cannot know');
	ok(!exists $record->{events},
		'and the machine-readable form carries the record D91 fixes and nothing beside it');
};

subtest 'the refresh a command may skip is declared at its registration' => sub {
	plan tests => 6;

	require_ok './bin/genesis';

	is(command_properties('pipeline-status')->{refresh}, 'optional',
		'pipeline-status declares that its refresh may be skipped');
	# pipeline-describe answers out of the repository's own files and offers
	# no flag to ask with, so its refresh is not optional but absent, and the
	# gate reads the difference rather than the command's name.
	is(command_properties('pipeline-describe')->{refresh}, 'never',
		'pipeline-describe declares that it never refreshes');
	ok(!defined(command_properties('propagate')->{refresh}),
		'propagate declares nothing, so the gate refreshes it');
	ok(!defined(command_properties('pipeline-apply')->{refresh}),
		'pipeline-apply declares nothing either');

	# A guard.  M7 took no-fetch off this command, and this goes red against
	# a step that revives the old name beside the new one.
	my %opts = @{command_properties('pipeline-status')->{options} || []};
	ok(!exists $opts{'no-fetch'}, 'the old name is gone from pipeline-status');
};

subtest 'the option and the declaration reach no other command' => sub {
	plan tests => 2;

	# Read from the registrations rather than by spawning each command.
	# t/integration-tests/genesis_commands_pipelines-refresh_flags.t drives
	# propagate, deploy, pipeline-apply, and new with the flag and reads the
	# usage error each of them answers with, so a spawned row here would
	# repeat that file and say nothing it does not.  What this reads instead
	# is the surface the new attribute could spread across: an option group
	# that gained the flag, or a registration that declared a refresh it
	# never makes, would go red here and nowhere else.
	my @with_option = grep {
		my %opts = @{command_properties($_)->{options} || []};
		exists $opts{'no-refresh'};
	} Genesis::Commands::commands();
	is_deeply([sort @with_option], ['pipeline-status'],
		'pipeline-status is the one command declaring the option');

	my @declaring = grep {
		defined command_properties($_)->{refresh}
	} Genesis::Commands::commands();
	is_deeply([sort @declaring], ['pipeline-describe', 'pipeline-status'],
		'and the two reading commands are the only ones declaring a refresh');
};

subtest 'a remedy that rests on the tracking refs is not offered stale' => sub {
	# Three assertions and one restoration for each of the two commands.
	plan tests => 5;

	my $h = make_harness(envs => ['lab'], provider => 'manual',
		kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	fixture_vault($h);
	fixture_applied($h, control => $h->git('a')->sha($h->control));
	fixture_pipeline_record($h, 'lab');

	# Refreshed, this is the branch a person cut and never published, and
	# the report names the remedy for it, which is to move anything wanted
	# to control and delete the branch.  Unrefreshed, this clone cannot tell
	# that branch from one a teammate pushed an hour ago, and a report that
	# told an operator to delete the second would be worse than one that
	# said nothing.
	local_branch_only($h, 'lab');
	refresh($h, 'a');

	my ($tree) = run_genesis($h, 'pipeline-status', '--no-refresh');
	unlike(env_line($tree, 'lab'), qr/local only/,
		'the stale report does not tell the operator to delete the branch');
	like(plain($tree), qr/the report is stale/,
		'it says the report is stale instead');

	my ($json) = run_genesis($h, 'pipeline-status', '--no-refresh', '--json');
	my ($row) = grep { $_->{env} eq 'lab' }
		@{decode_json($json || '{}')->{environments}};
	is($row->{divergence}{state}, 'unverifiable',
		'and the cell the remedy was read off carries the word');
};

subtest 'a commit this clone never fetched is not read as a fact' => sub {
	# Four assertions and one restoration for each of the two commands.
	plan tests => 6;

	my $h = make_harness(envs => ['lab'], kit => 'omega-v2.7.0',
		tracked => ['ops/shared.yml']);
	fixture_vault($h);
	init_branch($h, 'lab');
	my $c1 = commit_on_control($h, files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	deliver($h, 'lab', control => $c1);
	certify($h, 'lab', control_commit => $c1);
	fixture_pipeline_record($h, 'lab');
	refresh($h, 'a');

	# The pipeline was applied from a control commit this clone has never
	# held.  The staleness query diffs that commit against control, and git
	# refuses a diff against an object it does not have, so the report ended
	# at DATAERR rather than saying what it could not read.
	my $applied = move_on_r($h, $h->control);
	fixture_applied($h, control => $applied);

	my ($tree, $err, $exit) = run_genesis($h, 'pipeline-status', '--no-refresh');
	is($exit, 0, 'the report is produced rather than ended');
	is($err, '', 'and says nothing on standard error');
	like(plain($tree), qr/\[stale: unverifiable\]/,
		'and the applied line says the staleness could not be read');

	my ($json) = run_genesis($h, 'pipeline-status', '--no-refresh', '--json');
	my $record = decode_json($json || '{}');
	ok(!defined $record->{applied}{stale},
		'the record leaves the reading null rather than answering false');
};

subtest 'the breach report rests on refs nobody refreshed' => sub {
	# Two assertions and one restoration.
	plan tests => 3;

	my $h = make_harness(envs => ['lab'], kit => 'omega-v2.7.0',
		tracked => ['ops/shared.yml', 'ops/extra.yml']);
	fixture_vault($h);
	init_branch($h, 'lab');
	my $c1 = commit_on_control($h, files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	my $c2 = commit_on_control($h, files => {'ops/extra.yml' => "---\nextra\n"}, push => 1);
	deliver($h, 'lab', control => $c2);
	certify($h, 'lab', control_commit => $c2);
	fixture_applied($h, control => $c1);
	fixture_pipeline_record($h, 'lab');

	rewrite_control($h, drop => $c2);
	refresh($h, 'a');

	# The breach is real here, and it is read entirely off remote-tracking
	# refs.  Under this flag those refs are whatever the clone last fetched,
	# so a commit propagated an hour ago and never fetched reads exactly like
	# one the remote has dropped.  The line is printed and qualified rather
	# than withheld, because the first reading is the one that matters and
	# the second is the one an operator has to be able to discount.
	my ($tree) = run_genesis($h, 'pipeline-status', '--no-refresh');
	like(plain($tree), qr/lab's marker names control\@[0-9a-f]{7}/,
		'the breach is still named');
	like(plain($tree), qr/the remote no longer holds \[unverifiable\]/,
		'and the reading is marked as one no refresh stands behind');
};

subtest 'an environment with no branch rests on refs nobody refreshed' => sub {
	# Three assertions and one restoration for each of the two commands.
	plan tests => 5;

	my $h = make_harness(envs => ['lab'], kit => 'omega-v2.7.0',
		tracked => ['ops/shared.yml']);
	fixture_vault($h);
	# No branch is cut for lab, on either side, which is the repository
	# genesis pipeline-apply has not reached.  Unrefreshed, that reading
	# cannot be told from a clone that has simply never fetched a branch a
	# teammate applied an hour ago, so the wait is marked rather than said
	# flat, and an operator sent to pipeline-apply on a stale report would
	# be sent to a command that changes nothing.
	my $c = commit_on_control($h,
		files => {'ops/shared.yml' => "---\none\n"}, push => 1);
	fixture_applied($h, control => $c);
	fixture_pipeline_record($h, 'lab');
	refresh($h, 'a');

	my ($tree) = run_genesis($h, 'pipeline-status', '--no-refresh');
	like(env_line($tree, 'lab'),
		qr/held, awaiting pipeline-apply \[unverifiable\]/,
		'the wait carries the word the stale form marks it with');

	my ($json) = run_genesis($h, 'pipeline-status', '--no-refresh', '--json');
	my $row = decode_json($json || '{}')->{environments}[0];
	is($row->{certified}{state}, 'no-branch',
		'the state itself stands, so the wait is still worded by one sub');
	ok($row->{certified}{unverifiable},
		'and the record carries the mark the tree read it off');
};

done_testing;
