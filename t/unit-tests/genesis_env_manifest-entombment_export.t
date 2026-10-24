#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;

# _entomb_secrets reads every vault path a manifest references with one safe
# export, and reads any path the export left out again on its own.  These
# tests run the real mixin in a stand-in manifest class whose environment,
# CredHub, and local vault record every side effect, in order, and whose vault
# is a real Service::Vault that answers safe from a script.

use Service::Vault;
use Genesis::Env::Secrets::Entombment qw/credhub_var_name/;
use Cwd ();

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Everything the harness and the vault are asked to do, in order.
my @EVENTS;

# The manifest class: the mixin is loaded into it as the manifest classes
# load it, and only what the mixin calls on its own object is stood in for.
package EntombHarness {
	do('Genesis/Env/Manifest/_entombment_mixin.pm') or die($@ || $!);

	no warnings qw/redefine once/;
	*EntombHarness::prime_credhub_cache = sub { push @EVENTS, ['prime_credhub_cache']; $_[0] };
	*EntombHarness::make_local_vault    = sub { push @EVENTS, ['local_vault']; bless({}, 'EntombLocalVault') };
	*EntombHarness::put_secret          = sub { push @EVENTS, ['put_secret', @_[1,2]]; 'new' };

	sub new {
		my ($class, $vault, @references) = @_;
		return bless({vault => $vault, references => {map {($_ => 1)} @references}}, $class);
	}
	sub env             { bless({vault => $_[0]{vault}}, 'EntombEnv') }
	sub builder         { bless({}, 'EntombBuilder') }
	sub get_vault_paths { $_[0]{references} }
}
package EntombEnv {
	sub name         { 'lab-mgmt' }
	sub notify       { }
	sub vault        { $_[0]{vault} }
	sub secrets_base { '/secret/' }
	sub credhub      { push @EVENTS, ['credhub_target']; bless({}, 'EntombCredhub') }
}
package EntombBuilder {
	sub unevaluated { }
}
package EntombCredhub {
	sub base         { '/lab-mgmt-bosh/lab-mgmt/' }
	sub get          { undef }
	sub preload      { }
	sub is_preloaded { 1 }
}
package EntombLocalVault {
	sub set { shift; push @EVENTS, ['local_vault_set', @_] }
}
package main;

sub test_vault { Service::Vault->new('https://vault.example.com:8200', 'test-vault', 1, '', undef, '/secret/') }

# A query that answers safe export with $export and safe get of a path with
# what %gets holds for it, which is safe's output, or [out, rc, stderr] for a
# get that fails.  A path it holds nothing for is absent, as safe says it.
# Paths are looked up as safe reads them, without one leading or trailing
# slash and with repeated slashes collapsed, and stderr goes where the
# caller sent it, as run() would send it.
sub safe_answers {
	my ($export, %gets) = @_;
	return sub {
		my (undef, $opts, @cmd) = @_;
		$opts = {} unless ref($opts) eq 'HASH';
		push @EVENTS, ['safe', @cmd];
		my $path = ($cmd[1] // '') =~ s{^/|/$}{}gr =~ s{/{2,}}{/}gr;
		my ($out, $rc, $err) =
			$cmd[0] eq 'export'          ? ($export, 0, '') :
			ref($gets{$path}) eq 'ARRAY' ? @{$gets{$path}} :
			defined($gets{$path})        ? ($gets{$path}, 0, '') :
			                               ('', 1, "!! no secret exists at path `$path`\n");
		return (join('', grep {defined} $out, $err), $rc, undef) if ($opts->{stderr} // '&1') eq '&1';
		return ($out, $rc, $err);
	};
}

# Entomb the references with safe answering as given, and return what was
# entombed as {credhub name => value}.  Progress goes to STDERR, so it is
# kept out of the test output.
sub entomb {
	my ($query, @references) = @_;
	@EVENTS = ();
	no warnings 'redefine';
	local *Service::Vault::query = $query;
	open(local *STDERR, '>', \my $progress) or die;
	EntombHarness->new(test_vault(), @references)->_entomb_secrets();
	return {map {($_->[1] => $_->[2])} grep {$_->[0] eq 'put_secret'} @EVENTS};
}

sub entombed_as { my ($path, $key, $value) = @_; (credhub_var_name($path, $key, $value, 'genesis-entombed/') => $value) }
sub safe_calls  { [map {[@{$_}[1..$#$_]]} grep {$_->[0] eq 'safe'} @EVENTS] }

# safe export of secret/a and secret/ab once gave only secret/a, so the
# second path is left out of the export, as that bug left it.
my $EXPORT_A = '{"secret/a":{"password":"apple"}}';
my $GET_AB   = "--- # secret/ab\npassword: banana\n\n";
my $REFUSED  = "Error making API request.\n\nURL: GET https://vault.example.com:8200/v1/secret/data/ab\nCode: 403. Errors:\n\n* 1 error occurred:\n\t* permission denied\n";

subtest 'entombment tells secret/a from secret/ab' => sub {
	plan tests => 1;
	my $entombed = entomb(safe_answers($EXPORT_A, 'secret/ab' => $GET_AB), 'secret/a:password', 'secret/ab:password');
	is_deeply($entombed, {entombed_as('a', 'password', 'apple'), entombed_as('ab', 'password', 'banana')},
		'each path reaches CredHub with its own value, the one the export left out read on its own');
};

subtest 'the fallback reads one secret and needs no list access' => sub {
	plan tests => 2;
	entomb(safe_answers($EXPORT_A, 'secret/ab' => $GET_AB), 'secret/a:password', 'secret/ab:password');
	my @calls = @{safe_calls()};
	is_deeply([sort @{shift(@calls)}], [sort qw{export /secret/a /secret/ab}], 'the export names both paths');
	is_deeply(\@calls, [['get', 'secret/ab']],
		'and the path it left out is read with one safe get of exactly that secret, with no key, and no export');
};

subtest 'the fallback reports a refused read' => sub {
	plan tests => 2;
	throws_ok {
		entomb(safe_answers($EXPORT_A, 'secret/ab' => ['', 1, $REFUSED]), 'secret/a:password', 'secret/ab:password')
	} qr{Could not read secret/ab from vault at https://vault\.example\.com:8200:\s.*Code: 403.*permission denied}s,
		'a refused read stops entombment, naming the path and the reason, rather than reading as an empty secret';
	ok(!grep({$_->[0] eq 'put_secret'} @EVENTS), 'and nothing reaches CredHub');
};

subtest 'the fallback reports a missing secret as having no value' => sub {
	plan tests => 1;
	throws_ok {
		entomb(safe_answers($EXPORT_A), 'secret/a:password', 'secret/ab:password')
	} qr{Manifest\s+references\s+vault\s+path\s+/secret/ab:password\s+which\s+has\s+no\s+value\s+in\s+the\s+vault},
		'a secret safe says does not exist is the reference with no value';
};

subtest 'every number shape reaches CredHub through the fallback as safe get prints it' => sub {
	# What safe 1.26.0 prints for safe get of a secret holding one key for each
	# number shape that safe prints differently from the digits stored, made by
	# safe's own read path and encoder from the v1.26.0 tag, as the other files
	# under t/src/safe are.
	my $path = 'secret/fixture/numbers';
	my %printed = (
		big     => '12345678901234567000',
		e20     => '100000000000000000000',
		e21     => '1e+21',
		half    => '0.5',
		huge    => '1e+42',
		negzero => '-0',
		port    => '9000',
		tiny    => '1e-7',
	);
	plan tests => 2;
	my $entombed = entomb(
		safe_answers($EXPORT_A, $path => get_file(Cwd::abs_path('t/src/safe/get-numbers.out'))),
		'secret/a:password', map {"$path:$_"} sort keys %printed
	);
	is_deeply($entombed, {
		entombed_as('a', 'password', 'apple'),
		map {entombed_as('fixture/numbers', $_, $printed{$_})} sort keys %printed
	}, 'each number reaches CredHub as the text safe get prints, and the quoted 9000 stays 9000');
	is(scalar(grep {$_->[0] eq 'get'} @{safe_calls()}), 1, 'from one safe get of the secret');
};

done_testing;
