#!perl
use strict;
use warnings;

# The bosh-configs actions, driven against a mocked environment and
# director.  The kit hooks are stubbed through the env mock's run_hook, so
# these tests cover the command's own logic: which configs count as the
# environment's, how they are compared with the director's copies, what
# each action prints, and what each action changes on the director.

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;
use Test::Output;
use JSON::PP;

use Genesis;
use Genesis::Commands::Bosh;

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

my @director_calls; # what the actions asked the director (and its vault) to do
my @hook_calls;     # what the actions asked the kit hooks to do

my $vault = mock "Mock::BoshConfigs::Vault" => {
	set_path => sub {
		my ($self, @args) = @_;
		push @director_calls, ['set_path', @args];
		return 1;
	},
};

# make_director - a director mock over a `bosh configs` style listing
# ($configs is type => name => {current, entries}) and a map of
# "type|name" => content for get_config.
my $director_seq = 0;
sub make_director {
	my ($alias, $configs, %overrides) = @_;
	my $contents = delete($overrides{contents}) // {};
	my $locked = 0; # the network claims lock, held by this process once acquired
	$director_seq++;
	return mock "Mock::BoshConfigs::Director$director_seq" => {
		alias   => $alias,
		configs => sub { return $configs },
		has_config => sub {
			my ($self, $type, $name) = @_;
			return (exists($configs->{$type}{$name}) && defined($configs->{$type}{$name}{current})) ? 1 : 0;
		},
		get_config => sub {
			my ($self, $type, $name) = @_;
			return $contents->{"$type|$name"};
		},
		delete_config => sub {
			my ($self, @args) = @_;
			push @director_calls, ['delete_config', $alias, @args];
			return 1;
		},
		upload_config => sub {
			my ($self, $content, $type, $name) = @_;
			push @director_calls, ['upload_config', $alias, $type, $name, $content];
			return ('', 0, '');
		},
		check_network_lock   => sub { return {status => $locked ? 'locked' : 'unlocked'} },
		acquire_network_lock => sub { push @director_calls, ['acquire_network_lock', $alias]; $locked = 1 },
		network_locked_by_me => sub { $locked },
		clear_network_lock   => sub { push @director_calls, ['clear_network_lock', $alias]; $locked = 0; 1 },
		exodus_path          => "secret/exodus/$alias/bosh",
		vault                => sub { $vault },
		%overrides,
	};
}

# make_env - an env mock whose hooks return canned content.  `hooks` names
# the hooks the kit provides, `cloud` is the cloud-config content,
# `runtime` the entries the runtime-config hook collects, and `lookups`
# the environment file values.
my $env_seq = 0;
sub make_env {
	my (%overrides) = @_;
	my $cloud       = delete($overrides{cloud});
	my $network_map = delete($overrides{network_map}) // {};
	my $runtime     = delete($overrides{runtime}) // [];
	my $hooks       = delete($overrides{hooks}) // {};
	my $lookups     = delete($overrides{lookups}) // {};
	my $cpi         = delete($overrides{cpi});
	$env_seq++;
	my $kit = mock "Mock::BoshConfigs::Kit$env_seq" => {id => 'test-kit/1.0.0'};
	return mock "Mock::BoshConfigs::Env$env_seq" => {
		name                    => 'test-env',
		type                    => 'cf',
		bosh_config_name        => 'test-env.cf',
		use_create_env          => 0,
		is_bosh_director        => 0,
		is_ocfp                 => 1,
		cpi_enabled             => 0,
		cpi_name                => undef,
		cpi_credhub_base        => '/test/credhub/',
		can_build_cloud_configs => 1,
		kit                     => $kit,
		notify                  => sub { 1 },
		has_hook => sub {
			my ($self, $hook) = @_;
			return $hooks->{$hook} ? 1 : 0;
		},
		lookup => sub {
			my ($self, $key, $default) = @_;
			return exists($lookups->{$key}) ? $lookups->{$key} : $default;
		},
		run_hook => sub {
			my ($self, $hook, %opts) = @_;
			push @hook_calls, [$hook, \%opts];
			return ($cloud, $network_map) if $hook eq 'cloud-config';
			return $runtime if $hook eq 'runtime-config';
			return $cpi if $hook eq 'cpi-config';
			die "unexpected hook $hook";
		},
		get_target_bosh => sub { die "test env is not a director\n" },
		_fix_cpi_config => sub {
			my ($self, @args) = @_;
			push @hook_calls, ['_fix_cpi_config', @args];
			return {result => 'ok'};
		},
		%overrides,
	};
}

sub entry {
	my ($id, $date) = @_;
	return {current => $id, entries => {$id => {date => $date // '2026-09-10T10:00:00Z', team => ''}}};
}

# plain_diff - a stand-in for spruce_diff with the same return shape, so the
# subtests exercise how the command handles each outcome rather than spruce
# itself (which runs under a pseudo-terminal that is not always available
# on a busy test host).
sub plain_diff {
	my ($first, $second) = @_;
	return ('', 0, '') if $first->{content} eq $second->{content};
	return ("--- $first->{label}\n+++ $second->{label}\n", 1, '');
}

# ---------------------------------------------------------------------------
# Ownership of director config names
# ---------------------------------------------------------------------------
subtest '_bosh_configs_belongs_to_env - recognizes the names this environment owns' => sub {
	plan tests => 7;
	my $env = make_env(
		hooks => {'cpi-config' => 1}, cpi_enabled => 1, cpi_name => 'test-env.aws.cf',
	);
	ok(Genesis::Commands::Bosh::_bosh_configs_belongs_to_env($env, 'cloud', 'test-env.cf'),
		'the bare <env>.<type> name is ours');
	ok(Genesis::Commands::Bosh::_bosh_configs_belongs_to_env($env, 'runtime', 'test-env.cf.dns'),
		'a dotted name under <env>.<type> is ours');
	ok(Genesis::Commands::Bosh::_bosh_configs_belongs_to_env($env, 'cpi', 'test-env.aws.cf'),
		'the cpi name is ours for the cpi type');
	ok(!Genesis::Commands::Bosh::_bosh_configs_belongs_to_env($env, 'cloud', 'test-env.aws.cf'),
		'the cpi name is not ours for other types');
	ok(!Genesis::Commands::Bosh::_bosh_configs_belongs_to_env($env, 'cloud', 'other-env.cf'),
		'another environment\'s name is not ours');
	ok(!Genesis::Commands::Bosh::_bosh_configs_belongs_to_env($env, 'cloud', 'test-env.cfx'),
		'a name that merely extends ours without a dot is not ours');

	my $plain = make_env();
	ok(!Genesis::Commands::Bosh::_bosh_configs_belongs_to_env($plain, 'cpi', 'default'),
		'without a cpi-config hook no cpi name is ours');
};

# ---------------------------------------------------------------------------
# Runtime requests
# ---------------------------------------------------------------------------
subtest '_bosh_configs_runtime_requests - follows bosh-configs.runtime and --name' => sub {
	plan tests => 6;
	my $none = make_env();
	is(Genesis::Commands::Bosh::_bosh_configs_runtime_requests($none, undef), undef,
		'no bosh-configs.runtime means no runtime configs are enabled');

	my $env = make_env(lookups => {'bosh-configs.runtime' => {dns => {ttl => 5}, ops => {}}});
	is_deeply(Genesis::Commands::Bosh::_bosh_configs_runtime_requests($env, undef),
		{dns => {ttl => 5}, ops => {}},
		'the enabled builds and their options are passed through');
	is_deeply(Genesis::Commands::Bosh::_bosh_configs_runtime_requests($env, 'test-env.cf.dns'),
		{dns => {ttl => 5}},
		'--name selects one build and keeps its options');
	is_deeply(Genesis::Commands::Bosh::_bosh_configs_runtime_requests($env, 'test-env.cf.syslog'),
		{syslog => {}},
		'--name can select a build the environment has not enabled');
	is(Genesis::Commands::Bosh::_bosh_configs_runtime_requests($env, 'other.cf.dns'), undef,
		'--name outside the environment prefix selects nothing');
	is(Genesis::Commands::Bosh::_bosh_configs_runtime_requests($env, 'test-env.cf'), undef,
		'--name of the cloud config selects no runtime build');
};

# ---------------------------------------------------------------------------
# Status against the director
# ---------------------------------------------------------------------------
subtest '_bosh_configs_status - identical, different, missing, unsynthesized' => sub {
	plan tests => 6;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	my $director = make_director('parent',
		{cloud => {'test-env.cf' => entry(3)}},
		contents => {'cloud|test-env.cf' => "azs:\n- name: z1\n"},
	);

	my $same = {type => 'cloud', name => 'test-env.cf', bosh => $director, content => "azs:\n- name: z1\n"};
	is(Genesis::Commands::Bosh::_bosh_configs_status($same), 'identical',
		'matching content is identical');

	my $changed = {type => 'cloud', name => 'test-env.cf', bosh => $director, content => "azs:\n- name: z2\n"};
	is(Genesis::Commands::Bosh::_bosh_configs_status($changed), 'different',
		'changed content is different');
	like($changed->{diff}, qr/--- uploaded.*\+\+\+ synthesized/s, 'the diff labels the uploaded and synthesized sides');
	is($changed->{uploaded}, "azs:\n- name: z1\n", 'the uploaded copy is kept on the record');

	my $absent = {type => 'cloud', name => 'test-env.other', bosh => $director, content => "azs: []\n"};
	is(Genesis::Commands::Bosh::_bosh_configs_status($absent), 'missing',
		'a name the director does not hold is missing');

	my $failed = {type => 'cloud', name => 'test-env.cf', bosh => $director, content => undef};
	is(Genesis::Commands::Bosh::_bosh_configs_status($failed), 'unsynthesized',
		'undefined content is unsynthesized');
};

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
subtest 'bosh_configs_summary - one row per provided config with its director status' => sub {
	plan tests => 5;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	my $director = make_director('parent',
		{
			cloud   => {'test-env.cf' => entry(3)},
			runtime => {'test-env.cf.dns' => entry(7)},
		},
		contents => {
			'cloud|test-env.cf'       => "azs: []\n",
			'runtime|test-env.cf.dns' => "releases: []\n",
		},
	);
	my $env = make_env(
		hooks   => {'cloud-config' => 1, 'runtime-config' => 1},
		cloud   => "azs: []\n",
		runtime => [
			{build => 'dns', name => 'test-env.cf.dns', description => 'Dns', content => "releases:\n- name: bosh-dns\n"},
			{build => 'ops', name => 'test-env.cf.ops', description => 'Ops', content => "addons: []\n"},
		],
		lookups => {'bosh-configs.runtime' => {dns => {}, ops => {}}},
	);

	my ($out, $err) = output_from { Genesis::Commands::Bosh::bosh_configs_summary($env, $director) };
	my $all = $out.$err;
	like($all, qr/^.*cloud.*test-env\.cf\b.*parent.*identical/m,
		'the cloud config is reported identical');
	like($all, qr/^.*runtime.*test-env\.cf\.dns.*parent.*different/m,
		'the changed runtime config is reported different');
	like($all, qr/^.*runtime.*test-env\.cf\.ops.*parent.*missing/m,
		'the runtime config the director lacks is reported missing');
	like($all, qr/no cpi-config hook/,
		'the type the kit does not provide is explained in a note');
	my ($collect) = grep {$_->[0] eq 'runtime-config'} @hook_calls;
	ok($collect && $collect->[1]{collect},
		'runtime configs were synthesized through the hook in collect mode');
};

subtest 'bosh_configs_summary - nothing provided' => sub {
	plan tests => 2;
	my $director = make_director('parent', {});
	my $env = make_env();
	my ($out, $err) = output_from { Genesis::Commands::Bosh::bosh_configs_summary($env, $director, type => 'cloud') };
	like($out.$err, qr/No bosh configs are provided for test-env of type cloud/,
		'says nothing is provided, naming the filter');
	like($out.$err, qr/no cloud-config hook/, 'explains why');
};

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------
subtest 'bosh_configs_list - only the environment\'s configs, honoring --type' => sub {
	plan tests => 5;
	my $director = make_director('parent', {
		cloud   => {'test-env.cf' => entry(3), 'other-env.cf' => entry(4)},
		runtime => {'test-env.cf.dns' => entry(7)},
		cpi     => {'default' => entry(1)},
	});
	my $env = make_env();

	my ($out, $err) = output_from { Genesis::Commands::Bosh::bosh_configs_list($env, $director) };
	my $all = $out.$err;
	like($all, qr/^.*cloud.*test-env\.cf\b.*parent.*\b3\b/m, 'lists the cloud config with its id');
	like($all, qr/^.*runtime.*test-env\.cf\.dns.*parent.*\b7\b/m, 'lists the runtime config');
	unlike($all, qr/other-env\.cf/, 'leaves out another environment\'s config');
	unlike($all, qr/\bdefault\b/, 'leaves out the director\'s own cpi config');

	($out, $err) = output_from { Genesis::Commands::Bosh::bosh_configs_list($env, $director, type => 'runtime') };
	unlike($out.$err, qr/^.*cloud.*test-env\.cf\b/m, '--type runtime hides the cloud config');
};

# ---------------------------------------------------------------------------
# view
# ---------------------------------------------------------------------------
subtest 'bosh_configs_view - synthesized content on stdout, director copy with --uploaded' => sub {
	plan tests => 4;
	my $director = make_director('parent',
		{cloud => {'test-env.cf' => entry(3)}},
		contents => {'cloud|test-env.cf' => "azs:\n- name: uploaded\n"},
	);
	my $env = make_env(
		hooks   => {'cloud-config' => 1, 'runtime-config' => 1},
		cloud   => "azs:\n- name: synthesized\n",
		runtime => [{build => 'dns', name => 'test-env.cf.dns', description => 'Dns', content => "releases:\n- name: bosh-dns\n"}],
		lookups => {'bosh-configs.runtime' => {dns => {}}},
	);

	my ($out, $err) = output_from { Genesis::Commands::Bosh::bosh_configs_view($env, $director) };
	like($out, qr/^- name: synthesized$/m, 'the synthesized cloud config goes to stdout');
	like($out, qr/^- name: bosh-dns$/m, 'the synthesized runtime config goes to stdout');

	($out, $err) = output_from { Genesis::Commands::Bosh::bosh_configs_view($env, $director, uploaded => 1) };
	like($out, qr/^- name: uploaded$/m, '--uploaded prints the director\'s copy');
	unlike($out, qr/synthesized/, '--uploaded does not print the synthesized copy');
};

# ---------------------------------------------------------------------------
# compare
# ---------------------------------------------------------------------------
subtest 'bosh_configs_compare - reports identical, different, and missing' => sub {
	plan tests => 3;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	my $director = make_director('parent',
		{
			cloud   => {'test-env.cf' => entry(3)},
			runtime => {'test-env.cf.dns' => entry(7)},
		},
		contents => {
			'cloud|test-env.cf'       => "azs: []\n",
			'runtime|test-env.cf.dns' => "releases: []\n",
		},
	);
	my $env = make_env(
		hooks   => {'cloud-config' => 1, 'runtime-config' => 1},
		cloud   => "azs: []\n",
		runtime => [
			{build => 'dns', name => 'test-env.cf.dns', description => 'Dns', content => "releases:\n- name: bosh-dns\n"},
			{build => 'ops', name => 'test-env.cf.ops', description => 'Ops', content => "addons: []\n"},
		],
		lookups => {'bosh-configs.runtime' => {dns => {}, ops => {}}},
	);
	my ($out, $err) = output_from { Genesis::Commands::Bosh::bosh_configs_compare($env, $director) };
	my $all = $out.$err;
	like($all, qr/cloud config test-env\.cf on parent is identical/, 'identical config reported');
	like($all, qr/runtime config test-env\.cf\.dns on parent is different/, 'different config reported with a diff');
	like($all, qr/runtime config test-env\.cf\.ops on parent is missing.*addons: \[\]/s, 'missing config reported with its content');
};

# ---------------------------------------------------------------------------
# read-only actions and the network claims lock
# ---------------------------------------------------------------------------
subtest 'summary, list, view, and compare never touch the network claims lock' => sub {
	plan tests => 12;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;

	# A stale lock left by someone else is on the director; a read-only
	# action must neither clear it nor take one of its own, and must not even
	# ask about it.
	my $stale = {status => 'stale', description => 'about 11 minutes ago by ubuntu@bastion (env: ocf, pid: 229665)'};
	my $director = make_director('parent',
		{
			cloud   => {'test-env.cf' => entry(3)},
			runtime => {'test-env.cf.dns' => entry(7)},
		},
		contents => {
			'cloud|test-env.cf'       => "azs: []\n",
			'runtime|test-env.cf.dns' => "releases: []\n",
		},
		check_network_lock   => sub { push @director_calls, ['check_network_lock', 'parent']; return $stale },
		network_locked_by_me => sub { push @director_calls, ['network_locked_by_me', 'parent']; return 0 },
	);
	my %actions = (
		summary => sub { Genesis::Commands::Bosh::bosh_configs_summary(@_) },
		list    => sub { Genesis::Commands::Bosh::bosh_configs_list(@_) },
		view    => sub { Genesis::Commands::Bosh::bosh_configs_view(@_) },
		compare => sub { Genesis::Commands::Bosh::bosh_configs_compare(@_) },
	);
	for my $action (sort keys %actions) {
		my $env = make_env(
			hooks   => {'cloud-config' => 1, 'runtime-config' => 1},
			cloud   => "azs: [z1]\n",
			runtime => [
				{build => 'dns', name => 'test-env.cf.dns', description => 'Dns', content => "releases:\n- name: bosh-dns\n"},
			],
			lookups => {'bosh-configs.runtime' => {dns => {}}},
		);
		@director_calls = ();
		my ($out, $err) = output_from { $actions{$action}->($env, $director) };
		my @lock_calls = grep {$_->[0] =~ /network_lock/} @director_calls;
		is(scalar(@lock_calls), 0, "$action makes no network claims lock calls on the director")
			or diag explain \@lock_calls;
		unlike($out.$err, qr/network claims lock/i, "$action says nothing about the network claims lock");
		unlike($out.$err, qr/\[y\|n\]/, "$action asks no question");
	}
};

# ---------------------------------------------------------------------------
# delete
# ---------------------------------------------------------------------------
subtest 'bosh_configs_delete - needs a name, refuses foreign names, resolves the type' => sub {
	plan tests => 5;
	my $director = make_director('parent', {
		cloud   => {'test-env.cf' => entry(3), 'other-env.cf' => entry(4), 'test-env.cf.dual' => entry(8)},
		runtime => {'test-env.cf.dns' => entry(7), 'test-env.cf.dual' => entry(9)},
	});
	my $env = make_env();

	throws_ok { Genesis::Commands::Bosh::bosh_configs_delete($env, $director, yes => 1) }
		qr/needs the name of the config to remove/, 'delete without --name is refused';
	throws_ok { Genesis::Commands::Bosh::bosh_configs_delete($env, $director, yes => 1, name => 'other-env.cf') }
		qr/No bosh config named other-env\.cf belonging to test-env/, 'another environment\'s config cannot be deleted here';
	throws_ok { Genesis::Commands::Bosh::bosh_configs_delete($env, $director, yes => 1, name => 'test-env.cf.dual') }
		qr/matches 2 configs.*specify --type/, 'an ambiguous name asks for --type';

	@director_calls = ();
	my ($out, $err) = output_from {
		Genesis::Commands::Bosh::bosh_configs_delete($env, $director, yes => 1, name => 'test-env.cf.dns')
	};
	is_deeply($director_calls[-1], ['delete_config', 'parent', 'runtime', 'test-env.cf.dns'],
		'a unique name is deleted with its type inferred');

	@director_calls = ();
	Genesis::Commands::Bosh::bosh_configs_delete($env, $director, yes => 1, name => 'test-env.cf.dual', type => 'cloud');
	is_deeply($director_calls[-1], ['delete_config', 'parent', 'cloud', 'test-env.cf.dual'],
		'--type picks between configs sharing a name');
};

# ---------------------------------------------------------------------------
# upload
# ---------------------------------------------------------------------------
subtest 'bosh_configs_upload - cloud under the network lock, runtime through the hook, identical skipped' => sub {
	plan tests => 9;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	my $director = make_director('parent',
		{runtime => {'test-env.cf.dns' => entry(7), 'test-env.cf.ops' => entry(8)}},
		contents => {
			'runtime|test-env.cf.dns' => "releases: []\n",
			'runtime|test-env.cf.ops' => "addons: []\n",
		},
	);
	my $env = make_env(
		hooks       => {'cloud-config' => 1, 'runtime-config' => 1},
		cloud       => "azs: []\n",
		network_map => {subnets => {'ocfp-0' => {claims => {}}}},
		runtime     => [
			{build => 'dns', name => 'test-env.cf.dns', description => 'Dns', content => "releases:\n- name: bosh-dns\n"},
			{build => 'ops', name => 'test-env.cf.ops', description => 'Ops', content => "addons: []\n"},
		],
		lookups     => {'bosh-configs.runtime' => {dns => {}, ops => {}}},
	);

	@director_calls = ();
	@hook_calls = ();
	my ($out, $err) = output_from { Genesis::Commands::Bosh::bosh_configs_upload($env, $director, yes => 1) };
	my $all = $out.$err;

	my @names = map {$_->[0]} @director_calls;
	my ($acquire) = grep {$names[$_] eq 'acquire_network_lock'} 0..$#names;
	my ($upload)  = grep {$names[$_] eq 'upload_config'} 0..$#names;
	my ($claims)  = grep {$names[$_] eq 'set_path'} 0..$#names;
	my ($release) = grep {$names[$_] eq 'clear_network_lock'} 0..$#names;
	ok(defined $acquire && defined $upload && $acquire < $upload,
		'the network claims lock is taken before the cloud config is uploaded');
	is_deeply([@{$director_calls[$upload]}[1..3]], ['parent', 'cloud', 'test-env.cf'],
		'the missing cloud config is uploaded under its name');
	ok(defined $claims && $claims > $upload, 'the network map is submitted after the upload');
	is($director_calls[$claims][1], 'secret/exodus/parent/bosh/network',
		'the network map goes to the director\'s exodus network path');
	ok(defined $release && $release > $claims, 'the lock is released at the end');
	like($all, qr/runtime config test-env\.cf\.ops on parent is already up to date/,
		'the identical runtime config is skipped');

	my ($runtime_upload) = grep {$_->[0] eq 'runtime-config' && !$_->[1]{collect}} @hook_calls;
	ok($runtime_upload, 'the runtime-config hook is run to upload');
	is($runtime_upload->[1]{interactive}, 0, 'without prompting, since confirmation already happened');
	is_deeply($runtime_upload->[1]{args}, {dns => {}, ops => JSON::PP::false},
		'only the changed build is requested; the identical one is excluded');
};

subtest 'bosh_configs_upload - --name on a runtime config leaves the network lock alone' => sub {
	plan tests => 3;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	my $director = make_director('parent', {});
	my $env = make_env(
		hooks   => {'cloud-config' => 1, 'runtime-config' => 1},
		cloud   => "azs: []\n",
		runtime => [{build => 'dns', name => 'test-env.cf.dns', description => 'Dns', content => "releases:\n- name: bosh-dns\n"}],
		lookups => {'bosh-configs.runtime' => {dns => {}}},
	);

	@director_calls = ();
	@hook_calls = ();
	output_from { Genesis::Commands::Bosh::bosh_configs_upload($env, $director, yes => 1, name => 'test-env.cf.dns') };
	ok(!grep({$_->[0] eq 'acquire_network_lock'} @director_calls), 'no network lock is taken');
	ok(!grep({$_->[0] eq 'upload_config'} @director_calls), 'the cloud config is not uploaded');
	my ($runtime_upload) = grep {$_->[0] eq 'runtime-config' && !$_->[1]{collect}} @hook_calls;
	is_deeply($runtime_upload->[1]{args}, {dns => {}}, 'only the named build is uploaded');
};

subtest 'bosh_configs_upload - cpi goes through the shared fixer' => sub {
	plan tests => 3;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	my $director = make_director('parent',
		{cpi => {'test-env.aws.cf' => entry(2)}},
		contents => {'cpi|test-env.aws.cf' => "cpis: []\n"},
	);
	my $cpi = {content => "cpis:\n- name: aws\n", credhub_secrets => {}, error => undef};
	my $env = make_env(
		hooks => {'cpi-config' => 1}, cpi_enabled => 1, cpi_name => 'test-env.aws.cf', cpi => $cpi,
	);

	@hook_calls = ();
	output_from { Genesis::Commands::Bosh::bosh_configs_upload($env, $director, yes => 1, type => 'cpi') };
	my ($fix) = grep {$_->[0] eq '_fix_cpi_config'} @hook_calls;
	ok($fix, 'the cpi config is uploaded through _fix_cpi_config');
	is($fix->[1], 'changed', 'as a changed config');
	is($fix->[2]{name}, 'test-env.aws.cf', 'under the environment\'s cpi name');
};

# ---------------------------------------------------------------------------
# releasing the lock on every exit path
# ---------------------------------------------------------------------------
# A lock left on the director outlives the process that took it, and the next
# operator finds it and has to decide whether it is real.  The upload holds the
# lock across the synthesis and the upload, so every way out of that stretch --
# a return, an error, and a signal -- has to run the release.
subtest 'bosh_configs_upload - the network claims lock is released when the upload fails' => sub {
	plan tests => 4;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	my $director = make_director('parent', {},
		upload_config => sub {
			my ($self, @args) = @_;
			push @director_calls, ['upload_config', 'parent', @args[1,2]];
			die "director refused the cloud config\n";
		},
	);
	my $env = make_env(
		hooks       => {'cloud-config' => 1},
		cloud       => "azs: []\n",
		network_map => {subnets => {'ocfp-0' => {claims => {}}}},
	);

	@director_calls = ();
	throws_ok {
		output_from { Genesis::Commands::Bosh::bosh_configs_upload($env, $director, yes => 1) }
	} qr/director refused the cloud config/, 'the error the upload raised is re-raised to the caller';

	my @seen = map {$_->[0]} @director_calls;
	ok(grep({$_ eq 'acquire_network_lock'} @seen), 'the lock was taken');
	ok(grep({$_ eq 'clear_network_lock'} @seen), 'and released again despite the failure');
	ok(!$director->network_locked_by_me, 'so the director is left with no lock of ours');
};

subtest 'bosh_configs_upload - the network claims lock is released on a signal' => sub {
	# Signals the command is expected to survive with the lock cleaned up.
	# HUP is the one that matters most in practice: these run over ssh from a
	# bastion, and a dropped session hangs up every process in it.
	my @signals = (
		[INT  => qr/Interrupted by user/],
		[TERM => qr/Terminated/],
		[HUP  => qr/Hung up/],
		[QUIT => qr/Quit/],
	);
	plan tests => 4 * scalar(@signals);
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;

	for my $case (@signals) {
		my ($signal, $message) = @$case;
		my $director = make_director('parent', {},
			upload_config => sub {
				my ($self, @args) = @_;
				push @director_calls, ['upload_config', 'parent', @args[1,2]];
				# Delivered to ourselves while the lock is held, which is the
				# only way to exercise the handler the command installs.
				kill $signal => $$;
				return ('', 0, '');
			},
		);
		my $env = make_env(
			hooks       => {'cloud-config' => 1},
			cloud       => "azs: []\n",
			network_map => {subnets => {'ocfp-0' => {claims => {}}}},
		);

		@director_calls = ();
		throws_ok {
			output_from { Genesis::Commands::Bosh::bosh_configs_upload($env, $director, yes => 1) }
		} $message, "$signal stops the upload with its own message";

		my @seen = map {$_->[0]} @director_calls;
		ok(grep({$_ eq 'acquire_network_lock'} @seen), "$signal: the lock was taken");
		ok(grep({$_ eq 'clear_network_lock'} @seen), "$signal: and released on the way out");
		ok(!$director->network_locked_by_me, "$signal: so no lock of ours is left behind");
	}
};

done_testing;
