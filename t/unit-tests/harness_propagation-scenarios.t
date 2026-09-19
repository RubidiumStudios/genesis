#!/usr/bin/env perl
# Proves the composing half of T2: each named scenario leaves the state its
# name says, and a row that wants something else passes options through.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Service::Github;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'ready_envs does the five things a walking row needs' => sub {
	plan tests => 4;

	my $h = make_harness(envs => ['lab', 'qa']);
	ready_envs($h);

	ok(remote_sha($h, $h->slug('lab')), 'lab has its branch on R');
	ok(remote_sha($h, $h->slug('qa')), 'and so does qa');
	ok(record_at($h, $h->applied_path), 'the applied record is written');
	ok(record_at($h, $h->env_path('lab')), "and lab's certified commit");
};

subtest 'the named shapes each add the one thing their name says' => sub {
	plan tests => 5;

	my $ready = ready_harness();
	ok(record_at($ready, $ready->applied_path), 'ready_harness is walked');

	my $seeded = seeded_harness();
	isnt(harness_marker($seeded, $seeded->slug('qa')), undef,
		'seeded_harness carries a delivery');

	my $due = due_harness();
	isnt(tip_of($due, $due->control), harness_marker($due, $due->slug('qa')),
		'due_harness leaves a control commit undelivered');

	my $held = held_harness();
	ok(record_at($held, $held->env_path('prod') . '/hold'),
		'held_harness carries the hold record');

	my $pr = ready();
	ok($pr->{gh}, 'ready stands the GitHub double up for PR mode');
};

# Proves the reconciling half of T2: each scenario answers in the shape its
# callers use it in, which is a narrowed delivery set, a list of control
# commits in list context and the harness alone in scalar context, and the
# three shapes whose arguments the step files fixed.
subtest 'a scenario can be narrowed to some environments' => sub {
	plan tests => 4;

	my $full = ready_harness();
	isnt(harness_marker($full, $full->slug('qa')), undef,
		'everything is delivered by default');

	my $narrow = ready_harness(delivered => [], certified => ['lab']);
	is(harness_marker($narrow, $narrow->slug('qa')), undef,
		'nothing delivered leaves qa at its init commit');
	ok(record_at($narrow, $narrow->env_path('lab')),
		'lab is certified');
	is(record_at($narrow, $narrow->env_path('qa')), undef,
		'and qa is not');
};

subtest 'the two scenarios that carry commits answer in both contexts' => sub {
	plan tests => 9;

	my ($gated, @shas) = gated_harness();
	is(scalar(@shas), 4, 'gated_harness lays four control commits');
	is(trailers_of($gated, $shas[2])->{'Genesis-Stage'}, 'prod',
		'and the third of them carries the gate');
	is_deeply(trailers_of($gated, $shas[0]), {},
		'while a commit carrying none reads back empty');
	# The file each commit writes is the first environment's own, because a
	# commit whose content is in no environment's propagation set routes
	# nowhere and every row standing on this shape asks the walk to route all
	# four of them.
	like(files_at($gated, $shas[3])->{'qa.yml'}, qr/n: 4/,
		'and each of them writes the first environment\'s own file');
	# The option is read here and nowhere below, because the delivery the
	# shape seeds itself with takes a files option of its own.
	my ($named, @custom) = gated_harness(
		files => [map {+{"ops/change-$_.yml" => "---\nn: $_\n"}} 1 .. 4]);
	like(files_at($named, $custom[0])->{'ops/change-1.yml'}, qr/n: 1/,
		'while the files option names what they write instead');

	my $alone = gated_harness();
	isa_ok($alone, 'Harness::Propagation',
		'scalar context answers the harness alone');

	my ($due, @due) = due_harness();
	is(scalar(@due), 2, 'due_harness stands two commits up');
	like(files_at($due, $due[1])->{'qa.yml'}, qr/n: 2/,
		'and its commits write that file too');
	isa_ok(scalar(due_harness()), 'Harness::Propagation',
		'and answers the harness alone in scalar context');
};

subtest 'the three shapes whose arguments the step files fixed' => sub {
	plan tests => 11;

	my $unseeded = staged(envs => ['lab']);
	ok(remote_sha($unseeded, $unseeded->slug('lab')),
		'staged cuts the init branch');
	is(harness_marker($unseeded, $unseeded->slug('lab')), undef,
		'and delivers nothing onto it');
	is(record_at($unseeded, $unseeded->env_path('lab')), undef,
		'and certifies nothing either');

	my $prod = held_prod();
	ok(record_at($prod, $prod->applied_path),
		'held_prod writes the applied record');
	ok(remote_sha($prod, $prod->slug('prod')), 'and cuts prod');
	is(record_at($prod, $prod->env_path('prod') . '/hold'), undef,
		'and writes no hold of its own, which the rows write themselves');

	my ($pr_h, $gh, $pr, $control) = with_open_pr();
	ok($pr, 'with_open_pr answers the pull request number');
	is(record_at($pr_h, $pr_h->env_path('qa') . '/proposed')->{number}, $pr,
		'and the proposed record names it');
	like(files_at($pr_h, $control)->{'qa.yml'}, qr/^  instances: 2$/m,
		'the control commit it answers is the one the due file landed on');
	like(files_at($pr_h, $control)->{'qa.yml'}, qr/^    require_pr: true$/m,
		'and that file still carries the metadata the topology reads');

	# The double is read through the client the product uses, because a row
	# that read the state file would prove the fixture rather than what an
	# open pull request looks like from the outside.
	local $ENV{PATH} = join ':', $gh->{bin}, $ENV{PATH};
	local $ENV{GITHUB_AUTH_TOKEN} = $gh->{token};
	my $open = Service::Github->new(domain => $gh->{domain}, tls => 'no')
		->list_prs($gh->{repository}, state => 'open');
	is_deeply([map {$_->{number}} @$open], [$pr],
		'and that pull request is the one standing open on the double');
};

subtest 'a row that wants something else passes options through' => sub {
	plan tests => 2;

	my $h = ready_harness(envs => ['lab', 'qa', 'prod'], type => 'vault');
	is($h->type, 'vault', 'the type reached make_harness');
	ok(remote_sha($h, $h->slug('prod')),
		'and the third environment has its branch');
};

subtest 'the second deployment root is delivered under its own prefix' => sub {
	plan tests => 3;

	my $h = two_roots();
	my $second = files_at($h, $h->slug('lab', type => 'vault'));
	ok(exists $second->{'vault/lab.yml'},
		"the second root's branch holds its own environment file");
	ok(!exists $second->{'lab.yml'},
		"and not the first root's");
	ok(exists files_at($h, $h->slug('lab'))->{'lab.yml'},
		"while the first root's branch holds its own");
};

subtest 'the scenarios that write on control publish it' => sub {
	plan tests => 4;

	my $t = tracked_harness(qw/lab ops/);
	is(remote_sha($t, $t->control), tip_of($t, $t->control),
		'tracked_harness leaves control on R where copy A stands');
	like(slurp($t->a . '/qa.yml'), qr{lab/bosh},
		'and qa names the prerequisite it tracks');

	my $i = inherited_harness();
	is(remote_sha($i, $i->control), tip_of($i, $i->control),
		'inherited_harness leaves control on R where copy A stands');
	like(slurp($i->a . '/site.yml'), qr/manual_gate/,
		'and the pipeline keys sit on the site file');
};

subtest 'the pair, and one delivery per environment in one line' => sub {
	plan tests => 4;

	my $two = two_env_harness();
	isnt(harness_marker($two, $two->slug('lab')), undef,
		'two_env_harness delivers lab');
	isnt(harness_marker($two, $two->slug('qa')), undef, 'and qa');

	my $bare = ready_harness(delivered => []);
	is(harness_marker($bare, $bare->slug('qa')), undef,
		'a harness asked for no delivery has none');
	isnt(harness_marker($bare->deliver_all, $bare->slug('qa')), undef,
		'and deliver_all gives every environment one');
};

subtest 'the one-line shapes that stand on a scenario' => sub {
	plan tests => 10;

	my $h = ready_harness();
	is(a_delivery($h, 'qa'), remote_sha($h, $h->slug('qa')),
		'a_delivery publishes the delivery it wrote');

	my ($s, $control, $delivered) = seeded();
	is(harness_marker($s, $s->slug('qa')), $control,
		"seeded's branch marker names the control commit it answers");
	is($delivered, remote_sha($s, $s->slug('qa')),
		'and the delivered sha it answers is the branch tip');

	my $due = ready_harness(envs => ['qa']);
	my $taken = harness_marker($due, $due->slug('qa'));
	my @two = two_due($due);
	is(scalar(@two), 2, 'two_due lays two control commits');
	is(harness_marker($due, $due->slug('qa')), $taken,
		'and the branch has taken neither');

	my $pair = ready_harness(envs => ['lab', 'qa']);
	my @named = two_due($pair, env => 'qa');
	ok(files_at($pair, $named[-1])->{'qa.yml'},
		'two_due writes the environment named rather than the first');

	is(scalar(my @three = three_due(ready_harness(envs => ['qa']))), 3,
		'three_due lays three');
	is(scalar(my @same = three(ready_harness(envs => ['qa']))), 3,
		'and three lays the same, because it is the same sub');

	my @chain = chain($h);
	is(scalar(@chain), 2, 'chain writes one control commit per environment');
	like(files_at($h, $chain[-1])->{'qa.yml'}, qr/kit: \{name: dev\}/,
		'chain touches one environment per commit, in order');
};

subtest 'the shapes that write a record or a configuration' => sub {
	plan tests => 4;

	my $h = ready_harness(envs => ['qa']);
	my ($body) = run({dir => $h->a}, 'git', 'log', '-1', '--format=%B',
		gated($h, files => {'gate.yml' => "---\ng: 1\n"}));
	like($body, qr/Genesis-Stage: prod/, 'gated puts the stage on its commit');

	proposed($h, 'qa', pr => 7);
	is(record_at($h, $h->env_path('qa') . '/proposed')->{number}, 7,
		'proposed writes the record naming the pull request');

	like(slurp(automated($h)->a . '/.genesis/config'), qr/concourse/,
		'automated names the provider the repository runs under');

	isa_ok(top_for(make_harness(envs => ['qa'], vault => 0)), 'Genesis::Top',
		'the Top top_for answers');
};

subtest 'top_for can replace the whole configuration first' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0, pipeline => 1);
	like(slurp($h->a . '/.genesis/config'), qr/pipeline/,
		'the repository starts with a pipeline section');

	top_for($h, config => {version => 2, deployment_type => 'bosh',
		creator_version => '3.2.0'});
	unlike(slurp($h->a . '/.genesis/config'), qr/pipeline/,
		'and the config option writes the whole file over it');
};

subtest 'a configuration can be loaded through one pipeline block' => sub {
	plan tests => 3;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $top = load_with($h, automated_config('concourse', 'target: ci'));
	is($top->config->get('pipeline.provider.type'), 'concourse',
		'the block reaches the Top the load returns');
	is($top->config->get('pipeline.source_control.identity.name'),
		'Genesis CI', 'the committer identity comes with it');

	my $again = load_with($h, automated_config('github-actions'));
	is($again->config->get('pipeline.provider.type'), 'github-actions',
		'and a second load of a second block still has a delta to commit');
};

subtest 'the automation blocks answer in both forms' => sub {
	plan tests => 4;

	my %blocks = automation_blocks();
	is_deeply([sort keys %blocks], ['locker', 'shuttle', 'vault'],
		'the hash form names the three blocks the schema requires');
	is($blocks{shuttle}{backend}, 's3', 'and carries a backend for the shuttle');

	my @lines = automation_block_lines();
	is_deeply(\@lines, ['  shuttle:', '    backend: s3', '    bucket: pipes',
		'  vault:', '    url: https://vault.example.com',
		'  locker:', '    url: https://locker.example.com'],
		'the line form says the same thing, ready to sit under a pipeline key');

	is_deeply([automation_block_lines(without => ['vault'])],
		['  shuttle:', '    backend: s3', '    bucket: pipes',
		 '  locker:', '    url: https://locker.example.com'],
		'and a named block can be left out, for a row about what is missing');
};

subtest 'the shuttle shape writes the backend block a row hands it' => sub {
	plan tests => 3;

	# The part of an automated block that does not change between the two
	# rows below, written once so each row says only what its backend
	# changes.
	my @preamble = ('pipeline:', '  enabled: true',
		'  source_control:',
		'    repository: genesis/bosh-deployments',
		'    auth:', '      type: ssh', '      vault: secret/ci/git',
		'    identity:', '      name: Genesis CI',
		'      email: ci@genesis.example.com',
		'  provider:', '    type: concourse', '    target: ci');
	my @rest = ('  vault:', '    url: https://vault.example.com',
		'  locker:', '    url: https://locker.example.com');

	is_deeply([split(/\n/, shuttle('gcs', 'bucket: sig'))],
		[@preamble, '  shuttle:', '    backend: gcs', '    bucket: sig',
		 @rest],
		'the backend and the given lines sit under the shuttle key');

	is_deeply([split(/\n/, shuttle('s3', 'bucket: sig', 'region: us-east-1',
		'endpoint: https://minio.internal'))],
		[@preamble, '  shuttle:', '    backend: s3', '    bucket: sig',
		 '    region: us-east-1', '    endpoint: https://minio.internal',
		 @rest],
		'and every line a row hands over keeps the order it was given in');

	# The one block this builder leaves out of the three is the shuttle,
	# which is the whole reason it exists, so a row's own block is the only
	# one the answer carries.
	is(scalar(grep {$_ eq '  shuttle:'}
			split(/\n/, shuttle('gcs', 'bucket: sig'))),
		1, 'the defaulted shuttle is left out, so only the written one is there');
};

subtest 'the automated shape carries what an automation requires' => sub {
	plan tests => 6;

	my $h = make_harness(envs => ['qa'], vault => 0);
	automated($h);

	my ($config) = load_yaml_file($h->a . '/.genesis/config');
	is($config->{pipeline}{provider}{type}, 'concourse',
		'the provider is an automated one');
	is($config->{pipeline}{source_control}{auth}{vault}, 'secret/ci/git',
		'the clone credential is seeded beside it');
	is($config->{pipeline}{source_control}{identity}{email},
		'ci@genesis.example.com', 'and so is the committer identity');
	is($config->{pipeline}{shuttle}{backend}, 's3',
		'along with the three blocks the schema requires of an automation');

	# Whether the second call has a delta to commit is not something the row
	# can settle, because the configuration writer stamps the time of the
	# write into the file and that turns over with the wall clock.  What the
	# row can drive is that a repository already carrying the shape can be
	# asked for it again and still reads back complete.
	ok(eval {automated($h); 1},
		'asking for the shape a second time answers rather than dying');

	my ($again) = load_yaml_file($h->a . '/.genesis/config');
	is($again->{pipeline}{provider}{type}, 'concourse',
		'and the repository still carries the shape afterwards');
};

done_testing;
