#!/usr/bin/env perl
# Proves T474's run half (D144): a propagate run in a pipeline task, handed the
# Concourse URL, team, pipeline and webhook token, asks Concourse to check the
# resource of each deployment branch it pushed, once, naming the resource as
# the compiled pipeline names it.  A Concourse that answers an error has the
# run warn and still succeed, and a run handed none of it asks nothing.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use Test::TCP ();
use IO::Socket::IP;

use Genesis qw/slurp/;
use Genesis::CI::Compiler::PipelineDescriptor;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

my $TOKEN = 'harness-webhook-token';

# A Concourse stand-in: each request's first line is appended to the log, and
# the status it answers is read from the status file on every request.
my $tmp    = helper::workdir();
my $log    = "$tmp/concourse-requests.log";
my $status = "$tmp/concourse-status";
helper::put_file($status, "201\n");
my $server = Test::TCP->new(code => sub {
	my $port = shift;
	my $sock = IO::Socket::IP->new(LocalAddr => '127.0.0.1', LocalPort => $port,
		Proto => 'tcp', Listen => 5, ReuseAddr => 1) or die "no listener: $!\n";
	while (my $c = $sock->accept) {
		my $line = <$c> // '';
		while (my $h = <$c>) { last if $h =~ /^\r?\n$/ }
		open my $fh, '>>', $log; print $fh $line; close $fh;
		chomp(my $code = slurp($status));
		print $c "HTTP/1.1 $code Answered\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
		close $c;
	}
});

sub requests { -f $log ? grep {length} split /\n/, slurp($log) : () }

sub propagate_in_task {
	my ($h, %opts) = @_;
	helper::put_file($log, '');
	local $ENV{GENESIS_CONCOURSE_URL}           = $opts{bare} ? undef : 'http://127.0.0.1:' . $server->port;
	local $ENV{GENESIS_CONCOURSE_TEAM}          = $opts{bare} ? undef : 'main';
	local $ENV{GENESIS_CONCOURSE_PIPELINE}      = $opts{bare} ? undef : 'harness';
	local $ENV{GENESIS_CONCOURSE_WEBHOOK_TOKEN} = $opts{bare} ? undef : $TOKEN;
	my ($out, $err, $exit) = run_genesis($h, {pipeline_task => 'propagate', restore => 0}, 'propagate');
	return ($exit, unfolded($out, $err));
}

sub due_to_qa {
	my ($h, $n) = @_;
	init_branch($h, 'qa');
	return publish_from_b($h, files => {'ops/shared.yml' => "---\nshared: $n\n"},
		message => "a change for qa ($n)");
}

my $RESOURCE = Genesis::CI::Compiler::PipelineDescriptor->branch_resource_name('qa');

subtest 'a pushed branch has its resource checked' => sub {
	my $h = make_harness(envs => ['qa'], applied => 1, kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	due_to_qa($h, 1);
	my ($exit, $said) = propagate_in_task($h);
	is($exit, 0, 'the run succeeds') or return diag($said);
	is_deeply([requests()],
		["POST /api/v1/teams/main/pipelines/harness/resources/$RESOURCE/check/webhook?webhook_token=$TOKEN HTTP/1.1\r"],
		'one check request, for the branch it pushed, carrying the token') or diag($said);
	unlike($said, qr/\Q$TOKEN\E/, 'and the token is never printed');
};

subtest 'a Concourse that answers an error has the run warn and succeed' => sub {
	my $h = make_harness(envs => ['qa'], applied => 1, kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	due_to_qa($h, 2);
	helper::put_file($status, "500\n");
	my ($exit, $said) = propagate_in_task($h);
	helper::put_file($status, "201\n");
	is($exit, 0, 'the run still succeeds') or diag($said);
	like($said, qr/\Q$RESOURCE\E.*500/, 'warning with the resource and the status');
};

subtest 'a run handed nothing asks nothing' => sub {
	my $h = make_harness(envs => ['qa'], applied => 1, kit => 'omega-v2.7.0', tracked => ['ops/shared.yml']);
	due_to_qa($h, 3);
	my ($exit, $said) = propagate_in_task($h, bare => 1);
	is($exit, 0, 'the run succeeds') or diag($said);
	is_deeply([requests()], [], 'and makes no request');
};

done_testing;
