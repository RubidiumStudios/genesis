#!perl
use strict;
use warnings;

# check_embedded_genesis reads the version out of the genesis binary that
# a repository embeds under .genesis/bin/genesis, so it can warn when the
# running genesis differs from it.  It used to look for a line of the
# form `$Genesis::VERSION = "..."` inside the embedded archive, but pack
# writes `$VERSION = "X.Y.Z";` into Genesis.pm, so on every released
# build the marker was never found and every repo-scoped command printed
# "Embedded genesis is , current version is 3.2.0" along with a trio of
# uninitialized-value warnings.
#
# These cases build a fake embedded genesis -- a stub script with a
# base64-encoded gzipped tar after __DATA__, the layout pack produces --
# whose Genesis.pm carries a chosen version marker, and call the check
# directly with stderr captured.

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Cwd qw/abs_path getcwd/;
use File::Temp qw/tempdir/;
use MIME::Base64 qw/encode_base64/;

use_ok 'Genesis::Config';
use_ok 'Genesis::Commands';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{GENESIS_DEBUG} = 1;   # so the "could not determine" debug line is visible
delete @ENV{qw/GENESIS_USING_EMBEDDED GENESIS_IS_HELPING_YOU GENESIS_COMMAND/};

# The check only runs for repo- or env-scoped commands and only when the
# embedded_genesis RC setting is not 'ignore'.
provide_rc(undef, 0, {embedded_genesis => 'warn'});
Genesis::Commands::define_command('embedded-genesis-probe', {scope => 'repo'}, sub {});
{ no warnings 'once'; $Genesis::Commands::COMMAND = 'embedded-genesis-probe'; }

# A repository is anything with a .genesis/config naming a deployment_type.
my $sandbox = tempdir(CLEANUP => 1);
my $repo    = "$sandbox/repo";
mkdir_or_fail($repo);
mkdir_or_fail("$repo/.genesis");
mkdir_or_fail("$repo/.genesis/bin");
put_file("$repo/.genesis/config", "---\ndeployment_type: probe\n");

# The check skips when the running binary is the embedded one.
$ENV{GENESIS_CALLBACK_BIN} = abs_path("$TOPDIR/bin/genesis");

my $orig_cwd = getcwd();
chdir $repo or die "chdir $repo: $!";
END { chdir $orig_cwd if $orig_cwd }

# embed_fake_genesis - write .genesis/bin/genesis wrapping a tar whose
# lib/Genesis.pm holds the given line(s) where the version marker lives.
sub embed_fake_genesis {
	my ($version_line) = @_;

	my $stage = tempdir(DIR => $sandbox, CLEANUP => 1);
	mkdir_or_fail("$stage/lib");
	put_file("$stage/lib/Genesis.pm", <<PM);
package Genesis;
use strict;
use warnings;

our \$APP     = "genesis";
our \$VERSION;
$version_line
our \$BUILD   = " (abcdef0) build 20260101.000000";

1;
PM
	put_file("$stage/genesis", "#!/usr/bin/perl\nexit 0;\n");

	my $tarball = "$stage.tar.gz";
	system("tar -czf '$tarball' -C '$stage' ./genesis ./lib") == 0
		or die "failed to build fake runtime archive";

	open my $tfh, '<:raw', $tarball or die "open $tarball: $!";
	my $bytes = do { local $/; <$tfh> };
	close $tfh;

	my $stub = "$repo/.genesis/bin/genesis";
	open my $out, '>', $stub or die "open $stub: $!";
	print $out "#!/usr/bin/perl\nexit 0;\n__DATA__\n";
	print $out "0123456789abcdef0123456789abcdef01234567\n";
	print $out encode_base64($bytes);
	close $out;
	chmod 0755, $stub;
}

# run_check - run check_embedded_genesis with $Genesis::VERSION set to the
# given running version, returning everything it wrote to stderr.
sub run_check {
	my ($running_version) = @_;
	local $Genesis::VERSION = $running_version;

	my $stderr = '';
	open my $saved, '>&', \*STDERR or die "dup STDERR: $!";
	close STDERR;
	open STDERR, '>', \$stderr or die "capture STDERR: $!";
	my $err;
	eval { Genesis::Commands::check_embedded_genesis(); 1 } or $err = $@;
	close STDERR;
	open STDERR, '>&', $saved or die "restore STDERR: $!";
	close $saved;
	die $err if defined $err;
	return $stderr;
}

subtest 'packed marker, matching version, stays silent' => sub {
	plan tests => 2;
	embed_fake_genesis('$VERSION = "3.2.0";');
	my $out = run_check('3.2.0');
	unlike($out, qr/WARNING|Embedded genesis is/, 'no version warning is printed')
		or diag($out);
	unlike($out, qr/uninitialized/, 'no uninitialized-value warnings are printed')
		or diag($out);
};

subtest 'packed marker, differing version, warns with both versions' => sub {
	plan tests => 2;
	embed_fake_genesis('$VERSION = "3.2.0";');
	my $out = run_check('3.2.1');
	like($out, qr/Embedded genesis is 3\.2\.0, current version is 3\.2\.1/,
		'warning names the embedded and running versions') or diag($out);
	unlike($out, qr/uninitialized/, 'no uninitialized-value warnings are printed')
		or diag($out);
};

subtest 'legacy $Genesis::VERSION marker is still recognised' => sub {
	plan tests => 3;
	embed_fake_genesis('$Genesis::VERSION = "3.1.0";');

	my $out = run_check('3.1.0');
	unlike($out, qr/WARNING|Embedded genesis is/, 'matching legacy version stays silent')
		or diag($out);

	$out = run_check('3.2.0');
	like($out, qr/Embedded genesis is 3\.1\.0, current version is 3\.2\.0/,
		'differing legacy version warns with the real version') or diag($out);
	unlike($out, qr/uninitialized/, 'no uninitialized-value warnings are printed')
		or diag($out);
};

subtest 'no version marker at all is reported at debug level, not as a warning' => sub {
	plan tests => 3;
	embed_fake_genesis('# no version assignment in this copy');
	my $out = run_check('3.2.0');
	unlike($out, qr/WARNING|Embedded genesis is/, 'no version warning is printed')
		or diag($out);
	unlike($out, qr/uninitialized/, 'no uninitialized-value warnings are printed')
		or diag($out);
	like($out, qr/Could not determine the version of the embedded genesis/,
		'a debug line explains the check was skipped') or diag($out);
};

done_testing;
