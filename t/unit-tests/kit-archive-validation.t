#!perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;
use Test::Output;
use Test::Deep;

use_ok 'Genesis';
use_ok 'Genesis::Kit::Compiled';
use_ok 'Genesis::Config';
provide_rc();

my $tmp = workdir;

# Small helpers to keep each subtest focused on its own intent.
sub kit       { Genesis::Kit::Compiled->new(name => 'x', version => '1.0.0', @_) }
sub scan_dir  { my $d = "$tmp/$_[0]"; mkdir $d unless -d $d; $d }
sub bad_kit_dies {
	my ($name, $bytes, $re) = @_;
	subtest $name => sub {
		my $f = "$tmp/$name-1.0.0.tar.gz";
		put_file($f, $bytes);
		throws_ok { kit(archive => $f) } $re, $name;
	};
}

subtest 'rejects missing archive opt' => sub {
	throws_ok { Genesis::Kit::Compiled->new(name => 'x', version => '1.0.0') }
		qr/Missing required option: archive/;
};

subtest 'rejects nonexistent archive' => sub {
	throws_ok { kit(archive => '/no/such/file.tar.gz') } qr/does not exist/;
};

SKIP: {
	skip 'cannot test permission denied as root', 1 if $> == 0;
	subtest 'rejects unreadable archive' => sub {
		my $f = "$tmp/noread-1.0.0.tar.gz";
		put_file($f, "\x1f\x8b" . ("\x00" x 100));
		chmod 0000, $f;
		throws_ok { kit(archive => $f) } qr/cannot be read|permissions/i;
		chmod 0644, $f;
	};
}

bad_kit_dies 'empty',     '',                                                qr/empty.*0 bytes/i;
bad_kit_dies 'html',      '<!DOCTYPE html><html><body>403</body></html>',    qr/HTML.*proxy|captive portal/i;
bad_kit_dies 'non-gzip',  "\x00\x01\x02\x03" x 100,                          qr/not.*valid gzip/i;
bad_kit_dies 'truncated', "\x1f\x8b\x08\x00" . ("\x00" x 16),                qr/could not be read|corrupted|truncated|Failed to read/i;

subtest 'valid archive loads' => sub {
	my $f = mk_test_kit('good', '1.0.0', $tmp);
	lives_ok {
		Genesis::Kit::Compiled->new(name => 'good', version => '1.0.0', archive => $f)
	};
};

subtest 'local_kits skips corrupt and surfaces the valid' => sub {
	my $d = scan_dir 'local_kits_mixed';
	mk_test_kit('alpha',   '1.0.0', $d);
	mk_test_kit('charlie', '3.0.0', $d);
	put_file("$d/broken-2.0.0.tar.gz",
		'<!DOCTYPE html><html><body>403 Forbidden</body></html>');

	my $result;
	my $warn = stderr_from {
		lives_ok { $result = Genesis::Kit::Compiled->local_kits(undef, $d) }
			'local_kits does not die';
	};

	like $warn, qr{Skipping invalid kit archive .*broken-2\.0\.0\.tar\.gz},
		'warning names the corrupt archive';
	like $warn, qr{contains HTML instead of a gzip archive},
		'warning identifies the HTML-as-archive cause';
	cmp_deeply $result, {
		alpha   => { '1.0.0' => ignore() },
		charlie => { '3.0.0' => ignore() },
	}, 'only valid kits appear in the result (corrupt one absent)';
};

subtest 'local_kits with all valid kits' => sub {
	my $d = scan_dir 'local_kits_valid';
	mk_test_kit('foo', '1.0.0', $d);
	mk_test_kit('bar', '2.0.0', $d);
	cmp_deeply Genesis::Kit::Compiled->local_kits(undef, $d), {
		foo => { '1.0.0' => ignore() },
		bar => { '2.0.0' => ignore() },
	};
};

done_testing;
