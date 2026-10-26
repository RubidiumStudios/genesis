#!/usr/bin/env perl
# Proves T421: `genesis <env> pending-changes` answers what deploying the
# environment's branch would change, and changes nothing (D123).  It lists the
# commits since the deployed one, propagated or manual, diffs the manifest
# against the director and the exodus copy, lists the director configs that
# moved since the deployment last ran, and the releases and stemcells the
# deploy would upload, never in clear for a vault value, and without one bosh
# command that writes.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $SECRET = 'hunter2-never-in-clear';

sub env_file {
	my ($marker) = @_;
	return <<"YAML";
---
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

# The blueprint names one release and one stemcell, carries the marker, and
# takes one value from the vault, so every section has something to say.
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

# What an entombed deploy names the harness's one vault value by, which is
# what the director and exodus hold for it.
sub entombed_ref {
	my ($value) = @_;
	require Genesis::Env::Secrets::Entombment;
	return '(('.Genesis::Env::Secrets::Entombment::credhub_var_name(
		'_/secret/harness/pending', 'password', $value, 'genesis-entombed/').'))';
}

sub deployed_manifest {
	my ($marker, $password) = @_;
	$password = entombed_ref($password);
	return "---\nname: qa-bosh\nharness: $marker\npassword: \"$password\"\n".
		"releases:\n- name: harness\n  version: 1.2.3\n  url: https://releases.example/harness-1.2.3.tgz\n".
		"stemcells:\n- alias: default\n  os: ubuntu-jammy\n  version: \"1.1\"\n";
}

# A qa deployed at the first control commit, with a second delivered since
# and one hand commit on top, against a director whose configs moved.
sub pending_harness {
	my (%opts) = @_;
	my $h = make_harness(envs => ['qa'], type => 'bosh');
	$h->_write_record('secret/harness/pending', password => $SECRET);

	my $first = commit_on_control($h, files => {'qa.yml' => env_file('the-deployed-version')},
		message => 'the deployed content', push => 1);
	init_branch($h, 'qa');
	my $deployed = deliver($h, 'qa', control => $first);
	my %c = (first => $first, deployed => $deployed);
	unless ($opts{never_deployed}) {
		certify($h, 'qa', commit => $deployed, control_commit => $first,
			artifacts => {'qa.yml' => deployed_manifest('the-deployed-version', $SECRET)});
	}
	$c{second} = commit_on_control($h, files => {'qa.yml' => env_file('the-coming-version')},
		message => 'the coming content', push => 1);
	deliver($h, 'qa', control => $c{second});
	hand_commit($h, $h->slug('qa'), files => {'qa-notes.txt' => "a hand edit\n"},
		message => 'a hand edit on the branch');
	refresh($h, 'a');

	fixture_bosh($h, hooks => {blueprint => $BLUEPRINT});
	# A deployment never deployed is on no director either.
	bosh_answer($h, manifest => $opts{never_deployed} ? '' : $opts{director_manifest}
		// deployed_manifest('the-deployed-version', $SECRET));
	bosh_answer($h, '/deployment_configs?deployment=qa-bosh' => $opts{never_deployed} ? '[]' :
		'[{"config":{"id":"1","type":"cloud","name":"default"}}]');
	bosh_answer($h, '/configs?latest=true' =>
		'[{"id":"2","type":"cloud","name":"default","content":"azs: [{name: z2}]\n"},'.
		' {"id":"5","type":"runtime","name":"dns","content":"addons: []\n"}]');
	bosh_answer($h, '/configs/1' =>
		'{"id":"1","type":"cloud","name":"default","content":"azs: [{name: z1}]\n"}');

	stand_on($h, $h->control);
	return ($h, \%c);
}

my @WRITES = qw/deploy upload-release upload-stemcell update-config update-cloud-config
	update-runtime-config update-cpi-config delete-config/;

subtest 'T421: what deploying the branch would change, read-only' => sub {
	my ($h, $c) = pending_harness();
	my $before = snapshot_w($h);
	my ($out, $err, $exit) = run_genesis($h, {restore => 0}, 'qa', 'pending-changes');
	my $all = "$out$err";
	is($exit, 0, 'it succeeds with changes pending') or diag($all);

	my @order = map {index($all, $_)} ('Commits since', 'Manifest', 'BOSH configs', 'Uploads');
	ok(!grep({$_ < 0} @order) && "@order" eq join(' ', sort {$a <=> $b} @order),
		'the four sections, in order') or diag($all);

	like($all, qr/propagated.*\Q@{[substr($c->{second}, 0, 8)]}\E/,
		'the delivered commit, labelled propagated with its control commit');
	like($all, qr/manual.*a hand edit on the branch/, 'the hand commit, labelled manual');
	like($all, qr/qa-notes\.txt/, 'with the files it changes');
	unlike($all, qr/\Q@{[substr($c->{deployed}, 0, 8)]}\E.*the deployed content/,
		'and not the deployed commit');

	like($all, qr/director.*\n(?:.*\n)*?.*the-coming-version/, 'the manifest against the director');
	unlike($all, qr/drift/i, 'no drift where the director and exodus agree');

	like($all, qr/cloud config default.*changed on the director/,
		'a director config newer than the deployment');
	like($all, qr/runtime config dns.*new on the director/, 'and one the deployment never ran with');

	like($all, qr/release harness\/1\.2\.3/, 'the release the director lacks');
	like($all, qr/stemcell ubuntu-jammy\/1\.1/, 'and the stemcell');

	unlike($all, qr/\Q$SECRET\E/, 'a vault value never in clear');
	# Spruce heads each difference with its path on a line of its own;
	# entombing's own progress line names the reference it computed.
	unlike($all, qr/^\s*password\s*$/m, 'and an unchanged one, entombed, shows no difference');

	my %wrote = map {($_->{command} => 1)} grep {my $c = $_->{command}; grep {$_ eq $c} @WRITES} bosh_runs($h);
	is_deeply([sort keys %wrote], [], 'no bosh command that writes');
	assert_w_restored($before, 'the working state as it was');
};

subtest 'T421: a changed vault value shows as its entombed reference changing' => sub {
	my ($h) = pending_harness();
	my $rotated = 'rotated-and-never-in-clear';
	$h->_write_record('secret/harness/pending', password => $rotated);
	my ($out, $err, $exit) = run_genesis($h, 'qa', 'pending-changes');
	my $all = "$out$err";
	is($exit, 0, 'it succeeds, with no CredHub to write to') or diag($all);
	like($all, qr/\Q@{[entombed_ref($SECRET)]}\E/, "the deployed value's reference");
	like($all, qr/\Q@{[entombed_ref($rotated)]}\E/, 'and the one the deploy would send');
	unlike($all, qr/\Q$SECRET\E|\Q$rotated\E/, 'neither value in clear');
};

subtest 'T421: a director that differs from exodus is drift' => sub {
	my ($h) = pending_harness(director_manifest =>
		deployed_manifest('a-version-deployed-by-hand', $SECRET));
	my ($out, $err, $exit) = run_genesis($h, 'qa', 'pending-changes');
	is($exit, 0, 'it succeeds') or diag("$out$err");
	like("$out$err", qr/drift/i, 'the difference is reported as drift');
	unlike("$out$err", qr/\Q$SECRET\E/, 'still never in clear');
};

subtest 'T421: an environment never deployed says so' => sub {
	my ($h) = pending_harness(never_deployed => 1);
	my ($out, $err, $exit) = run_genesis($h, 'qa', 'pending-changes');
	is($exit, 0, 'it succeeds') or diag("$out$err");
	my $all = "$out$err";
	like($all, qr/never been deployed/, 'it says so');
	like($all, qr/manual.*a hand edit on the branch/, 'and lists the branch');
	like($all, qr/seed.*Initialize \S+ branch \[ci skip\]/, "the apply's seed commit labelled seed");
	unlike($all, qr/manual.*Initialize/, 'and not manual');
	like($all, qr/first deploy.*\n(?:.*\n)*?.*the-coming-version/,
		'the whole manifest, as additions against nothing deployed');
	like($all, qr/\Q@{[entombed_ref($SECRET)]}\E/, 'its vault value as the reference the deploy would send');
	unlike($all, qr/since the last deploy:/, 'and no director config said to have moved since a deploy there was none of');
	unlike($all, qr/\Q$SECRET\E/, 'never in clear');
};

done_testing;
