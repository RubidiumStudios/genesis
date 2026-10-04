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

my $stored_claims = {}; # what the network record in exodus holds, as the vault reads it; undef when none was written
my $claims_read_error;  # when set, the vault fails every read of the network record with this

my $vault = mock "Mock::BoshConfigs::Vault" => {
	get_path_strict => sub {
		my ($self, $path) = @_;
		push @director_calls, ['get_path_strict', $path];
		die $claims_read_error if $claims_read_error;
		return $stored_claims;
	},
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
		get_call_path_with_env  => sub { 'genesis '.$_[0]->name },
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

# broken_diff - plain_diff, except that synthesized content holding BROKEN
# makes spruce fail the way it does on YAML it cannot parse, with rc 2 and
# its error as the output.
sub broken_diff {
	my ($first, $second) = @_;
	return ("unable to parse data from $second->{label}: yaml: line 1: did not find expected node content", 2, undef)
		if $second->{content} =~ /BROKEN/;
	return plain_diff(@_);
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

subtest '_bosh_configs_status - a spruce failure is an error, not a difference' => sub {
	plan tests => 4;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&broken_diff;
	my $director = make_director('parent',
		{cloud => {'test-env.cf' => entry(3)}},
		contents => {'cloud|test-env.cf' => "azs:\n- name: z1\n"},
	);

	my $broken = {type => 'cloud', name => 'test-env.cf', bosh => $director, content => "azs: [BROKEN\n"};
	is(Genesis::Commands::Bosh::_bosh_configs_status($broken), 'error',
		'a config spruce cannot compare has the error status');
	like($broken->{diff}, qr/unable to parse data from synthesized/,
		'spruce\'s output is kept as the diff');
	is(Genesis::Commands::Bosh::_bosh_configs_status_label($broken), '#R{could not compare}',
		'the summary label says the comparison failed');
	isnt(Genesis::Commands::Bosh::_bosh_configs_status_label($broken), '#R{unknown}',
		'the error status has a label of its own');
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

subtest 'bosh_configs_summary - a config spruce cannot compare is not reported different' => sub {
	plan tests => 3;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&broken_diff;
	my $director = make_director('parent',
		{cloud => {'test-env.cf' => entry(3)}},
		contents => {'cloud|test-env.cf' => "azs: []\n"},
	);
	my $env = make_env(hooks => {'cloud-config' => 1}, cloud => "azs: [BROKEN\n");

	my ($out, $err) = output_from { Genesis::Commands::Bosh::bosh_configs_summary($env, $director) };
	my $all = $out.$err;
	like($all, qr/^.*cloud.*test-env\.cf\b.*parent.*could not compare/m,
		'the row says the comparison failed');
	unlike($all, qr/\b(different|identical)\b/, 'the row says neither different nor identical');
	unlike($all, qr/unknown/, 'the row does not fall back to unknown');
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

subtest 'bosh_configs_compare - a spruce failure is reported as an error with its output' => sub {
	plan tests => 3;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&broken_diff;
	my $director = make_director('parent',
		{cloud => {'test-env.cf' => entry(3)}},
		contents => {'cloud|test-env.cf' => "azs: []\n"},
	);
	my $env = make_env(hooks => {'cloud-config' => 1}, cloud => "azs: [BROKEN\n");

	my ($out, $err) = output_from { Genesis::Commands::Bosh::bosh_configs_compare($env, $director) };
	my $all = $out.$err;
	like($all, qr/cloud config test-env\.cf on parent could not be compared with the director's copy/,
		'the config is reported as not compared');
	like($all, qr/unable to parse data from synthesized/, 'spruce\'s output is shown');
	unlike($all, qr/\b(different|identical)\b/, 'it is not reported as different or identical');
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

subtest 'bosh_configs_upload - a config spruce cannot compare is never uploaded' => sub {
	plan tests => 6;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&broken_diff;
	my $director = make_director('parent',
		{
			cloud   => {'test-env.cf' => entry(3)},
			runtime => {'test-env.cf.dns' => entry(7), 'test-env.cf.ops' => entry(8)},
		},
		contents => {
			'cloud|test-env.cf'       => "azs: []\n",
			'runtime|test-env.cf.dns' => "releases: []\n",
			'runtime|test-env.cf.ops' => "addons: []\n",
		},
	);
	my $env = make_env(
		hooks       => {'cloud-config' => 1, 'runtime-config' => 1},
		cloud       => "azs: [BROKEN\n",
		network_map => {subnets => {'ocfp-0' => {claims => {}}}},
		runtime     => [
			{build => 'dns', name => 'test-env.cf.dns', description => 'Dns', content => "releases: [BROKEN\n"},
			{build => 'ops', name => 'test-env.cf.ops', description => 'Ops', content => "addons:\n- name: ops\n"},
		],
		lookups     => {'bosh-configs.runtime' => {dns => {}, ops => {}}},
	);

	@director_calls = ();
	@hook_calls = ();
	my ($out, $err);
	throws_ok {
		($out, $err) = output_from { Genesis::Commands::Bosh::bosh_configs_upload($env, $director, yes => 1) }
	} qr/2 bosh configs could not be compared with the director's copies, so they were not uploaded/,
		'the upload fails and counts the configs it could not compare';
	ok(!grep({$_->[0] eq 'upload_config'} @director_calls), 'the cloud config spruce could not compare is not uploaded');
	ok(!grep({$_->[0] eq 'set_path'} @director_calls), 'and no network map is submitted for it');
	my ($runtime_upload) = grep {$_->[0] eq 'runtime-config' && !$_->[1]{collect}} @hook_calls;
	ok($runtime_upload, 'the runtime config that compared cleanly is still uploaded');
	is_deeply($runtime_upload->[1]{args}, {dns => JSON::PP::false, ops => {}},
		'the runtime config spruce could not compare is excluded from the upload');
	ok(grep({$_->[0] eq 'clear_network_lock'} @director_calls), 'the network claims lock is released');
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

# ---------------------------------------------------------------------------
# a director's own cloud config
# ---------------------------------------------------------------------------
# A director environment owns a second cloud config, <env>.<type>.director,
# which the kit builds with the director-purpose cloud-config hook and which
# lives on the director itself.  Its network map is the director's own claims
# record in exodus, so the upload holds that director's network claims lock
# while the hook reads the claims and until the record is written back.

# make_director_env - a director environment whose kit honours the hook
# purpose the way Genesis::Kit::has_hook does.  The hook and every director
# call land in @director_calls as well, so a subtest can check their order.
sub make_director_env {
	my (%o) = @_;
	my $self_bosh = $o{self_bosh};
	my $parent    = $o{parent};
	my $hooks     = {'cloud-config' => 1, 'cloud-config-director' => 1, %{$o{hooks} // {}}};
	my $run_hook  = $o{run_hook} // sub {
		my ($s, $h, %p) = @_;
		return [] if $h eq 'runtime-config';
		return ($p{purpose} ? "director: yes\n" : "parent: yes\n", {subnets => {}});
	};
	return make_env(
		name => 'lab-ocf', type => 'bosh', bosh_config_name => 'lab-ocf.bosh',
		is_bosh_director => 1, use_create_env => $o{create_env} ? 1 : 0,
		exodus_base => 'secret/exodus/lab-ocf/bosh', vault => $o{vault} // $vault,
		has_hook => sub {
			my ($s, $h, %p) = @_;
			$h = "cloud-config-$p{purpose}" if $h eq 'cloud-config' && $p{purpose};
			return $hooks->{$h} ? 1 : 0;
		},
		run_hook => sub {
			my ($s, $h, %p) = @_;
			push @hook_calls, [$h, \%p];
			push @director_calls, ['run_hook', $h, $p{purpose} // ''];
			return $run_hook->(@_);
		},
		get_target_bosh => sub {
			my $s = shift;
			my $t = ref($_[0]) eq 'HASH' ? $_[0] : {@_};
			return ($t->{self} || $s->use_create_env) ? $self_bosh : $parent;
		},
		%{$o{overrides} // {}},
	);
}

# call_index - the position of the first recorded director call matching
# the given leading fields, or undef
sub call_index {
	my (@want) = @_;
	CALL: for my $i (0..$#director_calls) {
		for my $j (0..$#want) {
			next CALL unless defined($director_calls[$i][$j]) && $director_calls[$i][$j] eq $want[$j];
		}
		return $i;
	}
	return undef;
}

subtest 'director config - a director environment provides its own director cloud config' => sub {
	plan tests => 5;
	@hook_calls = ();
	my $self_bosh = make_director('lab-ocf', {});
	my $parent    = make_director('lab-mgmt', {});
	my $env = make_director_env(self_bosh => $self_bosh, parent => $parent);
	my ($configs) = Genesis::Commands::Bosh::_bosh_configs_provided($env, $parent, type => 'cloud');
	my ($dir) = grep { $_->{name} eq 'lab-ocf.bosh.director' } @$configs;
	ok($dir, 'the director config is in the list');
	is($dir && $dir->{bosh}->alias, 'lab-ocf', 'it targets the director itself');
	ok(grep({ $_->[0] eq 'cloud-config' && ($_->[1]{purpose} // '') eq 'director' } @hook_calls), 'it ran the director-purpose hook');
	is($dir && $dir->{exodus_path}, 'secret/exodus/lab-ocf/bosh/network',
		'its network map belongs in the director\'s own exodus network record');
	my ($parent_config) = grep { $_->{name} eq 'lab-ocf.bosh' } @$configs;
	is($parent_config && $parent_config->{bosh}->alias, 'lab-mgmt',
		'the parent-side cloud config is still provided, on the deploying director');
};

subtest 'director config - none for a non-director, and a note when the kit has no director hook' => sub {
	plan tests => 5;
	my $parent = make_director('lab-mgmt', {});

	@hook_calls = ();
	my $plain = make_env(hooks => {'cloud-config' => 1}, cloud => "azs: []\n");
	my ($configs) = Genesis::Commands::Bosh::_bosh_configs_provided($plain, $parent, type => 'cloud');
	ok(!grep({ $_->{name} =~ /\.director$/ } @$configs), 'an environment that is not a director gets no director config');
	ok(!grep({ ($_->[1]{purpose} // '') eq 'director' } @hook_calls), 'and no director-purpose hook runs for it');

	@hook_calls = ();
	my $self_bosh = make_director('lab-ocf', {});
	my $env = make_director_env(self_bosh => $self_bosh, parent => $parent, hooks => {'cloud-config-director' => 0});
	my ($dconfigs, $notes) = Genesis::Commands::Bosh::_bosh_configs_provided($env, $parent, type => 'cloud');
	ok(!grep({ $_->{name} eq 'lab-ocf.bosh.director' } @$dconfigs), 'a director whose kit has no director hook gets no director config');
	ok(grep({ /lab-ocf\.bosh\.director/ && /cloud-config-director/ } @$notes), 'and a note says the kit has no director hook')
		or diag explain $notes;
	ok(!grep({ ($_->[1]{purpose} // '') eq 'director' } @hook_calls), 'and no director-purpose hook runs');
};

subtest 'director config - --name selects only the director config' => sub {
	plan tests => 4;
	@hook_calls = ();
	my $self_bosh = make_director('lab-ocf', {});
	my $parent    = make_director('lab-mgmt', {});
	my $env = make_director_env(
		self_bosh => $self_bosh, parent => $parent,
		hooks => {'runtime-config' => 1},
	);
	my ($configs) = Genesis::Commands::Bosh::_bosh_configs_provided($env, $parent, name => 'lab-ocf.bosh.director');
	is(scalar(@$configs), 1, 'one config is selected');
	is($configs->[0]{name}, 'lab-ocf.bosh.director', 'and it is the director config');
	is(scalar(@hook_calls), 1, 'only one hook runs');
	is_deeply([$hook_calls[0][0], $hook_calls[0][1]{purpose}], ['cloud-config', 'director'],
		'and it is the director-purpose cloud-config hook');
};

subtest 'director config - upload locks the director, writes its own exodus record, and releases the lock' => sub {
	plan tests => 9;
	@director_calls = ();
	my $self_bosh = make_director('lab-ocf', {});
	my $parent    = make_director('lab-mgmt', {});
	my $env = make_director_env(self_bosh => $self_bosh, parent => $parent);
	output_from {
		Genesis::Commands::Bosh::bosh_configs_upload($env, $parent, yes => 1, type => 'cloud', name => 'lab-ocf.bosh.director')
	};

	my $acquire = call_index('acquire_network_lock', 'lab-ocf');
	my $hook    = call_index('run_hook', 'cloud-config', 'director');
	my $upload  = call_index('upload_config', 'lab-ocf', 'cloud', 'lab-ocf.bosh.director');
	my $claims  = call_index('set_path');
	my $release = call_index('clear_network_lock', 'lab-ocf');
	ok(defined $acquire && defined $hook && $acquire < $hook,
		'the director\'s lock is taken before the director-purpose hook reads the claims')
		or diag explain \@director_calls;
	ok(defined $upload && $upload > $hook, 'the director config is uploaded to the director itself');
	is_deeply($claims && [@{$director_calls[$claims]}[1..2]], ['secret/exodus/lab-ocf/bosh/network', {subnets => {}}],
		'the network map is written to the director\'s own exodus network record');
	is_deeply($claims && {@{$director_calls[$claims]}[3..6]}, {flatten => 1, clear => 1},
		'with flatten and clear, as post-deploy writes it');
	ok(defined $claims && $claims > $upload, 'after the upload');
	ok(defined $release && $release > $claims, 'and the lock is released at the end');
	ok(!$self_bosh->network_locked_by_me, 'so no lock of ours is left on the director');
	ok(!defined(call_index('acquire_network_lock', 'lab-mgmt')), 'the parent director\'s lock is not taken for the director config alone');
	ok(!defined(call_index('run_hook', 'cloud-config', '')), 'the parent-side cloud-config hook does not run');
};

subtest 'director config - upload releases the director\'s lock on every failure' => sub {
	plan tests => 9;
	my %cases = (
		'a failed upload' => {
			self_overrides => {upload_config => sub { push @director_calls, ['upload_config', 'lab-ocf']; return ('', 1, 'director refused the cloud config') }},
			error => qr/Failed to upload cloud config lab-ocf\.bosh\.director/,
		},
		'a failed exodus write' => {
			vault => mock("Mock::BoshConfigs::FailingVault" => {
				get_path_strict => sub { return {} },
				set_path => sub { push @director_calls, ['set_path']; die "vault sealed\n" },
			}),
			error => qr/was uploaded, but the network map could not be updated.*vault sealed/s,
		},
		'a failed hook' => {
			run_hook => sub { die "the director cloud-config hook failed\n" },
			error => qr/the director cloud-config hook failed/,
		},
	);
	for my $case (sort keys %cases) {
		my $c = $cases{$case};
		@director_calls = ();
		my $self_bosh = make_director('lab-ocf', {}, %{$c->{self_overrides} // {}});
		my $parent    = make_director('lab-mgmt', {});
		my $env = make_director_env(
			self_bosh => $self_bosh, parent => $parent,
			($c->{vault} ? (vault => $c->{vault}) : ()),
			($c->{run_hook} ? (run_hook => $c->{run_hook}) : ()),
		);
		throws_ok {
			output_from {
				Genesis::Commands::Bosh::bosh_configs_upload($env, $parent, yes => 1, name => 'lab-ocf.bosh.director')
			}
		} $c->{error}, "$case stops the upload with its own error";
		ok(defined(call_index('clear_network_lock', 'lab-ocf')), "$case: the director's lock is released");
		ok(!$self_bosh->network_locked_by_me, "$case: so no lock of ours is left behind");
	}
};

subtest 'director config - upload refuses when another process holds the director\'s lock' => sub {
	plan tests => 4;
	@director_calls = ();
	my $held = {status => 'locked', description => 'about 2 minutes ago by ubuntu@bastion (env: ocfp-cf1-lab-ocf, pid: 4242)'};
	my $self_bosh = make_director('lab-ocf', {},
		check_network_lock   => sub { return $held },
		network_locked_by_me => sub { 0 },
	);
	my $parent = make_director('lab-mgmt', {});
	my $env = make_director_env(self_bosh => $self_bosh, parent => $parent);
	my ($out, $err);
	throws_ok {
		($out, $err) = output_from {
			Genesis::Commands::Bosh::bosh_configs_upload($env, $parent, yes => 1, name => 'lab-ocf.bosh.director')
		}
	} qr/Network claims are currently locked/, 'the upload is refused with the lock message';
	ok(!defined(call_index('run_hook')), 'no hook runs');
	ok(!defined(call_index('upload_config')), 'nothing is uploaded');
	ok(!defined(call_index('clear_network_lock')), 'the other process\'s lock is left alone');
};

subtest 'director config - compare shows the diff without a lock or an exodus write' => sub {
	plan tests => 4;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	@director_calls = ();
	my $self_bosh = make_director('lab-ocf',
		{cloud => {'lab-ocf.bosh.director' => entry(5)}},
		contents => {'cloud|lab-ocf.bosh.director' => "director: no\n"},
	);
	my $parent = make_director('lab-mgmt', {});
	my $env = make_director_env(self_bosh => $self_bosh, parent => $parent);
	my ($out, $err) = output_from {
		Genesis::Commands::Bosh::bosh_configs_compare($env, $parent, name => 'lab-ocf.bosh.director')
	};
	like($out.$err, qr/cloud config lab-ocf\.bosh\.director on lab-ocf is different.*--- uploaded/s,
		'the director config\'s diff is shown');
	ok(defined(call_index('run_hook', 'cloud-config', 'director')), 'the director-purpose hook built the config');
	ok(!grep({ $_->[0] =~ /network_lock/ } @director_calls), 'no lock is checked, taken, or released')
		or diag explain \@director_calls;
	ok(!defined(call_index('set_path')), 'and no exodus record is written');
};

subtest 'director config - an upload of both cloud configs takes the parent lock first, then the director\'s' => sub {
	plan tests => 12;

	# Both configs go up and both locks come off
	@director_calls = ();
	my $self_bosh = make_director('lab-ocf', {});
	my $parent    = make_director('lab-mgmt', {});
	my $env = make_director_env(self_bosh => $self_bosh, parent => $parent);
	output_from { Genesis::Commands::Bosh::bosh_configs_upload($env, $parent, yes => 1, type => 'cloud') };
	my $parent_lock = call_index('acquire_network_lock', 'lab-mgmt');
	my $self_lock   = call_index('acquire_network_lock', 'lab-ocf');
	ok(defined $parent_lock && defined $self_lock && $parent_lock < $self_lock,
		'the parent lock is taken before the director\'s')
		or diag explain \@director_calls;
	ok(defined($self_lock) && defined(call_index('run_hook')) && $self_lock < call_index('run_hook'), 'both locks are held before any hook runs');
	ok(defined(call_index('upload_config', 'lab-mgmt', 'cloud', 'lab-ocf.bosh')), 'the parent-side cloud config is uploaded to the parent');
	ok(defined(call_index('upload_config', 'lab-ocf', 'cloud', 'lab-ocf.bosh.director')), 'the director config is uploaded to the director');
	ok(defined(call_index('clear_network_lock', 'lab-mgmt')) && defined(call_index('clear_network_lock', 'lab-ocf')),
		'both locks are released');
	ok(!$parent->network_locked_by_me && !$self_bosh->network_locked_by_me, 'and neither director is left locked');

	# The director config fails to upload, and both locks still come off
	@director_calls = ();
	$self_bosh = make_director('lab-ocf', {},
		upload_config => sub { push @director_calls, ['upload_config', 'lab-ocf']; return ('', 1, 'refused') },
	);
	$parent = make_director('lab-mgmt', {});
	$env = make_director_env(self_bosh => $self_bosh, parent => $parent);
	throws_ok {
		output_from { Genesis::Commands::Bosh::bosh_configs_upload($env, $parent, yes => 1, type => 'cloud') }
	} qr/Failed to upload cloud config lab-ocf\.bosh\.director/, 'a failed director upload stops the run';
	ok(!$parent->network_locked_by_me && !$self_bosh->network_locked_by_me,
		'and both locks are released after the failure');

	# The director's lock is held elsewhere, so the parent lock comes off again
	@director_calls = ();
	$self_bosh = make_director('lab-ocf', {},
		check_network_lock   => sub { return {status => 'locked', description => 'by someone else'} },
		network_locked_by_me => sub { 0 },
	);
	$parent = make_director('lab-mgmt', {});
	$env = make_director_env(self_bosh => $self_bosh, parent => $parent);
	throws_ok {
		output_from { Genesis::Commands::Bosh::bosh_configs_upload($env, $parent, yes => 1, type => 'cloud') }
	} qr/Network claims are currently locked/, 'a held director lock stops the run';
	ok(defined(call_index('clear_network_lock', 'lab-mgmt')), 'the parent lock that was taken is released');
	ok(!$parent->network_locked_by_me, 'so the parent is left unlocked');
	ok(!defined(call_index('run_hook')), 'and no hook ran');
};

subtest 'director config - a create-env director builds and uploads its own cloud config' => sub {
	plan tests => 8;
	@director_calls = ();
	@hook_calls = ();
	my $self_bosh = make_director('lab-ocf', {});
	my $env = make_director_env(self_bosh => $self_bosh, parent => undef, create_env => 1);

	# bosh_configs hands a create-env director's actions an undefined
	# deploying director
	my ($configs, $notes) = Genesis::Commands::Bosh::_bosh_configs_provided($env, undef, type => 'cloud');
	my ($dir) = grep { $_->{name} eq 'lab-ocf.bosh.director' } @$configs;
	ok($dir, 'the director config is provided');
	is($dir && $dir->{bosh}->alias, 'lab-ocf', 'on the director itself');
	ok(!grep({ $_->{name} eq 'lab-ocf.bosh' } @$configs), 'the parent-side cloud config is still skipped');
	ok(grep({ /create-env/ } @$notes), 'with the create-env note') or diag explain $notes;
	ok(!grep({ !($_->[1]{purpose}) } @hook_calls), 'and the parent-side hook never runs');

	@director_calls = ();
	lives_ok {
		output_from { Genesis::Commands::Bosh::bosh_configs_upload($env, undef, yes => 1) }
	} 'an unfiltered upload runs with no deploying director';
	ok(defined(call_index('upload_config', 'lab-ocf', 'cloud', 'lab-ocf.bosh.director')),
		'the director config is uploaded to the director');
	my $claims = call_index('set_path');
	is($claims && $director_calls[$claims][1], 'secret/exodus/lab-ocf/bosh/network',
		'and the director\'s own exodus network record is written');
};

# ---------------------------------------------------------------------------
# claims that drifted from an up-to-date cloud config
# ---------------------------------------------------------------------------
# The cloud config is uploaded before the network record is written, so a
# failed write leaves the director holding the new config.  Running the upload
# again finds that config identical, and has to write the record all the same.

my $fresh_claims = {subnets => {'ocfp-2' => {claims => {
	compilation => '10.61.148.228,10.61.148.230-10.61.148.231,10.61.148.248',
	cf          => '10.61.148.232-10.61.148.245',
}}}};
my $stale_claims = {subnets => {'ocfp-2' => {claims => {
	compilation => '10.61.148.228-10.61.148.231',
	cf          => '10.61.148.232-10.61.148.245',
}}}};

# claims_env - a director environment whose cloud config the director already
# holds, built with the given network map
sub claims_env {
	my (%o) = @_;
	my $self_bosh = make_director('lab-ocf', {cloud => {'lab-ocf.bosh.director' => entry(5)}},
		contents => {'cloud|lab-ocf.bosh.director' => "director: yes\n"});
	my $parent = make_director('lab-mgmt', {});
	my $env = make_director_env(
		self_bosh => $self_bosh, parent => $parent,
		run_hook => sub {
			my ($s, $h, %p) = @_;
			return [] if $h eq 'runtime-config';
			return ("director: yes\n", $o{network_map});
		},
	);
	return ($env, $parent, $self_bosh);
}

subtest 'claims drift - an identical cloud config still gets its claims written when the record is stale' => sub {
	plan tests => 8;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	@director_calls = ();
	$stored_claims = $stale_claims;
	my ($env, $parent, $self_bosh) = claims_env(network_map => $fresh_claims);
	my ($out, $err) = output_from {
		Genesis::Commands::Bosh::bosh_configs_upload($env, $parent, yes => 1, type => 'cloud', name => 'lab-ocf.bosh.director')
	};
	my $all = $out.$err;
	like($all, qr/already up to date/, 'the cloud config is reported as up to date');
	ok(!defined(call_index('upload_config')), 'and is not uploaded');
	my $write = call_index('set_path');
	ok(defined $write, 'the claims are written all the same') or diag explain \@director_calls;
	is_deeply($write && [@{$director_calls[$write]}[1..2]], ['secret/exodus/lab-ocf/bosh/network', $fresh_claims],
		'to the director\'s own record, from the built network map');
	is_deeply($write && {@{$director_calls[$write]}[3..6]}, {flatten => 1, clear => 1}, 'with flatten and clear');
	my $read = call_index('get_path_strict', 'secret/exodus/lab-ocf/bosh/network');
	ok(defined $read && defined $write && $read < $write, 'after the stored record is read');
	ok(defined(call_index('clear_network_lock', 'lab-ocf')), 'and the lock is released');
	like($all, qr/network claims.*differ/s, 'and the output says the claims were out of date');
};

subtest 'claims drift - nothing is written when the config and the claims both match' => sub {
	plan tests => 4;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	@director_calls = ();
	# the empty claims of ocfp-0 are not stored, so they must not read as drift
	$stored_claims = {subnets => {'ocfp-2' => $fresh_claims->{subnets}{'ocfp-2'}}};
	my ($env, $parent) = claims_env(network_map => {subnets => {%{$fresh_claims->{subnets}}, 'ocfp-0' => {claims => {}}}});
	my ($out, $err) = output_from {
		Genesis::Commands::Bosh::bosh_configs_upload($env, $parent, yes => 1, type => 'cloud', name => 'lab-ocf.bosh.director')
	};
	like($out.$err, qr/already up to date/, 'the cloud config is reported as up to date');
	ok(!defined(call_index('upload_config')), 'nothing is uploaded');
	ok(!defined(call_index('set_path')), 'and no claims are written');
	ok(defined(call_index('get_path_strict', 'secret/exodus/lab-ocf/bosh/network')), 'though the stored record was compared');
};

subtest 'claims drift - a cloud config that is not the director\'s own is checked the same way' => sub {
	plan tests => 3;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	@director_calls = ();
	$stored_claims = $stale_claims;
	my $director = make_director('parent', {cloud => {'test-env.cf' => entry(3)}}, contents => {'cloud|test-env.cf' => "azs: []\n"});
	my $env = make_env(hooks => {'cloud-config' => 1}, cloud => "azs: []\n", network_map => $fresh_claims);
	output_from { Genesis::Commands::Bosh::bosh_configs_upload($env, $director, yes => 1, type => 'cloud') };
	ok(!defined(call_index('upload_config')), 'the identical config is not uploaded');
	my $write = call_index('set_path');
	ok(defined $write, 'its claims are written');
	is($write && $director_calls[$write][1], 'secret/exodus/parent/bosh/network', 'under the director that holds it');
};

subtest 'claims drift - a failed claims write tells the operator how to repair it' => sub {
	plan tests => 4;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	my $failing = mock "Mock::BoshConfigs::DriftVault" => {
		get_path_strict => sub { return $stale_claims },
		set_path => sub { die "vault sealed\n" },
	};
	my $self_bosh = make_director('lab-ocf', {cloud => {'lab-ocf.bosh.director' => entry(5)}},
		contents => {'cloud|lab-ocf.bosh.director' => "director: yes\n"});
	my $parent = make_director('lab-mgmt', {});
	my $env = make_director_env(
		self_bosh => $self_bosh, parent => $parent, vault => $failing,
		run_hook => sub { my ($s, $h) = @_; return $h eq 'runtime-config' ? [] : ("director: yes\n", $fresh_claims) },
	);
	@director_calls = ();
	my $message;
	eval { output_from { Genesis::Commands::Bosh::bosh_configs_upload($env, $parent, yes => 1, type => 'cloud', name => 'lab-ocf.bosh.director') }; 1 }
		or $message = $@ =~ s/\s+/ /gr;
	like($message, qr/network map could not be updated.*vault sealed/s, 'the write failure is reported with its cause');
	like($message, qr/genesis lab-ocf bosh-configs upload --type cloud --name lab-ocf\.bosh\.director -y/,
		'with the command that repairs it');
	like($message, qr/already up to date on the director and writes the claims/, 'and what that command does');
	ok(!$self_bosh->network_locked_by_me, 'and the lock is released');
};

# ---------------------------------------------------------------------------
# reading the stored claims before they are rewritten
# ---------------------------------------------------------------------------
# The write clears the network record before it fills it, so a record that
# could not be read must stop the upload rather than read as empty, and an
# operator is shown what a write changes before it happens.

# missing_claims_env - a director environment whose cloud config the director
# does not hold yet, so an upload runs
sub missing_claims_env {
	my (%o) = @_;
	my $self_bosh = make_director('lab-ocf', {});
	my $parent = make_director('lab-mgmt', {});
	my $env = make_director_env(
		self_bosh => $self_bosh, parent => $parent, ($o{vault} ? (vault => $o{vault}) : ()),
		run_hook => sub { my ($s, $h) = @_; return $h eq 'runtime-config' ? [] : ("director: yes\n", $fresh_claims) },
	);
	return ($env, $parent, $self_bosh);
}

subtest 'claims read - a failed read of the stored claims stops the upload before anything is written' => sub {
	plan tests => 12;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	$claims_read_error = "Could not read secret/exodus/lab-ocf/bosh/network from vault at https://vault.example.com:8200: connection refused\n";
	$stored_claims = $stale_claims;

	for my $case ('a cloud config to upload', 'a cloud config that is already up to date') {
		@director_calls = ();
		my ($env, $parent, $self_bosh) = $case =~ /already/ ? claims_env(network_map => $fresh_claims) : missing_claims_env();
		my $message;
		eval {
			output_from {
				Genesis::Commands::Bosh::bosh_configs_upload($env, $parent, yes => 1, type => 'cloud', name => 'lab-ocf.bosh.director')
			};
			1;
		} or $message = $@ =~ s/\s+/ /gr;
		like($message, qr/Could not read secret\/exodus\/lab-ocf\/bosh\/network from vault.*connection refused/,
			"$case: the failure names the path and the error");
		ok(!defined(call_index('set_path')), "$case: no claims are written");
		ok(!defined(call_index('upload_config')), "$case: nothing is uploaded");
		ok(defined(call_index('clear_network_lock', 'lab-ocf')), "$case: the lock is released");
		ok(!$self_bosh->network_locked_by_me, "$case: so no lock of ours is left");
		ok(!defined(call_index('delete_config')), "$case: and nothing is deleted");
	}
	$claims_read_error = undef;
	$stored_claims = {};
};

subtest 'claims read - a record that was never written builds from empty and every claim is shown as added' => sub {
	plan tests => 5;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	@director_calls = ();
	$stored_claims = undef;
	my ($env, $parent) = missing_claims_env();
	my ($out, $err) = output_from {
		Genesis::Commands::Bosh::bosh_configs_upload($env, $parent, yes => 1, type => 'cloud', name => 'lab-ocf.bosh.director')
	};
	my $all = $out.$err;
	ok(defined(call_index('upload_config', 'lab-ocf', 'cloud', 'lab-ocf.bosh.director')), 'the upload goes ahead');
	my $write = call_index('set_path');
	is_deeply($write && $director_calls[$write][2], $fresh_claims, 'and the network map is written');
	like($all, qr/cf \(ocfp-2\): adds 10\.61\.148\.232-10\.61\.148\.245/, 'the summary shows a claim with no record as added');
	unlike($all, qr/removes/, 'and removes nothing');
	like($all, qr/compilation \(ocfp-2\): adds 10\.61\.148\.228,10\.61\.148\.230-10\.61\.148\.231,10\.61\.148\.248/,
		'with every address of the network');
	$stored_claims = {};
};

subtest 'claims read - the summary of the change prints before the claims are written' => sub {
	plan tests => 7;
	no warnings 'redefine';
	local *Genesis::Commands::Bosh::spruce_diff = \&plain_diff;
	@director_calls = ();
	$stored_claims = $stale_claims;
	my $sealed = mock "Mock::BoshConfigs::SummaryVault" => {
		get_path_strict => sub { return $stale_claims },
		set_path => sub { push @director_calls, ['set_path']; die "vault sealed\n" },
	};
	my ($env, $parent) = missing_claims_env(vault => $sealed);
	my ($out, $err, $message);
	eval {
		($out, $err) = output_from {
			eval {
				Genesis::Commands::Bosh::bosh_configs_upload($env, $parent, yes => 1, type => 'cloud', name => 'lab-ocf.bosh.director')
			} or print STDOUT "[died] ".($@ =~ s/\s+/ /gr);
		};
		1;
	};
	my $all = $out.$err;
	my $summary = index($all, 'compilation (ocfp-2)');
	my $submit  = index($all, 'submitting network claims');
	ok($summary >= 0, 'a summary is printed') or diag $all;
	ok($submit > $summary, 'before the claims are submitted');
	like($all, qr/compilation \(ocfp-2\): adds 10\.61\.148\.248, removes 10\.61\.148\.229/, 'it shows the addresses a network gains and loses');
	unlike($all, qr/cf \(ocfp-2\)/, 'and says nothing of a network whose claim is unchanged');
	like($all, qr/vault sealed/, 'and the write still fails on a sealed vault');
	ok(defined(call_index('set_path')), 'the write was attempted');
	unlike($all, qr/\[y\|n\].*\[y\|n\]/s, 'with no confirmation prompt added');
};

subtest 'director config - delete refuses the director config' => sub {
	plan tests => 2;
	@director_calls = ();
	my $self_bosh = make_director('lab-ocf', {cloud => {'lab-ocf.bosh.director' => entry(5)}});
	my $parent    = make_director('lab-mgmt', {});
	my $env = make_director_env(self_bosh => $self_bosh, parent => $parent);
	throws_ok {
		Genesis::Commands::Bosh::bosh_configs_delete($env, $parent, yes => 1, name => 'lab-ocf.bosh.director')
	} qr/lab-ocf\.bosh\.director.*compilation network/s, 'delete refuses, saying the compilation network depends on it';
	ok(!defined(call_index('delete_config')), 'and nothing is deleted');
};

done_testing;
