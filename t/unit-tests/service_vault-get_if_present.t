#!/usr/bin/env perl
# Proves the reader half of T144: a read that tells an absent path from a
# vault that answered an error.  get answers {} for both, so a caller that
# must refuse on an error and read on an absence cannot use it.  safe exits
# 1 either way and says which in its message, and nothing else tells them
# apart.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use Test::More;

use_ok 'Service::Vault';
use Genesis;

sub make_vault {
	return Service::Vault->new(
		'https://vault.example.com:8200', 'test-vault', 1, '', undef, '/secret/'
	);
}

# Per-instance stub, so nothing leaks between subtests.
sub stub_query {
	my ($v, $out, $rc, $err) = @_;
	$v->{__test_query} = sub { return ($out, $rc // 0, $err // '') };
}

{
	no warnings 'redefine', 'once';
	*Service::Vault::query = sub {
		my $self = shift;
		shift if ref($_[0]) eq 'HASH';
		return $self->{__test_query}->(@_) if $self->{__test_query};
		return ('', 1, 'no stub installed');
	};
}

subtest 'a path that holds a record answers its fields' => sub {
	plan tests => 1;
	my $v = make_vault();
	stub_query($v, "control_commit: abc123\nprovider: manual\n", 0, '');
	is_deeply($v->get_if_present('secret/exodus_pipelines/bosh'),
		{control_commit => 'abc123', provider => 'manual'},
		'the fields come back as a hash');
};

subtest 'a path that holds nothing answers undef' => sub {
	plan tests => 1;
	my $v = make_vault();
	stub_query($v, '', 1,
		"!! no secret exists at path `secret/exodus_pipelines/bosh`\n");
	is($v->get_if_present('secret/exodus_pipelines/bosh'), undef,
		'an absence is not an error');
};

subtest 'a record deleted under KV v2 is an absence too' => sub {
	plan tests => 2;
	# KV v2 keeps a deleted secret's path and answers for its latest version,
	# which is what a safe rm or a move away leaves behind.
	my $v = make_vault();
	stub_query($v, '', 1,
		"!! version 1 of secret `secret/exodus/_pipelines/bosh` has been deleted\n");
	is($v->get_if_present('secret/exodus/_pipelines/bosh'), undef,
		'a deleted version reads as nothing there');
	stub_query($v, '', 1,
		"!! version 3 of secret `secret/exodus/_pipelines/bosh` has been destroyed\n");
	is($v->get_if_present('secret/exodus/_pipelines/bosh'), undef,
		'and so does a destroyed one');
};

subtest 'a vault that answers an error is not an absence' => sub {
	plan tests => 2;
	my $v = make_vault();
	stub_query($v, '', 1, "!! permission denied\n");
	my $got = eval {$v->get_if_present('secret/exodus_pipelines/bosh'); 1};
	ok(!$got, 'the read dies rather than answering');
	like($@, qr/permission denied/, 'and says what the vault answered');
};

subtest 'an error with no message still dies' => sub {
	plan tests => 1;
	my $v = make_vault();
	stub_query($v, '', 2, '');
	ok(!eval {$v->get_if_present('secret/exodus_pipelines/bosh'); 1},
		'a failure safe did not explain is not taken for an absence');
};

done_testing;
