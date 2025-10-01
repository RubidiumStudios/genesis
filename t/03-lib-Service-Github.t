use strict;
use warnings;

use lib 'lib';
use lib 't';

use Test::More;
use Test::Exception;

BEGIN {
	use_ok 'Service::Github';
}

subtest 'Service::Github SSH key methods' => sub {
	plan tests => 5;

	subtest 'validate_ssh_key method' => sub {
		plan tests => 8;

		my $gh = Service::Github->new(domain => 'github.com');

		# Valid keys
		ok($gh->validate_ssh_key('ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA test@example.com'),
			'validates ssh-rsa key');
		ok($gh->validate_ssh_key('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG'),
			'validates ssh-ed25519 key');
		ok($gh->validate_ssh_key('ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY'),
			'validates ecdsa-sha2-nistp256 key');

		# Invalid keys
		ok(!$gh->validate_ssh_key('invalid key format'),
			'rejects invalid key format');
		ok(!$gh->validate_ssh_key('ssh-rsa'),
			'rejects incomplete key');
		ok(!$gh->validate_ssh_key(''),
			'rejects empty string');
		ok(!$gh->validate_ssh_key(undef),
			'rejects undef');
		ok(!$gh->validate_ssh_key('BEGIN RSA PRIVATE KEY'),
			'rejects private key format');
	};

	subtest 'get_user_ssh_keys with GitHub user' => sub {
		plan tests => 4;

		my $gh = Service::Github->new(domain => 'github.com');
		my ($keys, $err) = $gh->get_user_ssh_keys('dennisjbell');

		ok(!$err, 'no error fetching GitHub user keys');
		ok($keys, 'returned keys array');
		isa_ok($keys, 'ARRAY', 'keys is an array reference');
		ok(scalar(@$keys) > 0, 'found at least one key for dennisjbell');
	};

	subtest 'get_user_ssh_keys with GitLab user' => sub {
		plan tests => 4;

		my $gitlab = Service::Github->new(domain => 'gitlab.com');
		my ($keys, $err) = $gitlab->get_user_ssh_keys('sytses');

		ok(!$err, 'no error fetching GitLab user keys');
		ok($keys, 'returned keys array');
		isa_ok($keys, 'ARRAY', 'keys is an array reference');
		ok(scalar(@$keys) > 0, 'found at least one key for sytses on GitLab');
	};

	subtest 'get_user_ssh_keys error handling' => sub {
		plan tests => 6;

		my $gh = Service::Github->new(domain => 'github.com');

		# Non-existent user
		my ($keys, $err) = $gh->get_user_ssh_keys('thisuserdoesnotexist12345678');
		ok($err, 'returns error for non-existent user');
		ok(!$keys, 'returns undef keys for non-existent user');
		like($err, qr/not found/i, 'error message mentions not found');

		# Invalid username format
		dies_ok { $gh->get_user_ssh_keys('invalid..username') }
			'dies with invalid username format';
		dies_ok { $gh->get_user_ssh_keys('') }
			'dies with empty username';
		dies_ok { $gh->get_user_ssh_keys(undef) }
			'dies with undef username';
	};

	subtest 'get_user_ssh_keys validates returned keys' => sub {
		plan tests => 2;

		my $gh = Service::Github->new(domain => 'github.com');
		my ($keys, $err) = $gh->get_user_ssh_keys('dennisjbell');

		ok(!$err, 'successfully fetched keys');

		# All returned keys should pass validation
		my $all_valid = 1;
		foreach my $key (@$keys) {
			$all_valid = 0 unless $gh->validate_ssh_key($key);
		}
		ok($all_valid, 'all returned keys are valid SSH public keys');
	};
};

done_testing;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1
