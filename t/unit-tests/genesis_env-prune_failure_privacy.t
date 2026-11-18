#!/usr/bin/env perl
# A deploy recorded in exodus keeps its manifest, credentials included.
# When Genesis prunes an old unpruned manifest and spruce fails, what
# spruce printed can quote the manifest, so the error that is returned and
# traced names how spruce ended and the kind of failure, never its words.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;
use IO::Compress::Gzip qw/gzip/;
use MIME::Base64 qw/encode_base64/;

use Genesis;
use Genesis::Env;

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/bin";
put_file("$dir/bin/spruce", 0755, <<'SH');
#!/bin/bash
cat > /dev/null
echo "1 error(s) detected: \$.params.password: '$FAKE_SPRUCE_VALUE' could not be found" >&2
exit 2
SH

my $secret = fake_secret('archived-manifest');
my $manifest = "genesis:\n  env: fake\nparams:\n  password: $secret\n";
gzip(\$manifest => \my $compressed);

package FakeDeployments { sub latest { undef } }
my %exodus = (manifest => encode_base64($compressed, ''), manifest_type => 'unredacted', manifest_sha1 => 'abc');
no warnings qw/redefine once/;
local *Genesis::Env::notify = sub {};
local *Genesis::Env::manifest_store = sub { 'exodus' };
local *Genesis::Env::exodus_lookup = sub { $exodus{$_[1]} };
local *Genesis::Env::deployments = sub { bless({}, 'FakeDeployments') };
local *Genesis::Env::prunable_keys = sub { ('genesis') };
local *Genesis::Env::use_create_env = sub { 0 };
use warnings qw/redefine once/;

subtest 'a failed prune is described without what spruce printed' => sub {
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $ENV{FAKE_SPRUCE_VALUE} = $secret;
	my $env = bless({name => 'fake'}, 'Genesis::Env');
	my ($log, $stderr) = capture_trace { $env->last_deployed_manifest() };
	like($log, qr/could not be retroactively pruned:\s+spruce\s+exited\s+2\s+\(could\s+not\s+resolve\s+a\s+reference\)/,
		'the traced error names how spruce ended and the kind of failure');
	unlike($log.$stderr, qr/\Q$secret\E/, 'and quotes nothing spruce printed');
};

done_testing;
