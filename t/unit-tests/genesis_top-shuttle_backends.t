#!perl
# Proves that the shuttle block is declared on its backend, which admits the
# keys it declares and refuses the rest.  S3 is the only backend: the shuttle
# resource the pipeline runs is S3 only, and gcs came from an image that never
# existed (D23, noted 2026-10-18).
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

my $h = make_harness(envs => ['qa'], pipeline => 0, vault => 0);

subtest 'a GCS shuttle is refused by name' => sub {
	plan tests => 1;

	throws_ok {load_with($h, shuttle('gcs', 'bucket: sig'))}
		qr/pipeline\.shuttle\.backend: unknown value: gcs; expected one of s3/,
		's3 being the one backend the shuttle resource has';
};

subtest 'an S3 shuttle carries both' => sub {
	plan tests => 2;

	lives_ok {load_with($h, shuttle('s3', 'bucket: sig', 'region: us-east-1',
		'endpoint: https://minio.internal'))}
		'S3 reads a region and an endpoint, so it admits them';
	throws_ok {load_with($h, shuttle('s3', 'region: us-east-1'))}
		qr/pipeline\.shuttle: missing required key .*bucket/,
		'and the bucket is still required under it';
};

subtest 'a backend nobody owns is refused by name' => sub {
	plan tests => 1;

	throws_ok {load_with($h, shuttle('file', 'path: /tmp/signals'))}
		qr/pipeline\.shuttle\.backend: unknown value: file; expected one of s3/,
		'a directory backend is refused, and the map is what says so';
};

done_testing;
