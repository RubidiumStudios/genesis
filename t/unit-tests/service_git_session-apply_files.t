#!/usr/bin/env perl
# Proves T110, T112, T116, and T117: the writer delivers one control commit to
# qa/bosh as a mirror, so the branch's tree equals the propagation set as it
# stood at the delivered commit and a path that dropped out of the set is gone
# from the branch, it names every hand edit it overwrote, and it commits with
# the message its caller handed it rather than with one of its own.
#
# Three rows below stand behind the writer's three refusals.  Two of them are
# the empty set and the set whose paths the source commit holds none of, and
# both end the run at SOFTWARE before anything is written, because a mirror
# handed nothing to deliver would take every file off the branch and the check
# that follows would still be happy about it.  The third is the caller who
# hands the writer no message, which is refused before the set is even read.
#
# The last row is the preview, which computes the whole delivery and then
# returns before the first write, so it reports what would land and what would
# go while the branch stays where it was.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Cwd ();
use Genesis;
use Genesis::CI::Marker;
use Genesis::Exit qw/SOFTWARE/;
use Genesis::Top;
use Service::Git;
use Service::Git::Session;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# bail_from - the refusal one call raised, and the code it would have exited on
#
# A row that weighs an exit code cannot read one out of this process, because
# bail dies rather than exits whenever it is reached from inside an eval, and
# a test file always is.  The refusal is caught in the package that raises it
# and the code is read off the arguments it was composed with.  It asserts
# what a row means rather than building any state, so it lives here beside the
# rows that use it.
sub bail_from {
	my ($code) = @_;

	my @raised;
	{
		no warnings 'redefine', 'once';
		local *Service::Git::Session::bail =
			sub {push @raised, [@_]; die "refused\n"};
		eval {$code->(); 1};
	}
	unless (@raised) {
		diag("nothing was raised; the code died of: $@") if $@;
		return ('', undef);
	}

	my @args = @{$raised[0]};
	my $opts = ref($args[0]) eq 'HASH' ? shift(@args) : {};
	my ($format, @rest) = @args;

	return (sprintf($format, @rest), $opts->{exitcode});
}

subtest 'a delivery mirrors the set at the delivered commit' => sub {
	plan tests => 6;

	# The kit's blueprint names one repository-side fragment, so ops/extra.yml
	# is in the set for as long as control holds it, and the embedded genesis
	# is there so the eighth kind is a file rather than a name nothing tracks.
	my $h = make_harness(
		envs => ['qa'], root => 'bosh',
		kit  => 't/src/ops-blueprint', embed => 1,
	);
	fixture_vault($h);
	init_branch($h, 'qa');

	# A control commit the branch is delivered from, and then one that deletes
	# the fragment, so a path leaves the set for a reason the working tree and
	# the delivered commit agree about.  The second commit also rewrites a file
	# the set keeps, because a delivery whose only change is a deletion never
	# reaches the writing half of the mirror and would leave it unproven.
	my $first = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => "---\nextra: yes\n"},
		message => 'add the fragment the blueprint names',
		push    => 1,
	);
	deliver($h, 'qa', copy => 'a', control => $first);

	my $second = commit_on_control($h,
		files   => {
			'bosh/ops/extra.yml'    => undef,
			'bosh/dev/manifest.yml' => "---\nsimple: you know it differently\n",
		},
		message => 'delete the fragment and edit the kit',
		push    => 1,
	);

	# propagation_files reads the repository through Service::Git->new('.'),
	# which is the deployment root a command is run from, and the Top and the
	# environment are built before the session opens, because a deployment
	# branch is not a repository a Top can be opened on.
	# The row has to run from the deployment root, because the reader reaches
	# the repository through Service::Git->new('.'), and it has to come back
	# out however it leaves, which is what the harness guard is for.
	my $in_root = in_root($h);
	# The handle is built at the deployment root and not at the copy root,
	# because Service::Git keeps one instance per repository and fixes its
	# prefix at that first construction.  A handle built at the copy root
	# carries no prefix, and the set then comes back deployment-root-relative
	# and matches nothing the branch holds, which is not the shape a command
	# run from the deployment root has.
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = $top->load_env('qa');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));

	my $result = $session->apply_files($second,
		env     => $env,
		message => Genesis::CI::Marker::build($second, 'qa'),
	);
	$session->finish;
	assert_w_restored($w, 'the session restores the working state');

	ok($result->{commit}, 'the writer reports a commit');

	is_deeply($result->{delivered}, ['bosh/dev/manifest.yml'],
		'the writer reports the one path whose blob the delivery moved');

	my @expected = sort(propagation_set($h, 'qa', at => $second));
	is_deeply(tree_of($h->a, $h->slug('qa')), [@expected],
		"the branch's tree equals the set at the delivered commit");

	ok(!grep({$_ eq 'bosh/ops/extra.yml'} @{tree_of($h->a, $h->slug('qa'))}),
		'the path that dropped out of the set is gone from the branch');

	assert_snapshot_invariant($h, 'qa', copy => 'a',
		name => 'the delivered branch holds its source');
};

# Proves T112: a hand edit to a propagated file that the delivered commit did
# not change is overwritten, the index check still passes, and the file is
# reported as overwrote-hand-edit.
subtest 'a hand edit is overwritten and named' => sub {
	plan tests => 5;

	# The same repository the mirror row runs against, because the file the
	# hand edit lands on has to be one the product's own reader puts in the
	# set, and the blueprint's fragment is the one ops file that is.
	my $h = make_harness(
		envs => ['qa'], root => 'bosh',
		kit  => 't/src/ops-blueprint', embed => 1,
	);
	fixture_vault($h);
	init_branch($h, 'qa');

	my $first = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => "---\nextra: yes\n"},
		message => 'add the fragment the blueprint names',
		push    => 1,
	);
	deliver($h, 'qa', copy => 'a', control => $first);

	# The hand edit, on a file the next commit does not touch.  It is written
	# in copy A, because that is the clone the session opens in and a hand
	# edit copy B alone holds is not on the branch the writer stands on.
	hand_commit($h, $h->slug('qa'), copy => 'a',
		files   => {'bosh/ops/extra.yml' => "---\nextra: edited by hand\n"},
		message => 'fix it on the branch, just this once',
	);

	# The delivered commit moves one other file in the set, so the delivery
	# has something of its own to write and the row can tell a path the
	# commit changed from a path it did not.  It adds a third, which the
	# branch has never held, so the row also says that an addition is not an
	# overwrite however new its content is.
	my $second = commit_on_control($h,
		files   => {
			'bosh/dev/manifest.yml'   => "---\nsimple: you know it differently\n",
			'bosh/dev/extra-spec.yml' => "---\nspec: brand new\n",
		},
		message => 'edit the kit and add a file to it',
		push    => 1,
	);

	my $in_root = in_root($h);
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = $top->load_env('qa');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));

	my $result = $session->apply_files($second,
		env     => $env,
		changed => ['bosh/dev/manifest.yml'],
		message => Genesis::CI::Marker::build($second, 'qa'),
	);
	$session->finish;
	assert_w_restored($w, 'the session restores the working state');

	ok($result->{commit}, 'the delivery committed, so the check passed');

	is_deeply([@{$result->{overwrote}}], ['bosh/ops/extra.yml'],
		'the hand-edited file is reported as overwrote-hand-edit');

	is($git->show_file($h->slug('qa'), 'bosh/ops/extra.yml'),
		$git->show_file($second, 'bosh/ops/extra.yml'),
		'the hand edit was overwritten from the source');

	assert_snapshot_invariant($h, 'qa', copy => 'a',
		name => 'the branch holds its source after the overwrite');
};

# Proves T117: the writer commits with the message its caller handed it and
# builds none of its own, so a direct-mode call carries one marker naming the
# delivered control commit, a PR-mode call carries the aggregate's subject and
# body, and the check that follows reads the marker the caller wrote.
subtest "the writer commits with its caller's message" => sub {
	plan tests => 10;

	my $h = make_harness(
		envs => ['qa'], root => 'bosh',
		kit  => 't/src/ops-blueprint', embed => 1,
	);
	fixture_vault($h);
	init_branch($h, 'qa');

	# Both branches are cut at the seeded tip of control, so each of them
	# already carries the set and each delivery below has something of its
	# own to write.  The pull request branch is cut through deliver rather
	# than named at the switch, because switch reads a name no branch carries
	# as a commit and bails on it before the writer is ever reached.
	my $base = ref_in($h->a, 'refs/heads/' . $h->control);
	deliver($h, 'qa', copy => 'a', control => $base);
	deliver($h, 'qa', copy => 'a', pr => 1, control => $base);

	my $one = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => "---\nextra: yes\n"},
		message => 'add the ops file the blueprint names',
		push    => 1,
	);
	my $two = commit_on_control($h,
		files   => {'bosh/dev/manifest.yml' => "---\nsimple: you know it differently\n"},
		message => 'edit the kit the branch carries',
		push    => 1,
	);

	my $in_root = in_root($h);
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = $top->load_env('qa');

	# The fault plan belongs to this harness, and the handle it arms is the
	# one this row has already built at the deployment root, so the prefix
	# survives the arming.  A later subtest builds a harness of its own and
	# inherits the subclass on its own copy rather than on this one.
	my $fault = fault_git($h);
	reset_steps($fault);

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));

	# In direct mode the row makes one call, which delivers one control
	# commit under the marker the caller built.
	my $direct = Genesis::CI::Marker::build($one, 'qa');
	$session->apply_files($one, env => $env, message => $direct);

	my ($subject) = $git->log_subjects($h->slug('qa'), limit => 1, format => '%s');
	is($subject, $direct, 'the subject is the message the caller handed it');
	is(harness_marker($h, $h->slug('qa'), copy => 'a'), $one,
		'the marker names the delivered control commit');

	my @commits = grep {$_->[0] eq 'commit'} step_log($fault);
	is(scalar(@commits), 1, 'exactly one commit was made');
	is($commits[0][1], $direct, 'the writer passed the message through unchanged');

	# In pull request mode the row makes one call for the whole aggregate,
	# and the message it hands over carries a body under its subject.  That
	# body is what a writer building a subject of its own could not carry,
	# and it is the half the pull request's reviewer reads.
	my $aggregate = Genesis::CI::Marker::build($two, 'qa')
		. "\n\n"
		. sprintf("%s %s\n", substr($one, 0, 8), 'add the ops file the blueprint names')
		. sprintf("%s %s\n", substr($two, 0, 8), 'edit the kit the branch carries');
	$session->switch($h->pr_branch('qa'));
	$session->apply_files($two, env => $env, message => $aggregate);
	$session->finish;
	assert_w_restored($w, 'the session restores the working state');

	# Both of the aggregate's entries are read, because a writer that kept
	# the first line and dropped the rest would leave the body looking whole
	# to a row that only asked about its opening.
	my ($body) = run({dir => $h->a}, 'git', 'log', '-1', '--format=%B',
		$h->pr_branch('qa'));
	like($body, qr{add the ops file the blueprint names},
		"the aggregate's body survived");
	like($body, qr{edit the kit the branch carries},
		"and its second entry survived beside the first");
	is(harness_marker($h, $h->pr_branch('qa'), copy => 'a'), $two,
		"the check reads the marker the caller wrote, which names the newest");

	# The step log is read again after the second call, so a writer that
	# passed a direct-mode message through and rebuilt a pull-request-mode
	# one is caught here rather than left to the body assertion alone.  The
	# log was not reset between the two calls, so it holds both commits.
	my @both = grep {$_->[0] eq 'commit'} step_log($fault);
	is(scalar(@both), 2, 'the pull request call made one commit of its own');
	is($both[1][1], $aggregate,
		'and the writer passed the aggregate through unchanged too');
};

# The first of the writer's two refusals.  A delivery is a mirror, so a set
# with nothing in it would take every file off the branch, and the check that
# follows would be happy about the emptied branch afterwards.  The writer
# therefore refuses before it reads the index at all.
#
# No repository produces the state, because _propagation_file_kinds always
# names the configuration and the embedded genesis, so the row makes the
# reader answer empty for the length of the block below.  The writer reads
# its set through propagation_files_at, which is the at-commit reader, so
# that is the sub the row localises and not the working-tree one beneath it.
# It is a localised glob and not a stand-in environment, so everything below
# the reader is the production writer.
subtest 'an empty set is refused before anything is written' => sub {
	plan tests => 5;

	my $h = make_harness(
		envs => ['qa'], root => 'bosh',
		kit  => 't/src/ops-blueprint', embed => 1,
	);
	fixture_vault($h);
	init_branch($h, 'qa');

	my $base = ref_in($h->a, 'refs/heads/' . $h->control);
	deliver($h, 'qa', copy => 'a', control => $base);

	# A control commit the writer would have had work to do for, so the row
	# reads a branch the refusal left alone rather than one there was nothing
	# to write onto in the first place.
	my $one = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => "---\nextra: yes\n"},
		message => 'add the ops file the blueprint names',
		push    => 1,
	);

	my $in_root = in_root($h);
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = $top->load_env('qa');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));

	my $tip = ref_in($h->a, 'refs/heads/' . $h->slug('qa'));
	my ($message, $code) = bail_from(sub {
		# The glob is localised for the whole of this closure and not for
		# one statement of it, so the reader answers empty for everything
		# below, and the one call the closure makes is the delivery.
		no warnings 'redefine';
		local *Genesis::Env::propagation_files_at = sub {()};
		$session->apply_files($one,
			env     => $env,
			message => Genesis::CI::Marker::build($one, 'qa'),
		);
	});

	is($code, SOFTWARE, 'the empty set ends the run as a system failure');
	like($message, qr{\Qpropagation set of #C{qa} is empty\E},
		'the refusal names the environment whose set came back empty');
	is(ref_in($h->a, 'refs/heads/' . $h->slug('qa')), $tip,
		'the branch is where the refusal found it');
	# The porcelain is read whole rather than through is_clean, which
	# filters git's untracked half out.  Both of the writer's writes stage,
	# so is_clean would catch either one, but the assertion says the tree
	# and it should read the tree.
	my ($porcelain) = run({dir => $h->a}, 'git', 'status', '--porcelain');
	is($porcelain // '', '', 'nothing was written and nothing was staged');

	$session->finish;
	assert_w_restored($w, 'the session restores the working state');
};

# The second refusal, onto the same ending.  A set can be full and still
# resolve to nothing, and then every path on the branch falls outside the
# membership, the whole branch is staged for removal, and the commit succeeds
# because a removal is something to commit.
#
# No repository produces the state either, now that the at-commit reader
# finds the deployment root at the commit it is asked about rather than from
# the handle the caller passes in.  A handle built at the copy root used to
# make the set come back deployment-root-relative, and the reader now works
# the prefix out for itself, so that scene answers a set the commit does hold
# and never reaches the refusal.  The row therefore localises the at-commit
# reader too, and answers a full set of deployment-root-relative paths, which
# is the shape a prefix mismatch produced and is the one input the refusal
# reads.  Everything below the reader is the production writer.
subtest 'a set the source commit holds none of is refused' => sub {
	plan tests => 5;

	my $h = make_harness(
		envs => ['qa'], root => 'bosh',
		kit  => 't/src/ops-blueprint', embed => 1,
	);
	fixture_vault($h);
	init_branch($h, 'qa');

	my $base = ref_in($h->a, 'refs/heads/' . $h->control);
	deliver($h, 'qa', copy => 'a', control => $base);

	my $one = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => "---\nextra: yes\n"},
		message => 'add the ops file the blueprint names',
		push    => 1,
	);

	my $in_root = in_root($h);
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = $top->load_env('qa');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));

	my $tip = ref_in($h->a, 'refs/heads/' . $h->slug('qa'));
	my ($message, $code) = bail_from(sub {
		no warnings 'redefine';
		# The set a handle carrying the wrong prefix answered, which is every
		# path named as the deployment root names it rather than as the git
		# root does.  The commit holds each of them under bosh/ and none of
		# them where the set puts them.
		local *Genesis::Env::propagation_files_at = sub {
			qw(.genesis/config .genesis/bin/genesis qa.yml ops/extra.yml)
		};
		$session->apply_files($one,
			env     => $env,
			message => Genesis::CI::Marker::build($one, 'qa'),
		);
	});

	is($code, SOFTWARE, 'the unresolvable set ends the run as a system failure');
	my $counted = qr{\QNone of the\E \d+ \Qpaths in the propagation set of\E};
	my $located = qr{\Q#C{qa} is in the tree of #C{$one}\E};
	like($message, qr{$counted $located},
		'the refusal names the count and the commit the lookup went wrong at');
	is(ref_in($h->a, 'refs/heads/' . $h->slug('qa')), $tip,
		'the branch is where the refusal found it');
	# Read whole, for the reason the row above gives.
	my ($porcelain) = run({dir => $h->a}, 'git', 'status', '--porcelain');
	is($porcelain // '', '', 'nothing was written and nothing was staged');

	$session->finish;
	assert_w_restored($w, 'the session restores the working state');
};

# The third refusal, and the one a caller meets rather than an operator.  The
# writer builds no message of its own, so a caller that hands it none has
# asked for a commit nobody can write, and saying so where the call is made
# is better than composing a subject the caller never chose.  It is refused
# before the set is read, so nothing about the repository is even looked at.
subtest 'a call with no message is refused' => sub {
	plan tests => 4;

	my $h = make_harness(
		envs => ['qa'], root => 'bosh',
		kit  => 't/src/ops-blueprint', embed => 1,
	);
	fixture_vault($h);
	init_branch($h, 'qa');

	my $base = ref_in($h->a, 'refs/heads/' . $h->control);
	deliver($h, 'qa', copy => 'a', control => $base);

	# A control commit the writer would have had work to do for, so the row
	# reads a branch the refusal left alone rather than one there was
	# nothing to write onto in the first place.
	my $one = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => "---\nextra: yes\n"},
		message => 'add the ops file the blueprint names',
		push    => 1,
	);

	my $in_root = in_root($h);
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = $top->load_env('qa');

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));

	my $tip = ref_in($h->a, 'refs/heads/' . $h->slug('qa'));
	my ($message) = bail_from(sub {
		$session->apply_files($one, env => $env);
	});

	like($message, qr{\Qapply_files needs its caller's commit message\E},
		'the refusal says the message is the caller\'s to hand over');
	like($message, qr{\Qsince it builds none\E},
		'and says why, which is that the writer builds none of its own');
	is(ref_in($h->a, 'refs/heads/' . $h->slug('qa')), $tip,
		'the branch is where the refusal found it');

	$session->finish;
	assert_w_restored($w, 'the session restores the working state');
};

# Proves T116: a dry run writes no file and makes no commit, so the writer's
# two assertions never run, no branch moves in copy A, and the preview still
# reports what would land and what would go.
#
# The preview is worth more than the absence of a commit, because the run
# reports per environment and per control commit the files a delivery would
# land, and the mirror is the only thing that knows either that list or the
# list of paths that would go.
subtest 'a dry run writes nothing and checks nothing' => sub {
	plan tests => 10;

	# The same repository the rows above run against, because the preview has
	# to read a real set and the blueprint's fragment is the one ops file the
	# product's own reader puts in it.
	my $h = make_harness(
		envs => ['qa'], root => 'bosh',
		kit  => 't/src/ops-blueprint', embed => 1,
	);
	fixture_vault($h);
	init_branch($h, 'qa');

	my $first = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => "---\nextra: yes\n"},
		message => 'add the fragment the blueprint names',
		push    => 1,
	);
	# The init file is kept, so the preview has a removal to report as well as
	# a write.  A plain delivery takes it off by construction, and the row
	# would then have nothing to read the removed list against.
	deliver($h, 'qa', copy => 'a', control => $first, keep => ['init']);

	# One file the set keeps moves between the delivery and the source, so
	# the preview has a path to name as one that would land.
	my $source = commit_on_control($h,
		files   => {'bosh/dev/manifest.yml' => "---\nsimple: moved on\n"},
		message => 'edit the kit',
		push    => 1,
	);

	my $in_root = in_root($h);
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = $top->load_env('qa');

	# The fault plan belongs to this harness and to its copy A, and the
	# handle it arms is the one this row has already built at the deployment
	# root, so the prefix survives the arming.  A subtest that builds a
	# harness of its own inherits the subclass on that copy rather than on
	# this one.
	my $fault = fault_git($h, copy => 'a');
	reset_steps($fault);

	my $w = snapshot_w($h);
	my $session = $git->session;
	$session->begin;
	$session->switch($h->slug('qa'));

	my $before = ref_in($h->a, 'refs/heads/' . $h->slug('qa'));

	my $result = $session->apply_files($source,
		env     => $env,
		dry_run => 1,
		message => Genesis::CI::Marker::build($source, 'qa'),
	);

	# The tree and the index are read before the finish, because finish puts
	# control's working state back and the state this row asks about is the
	# one the preview left behind.
	# Read whole rather than through is_clean, which filters the untracked
	# half out, because a preview that wrote a file without staging it is
	# exactly the shape this row is here to rule out.
	my ($porcelain) = run({dir => $h->a}, 'git', 'status', '--porcelain');
	is($porcelain // '', '',
		'the tree and the index are clean, so no check could have run');

	# A real delivery leaves the tree clean too, since it commits what it
	# writes, so the file the source moved is read as well and has to hold
	# what the branch held before the call.
	is(slurp($h->a . '/bosh/dev/manifest.yml'), "---\nsimple: you know it\n",
		'the file the source moved still holds what the branch held');

	$session->finish;
	assert_w_restored($w, 'the session restores the working state');

	is($result->{commit}, undef, 'no commit was made');
	is($result->{dry_run}, 1, 'the result says it was a preview');
	is_deeply($result->{delivered}, ['bosh/dev/manifest.yml'],
		'the preview still says what would land');
	is_deeply($result->{overwrote}, ['bosh/dev/manifest.yml'],
		'the preview still names what a delivery would overwrite');
	is_deeply([sort @{$result->{removed}}], ['init'],
		'the preview still says what would go');

	is(ref_in($h->a, 'refs/heads/' . $h->slug('qa')), $before,
		'no branch moved in copy A');

	my @steps = step_log($fault);
	is_deeply([grep {$_->[0] =~ /^(checkout_file|rm|commit)$/} @steps], [],
		'no file was written, removed, or committed');
};

# The writer records every branch it commits to, so that a commit which left
# a tip where it was is still in the set an abort resets.  The restore is the
# other end of that record.  Once it has put a branch back there is nothing
# left for an abort to do about it, and for a branch this run cut the second
# pass would answer for a delete it never made, so the restore takes the
# branch off the set the way discard already does.
subtest 'the restore takes a branch off the committed set' => sub {
	plan tests => 3;

	my $h = make_harness(
		envs => ['qa'], root => 'bosh',
		kit  => 't/src/ops-blueprint', embed => 1,
	);
	fixture_vault($h);
	init_branch($h, 'qa');

	# The branch is cut at the seeded tip of control, so it already carries
	# the set and the delivery below has something of its own to write.
	my $base = ref_in($h->a, 'refs/heads/' . $h->control);
	deliver($h, 'qa', copy => 'a', control => $base);

	my $due = commit_on_control($h,
		files   => {'bosh/ops/extra.yml' => "---\nextra: yes\n"},
		message => 'add the ops file the blueprint names',
		push    => 1,
	);

	my $in_root = in_root($h);
	my $git = Service::Git->new($h->a . '/bosh');
	my $top = Genesis::Top->new($h->a . '/bosh');
	my $env = $top->load_env('qa');

	my $branch  = $h->slug('qa');
	my $session = $git->session;
	$session->begin;
	$session->switch($branch);
	$session->apply_files($due, env => $env,
		message => Genesis::CI::Marker::build($due, 'qa'));

	ok(grep({$_ eq $branch} $session->committed_branches),
		'the writer put the branch in the set an abort would reset');
	is($session->restore_branch($branch), 'reset',
		'the restore puts it back where the remote has it');
	ok(!grep({$_ eq $branch} $session->committed_branches),
		'and it is off that set afterwards');

	$session->finish;
};

done_testing;
