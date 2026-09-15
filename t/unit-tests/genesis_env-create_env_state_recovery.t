#!/usr/bin/env perl
use strict;
use warnings;

# `bosh create-env` rewrites the state file while it works, so an attempt that
# died partway still recorded what it had already changed on the IaaS.  These
# tests cover the selection that makes the next deploy, and the next
# terminate, build on that state instead of on the state the last successful
# deploy left behind.

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Exception;
use File::Temp qw/tempdir/;
use Time::Piece;

use Genesis;
use_ok 'Genesis::Config';
provide_rc();
use_ok 'Genesis::Env';
use_ok 'Genesis::Env::Deployment';
use_ok 'Genesis::Env::DeploymentManager';

my $workdir = tempdir(CLEANUP => 1);
my $seq = 0;

# A deployment record in the shape Genesis writes one: artifacts as a hash of
# local file paths, keyed by type.
sub make_record {
	my (%opts) = @_;
	my $name = $opts{name} // 'test-env';
	my $dir = "$workdir/record-" . ++$seq;
	mkdir_or_fail($dir);

	my %artifacts;
	for my $type (keys %{$opts{artifacts} // {}}) {
		my $file = "$dir/$name-$type." . ($type eq 'state' ? 'json' : 'yml');
		$file = "$dir/$name.yml" if $type eq 'manifest';
		mkfile_or_fail($file, $opts{artifacts}{$type});
		$artifacts{$type} = $file;
	}

	return bless {
		env => Mock->new(name => $name),
		timestamp => $opts{timestamp},
		data => {
			action => $opts{action} // 'deploy',
			result => $opts{result} // 'success',
			reason => 'testing',
			genesis_version => '3.2.0',
			user => {shell => '/bin/bash'},
			kit => {id => 'test/1.0', name => 'test', version => '1.0', is_dev => 0, features => []},
			manifest => {type => 'bosh', sha2 => 'abc123'},
		},
		artifacts => (keys %artifacts)
			? {format => 'local-file-hash', data => \%artifacts}
			: undef,
	}, 'Genesis::Env::Deployment';
}

sub make_manager {
	my (@records) = @_;
	# Newest first, the order _all() guarantees.
	return bless {
		env => Mock->new(name => 'test-env'),
		__all_deployments => [@records],
	}, 'Genesis::Env::DeploymentManager';
}

# ===========================================================================
subtest 'has_artifact answers without fetching anything' => sub {
	plan tests => 7;

	my $record = make_record(
		timestamp => '20260101120000',
		artifacts => {state => '{"vm":"i-123"}', manifest => "---\nname: test-env\n"},
	);
	ok($record->has_artifact('state'), 'finds an artifact by type');
	ok($record->has_artifact('manifest'), 'finds the manifest too');
	ok($record->has_artifact('test-env-state.json'), 'finds an artifact by filename');
	ok(!$record->has_artifact('store'), 'says no to an artifact it does not carry');

	my $bare = make_record(timestamp => '20260101110000');
	ok(!$bare->has_artifact('state'), 'a record with no artifacts carries nothing');
	is_deeply([$bare->artifact_types], [], 'artifact_types is empty rather than fatal');
	is_deeply([$bare->artifact_filenames], [], 'artifact_filenames is empty rather than fatal');
};

# ===========================================================================
subtest 'latest_with_artifacts prefers the newest attempt that archived one' => sub {
	plan tests => 8;

	my $failed = make_record(
		timestamp => '20260101130000', result => 'failed',
		artifacts => {state => '{"vm":"new"}', manifest => "---\nname: new\n"},
	);
	my $succeeded = make_record(
		timestamp => '20260101120000',
		artifacts => {state => '{"vm":"old"}', manifest => "---\nname: old\n"},
	);
	my $mgr = make_manager($failed, $succeeded);

	is($mgr->latest_with_artifacts(action => 'deploy'), $failed,
		'the failed attempt wins, because its state file is the newer one');
	is($mgr->latest, $succeeded,
		'latest() still skips the failure, so the manifest diff stays honest');
	is($mgr->latest_with_artifacts(action => 'deploy', artifacts => ['state', 'manifest']),
		$failed, 'the manifest that pairs with that state comes from the same record');

	# A failure that never got as far as archiving a state file must not
	# displace the deploy that did.
	my $stateless = make_record(
		timestamp => '20260101140000', result => 'failed',
		artifacts => {manifest => "---\nname: nostate\n"},
	);
	is(make_manager($stateless, $succeeded)->latest_with_artifacts(action => 'deploy'),
		$succeeded, 'a failure with no state file is passed over');

	my $terminated = make_record(
		timestamp => '20260101150000', action => 'terminate', result => 'failed',
		artifacts => {state => '{"vm":"gone"}'},
	);
	is(make_manager($terminated, $succeeded)->latest_with_artifacts(action => 'deploy'),
		$succeeded, 'the action filter keeps terminations out of the deploy search');
	is(make_manager($terminated, $succeeded)->latest_with_artifacts(action => 'terminate'),
		$terminated, 'and finds them when they are what was asked for');

	is(make_manager()->latest_with_artifacts(action => 'deploy'), undef,
		'no records at all means nothing to recover');

	throws_ok {$mgr->latest_with_artifacts(bogus => 1)} qr/Invalid options: bogus/,
		'an unknown option is a bug, not a silent pass';
};

# ===========================================================================
subtest '_recovered_create_env_state extracts the state of a failed attempt' => sub {
	plan tests => 9;

	my $failed = make_record(
		timestamp => '20260101130000', result => 'failed',
		artifacts => {
			state => '{"current_vm_cid":"vm-new"}',
			store => "---\nstore: new\n",
			manifest => "---\nname: new\n",
		},
	);
	my $succeeded = make_record(
		timestamp => '20260101120000',
		artifacts => {state => '{"current_vm_cid":"vm-old"}', manifest => "---\nname: old\n"},
	);

	my $mgr = make_manager($failed, $succeeded);
	my $env = bless {name => 'test-env', __tmp => "$workdir/env-work"}, 'Genesis::Env';
	mkdir_or_fail($env->{__tmp});

	no warnings qw/redefine once/;
	local *Genesis::Env::deployments = sub {$mgr};
	local *Genesis::Env::manifest_store = sub {'hybrid'};

	my $recovered = $env->_recovered_create_env_state();
	ok($recovered->{state}, 'a state file came back');
	is(slurp($recovered->{state}), '{"current_vm_cid":"vm-new"}',
		'it is the state the failed attempt wrote, not the older one');
	is(slurp($recovered->{store}), "---\nstore: new\n",
		'the credentials store travels with it');
	is($recovered->{timestamp}, '20260101130000', 'the record it came from is named');

	# Nothing to recover once a deploy has succeeded on top of the failure.
	my $clean = make_manager($succeeded, $failed);
	local *Genesis::Env::deployments = sub {$clean};
	is_deeply($env->_recovered_create_env_state(), {},
		'a successful newest deploy leaves nothing to recover');

	# Repository-mode environments keep their state on disk, refreshed by the
	# failed deploy itself, so there is nothing to pull out of the archive.
	local *Genesis::Env::deployments = sub {$mgr};
	local *Genesis::Env::manifest_store = sub {'repository'};
	is_deeply($env->_recovered_create_env_state(), {},
		'repository mode reads its state from the repository');

	# A failed attempt that archived a state file but no store.
	my $no_store = make_record(
		timestamp => '20260101140000', result => 'failed',
		artifacts => {state => '{"current_vm_cid":"vm-solo"}'},
	);
	local *Genesis::Env::deployments = sub {make_manager($no_store, $succeeded)};
	local *Genesis::Env::manifest_store = sub {'hybrid'};
	my $solo = $env->_recovered_create_env_state();
	is(slurp($solo->{state}), '{"current_vm_cid":"vm-solo"}', 'the state still comes back');
	is($solo->{store}, undef, 'and no store is invented for it');
	is($solo->{timestamp}, '20260101140000', 'from the attempt that wrote it');
};

# ===========================================================================
subtest '_copy_cached_files_to_repository keeps the repository state current' => sub {
	plan tests => 4;

	my $repo = "$workdir/repo";
	mkdir_or_fail($repo);
	mkdir_or_fail("$repo/.genesis");
	mkdir_or_fail("$repo/.genesis/manifests");

	my $cache = "$workdir/cache";
	mkdir_or_fail($cache);
	mkfile_or_fail("$cache/test-env-state.json", '{"current_vm_cid":"vm-new"}');

	my $env = bless {name => 'test-env'}, 'Genesis::Env';

	no warnings qw/redefine once/;
	local *Genesis::Env::path = sub {"$repo/$_[1]"};
	local *Genesis::Env::deployment_cache_path_lookup = sub {
		my ($self, $descriptor) = @_;
		return "$cache/test-env-state.json" if $descriptor eq 'state';
		return "$cache/test-env-store.yml";  # never written, so never copied
	};

	ok($env->_copy_cached_files_to_repository('state', 'store'), 'the copy reports success');
	ok(-f "$repo/.genesis/manifests/test-env-state.json", 'the state file landed in the repository');
	is(slurp("$repo/.genesis/manifests/test-env-state.json"), '{"current_vm_cid":"vm-new"}',
		'with the contents the failed attempt wrote');
	ok(!-f "$repo/.genesis/manifests/test-env-store.yml",
		'a descriptor with no file on disk is skipped');
};

done_testing;
