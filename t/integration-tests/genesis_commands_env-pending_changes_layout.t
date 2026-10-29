#!/usr/bin/env perl
# Proves T445: `genesis <env> pending-changes` reads top to bottom (D123's
# note of 2026-10-29).  Four repositories, one per verdict a reader meets: a
# first deploy, real changes, nothing pending, and commits that change nothing
# on the director.  Each opens with a framed summary, then the files and the
# commits since the deployed commit or the seed, a labelled rule, the
# director's side, and the verdict again at the close.
#
# What the rows catch: a summary that is not the first thing printed, or that
# counts what the sections below it do not show; a verdict that calls a deploy
# with nothing to change on the director pending changes, which is what the
# lmelt notify job said of a branch that carried Genesis updates alone; a range
# that lists the seed or starts from the wrong base; commits newest first; and
# folding that merges commits by different authors or hides them under
# --verbose.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use File::Temp ();

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $SECRET = 'hunter2-never-in-clear';

sub env_file {
	my ($marker, $note) = @_;
	return "---\n".($note ? "# $note\n" : '').<<"YAML";
kit:
  name:     dev
  version:  latest
  features: []
genesis:
  env:      qa
params:
  marker: $marker
YAML
}

my $BLUEPRINT =
	qq{cat > manifest.yml <<'MANIFEST'\n}.
	qq{---\n}.
	qq{name: qa-bosh\n}.
	qq{harness: (( grab params.marker ))\n}.
	qq{password: (( vault "secret/harness/pending:password" ))\n}.
	qq{releases:\n- name: harness\n  version: 1.2.3\n  url: https://releases.example/harness-1.2.3.tgz\n}.
	qq{stemcells:\n- alias: default\n  os: ubuntu-jammy\n  version: "1.1"\n}.
	qq{MANIFEST\n}.
	qq{echo manifest.yml\n};

sub entombed_ref {
	require Genesis::Env::Secrets::Entombment;
	return '(('.Genesis::Env::Secrets::Entombment::credhub_var_name(
		'_/secret/harness/pending', 'password', $_[0], 'genesis-entombed/').'))';
}

sub deployed_manifest {
	my ($marker) = @_;
	my $password = entombed_ref($SECRET);
	return "---\nname: qa-bosh\nharness: $marker\npassword: \"$password\"\n".
		"releases:\n- name: harness\n  version: 1.2.3\n  url: https://releases.example/harness-1.2.3.tgz\n".
		"stemcells:\n- alias: default\n  os: ubuntu-jammy\n  version: \"1.1\"\n";
}

# qa delivered once from control, certified there unless never_deployed, then
# each step: [control => $message, $file_content] delivers a control commit,
# and [hand => $message, $file, $content] commits on the branch.  The director
# holds the deployed manifest, its configs unmoved, the release and stemcell.
sub repository {
	my (%o) = @_;
	my $h = make_harness(envs => ['qa'], type => 'bosh');
	$h->_write_record('secret/harness/pending', password => $SECRET);

	my $first = commit_on_control($h, files => {'qa.yml' => env_file('the-deployed-version')},
		message => 'the deployed content', push => 1);
	init_branch($h, 'qa');
	my $deployed = deliver($h, 'qa', control => $first);
	certify($h, 'qa', commit => $deployed, control_commit => $first,
		artifacts => {'qa.yml' => deployed_manifest('the-deployed-version')})
		unless $o{never_deployed};

	for my $step (@{$o{then} || []}) {
		my ($kind, $message, @rest) = @$step;
		if ($kind eq 'control') {
			my $c = commit_on_control($h, files => {'qa.yml' => $rest[0]}, message => $message, push => 1);
			deliver($h, 'qa', control => $c);
		} else {
			hand_commit($h, $h->slug('qa'), files => {$rest[0] => $rest[1]}, message => $message);
		}
	}
	refresh($h, 'a');

	fixture_bosh($h, hooks => {blueprint => $BLUEPRINT});
	bosh_answer($h, manifest => $o{never_deployed} ? '' : deployed_manifest('the-deployed-version'));
	bosh_answer($h, '/deployment_configs?deployment=qa-bosh' => $o{never_deployed} ? '[]' :
		'[{"config":{"id":"1","type":"cloud","name":"default"}}]');
	bosh_answer($h, '/configs?latest=true' =>
		'[{"id":"1","type":"cloud","name":"default","content":"azs: [{name: z1}]\n"}]');
	bosh_answer($h, releases =>
		'{"Tables":[{"Rows":[{"name":"harness","version":"1.2.3*"}]}]}');
	bosh_answer($h, stemcells =>
		'{"Tables":[{"Rows":[{"name":"bosh-harness","os":"ubuntu-jammy","version":"1.1*","cpi":""}]}]}');

	stand_on($h, $h->control);
	return $h;
}

sub report {
	my ($h, @flags) = @_;
	my ($out, $err, $exit) = run_genesis($h, 'qa', 'pending-changes', @flags);
	return ("$out$err", $exit);
}

# The summary frame's body, from its header to the next frame line.
sub summary_of {
	my ($all) = @_;
	return $all =~ /══ Summary: qa \(bosh\) (?:═)+\n(.*?)\n(?:═){10,}/s ? $1 : '';
}

sub layout_ok {
	my ($all, $since) = @_;
	my @order = map {index($all, $_)} ('══ Summary: qa (bosh)', "\nFiles changed since $since\n",
		"\nCommits, oldest first\n", '── What the deploy would change on the director ',
		"\nManifest\n", "\nBOSH configs\n", "\nUploads\n");
	ok(!grep({$_ < 0} @order) && "@order" eq join(' ', sort {$a <=> $b} @order),
		"summary, files since $since, commits, rule, then the director's sections") or diag($all);
	like(summary_of($all), qr/\A\n  \S.*\n\n  \S/s, 'the summary in paragraphs, a blank line between');
}

subtest 'a first deploy' => sub {
	my $h = repository(never_deployed => 1);
	my ($all, $exit) = report($h);
	is($exit, 0, 'it succeeds') or diag($all);
	layout_ok($all, 'the branch was cut');
	my $summary = summary_of($all);
	like($summary, qr/qa has never been deployed\./, 'the summary says it has never deployed');
	like($summary, qr/Deploying it creates deployment qa-bosh, 1 release, stemcell ubuntu-jammy\/1\.1\./,
		'and what the first deploy creates');
	unlike($all, qr/Initialize \S+ branch/, 'the seed never listed');
	like($all, qr/══ A first deploy is pending for qa (?:═)+\s*\z/, 'and the verdict closes it');
};

subtest 'real changes' => sub {
	my $h = repository(then => [
		[control => 'the coming content', env_file('the-coming-version')],
		[control => 'a comment on the coming content', env_file('the-coming-version', 'reviewed')],
		[hand    => 'a hand edit on the branch', 'qa-notes.txt', "a hand edit\n"],
	]);
	my ($all, $exit) = report($h);
	is($exit, 0, 'it succeeds') or diag($all);
	layout_ok($all, 'the last deploy');
	my $summary = summary_of($all);
	like($summary, qr/3 commits pending, .*changing 2 files\./, 'three commits and two files');
	like($summary, qr/Last deployed .*, by harness, at [0-9a-f]{8}\./, 'when and by whom it last deployed');
	like($summary, qr/Deploying it changes the manifest\./, 'the manifest change, counted by kind');
	like($all, qr/the coming content.*\n(?:.*\n)*?.*a comment on the coming content.*\n(?:.*\n)*?.*a hand edit on the branch/,
		'the commits oldest first');
	like($all, qr/\w{3} \d\d \d\d:\d\d  \(.* ago\)  propagated from control\@[0-9a-f]{8} by \S/,
		'each with an absolute and a fuzzy date, its control commit and author');
	like($all, qr/"the coming content"  \(1 file\)/, 'its subject and a file count');
	unlike($all, qr/^\s+qa\.yml\s*$/m, 'no file names without --verbose');
	unlike($all, qr/the deployed content/, 'and not the deployed commit');
	like($all, qr/══ Changes are pending for qa (?:═)+\s*\z/, 'and the verdict closes it');
};

subtest 'nothing pending' => sub {
	my $h = repository();
	my ($all, $exit) = report($h);
	is($exit, 0, 'it succeeds') or diag($all);
	layout_ok($all, 'the last deploy');
	like(summary_of($all), qr/No commits are pending/, 'no commits');
	like(summary_of($all), qr/nothing is pending\./, 'and nothing on the director');
	like($all, qr/══ Nothing is pending for qa (?:═)+\s*\z/, 'and the verdict closes it');
};

subtest 'commits that change nothing on the director' => sub {
	my @embeds = map {
		[control => "Embed genesis 3.2.0-rc.$_+pipeline.".substr("a1b2c3d4e5f6a7b8", $_, 8)." in qa",
			env_file('the-deployed-version', "build $_")]
	} 1 .. 4;
	my $h = repository(then => [@embeds,
		[hand => 'Embed genesis 3.2.0-rc.9+pipeline.0badc0de in qa', 'qa-notes.txt', "a hand edit\n"]]);
	my ($all, $exit) = report($h);
	is($exit, 0, 'it succeeds') or diag($all);
	layout_ok($all, 'the last deploy');
	my $summary = summary_of($all);
	like($summary, qr/5 commits pending/, 'five commits');
	like($summary, qr/Deploying it changes nothing on the director: .*The deploy only records the newer commit\./s,
		'which change nothing on the director');
	like($all, qr/rc\.1\+pipeline\.1b2c3d4e in qa"/, 'the first of the run');
	like($all, qr/\.\.\. 2 more "Embed genesis … in qa" commits, \w{3} \d\d \d\d:\d\d to \w{3} \d\d \d\d:\d\d \.\.\./,
		'the middle two folded');
	like($all, qr/rc\.4\+pipeline\.c3d4e5f6 in qa"/, 'the last of the run');
	unlike($all, qr/rc\.2\+pipeline/, 'and the folded ones not listed');
	like($all, qr/manual commit .*\n.*rc\.9\+pipeline\.0badc0de in qa"/,
		"another author's like commit, not folded in");
	like($all, qr/══ Nothing to deploy changes on the director for qa (?:═)+\s*\z/, 'and the verdict closes it');

	($all, $exit) = report($h, '--verbose');
	is($exit, 0, 'the verbose run succeeds') or diag($all);
	like($all, qr/rc\.$_\+pipeline/, "--verbose lists the run's commit $_") for 2, 3;
	unlike($all, qr/more "Embed genesis/, 'and folds nothing');
	like($all, qr/^\s+qa\.yml\s*$/m, 'and names each commit\'s files');
};

# Proves T446's command half: --summary-file writes the summary's paragraphs,
# and nothing else, which is what the notify job's Slack message sends.
subtest 'the summary written to a file' => sub {
	my $h = repository(then => [[control => 'the coming content', env_file('the-coming-version')]]);
	my $tmp  = File::Temp->newdir();
	my $file = "$tmp/summary.txt";
	my ($all, $exit) = report($h, '--summary-file', $file);
	is($exit, 0, 'it succeeds') or diag($all);
	ok(-f $file, 'the file is written') or return;
	my $text = helper::get_file($file);
	(my $framed = summary_of($all)) =~ s/^  //mg;
	$framed =~ s/\A\n|\s+\z//g;
	is($text, "$framed\n", "it holds the frame's paragraphs, plain");
	unlike($text, qr/══|──|#[A-Za-z]\{|\e\[/, 'with no frame, markup or colour');
	like($text, qr/\A1 commit pending.*\n\n.*\n\nDeploying it changes the manifest\.\n\z/s,
		'one paragraph per point, a blank line between');
};

subtest 'a marker whose control commit this clone lacks' => sub {
	require Genesis::Env::PendingChanges;
	require Genesis::CI::Marker;
	my $tmp = File::Temp->newdir();
	my $dir = "$tmp";
	run({dir => $dir, onfailure => 'git init'}, 'git', 'init', '-q');
	run({dir => $dir}, 'git', '-c', 'user.name=Robot', '-c', 'user.email=r@example', 'commit', '-q',
		'--allow-empty', '-m', Genesis::CI::Marker::build('0123456789abcdef0123456789abcdef01234567', 'qa'));
	my ($sha) = run({dir => $dir}, 'git', 'rev-parse', 'HEAD');
	chomp $sha;
	my $git = bless {root => $dir}, 'T445::Git';
	my ($message) = run({dir => $dir}, 'git', 'log', '-1', '--format=%B', $sha);
	my $e = Genesis::Env::PendingChanges::_entry($git, {sha => $sha, message => $message}, []);
	is($e->{kind}, 'propagated', 'it is still a delivery');
	is($e->{control}, '0123456789abcdef0123456789abcdef01234567', 'naming the control commit');
	like($e->{subject}, qr/^\[pipeline\] control\@0123/, 'with the marker line as its subject');
	is($e->{author}, 'Robot', "and the delivery's own author");
	ok($e->{unread}, 'marked as read from the marker');
};

package T445::Git;
sub root       {$_[0]{root}}
sub unprefixed {shift; @_}
sub commit_files {()}

package main;
done_testing;
