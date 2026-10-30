#!/usr/bin/env perl
# Proves T450, T451 and T452's command half (D129): a pipeline deploy fixes
# what Genesis can fix and refuses what only an operator can supply, and the
# preview says which first.  The kit declares one secret Genesis generates
# and one an operator provides, and the manifest uses both.
#
# What the rows catch: a deploy that skips a missing user-provided secret off
# a terminal, writes the generated ones, and fails at the render; a preview
# that fails to render rather than naming what is missing; a preview that
# reports a block and exits 0, which lets the notify job pass and the deploy
# be offered; and a failed preview that leaves the notify job's Slack message
# with nothing to say.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use File::Temp ();

use Genesis;
use Genesis::Exit;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $KIT = <<'YAML';
credentials:
  base:
    harness/generated:
      password: random 16
provided:
  base:
    harness/provided:
      keys:
        token:
          prompt: The harness token
YAML

my $BLUEPRINT =
	qq{cat > manifest.yml <<'MANIFEST'\n}.
	qq{---\n}.
	qq{name: qa-bosh\n}.
	qq{generated: (( vault "secret/qa/bosh/harness/generated:password" ))\n}.
	qq{provided: (( vault "secret/qa/bosh/harness/provided:token" ))\n}.
	qq{releases:\n- name: harness\n  version: 1.2.3\n  url: https://releases.example/harness-1.2.3.tgz\n}.
	qq{stemcells:\n- alias: default\n  os: ubuntu-jammy\n  version: "1.1"\n}.
	qq{MANIFEST\n}.
	qq{echo manifest.yml\n};

# qa delivered once and never deployed, with whichever secrets the row sets.
sub repository {
	my (%set) = @_;
	my $h = make_harness(envs => ['qa'], type => 'bosh');
	# The harness has no CredHub for a deploy to entomb into, so a row that
	# deploys turns entombing off.
	my $c = commit_on_control($h, files => {'qa.yml' => <<"YAML"}, message => 'qa', push => 1);
---
kit:
  name:     dev
  version:  latest
  features: []
genesis:
  env:      qa
@{[$set{no_entomb} ? "  entomb:   false\n" : '']}
YAML
	init_branch($h, 'qa');
	deliver($h, 'qa', control => $c);
	refresh($h, 'a');
	# The harness vault outlives each repository, so what a row does not set
	# is cleared of what an earlier row set.
	run({env => {SAFE_TARGET => $h->{vault_target}}}, 'safe', 'rm', '-f', "secret/qa/bosh/harness/$_")
		for qw/generated provided/;
	$h->_write_record('secret/qa/bosh/harness/generated', password => 'already-generated')
		if $set{generated};
	$h->_write_record('secret/qa/bosh/harness/provided', token => 'already-provided')
		if $set{provided};

	fixture_bosh($h, hooks => {blueprint => $BLUEPRINT}, metadata => $KIT);
	bosh_answer($h, manifest => '');
	bosh_answer($h, '/deployment_configs?deployment=qa-bosh' => '[]');
	bosh_answer($h, '/configs?latest=true' => '[]');
	# The director holds the release and stemcell, so -F has no stemcell to
	# fix and the rows are about secrets alone.
	bosh_answer($h, releases =>
		'{"Tables":[{"Rows":[{"name":"harness","version":"1.2.3*"}]}]}');
	bosh_answer($h, stemcells =>
		'{"Tables":[{"Rows":[{"name":"bosh-harness","os":"ubuntu-jammy","version":"1.1*","cpi":""}]}]}');
	stand_on($h, $h->control);
	return $h;
}

sub vault_has {
	my ($h, $path) = @_;
	my ($out, $rc) = run({env => {SAFE_TARGET => $h->{vault_target}}}, 'safe', 'exists', $path);
	return $rc == 0;
}

sub preview {
	my ($h, @flags) = @_;
	my ($out, $err, $exit) = run_genesis($h, 'qa', 'pending-changes', @flags);
	return ("$out$err", $exit);
}

subtest 'T451: a secret the deploy would generate' => sub {
	my $h = repository(provided => 1);
	my ($all, $exit) = preview($h);
	is($exit, 0, 'the preview succeeds') or diag($all);
	like($all, qr/\nSecrets\n(?:.*\n)*?.*would generate.*harness\/generated:password/,
		'its Secrets section names the secret the deploy would generate') or diag($all);
	like($all, qr/Summary:.*\n(?:.*\n)*?.*generates 1 missing secret/,
		'the summary counts it') or diag($all);
	like($all, qr/<generated on deploy>/, 'the manifest renders with a placeholder in its place')
		or diag($all);
	ok(!vault_has($h, 'secret/qa/bosh/harness/generated:password'), 'and nothing was written');
};

subtest 'T451: a user-provided secret blocks the deploy' => sub {
	my $h = repository();
	my $tmp = File::Temp->newdir();
	my ($all, $exit) = preview($h, '--summary-file', "$tmp/summary.txt");
	is($exit, Genesis::Exit::CONFIG, 'the preview exits CONFIG') or diag($all);
	like($all, qr/\nSecrets\n(?:.*\n)*?.*must be provided.*harness\/provided:token.*The harness token/,
		'naming the user-provided secret and its prompt') or diag($all);
	like($all, qr/Deploying it is blocked: 1 user-provided secret must be set first/,
		'the verdict is blocked') or diag($all);
	like($all, qr/══ Deploying qa is blocked/, 'and so is the closing frame') or diag($all);
	like(-f "$tmp/summary.txt" ? helper::get_file("$tmp/summary.txt") : '', qr/blocked: 1 user-provided secret must be set first/,
		'the summary file says so');
	ok(!vault_has($h, 'secret/qa/bosh/harness/generated:password'), 'and nothing was written');
};

subtest 'T451: nothing missing' => sub {
	my $h = repository(generated => 1, provided => 1);
	my ($all, $exit) = preview($h);
	is($exit, 0, 'the preview succeeds') or diag($all);
	like($all, qr/\nSecrets\n\s+none\n/, 'its Secrets section says none') or diag($all);
};

subtest 'T450: -F refuses a missing user-provided secret before writing' => sub {
	my $h = repository();
	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'qa', 'deploy', '-F', '-y');
	my $all = "$out$err";
	is($exit, Genesis::Exit::CONFIG, 'the deploy exits CONFIG') or diag($all);
	like($all, qr/harness\/provided:token/, 'naming the user-provided secret') or diag($all);
	like($all, qr/The harness token/, 'its prompt');
	like($all, qr/add-secrets/, 'and how to set it');
	ok(!vault_has($h, 'secret/qa/bosh/harness/generated:password'),
		'the generated secret was not written');
	is(scalar(bosh_runs($h, command => 'deploy')), 0, 'and BOSH was never asked to deploy');
};

subtest 'T450: -F generates what Genesis can' => sub {
	my $h = repository(provided => 1, no_entomb => 1);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'qa', 'deploy', '-F', '-y');
	my $all = "$out$err";
	ok(vault_has($h, 'secret/qa/bosh/harness/generated:password'), 'the missing secret is generated')
		or diag($all);
	is(scalar(bosh_runs($h, command => 'deploy')), 1, 'and the deploy reaches BOSH') or diag($all);
};

subtest 'T452: a failed preview still writes why' => sub {
	my $h = repository(generated => 1, provided => 1);
	fixture_bosh($h, hooks => {blueprint => "echo 'the blueprint cannot be read' >&2\nexit 1\n"},
		metadata => $KIT);
	my $tmp = File::Temp->newdir();
	my ($all, $exit) = preview($h, '--summary-file', "$tmp/summary.txt");
	isnt($exit, 0, 'the preview fails') or diag($all);
	my $text = -f "$tmp/summary.txt" ? helper::get_file("$tmp/summary.txt") : '';
	like($text, qr/^The changes could not be determined: /, 'the summary file says it could not determine them')
		or diag($all);
	unlike($text, qr/\e\[|#[A-Za-z]\{/, 'plain');
};

done_testing;
