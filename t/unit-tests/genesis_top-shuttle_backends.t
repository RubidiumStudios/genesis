#!perl
# Proves that the shuttle block is declared on its backend.  Each backend
# admits the keys it declares and refuses the rest, so a GCS configuration
# cannot carry a region.  The credentials the compiler reads out of the
# block are left exactly where they are, because how one vault reference
# becomes two S3 keys or one GCS key is the emitter rewrite's question.
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

subtest 'a GCS shuttle carries no region and no endpoint' => sub {
	plan tests => 3;

	throws_ok {load_with($h, shuttle('gcs', 'bucket: sig', 'region: us-east-1'))}
		qr/pipeline\.shuttle\.region: unknown configuration key/,
		'the region is refused, because GCS has nothing to do with one';
	throws_ok {load_with($h, shuttle('gcs', 'bucket: sig', 'endpoint: https://x'))}
		qr/pipeline\.shuttle\.endpoint: unknown configuration key/,
		'and so is an endpoint';
	lives_ok {load_with($h, shuttle('gcs', 'bucket: sig'))}
		'while the keys GCS does read are accepted';
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
		qr/pipeline\.shuttle\.backend: unknown value: file; expected one of gcs, s3/,
		'D23 refuses a directory, and the map is what says so';
};

done_testing;
