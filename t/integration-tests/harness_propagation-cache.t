#!/usr/bin/env perl
# The harness caches what its builders build.  The first build of a set of
# arguments is kept under t/tmp/fixture-cache; a later build of the same
# arguments is restored from it into a base of its own, with its repositories,
# vault records and armed variables as the first build left them and every
# path moved to the new base.  A restored harness is indistinguishable from
# the build it was kept from.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;
use File::Find ();
use Genesis qw/run slurp/;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# Everything about a harness that a row can see, with its own base written as
# BASE so two harnesses in different directories compare equal.
sub state_of {
	my ($h) = @_;
	my %refs = map {
		my ($out) = run({dir => $h->{$_}}, 'git', 'for-each-ref',
			'--format=%(refname) %(objectname)');
		($_ => $out);
	} qw/r a b/;
	my ($records) = run({env => {SAFE_TARGET => $h->{vault_target}}, stderr => 0},
		'safe', 'export', $h->{mount});
	my %fields = map {
		my $v = $h->{$_};
		($_ => ref($v) ? JSON::PP->new->canonical->encode($v) : $v)
	} grep {!/^vault_url$/} keys %$h;
	my $json = JSON::PP->new->canonical->encode({
		refs => \%refs, records => $records, fields => \%fields,
		root => $ENV{GENESIS_ROOT},
	});
	$json =~ s/\Q$h->{base}\E/BASE/g;
	return $json;
}

# Every file under a base that names another base.
sub naming {
	my ($base, $other) = @_;
	my @found;
	File::Find::find({no_chdir => 1, wanted => sub {
		return if -d $_ || m{/objects/};
		push @found, $_ if index(slurp($_) // '', $other) >= 0;
	}}, $base);
	return @found;
}

subtest 'a second build of the same arguments is restored as the first' => sub {
	# Six, and the restoration run_genesis asserts for itself.
	plan tests => 7;

	my @args = (envs => ['lab', 'qa'], tracked => ['ops/cache-probe.yml']);
	my $first  = ready_harness(@args);
	my $state  = state_of($first);
	my $second = ready_harness(@args);

	isnt($second->{base}, $first->{base}, 'the second has a base of its own');
	ok(-d "$helper::TOPDIR/t/tmp/fixture-cache", 'which came from the cache');
	is(state_of($second), $state,
		'its repositories, records, fields and root are the first build\'s');
	is_deeply([naming($second->{base}, $first->{base})], [],
		'and no file under it names the first build\'s base');
	unlike(JSON::PP->new->canonical->encode({%$second}), qr/\Q$first->{base}\E/,
		'nor does any field');

	my (undef, $err, $rc) = run_genesis($second, 'pipeline-status');
	is($rc, 0, 'a restored harness runs a real genesis command') or diag $err;
};

subtest 'what a build armed is armed again on restore' => sub {
	plan tests => 3;

	ready(kit => 'omega-v2.7.0');
	my $second = ready(kit => 'omega-v2.7.0');
	ok($second->{gh}, 'the GitHub double is part of the restored harness');
	my (undef, $err, $rc) = run_genesis($second, 'pipeline-status');
	is($rc, 0, 'and a command reading through it runs') or diag $err;
};

subtest 'a build the cache cannot key is built afresh' => sub {
	plan tests => 2;

	local $ENV{GENESIS_HARNESS_NO_CACHE} = 1;
	my $a = make_harness(envs => ['qa'], vault => 0);
	my $b = make_harness(envs => ['qa'], vault => 0);
	my ($ta) = run({dir => $a->{r}}, 'git', 'rev-parse', 'control');
	my ($tb) = run({dir => $b->{r}}, 'git', 'rev-parse', 'control');
	isnt($ta, $tb, 'with the cache turned off, two builds are two builds');

	delete local $ENV{GENESIS_HARNESS_NO_CACHE};
	my $c = make_harness(envs => ['qa'], vault => 0, answers => sub {1});
	ok($c->{base}, 'and one with a code reference among its arguments still builds');
};

done_testing;
