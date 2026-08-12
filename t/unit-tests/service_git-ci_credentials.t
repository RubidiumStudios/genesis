#!perl
#
# Git credentials supplied through the environment, as a CI task does.
# Replaces the setup the retired ci-* task commands performed before
# handing off to Genesis.
#
use strict;
use warnings;

use lib 'lib';
use lib 't';
use Test::More;
use Test::Exception;

$ENV{GENESIS_TESTING} = 'yes';
$ENV{GENESIS_LIB}   ||= 'lib';
$ENV{NOCOLOR}         = 1;

use_ok 'Service::Git';

# Every test drives the function from a known-clean environment.
my @VARS = qw(
	GIT_PRIVATE_KEY GIT_USERNAME GIT_PASSWORD
	GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
	GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
	GIT_SSH_COMMAND GIT_ASKPASS GIT_TERMINAL_PROMPT
);

sub with_env {
	my (%set) = @_;
	local %ENV = (%ENV);
	delete $ENV{$_} for @VARS;
	$ENV{$_} = $set{$_} for keys %set;
	Service::Git::reset_ci_credentials();
	Service::Git::provision_ci_credentials();
	return {map {$_ => $ENV{$_}} @VARS};
}

my $FAKE_KEY = "-----BEGIN OPENSSH PRIVATE KEY-----\nabc123\n-----END OPENSSH PRIVATE KEY-----";

# ======================================================================
# No credentials in the environment
# ======================================================================

subtest 'without credentials the environment is left completely alone' => sub {
	plan tests => 3;

	# The prompt guards below exist to stop a CI task hanging on a prompt
	# nobody can answer.  Applying them unconditionally would break every
	# local operator whose credential helper or agent misses: git would
	# fail outright where it used to ask.  So: no credentials, no changes.
	my $env = with_env();

	ok !defined $env->{GIT_SSH_COMMAND}, 'no GIT_SSH_COMMAND is set';
	ok !defined $env->{GIT_ASKPASS},
		'askpass is untouched, leaving credential helpers and agents to work';
	ok !defined $env->{GIT_TERMINAL_PROMPT},
		'terminal prompting is untouched, so an interactive git can still ask';
};

subtest 'a repository with no remote provisions nothing' => sub {
	plan tests => 2;

	# Constructing against a freshly-initialised repo must not write
	# credential files or alter git's behaviour -- there is no remote to
	# authenticate to.
	use File::Temp qw/tempdir/;
	my $dir = tempdir(CLEANUP => 1);
	system('git', '-C', $dir, 'init', '-q') == 0 or plan skip_all => 'git init failed';

	local %ENV = (%ENV);
	delete $ENV{$_} for @VARS;
	Service::Git::reset_ci_credentials();

	lives_ok {Service::Git->new($dir)} 'constructing against a local-only repo works';
	ok !defined $ENV{GIT_ASKPASS},
		'and leaves git configuration untouched';
};

subtest 'existing prompt settings are never overridden' => sub {
	plan tests => 2;

	my $env = with_env(
		GIT_USERNAME        => 'ci-bot',
		GIT_PASSWORD        => 's3cr3t',
		GIT_TERMINAL_PROMPT => '1',
	);

	is $env->{GIT_TERMINAL_PROMPT}, '1',
		'a caller-supplied GIT_TERMINAL_PROMPT wins';
	isnt $env->{GIT_ASKPASS}, '/bin/false',
		'the askpass helper still replaces the fail-fast default';
};

# ======================================================================
# SSH key
# ======================================================================

subtest 'an ssh key is materialised and pointed at by GIT_SSH_COMMAND' => sub {
	plan tests => 6;

	my $env = with_env(GIT_PRIVATE_KEY => $FAKE_KEY);

	my $cmd = $env->{GIT_SSH_COMMAND};
	ok $cmd, 'GIT_SSH_COMMAND is set';
	like $cmd, qr/^ssh /, 'it invokes ssh';

	my ($config) = $cmd =~ /-F\s+(\S+)/;
	ok $config && -f $config, 'it names an ssh config file that exists';

	my $conf_text = do {local (@ARGV, $/) = ($config); <>};
	like $conf_text, qr/IdentityFile\s+(\S+)/, 'the config names an identity file';

	my ($key) = $conf_text =~ /IdentityFile\s+(\S+)/;
	is do {local (@ARGV, $/) = ($key); <>}, $FAKE_KEY,
		'the key file holds the supplied key verbatim';

	is sprintf('%04o', (stat $key)[2] & 07777), '0600',
		'the key is written unreadable to other users';
};

# ======================================================================
# HTTPS username/password
# ======================================================================

subtest 'username and password are answered through GIT_ASKPASS' => sub {
	plan tests => 5;

	my $env = with_env(GIT_USERNAME => 'ci-bot', GIT_PASSWORD => 's3cr3t');

	my $askpass = $env->{GIT_ASKPASS};
	ok $askpass && -f $askpass, 'GIT_ASKPASS names a file that exists';
	ok -x $askpass, 'it is executable';
	isnt $askpass, '/bin/false', 'it is not the fail-fast default';

	# git calls askpass with the prompt as the sole argument.
	chomp(my $user = `GIT_USERNAME=ci-bot GIT_PASSWORD=s3cr3t $askpass "Username for 'https://example.com': "`);
	is $user, 'ci-bot', 'a username prompt is answered with the username';

	chomp(my $pass = `GIT_USERNAME=ci-bot GIT_PASSWORD=s3cr3t $askpass "Password for 'https://example.com': "`);
	is $pass, 's3cr3t', 'a password prompt is answered with the password';
};

subtest 'a password containing shell metacharacters survives' => sub {
	plan tests => 1;

	my $nasty = 'p@ss w$rd`"\'!';
	my $env = with_env(GIT_USERNAME => 'ci-bot', GIT_PASSWORD => $nasty);

	my $askpass = $env->{GIT_ASKPASS};
	local $ENV{GIT_USERNAME} = 'ci-bot';
	local $ENV{GIT_PASSWORD} = $nasty;
	chomp(my $pass = `$askpass "Password for 'https://example.com': "`);
	is $pass, $nasty,
		'the password is read from the environment, not interpolated into the script';
};

# ======================================================================
# Identity
# ======================================================================

subtest 'committer identity is derived from the author identity' => sub {
	plan tests => 2;

	# Without this a container with no user.email configured fails every
	# commit with "Please tell me who you are".
	my $env = with_env(
		GIT_AUTHOR_NAME  => 'Concourse Bot',
		GIT_AUTHOR_EMAIL => 'concourse@pipeline',
	);

	is $env->{GIT_COMMITTER_NAME},  'Concourse Bot',       'committer name mirrors author';
	is $env->{GIT_COMMITTER_EMAIL}, 'concourse@pipeline',  'committer email mirrors author';
};

subtest 'an explicit committer identity is not overwritten' => sub {
	plan tests => 1;

	my $env = with_env(
		GIT_AUTHOR_NAME     => 'Concourse Bot',
		GIT_COMMITTER_NAME  => 'Someone Else',
	);

	is $env->{GIT_COMMITTER_NAME}, 'Someone Else',
		'a caller-supplied committer wins over the author fallback';
};

# ======================================================================
# Idempotency
# ======================================================================

subtest 'provisioning twice reuses the first materialisation' => sub {
	plan tests => 2;

	local %ENV = (%ENV);
	delete $ENV{$_} for @VARS;
	$ENV{GIT_PRIVATE_KEY} = $FAKE_KEY;
	Service::Git::reset_ci_credentials();

	Service::Git::provision_ci_credentials();
	my $first = $ENV{GIT_SSH_COMMAND};

	lives_ok {Service::Git::provision_ci_credentials()}
		'a second call does not die';
	is $ENV{GIT_SSH_COMMAND}, $first,
		'and does not rewrite the credentials it already provisioned';
};

done_testing;
