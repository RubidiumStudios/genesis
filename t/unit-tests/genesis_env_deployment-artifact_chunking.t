#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 't';
use helper;

use Test::More;
use Test::Deep;
use Test::Exception;
use MIME::Base64 qw/encode_base64 decode_base64/;
use IO::Compress::Gzip qw/gzip $GzipError/;
use Archive::Tar;

use Genesis;
$Genesis::VERSION = '999.999.999';
use_ok 'Genesis::Env::Deployment';

# ===========================================================================
# Artifact chunking: write side splits large blobs across multiple vault
# keys (artifacts[0], artifacts[1], ...), read side normalises both
# array-of-chunks (new) and single-scalar (back-compat) shapes by
# concatenation before decode.
# ===========================================================================

# Build a real base64-gzipped tarball with a single file inside.
sub make_b64_gzipped_tarball {
	my (%files) = @_;
	my $tar = Archive::Tar->new;
	for my $name (keys %files) {
		$tar->add_data($name, $files{$name});
	}
	my $compressed;
	open my $fh, '>', \$compressed;
	$tar->write(IO::Compress::Gzip->new($fh, Level => 9, AutoClose => 1));
	return encode_base64($compressed);
}

{
	package Genesis::Env::_Mock;
	our @ISA = ('Mock');
	sub isa { return $_[1] eq 'Genesis::Env' ? 1 : $_[0]->SUPER::isa($_[1]) }
}

sub make_mock_env {
	return Genesis::Env::_Mock->new(
		vault       => sub { Mock->new(authenticate => sub { $_[0] }) },
		exodus_base => '/secret/exodus/test',
		workpath    => sub { "/tmp/wp-$_[1]" },
		deployments => sub { Mock->new(next_sequence_number => sub { 1 }, reset => sub { 1 }) },
	);
}

# Minimal valid args for Deployment->new — the smaller-than-a-full-blob
# subtests don't need a real action loop.
sub deploy_args {
	my (%over) = @_;
	return (
		action          => 'terminate',
		result          => 'success',
		reason          => 'test',
		genesis_version => '3.0.0',
		user            => { shell => '/bin/bash' },
		%over,
	);
}

# ---------- back-compat: scalar artifacts (existing deployments) ----------

subtest 'scalar artifacts (existing) stored as b64-gzipped' => sub {
	plan tests => 2;
	my $env = make_mock_env();
	my $blob = make_b64_gzipped_tarball('manifest.yml' => "kind: Manifest\n");
	my $d = Genesis::Env::Deployment->new($env, deploy_args(artifacts => $blob));
	is $d->{artifacts}{format}, 'b64-gzipped',
		'single-scalar artifacts => format b64-gzipped';
	is $d->{artifacts}{data}, $blob,
		'single-scalar artifacts => data unchanged';
};

# ---------- new: array-of-chunks artifacts ----------

subtest 'array of chunks => concatenated to single b64-gzipped blob' => sub {
	plan tests => 2;
	my $env = make_mock_env();
	my $blob = make_b64_gzipped_tarball('manifest.yml' => "kind: Manifest\n");
	# Split arbitrarily into 3 chunks; concatenation must reproduce original
	my $len = length($blob);
	my $third = int($len / 3);
	my @chunks = (
		substr($blob, 0, $third),
		substr($blob, $third, $third),
		substr($blob, 2 * $third),
	);
	my $d = Genesis::Env::Deployment->new($env, deploy_args(artifacts => \@chunks));
	is $d->{artifacts}{format}, 'b64-gzipped',
		'arrayref artifacts => format b64-gzipped';
	is $d->{artifacts}{data}, $blob,
		'arrayref artifacts => chunks concatenated in order';
};

subtest 'single-chunk array equivalent to bare scalar' => sub {
	plan tests => 1;
	my $env = make_mock_env();
	my $blob = make_b64_gzipped_tarball('a.txt' => "hello\n");
	my $d = Genesis::Env::Deployment->new($env, deploy_args(artifacts => [$blob]));
	is $d->{artifacts}{data}, $blob,
		'[$blob] equivalent to $blob';
};

subtest 'many-chunk array preserves order' => sub {
	plan tests => 1;
	my $env = make_mock_env();
	my $blob = make_b64_gzipped_tarball('a.txt' => "abc" x 1000);
	# 10-way split
	my $n = length($blob);
	my $chunk_size = int($n / 10);
	my @chunks = map {
		substr($blob, $_ * $chunk_size, ($_ == 9 ? $n : $chunk_size));
	} 0 .. 9;
	my $d = Genesis::Env::Deployment->new($env, deploy_args(artifacts => \@chunks));
	is $d->{artifacts}{data}, $blob,
		'10 chunks concatenate to original blob';
};

# ---------- write side: commit chunks the blob into artifacts[N] keys ----------

subtest 'commit splits artifacts blob into multiple artifacts[N] keys' => sub {
	plan tests => 4;
	my $tmpdir = workdir;

	# Capture the @cmds AND chunk file contents inside the query stub
	# - commit() unlinks chunk files immediately after the vault call,
	# so reading them later would race against cleanup.
	my @captured;
	my @captured_chunks;
	my $vault = Mock->new(
		authenticate     => sub { $_[0] },
		# Per-string limit of 3048; with 2 KiB headroom, chunk_size = 1000
		max_json_string_value_length => sub { 3048 },
		query            => sub {
			my $self = shift;
			shift if ref($_[0]) eq 'HASH';   # opts
			@captured = @_;
			for my $arg (@captured) {
				if ($arg =~ /^artifacts\[(\d+)\]\@(.+)$/) {
					my ($idx, $file) = ($1, $2);
					open my $fh, '<', $file or next;
					local $/;
					$captured_chunks[$idx] = <$fh>;
					close $fh;
				}
			}
			return ('', 0, '');
		},
	);

	my $env = Genesis::Env::_Mock->new(
		vault       => sub { $vault },
		exodus_base => '/secret/exodus/test',
		workpath    => sub { "$tmpdir/$_[1]" },
		deployments => sub { Mock->new(
			next_sequence_number => sub { 1 },
			reset                => sub { 1 },
		)},
	);

	# Build a deployment with a blob larger than the chunk size.
	# Random bytes don't compress well, so the resulting base64 stays
	# proportional to the input.  ~10 KB of random => ~13 KB base64.
	srand(42);   # deterministic
	my $payload = join('', map { chr(int(rand(256))) } 1 .. 10_000);
	my $blob = make_b64_gzipped_tarball('big.bin' => $payload);
	cmp_ok length($blob), '>', 1000,
		'test blob exceeds the 1000-byte chunk size';

	my $d = Genesis::Env::Deployment->new($env, deploy_args(
		artifacts => $blob,
		kit       => { id => 'k', name => 'k', version => '1', is_dev => 0, features => [] },
		manifest  => { type => 'bosh', sha2 => 'a' x 64 },
		action    => 'deploy',
		completed => '2026-06-03 12:00:00 +0000',
		started   => '2026-06-03 11:55:00 +0000',
	));

	$d->commit;

	# Assert we issued at least 2 chunked write entries
	my @chunk_args = grep { /^artifacts\[\d+\]\@/ } @captured;
	cmp_ok scalar(@chunk_args), '>=', 2,
		'at least 2 artifacts[N]@file entries in vault command';

	# Assert no single-blob `artifacts@file` entry was written
	my @legacy = grep { /^artifacts\@/ } @captured;
	is scalar(@legacy), 0,
		'no legacy single-key artifacts@file entry written';

	# Reassemble captured chunks and verify they match the original blob
	my $reassembled = join('', grep { defined } @captured_chunks);
	is $reassembled, $blob,
		'chunk files concatenate back to the original blob';
};

# ---------- artifact tarball decode still works post-normalisation ----------

subtest 'chunked artifacts decode through _get_artifact_tarball' => sub {
	plan tests => 1;
	my $env = make_mock_env();
	my $blob = make_b64_gzipped_tarball('manifest.yml' => "kind: Manifest\n");
	# Stash in 4 chunks
	my @chunks = grep { length } split /(.{50})/s, $blob;
	my $d = Genesis::Env::Deployment->new($env, deploy_args(artifacts => \@chunks));
	# Manually drive _get_artifact_tarball via package access
	my $tar = $d->_get_artifact_tarball();
	my $content = $tar->get_content('manifest.yml');
	is $content, "kind: Manifest\n",
		'chunked artifacts decode cleanly through gunzip/untar pipeline';
};

done_testing;

# vim: ts=2 sw=2 sts=2 noet
