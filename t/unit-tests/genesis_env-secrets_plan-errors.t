#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;

# Test that Genesis::Env::Secrets::Plan reports the safe command's stderr
# (not just stdout) when adding, rotating or removing a secret fails.
#
# safe writes its errors to stderr and leaves stdout empty, and the vault
# service returns them as (stdout, rc, stderr).  The plan needs to pass
# both on to the error notification, otherwise the user only sees a bare
# "failed!" with no reason.

use_ok 'Genesis::Config';
use_ok 'Genesis::Env::Secrets::Plan';

# Stand-ins for the collaborators the plan uses; only what the code paths
# under test touch is implemented.
{
	package Test::Service;
	sub new   { my ($c, @r) = @_; bless {responses => [@r]}, $c }
	sub query { my $self = shift; return @{ shift @{$self->{responses}} } }

	package Test::Store;
	sub new        { bless {service => $_[1]}, $_[0] }
	sub service    { $_[0]{service} }
	sub base       { 'secret/test/env/dep/' }
	sub fill       { }
	sub clear_data { }

	package Test::Config;
	sub new { bless {}, shift }
	sub get { 0 }

	package Test::Env;
	sub new    { bless {}, shift }
	sub notify { }
	sub top    { $_[0] }
	sub config { Test::Config->new }

	package Test::Credhub;
	sub new     { bless {}, shift }
	sub preload { }

	package Genesis::Secret::TestFake;
	sub new                { bless {}, shift }
	sub describe           { ('ssl/server', 'X.509 certificate', 'signed by ssl/ca') }
	sub path               { 'ssl/server' }
	sub all_paths          { ('ssl/server') }
	sub has_value          { 0 }
	sub exists             { 1 }
	sub from_manifest      { 0 }
	sub reset              { }
	sub is_command_interactive { 0 }
	sub get_safe_command_for   { ('x509', 'issue', 'secret/test/env/dep/ssl/server') }
	sub process_command_output { my ($s, $action, @r) = @_; @r }

	# Records the done-item notifications instead of rendering them
	package Test::Plan;
	our @ISA = ('Genesis::Env::Secrets::Plan');
	sub notify {
		my ($self, $action, @args) = @_;
		shift @args if ref($args[0]) eq 'HASH';
		my ($state, %args) = @args;
		push @{$self->{done}}, {%args} if $state eq 'done-item';
		return {};
	}
}

$Genesis::RC = Genesis::Config->new("$ENV{HOME}/.genesis/config");

sub plan_with {
	my @responses = @_;
	my $store = Test::Store->new(Test::Service->new(@responses));
	my $plan = Test::Plan->new(Test::Env->new, $store, Test::Credhub->new);
	$plan->{done} = [];
	$plan->{secrets} = [Genesis::Secret::TestFake->new];
	return $plan;
}

my $missing = "!! no secret exists at path `secret/test/env/dep/ssl/ca`";

subtest 'add reports stderr on failure' => sub {
	my $plan = plan_with(['', 1, $missing]);
	$plan->generate_secrets;
	my ($done) = grep {$_->{result} eq 'error'} @{$plan->{done}};
	ok $done, "error result was reported";
	is $done->{msg}, $missing, "message carries safe's stderr";
};

subtest 'add reports both stdout and stderr on failure' => sub {
	my $plan = plan_with(['some output', 1, $missing]);
	$plan->generate_secrets;
	my ($done) = grep {$_->{result} eq 'error'} @{$plan->{done}};
	is $done->{msg}, "some output\n$missing", "message carries stdout and stderr";
};

subtest 'add reports stdout alone without a blank line' => sub {
	my $plan = plan_with(['some output', 1, '']);
	$plan->generate_secrets;
	my ($done) = grep {$_->{result} eq 'error'} @{$plan->{done}};
	is $done->{msg}, "some output", "message is only stdout";
};

subtest 'rotate reports stderr on failure' => sub {
	my $plan = plan_with(['', 1, $missing]);
	$plan->regenerate_secrets(no_prompt => 1);
	my ($done) = grep {$_->{result} eq 'error'} @{$plan->{done}};
	ok $done, "error result was reported";
	is $done->{msg}, $missing, "message carries safe's stderr";
};

subtest 'remove reports stderr on failure' => sub {
	my $plan = plan_with(['', 1, $missing]);
	$plan->remove_secrets(no_prompt => 1);
	my ($done) = grep {$_->{result} eq 'error'} @{$plan->{done}};
	ok $done, "error result was reported";
	is $done->{msg}, $missing, "message carries safe's stderr";
};

done_testing;
