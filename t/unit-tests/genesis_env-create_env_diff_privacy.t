#!/usr/bin/env perl
# Before a create-env redeploy, Genesis compares the last deployed manifest
# and vars file with the current ones.  Both hold the director's own
# credentials, and a rotated password would show as its old and new value,
# so the comparison never shows a value, on the terminal or in a log.  Any
# key or name in them can have come from vault, so manifest changes are
# named by schema keys and positions, and vars file changes are counted.
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

subtest 'changed_paths names schema paths and never values' => sub {
	my @changes = Genesis::changed_paths(
		{name => 'bosh', releases => [{name => 'bosh', version => '1'}],
		 instance_groups => [{name => 'bosh', instances => 1, jobs => [{name => 'director', release => 'bosh'}]}],
		 update => {canaries => 1}},
		{name => 'bosh', releases => [{name => 'bosh', version => '2'}, {name => 'cpi', version => '1'}],
		 instance_groups => [{name => 'bosh', instances => 2, jobs => [{name => 'director', release => 'bosh'}], vm_type => 'large'}]},
	);
	is_deeply([sort @changes], [sort(
		'~ releases.0.version', '+ releases.1', '~ instance_groups.0.instances', '+ instance_groups.0.vm_type', '- update',
	)], 'each added, removed, and changed path is listed by schema keys and positions');
	is_deeply([Genesis::changed_paths({a => [1]}, {a => [1]})], [], 'identical data has no changes');
};

subtest 'names and keys the schema does not own are never shown' => sub {
	# Any name or key in an evaluated or archived manifest can have come
	# from vault or a parameter.
	my ($group, $user, $new_user, $key) = map {fake_secret($_)} qw/group-name user-name new-user-name property-key/;
	my @changes = Genesis::changed_paths(
		{
			instance_groups => [{name => $group, jobs => [{name => 'director', properties => {users => [{name => $user, password => 'a'}], $key => 'x'}}], networks => [{name => 'default', static_ips => ['10.0.0.6']}]}],
			properties => {$key => {a => 1}},
		},
		{
			instance_groups => [{name => $group, jobs => [{name => 'director', properties => {users => [{name => $new_user, password => 'b'}]}}], networks => [{name => 'default', static_ips => ['10.0.0.7']}]}],
			properties => {$key => {a => 2}, other => 1},
		},
	);
	unlike(join("\n", @changes), qr/\Q$group\E|\Q$user\E|\Q$new_user\E|\Q$key\E|director|default/, 'no name or free-form key is shown');
	is_deeply([sort @changes], [sort(
		'~ instance_groups.0.jobs.0.properties (2 paths changed, 1 path removed)',
		'~ instance_groups.0.networks.0.static_ips.0',
		'~ properties (1 path changed, 1 path added)',
	)], 'named lists are labeled by position, and changes below free-form keys are counted');
	is(Genesis::change_counts({properties => {$key => 1}}, {properties => {$key => 2, other => 1}}),
		'1 path changed, 1 path added', 'change_counts still counts every path');
};

subtest 'a named list is matched by name and labeled by position' => sub {
	my ($x, $y) = map {fake_secret("group-$_")} qw/x y/;
	is_deeply([Genesis::changed_paths(
		{instance_groups => [{name => $x, instances => 1}, {name => $y, instances => 1}]},
		{instance_groups => [{name => $y, instances => 1}, {name => $x, instances => 1}]},
	)], [], 'a reordered list is not a change');
	is_deeply([Genesis::changed_paths(
		{instance_groups => [{name => $x, instances => 1}, {name => $y, instances => 1}]},
		{instance_groups => [{name => $y, instances => 2}]},
	)], ['- instance_groups.0', '~ instance_groups.0.instances'],
		'a removed item takes its old place and a kept one its new place');
};

subtest 'equal booleans and numbers are not changes' => sub {
	my $decode = sub { JSON::PP->new->decode($_[0]) };
	is_deeply([Genesis::changed_paths($decode->('{"a":true,"b":false,"c":1,"d":2.50}'), $decode->('{"a":true,"b":false,"c":1.0,"d":2.5}'))], [],
		'the same boolean or number is unchanged');
	is_deeply([Genesis::changed_paths($decode->('{"update":{"serial":true,"canaries":1,"max_in_flight":"x"}}'), $decode->('{"update":{"serial":false,"canaries":"1","max_in_flight":"y"}}'))],
		['~ update.canaries', '~ update.max_in_flight', '~ update.serial'],
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
	like($log, qr/~ properties \(1 path changed\)/, 'the change is counted under the last schema path');
	unlike($log, qr/[~+-] \S*(?:director|port)\b/, 'and no key below it is named');
	like($log, qr/bosh variables:\s+1 path changed,\s+1 path added/, 'the vars file\'s changes are counted');
	unlike($log, qr/admin_password|nats_password/, 'and its keys are not named');
};

subtest 'identical files report no differences' => sub {
	my $log = capture_trace {
		$env->_show_create_env_differences("$dir/current.yml", "$dir/current.yml", undef, undef, 'exodus');
	};
	like($log, qr/no differences found/, 'no differences are reported');
};

done_testing;
