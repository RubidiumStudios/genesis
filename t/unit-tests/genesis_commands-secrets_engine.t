#!perl
#
# Genesis::Commands::check_secrets_engine
#
# safe drives either Vault or OpenBao, so either satisfies Genesis. Which
# ones are acceptable depends on safe itself: OpenBao support arrived in
# safe 1.20.0, and below that safe shells out to `vault` regardless of what
# else is installed.
#
# The engines are faked as scripts on the PATH rather than mocked in Perl,
# because the code under test resolves them by running them.

use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Deep;

use_ok 'Genesis::Commands';
use Genesis;

$ENV{NOCOLOR} = 1;

# safe reports its version on stderr and the engines report theirs on
# stdout, which is why the prereq commands redirect differently.  The fakes
# have to match, or the checks read an empty string and every answer here
# is about the fake rather than the code.
my %VERSION_STREAM = (safe => 2, vault => 1, bao => 1);

# Every tool gets a stub on every run, including the ones a case wants
# absent -- those print nothing, which is what check_version reads as
# missing.  Leaving them out instead would let the host's own binaries
# answer: the PATH below keeps /usr/bin for ordinary utilities, and an
# image that installs vault there satisfies the check for cases built to
# assert it cannot be satisfied.
sub fake_engines {
	my (%versions) = @_;
	my $bin = workdir();
	for my $name (keys %VERSION_STREAM) {
		my $version  = $versions{$name};
		my $redirect = $VERSION_STREAM{$name} == 2 ? ' >&2' : '';
		open my $fh, '>', "$bin/$name" or die "cannot write fake $name: $!";
		print $fh defined $version
			? "#!/bin/sh\nprintf '%s\\n' '$version'$redirect\n"
			: "#!/bin/sh\nexit 1\n";
		close $fh;
		chmod 0755, "$bin/$name";
	}
	return $bin;
}

sub engine_check_with {
	my (%versions) = @_;
	my $bin = fake_engines(%versions);
	local $ENV{PATH} = "$bin:/usr/bin:/bin";
	return join("\n", Genesis::Commands::check_secrets_engine());
}

subtest 'vault alone, new enough' => sub {
	is engine_check_with(
		vault => 'Vault v1.14.4 (abc), built 2023-09-22',
		safe  => 'safe v1.9.0',
	), '', 'vault satisfies the requirement on its own';
};

subtest 'vault too old, no bao' => sub {
	my $err = engine_check_with(
		vault => 'Vault v0.9.0 (abc)',
		safe  => 'safe v1.20.0',
	);
	like $err, qr/at least 1\.9\.0/, 'names the vault minimum';
	like $err, qr/Missing `bao`/,    'and reports bao as the other option';
};

subtest 'bao alone, safe new enough' => sub {
	is engine_check_with(
		bao  => 'OpenBao v2.6.1 (abc), committed 2026-07-22',
		safe => 'safe v1.20.0',
	), '', 'bao satisfies the requirement when safe can drive it';
};

subtest 'bao alone, safe too old' => sub {
	# The case the gate exists for: bao is present and new enough, but the
	# safe that would have to drive it predates OpenBao support entirely.
	my $err = engine_check_with(
		bao  => 'OpenBao v2.6.1 (abc)',
		safe => 'safe v1.9.0',
	);
	isnt $err, '', 'bao is not accepted';
	like $err, qr/needs safe .*1\.20\.0/,
		'and says the safe version is why, not that bao is missing';
	unlike $err, qr/Missing `bao`/,
		'an installed-but-undriveable bao is not reported as absent';
};

subtest 'bao too old, safe new enough' => sub {
	my $err = engine_check_with(
		bao  => 'OpenBao v2.5.0 (abc)',
		safe => 'safe v1.20.0',
	);
	like $err, qr/at least 2\.6\.0/, 'names the bao minimum';
};

subtest 'neither engine installed' => sub {
	my $err = engine_check_with(safe => 'safe v1.20.0');
	like $err, qr/Missing `vault`/, 'reports vault missing';
	like $err, qr/Missing `bao`/,   'and bao missing';
};

subtest 'vault wins when both are usable' => sub {
	# Matches safe's own resolution order, so Genesis does not accept an
	# engine that safe would not have chosen.
	is engine_check_with(
		vault => 'Vault v1.14.4 (abc)',
		bao   => 'OpenBao v2.6.1 (abc)',
		safe  => 'safe v1.20.0',
	), '', 'both present is fine';
};

subtest 'safe missing entirely' => sub {
	# Cannot be shown to support OpenBao, so bao is not offered.
	my $err = engine_check_with(bao => 'OpenBao v2.6.1 (abc)');
	isnt $err, '', 'bao alone with no safe is not accepted';
};

done_testing;
