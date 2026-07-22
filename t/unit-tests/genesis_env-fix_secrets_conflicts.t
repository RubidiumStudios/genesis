#!/usr/bin/env perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use Test::Exception;
use_ok 'Genesis::Env';

# ---------------------------------------------------------------------------
# _manifest_secret_credhub_conflicts identifies the non-entombed credhub paths
# that collide with manifest-sourced secrets.  Fixing secrets in a vaultified
# environment is only unsafe for that intersection; disjoint credhub paths are
# harmless and must not block the operation.
# ---------------------------------------------------------------------------

{
	package FakeSecret;
	sub new { my ($c, %o) = @_; bless {%o}, $c }
	sub from_manifest { $_[0]->{from_manifest} }
	sub var_name      { $_[0]->{var_name} }
}
{
	package FakePlan;
	sub new { my ($c, @s) = @_; bless {secrets => [@s]}, $c }
	sub secrets { @{$_[0]->{secrets}} }
}
{
	package FakeCredhub;
	sub new { my ($c, $base, @paths) = @_; bless {base => $base, paths => [@paths]}, $c }
	sub base  { $_[0]->{base} }
	sub paths { @{$_[0]->{paths}} }
}

# Run $code with the three accessors the helper consults stubbed out.
sub with_env (&%) {
	my ($code, %opts) = @_;
	my $env = bless {}, 'Genesis::Env';
	no warnings 'redefine', 'once';
	local *Genesis::Env::is_vaultified = sub { $opts{vaultified} };
	local *Genesis::Env::secrets_plan  = sub { $opts{plan} };
	local *Genesis::Env::credhub       = sub { $opts{credhub} };
	return $code->($env);
}

my $manifest = sub { FakeSecret->new(from_manifest => 1, var_name => $_[0]) };
my $kit      = sub { FakeSecret->new(from_manifest => 0, var_name => undef) };

subtest 'not vaultified returns no conflicts' => sub {
	plan tests => 1;
	my @c = with_env {
		$_[0]->_manifest_secret_credhub_conflicts
	}
	vaultified => 0,
	plan       => FakePlan->new($manifest->('foo/bar')),
	credhub    => FakeCredhub->new('/secret/env/', '/secret/env/foo/bar');
	is_deeply([@c], [], 'no conflicts when environment is not vaultified');
};

subtest 'no manifest secrets returns no conflicts' => sub {
	plan tests => 1;
	my @c = with_env {
		$_[0]->_manifest_secret_credhub_conflicts
	}
	vaultified => 1,
	plan       => FakePlan->new($kit->()),
	credhub    => FakeCredhub->new('/secret/env/', '/secret/env/foo/bar');
	is_deeply([@c], [], 'no conflicts when no secret is manifest-sourced');
};

subtest 'intersecting path is reported as a conflict' => sub {
	plan tests => 1;
	my @c = with_env {
		$_[0]->_manifest_secret_credhub_conflicts
	}
	vaultified => 1,
	plan       => FakePlan->new($manifest->('foo/bar'), $manifest->('baz/qux')),
	credhub    => FakeCredhub->new('/secret/env/', '/secret/env/foo/bar');
	is_deeply([@c], ['foo/bar'], 'the credhub path matching a manifest secret is a conflict');
};

subtest 'disjoint credhub paths do not conflict' => sub {
	plan tests => 1;
	my @c = with_env {
		$_[0]->_manifest_secret_credhub_conflicts
	}
	vaultified => 1,
	plan       => FakePlan->new($manifest->('foo/bar')),
	credhub    => FakeCredhub->new('/secret/env/', '/secret/env/unrelated/leftover');
	is_deeply([@c], [], 'credhub paths that no manifest secret owns are not conflicts');
};

subtest 'entombed credhub paths are excluded' => sub {
	plan tests => 1;
	my @c = with_env {
		$_[0]->_manifest_secret_credhub_conflicts
	}
	vaultified => 1,
	plan       => FakePlan->new($manifest->('genesis-entombed/foo--bar--abc123')),
	credhub    => FakeCredhub->new('/secret/env/', '/secret/env/genesis-entombed/foo--bar--abc123');
	is_deeply([@c], [], 'entombed paths are never treated as conflicts');
};

subtest 'multiple conflicts returned sorted' => sub {
	plan tests => 1;
	my @c = with_env {
		$_[0]->_manifest_secret_credhub_conflicts
	}
	vaultified => 1,
	plan       => FakePlan->new($manifest->('b/two'), $manifest->('a/one')),
	credhub    => FakeCredhub->new('/secret/env/',
		'/secret/env/b/two', '/secret/env/a/one', '/secret/env/c/three');
	is_deeply([@c], ['a/one', 'b/two'], 'conflicts are returned sorted, disjoint path omitted');
};

subtest 'undef credhub base bails loudly' => sub {
	plan tests => 1;
	throws_ok {
		with_env {
			$_[0]->_manifest_secret_credhub_conflicts
		}
		vaultified => 1,
		plan       => FakePlan->new($manifest->('foo/bar')),
		credhub    => FakeCredhub->new(undef, '/secret/env/foo/bar');
	} qr/credhub base is unset/i,
		'unset credhub base is a bail, not a silent no-match';
};

subtest 'credhub base without trailing slash still matches' => sub {
	plan tests => 1;
	my @c = with_env {
		$_[0]->_manifest_secret_credhub_conflicts
	}
	vaultified => 1,
	plan       => FakePlan->new($manifest->('foo/bar')),
	credhub    => FakeCredhub->new('/secret/env', '/secret/env/foo/bar');
	is_deeply([@c], ['foo/bar'],
		'trailing slash is normalized so the conflict is detected either way');
};

done_testing;
