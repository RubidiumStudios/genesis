#!/usr/bin/env perl
# Before a create-env redeploy, Genesis compares the last deployed manifest
# and vars file with the current ones.  Both hold the director's own
# credentials, and a rotated password would show as its old and new value,
# so the comparison lists the paths that were added, removed, or changed,
# and never a value, on the terminal or in a log.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Genesis::Env;
use JSON::PP;

my $dir = tempdir(CLEANUP => 1);
my $env = bless({name => 'fake-env'}, 'Genesis::Env');

subtest 'changed_paths names paths and never values' => sub {
	my @changes = Genesis::changed_paths(
		{a => 1, b => {c => 'x', d => 'y'}, list => [1, 2], instance_groups => [{name => 'bosh', p => 'old'}], gone => 1},
		{a => 1, b => {c => 'z', d => 'y'}, list => [1, 3, 4], instance_groups => [{name => 'bosh', p => 'new'}], added => {deep => 1}},
	);
	is_deeply([sort @changes], [sort(
		'+ added', '- gone', '~ b.c', '~ instance_groups.bosh.p', '~ list.1', '+ list.2',
	)], 'each added, removed, and changed path is listed');
	is_deeply([Genesis::changed_paths({a => [1]}, {a => [1]})], [], 'identical data has no changes');
};

subtest 'a list is labeled by name only where the manifest schema names it' => sub {
	my $user = fake_secret('user-name');
	my $new_user = fake_secret('new-user-name');
	my @changes = Genesis::changed_paths(
		{
			instance_groups => [{name => 'bosh', jobs => [{name => 'director', properties => {users => [{name => $user, password => 'a'}]}}], networks => [{name => 'default', static_ips => ['10.0.0.6']}]}],
			releases => [{name => 'bosh', version => '1'}],
			properties => {users => [{name => $user, password => 'a'}, {name => 'two', password => 'b'}]},
		},
		{
			instance_groups => [{name => 'bosh', jobs => [{name => 'director', properties => {users => [{name => $new_user, password => 'b'}]}}], networks => [{name => 'default', static_ips => ['10.0.0.7']}]}],
			releases => [{name => 'bosh', version => '2'}],
			properties => {users => [{name => $user, password => 'c'}, {name => 'two', password => 'b'}]},
		},
	);
	unlike(join("\n", @changes), qr/\Q$user\E|\Q$new_user\E/, 'a name in a list the schema does not name is never shown');
	is_deeply([sort @changes], [sort(
		'~ instance_groups.bosh.jobs.director.properties.users.0.name',
		'~ instance_groups.bosh.jobs.director.properties.users.0.password',
		'~ instance_groups.bosh.networks.default.static_ips.0',
		'~ properties.users.0.password',
		'~ releases.bosh.version',
	)], 'instance groups, jobs, networks, and releases are labeled by name, and other lists by index');
};

subtest 'equal booleans and numbers are not changes' => sub {
	my $decode = sub { JSON::PP->new->decode($_[0]) };
	is_deeply([Genesis::changed_paths($decode->('{"a":true,"b":false,"c":1,"d":2.50}'), $decode->('{"a":true,"b":false,"c":1.0,"d":2.5}'))], [],
		'the same boolean or number is unchanged');
	is_deeply([sort(Genesis::changed_paths($decode->('{"a":true,"b":1,"c":"x"}'), $decode->('{"a":false,"b":"1","c":"y"}')))], ['~ a', '~ b', '~ c'],
		'a flipped boolean, a number become a string, and a changed string are changes');
};

subtest 'a create-env redeploy compares paths, not values' => sub {
	my ($old_pw, $new_pw, $old_var, $new_var, $added_var) = map {fake_secret("create-env-$_")}
		qw/old-password new-password old-var new-var added-var/;
	put_file("$dir/last.yml",      0600, "---\nname: bosh\nproperties:\n  director:\n    password: $old_pw\n    port: 25555\n");
	put_file("$dir/current.yml",   0600, "---\nname: bosh\nproperties:\n  director:\n    password: $new_pw\n    port: 25555\n");
	put_file("$dir/last-vars.yml", 0600, "---\nadmin_password: $old_var\n");
	put_file("$dir/vars.yml",      0600, "---\nadmin_password: $new_var\nnats_password: $added_var\n");
	my ($log, $stderr, $stdout) = capture_trace {
		$env->_show_create_env_differences(
			"$dir/last.yml", "$dir/current.yml", "$dir/last-vars.yml", "$dir/vars.yml", 'exodus'
		);
	};
	for my $value ($old_pw, $new_pw, $old_var, $new_var, $added_var) {
		unlike($log, qr/\Q$value\E/, 'no value is in the log');
		unlike($stderr.$stdout, qr/\Q$value\E/, 'or on the terminal');
	}
	like($log, qr/~ properties\.director\.password/, 'the changed manifest path is named');
	unlike($log, qr/director\.port/, 'an unchanged path is not');
	like($log, qr/~ admin_password/, 'the changed vars path is named');
	like($log, qr/\+ nats_password/, 'and the added one');
};

subtest 'identical files report no differences' => sub {
	my $log = capture_trace {
		$env->_show_create_env_differences("$dir/current.yml", "$dir/current.yml", undef, undef, 'exodus');
	};
	like($log, qr/no differences found/, 'no differences are reported');
};

done_testing;
