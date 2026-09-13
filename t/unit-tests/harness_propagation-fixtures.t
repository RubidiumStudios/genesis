#!/usr/bin/env perl
# Proves T2: the harness cuts each environment on R as the init branch the
# apply would leave, a second deployment root sharing an environment name can
# be built beside the first, and the vault fixture answers a read at the two
# addresses the design fixes.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the harness cuts the init branch on R' => sub {
	plan tests => 6;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $before = run({dir => $h->a}, 'git', 'rev-parse', '--abbrev-ref', 'HEAD');
	chomp $before;

	my $init = init_branch($h, 'qa');

	my ($sha) = run({dir => $h->r}, 'git', 'rev-parse', 'qa/bosh');
	chomp $sha;
	is($sha, $init, 'R carries qa/bosh at the init commit');

	is_deeply(tree_of($h->r, 'qa/bosh'), ['init'],
		'the init branch holds the init file alone');

	my ($subject) = run({dir => $h->r}, 'git', 'log', '-1', '--format=%s', 'qa/bosh');
	chomp $subject;
	is($subject, 'Initialize qa/bosh branch [ci skip]',
		'the init commit carries the subject the apply writes');

	my ($parents) = run({dir => $h->r}, 'git', 'log', '-1', '--format=%P', 'qa/bosh');
	chomp $parents;
	is($parents, '', 'the init commit is an orphan root');

	my $unrelated = run({dir => $h->r, passfail => 1},
		'git', 'merge-base', '--is-ancestor', $h->control, 'qa/bosh');
	ok(!$unrelated, 'it shares no history with control');

	my $after = run({dir => $h->a}, 'git', 'rev-parse', '--abbrev-ref', 'HEAD');
	chomp $after;
	is($after, $before, 'nothing was checked out in copy A');
};

subtest 'a delivery mirrors the set and carries the marker' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');

	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	my $delivered = deliver($h, 'qa', control => $control);

	my ($subject) = run({dir => $h->r}, 'git', 'log', '-1', '--format=%s', 'qa/bosh');
	chomp $subject;
	is($subject, sprintf('[pipeline] control@%s -> qa', substr($control, 0, 12)),
		'the delivery carries the marker naming its control commit');

	is(harness_marker($h, 'qa/bosh'), $control,
		"the harness's own marker read resolves the control commit");

	my $files = tree_of($h->r, $delivered);
	ok(!(grep {$_ eq 'init'} @$files), 'the delivery removed the init file');
};

subtest 'a second deployment root shares an environment name' => sub {
	plan tests => 7;

	my $h = make_harness(envs => ['lmelt-vsphere-canwest-1-mgmt'], vault => 0);
	my $root = add_deployment_root($h, type => 'vault',
		envs => ['lmelt-vsphere-canwest-1-mgmt']);

	is($root, 'vault', 'the second root answers its repository-relative path');
	ok(-f $h->a."/vault/.genesis/config",
		'the second root carries a configuration the real code path wrote');
	ok(scalar(grep {$_ eq 'vault/lmelt-vsphere-canwest-1-mgmt.yml'}
		@{tree_of($h->a, $h->control)}),
		"control's tree carries the second root's environment file");

	init_branch($h, 'lmelt-vsphere-canwest-1-mgmt');
	init_branch($h, 'lmelt-vsphere-canwest-1-mgmt', type => 'vault');

	is($h->slug('lmelt-vsphere-canwest-1-mgmt'),
		'lmelt-vsphere-canwest-1-mgmt/bosh', 'the bosh root names its own slug');
	is($h->slug('lmelt-vsphere-canwest-1-mgmt', type => 'vault'),
		'lmelt-vsphere-canwest-1-mgmt/vault', 'the vault root names its own slug');

	for my $branch (qw(lmelt-vsphere-canwest-1-mgmt/bosh
	                   lmelt-vsphere-canwest-1-mgmt/vault)) {
		my $ok = run({dir => $h->r, passfail => 1},
			'git', 'show-ref', '--verify', '--quiet', "refs/heads/$branch");
		ok($ok, "R carries $branch");
	}
};

subtest "the set is the harness's own read and a delivery mirrors it" => sub {
	plan tests => 6;

	my $h = make_harness(envs => ['qa'], vault => 0);
	init_branch($h, 'qa');

	my $path = write_env_file($h, 'qa-lab', commit => 1);
	is($path, 'qa-lab.yml', 'the writer answers the git-root-relative path');
	ok(scalar(grep {$_ eq $path} @{tree_of($h->a, $h->control)}),
		"control's tree carries the file the writer committed");

	my $control = commit_on_control($h,
		files   => {'notes.md' => "not part of the set\n"},
		message => 'add a note',
		push    => 1,
	);

	my @set = propagation_set($h, 'qa', at => $control);
	is(scalar @set, scalar(grep {!ref} @set),
		'the set comes back as a plain list of paths and not an arrayref');
	ok(scalar(grep {$_ eq $path} @set),
		'the set holds the environment file the writer added');
	is_deeply([grep {$_ eq 'notes.md'} @set], [],
		'the set leaves a file outside it where it stands');

	my $delivered = deliver($h, 'qa', control => $control);
	is_deeply(tree_of($h->r, $delivered), [sort @set],
		'the delivered tree is the set and nothing besides');
};

# Proves T2, the vault half: the fixture answers a read of the certified
# commit and of the applied record at the two addresses D103 fixes.
subtest 'the fixture answers the two vault addresses' => sub {
	plan tests => 8;

	my $h = make_harness(envs => ['qa']);
	init_branch($h, 'qa');

	my $control = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
		push    => 1,
	);
	my $delivered = deliver($h, 'qa', control => $control);

	is($h->applied_path, '/secret/exodus/_pipelines/bosh',
		'the applied record sits where D103 puts it');
	is($h->env_path('qa'), '/secret/exodus/qa/bosh',
		"the environment's own record sits beside it");

	fixture_applied($h, control => $control, provider => 'manual');
	have_secret($h->applied_path . ':control_commit');
	is(secret($h->applied_path . ':control_commit'), $control,
		'the applied record names the control commit it applied from');
	like(secret($h->applied_path . ':at'),
		qr/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [-+]\d{4}$/,
		'applied.at is in EXODUS_TIME_FORMAT');

	certify($h, 'qa', commit => $delivered, control_commit => $control);
	is(secret($h->env_path('qa') . ':git.commit'), $delivered,
		'the deploy record names the deployed commit');
	is(secret($h->env_path('qa') . ':git.control_commit'), $control,
		'the deploy record names the certified commit');

	fixture_pipeline_record($h, 'qa',
		dependencies => ['lab/bosh'], discovery => 'complete');
	is(secret($h->env_path('qa') . '/pipeline:discovery'), 'complete',
		"the environment's compiled pipeline facts sit under a pipeline subpath");
};

subtest 'a broken read refuses rather than answering stale' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['qa']);
	no_secret($h->env_path('qa') . ':git.commit',
		'a fresh harness starts on an empty exodus mount');

	certify($h, 'qa', commit => 'deadbeef', control_commit => 'cafebabe');
	have_secret($h->env_path('qa') . ':git.commit');

	break_vault($h, envs => ['qa']);
	no_secret($h->env_path('qa') . ':git.commit');

	restore_vault($h);
	have_secret($h->env_path('qa') . ':git.commit',
		'the restore puts the broken record back');
};

subtest 'break_vault takes the environments and the applied record apart' => sub {
	plan tests => 8;

	my $h = make_harness(envs => ['qa', 'lab']);
	certify($h, $_, commit => 'deadbeef', control_commit => 'cafebabe')
		for qw/qa lab/;
	fixture_applied($h, control => 'cafebabe');

	break_vault($h);
	no_secret($h->env_path('qa') . ':git.commit',
		'a break naming no environments takes qa');
	no_secret($h->env_path('lab') . ':git.commit',
		'and takes lab along with it');
	have_secret($h->applied_path . ':control_commit',
		'and leaves the applied record where it stands');

	restore_vault($h);
	have_secret($h->env_path('qa') . ':git.commit',
		'the restore puts qa back');
	have_secret($h->env_path('lab') . ':git.commit',
		'and puts lab back');

	break_vault($h, envs => [], applied => 1);
	no_secret($h->applied_path . ':control_commit',
		'an empty environment list with applied takes the applied record');
	have_secret($h->env_path('qa') . ':git.commit',
		'and leaves every environment readable');

	restore_vault($h);
	have_secret($h->applied_path . ':control_commit',
		'the restore puts the applied record back');
};

subtest 'a harness with no vault refuses to break one' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);

	eval {break_vault($h); 1};
	like($@, qr/^break_vault needs a vault fixture, and this harness has none$/m,
		'the break refuses rather than moving records in the ambient vault');

	eval {restore_vault($h); 1};
	like($@, qr/^restore_vault needs a vault fixture, and this harness has none$/m,
		'and so does the restore');
};

done_testing;
