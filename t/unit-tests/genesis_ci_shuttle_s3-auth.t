#!perl
# Proves T502: pipeline.shuttle.auth is a credential like the others, a
# path or each key on its own (D171).
#
# It took one path, and the S3 backend read access_key_id and
# secret_access_key from it under exactly those names, so credentials stored
# under other names had to be published a second time.
#
# The rows read which forms the load accepts and refuses, and where each
# form says the two keys are held.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;
use Test::More;
use Test::Exception;

use Genesis;
provide_rc();
use_ok 'Genesis::Top';
use_ok 'Genesis::CI::Shuttle::S3';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

# An automated pipeline whose shuttle's auth is the lines given.
sub shuttle_with {
	my (@auth) = @_;
	my @lines = ('pipeline:', '  enabled: true',
		'  provider:', '    type: concourse',
		'    url: https://ci.example.com', '    team: main',
		'  source_control:', '    repository: team/bosh',
		'    auth:', '      type: ssh', '      path: secret/ci/git',
		'    identity:', '      name: Genesis', '      email: ci@example.com',
		automation_block_lines(without => ['shuttle']),
		'  shuttle:', '    backend: s3', '    bucket: pipes', @auth);
	return join("\n", @lines);
}

sub held_at { Genesis::CI::Shuttle::S3->auth_components($_[0]) }

subtest 'a path holds both keys under their own names' => sub {
	plan tests => 4;
	my %both = (
		access_key_id     => 'management-bucket:access_key_id',
		secret_access_key => 'management-bucket:secret_access_key',
	);
	is_deeply(held_at('management-bucket'), \%both, 'written as the path alone, as it always was');
	is_deeply(held_at({path => 'management-bucket'}), \%both, 'or as a block naming the path');
	lives_ok {load_with($h, shuttle_with('    auth: management-bucket'))} 'the first loads';
	lives_ok {load_with($h, shuttle_with('    auth:', '      path: management-bucket'))}
		'and so does the second';
};

subtest 'each key can be held where it is' => sub {
	plan tests => 3;
	my @split = ('    auth:',
		'      access_key_id: management-bucket:aws_access_key_id',
		'      secret_access_key: management-bucket:aws_secret_access_key');
	lives_ok {load_with($h, shuttle_with(@split))} 'a block naming each key loads';
	is_deeply(held_at({
		access_key_id     => 'management-bucket:aws_access_key_id',
		secret_access_key => 'management-bucket:aws_secret_access_key',
	}), {
		access_key_id     => 'management-bucket:aws_access_key_id',
		secret_access_key => 'management-bucket:aws_secret_access_key',
	}, 'and each is read from where it says');
	is_deeply(held_at({path => 'management-bucket', secret_access_key => '((other.secret))'}), {
		access_key_id     => 'management-bucket:access_key_id',
		secret_access_key => '((other.secret))',
	}, 'a key not given is read from the path, and one given in Concourse\'s form is taken as written');
};

subtest 'a block that cannot give both keys is refused' => sub {
	plan tests => 3;
	throws_ok {load_with($h, shuttle_with('    auth:',
			'      access_key_id: management-bucket:aws_access_key_id'))}
		qr/pipeline\.shuttle\.auth: .*secret_access_key/s,
		'one that names one key and no path, naming the key it lacks';
	throws_ok {load_with($h, shuttle_with('    auth:',
			'      path: management-bucket', '      region: us-east-1'))}
		qr/pipeline\.shuttle\.auth: .*region/s,
		'one that carries a key that is no part of the credential, naming it';
	throws_ok {load_with($h, shuttle_with('    auth:', '      - management-bucket'))}
		qr/pipeline\.shuttle\.auth: /,
		'and one that is neither a path nor a block';
};

subtest 'no auth is no credential' => sub {
	plan tests => 2;
	is_deeply(held_at(undef), {}, 'nothing is answered for a shuttle that names none');
	lives_ok {load_with($h, shuttle_with())} 'and the block loads without one';
};

done_testing;
