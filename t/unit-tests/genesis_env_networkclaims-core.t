#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use helper;

use Test::More;
use Test::Output;

use Genesis;
use_ok 'Genesis::Env::NetworkClaims';

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

sub record {
	my (%claims) = @_;
	return {subnets => {'ocfp-2' => {claims => {%claims}}}};
}

subtest 'claims_flat - joins nested keys, keeps strings, and drops empty containers' => sub {
	is_deeply(
		Genesis::Env::NetworkClaims::claims_flat({net => {subnets => {a => {claims => '10.0.0.1-10.0.0.3'}}}}),
		{'net.subnets.a.claims' => '10.0.0.1-10.0.0.3'}, 'nested keys become dotted paths'
	);
	is_deeply(Genesis::Env::NetworkClaims::claims_flat({net => {subnets => {}}}), {}, 'an empty hash is dropped');
	is_deeply(Genesis::Env::NetworkClaims::claims_flat({a => undef}), {a => ''}, 'an undefined value is the empty string');
};

subtest 'claims_changes - reports the addresses added and removed per network and subnet' => sub {
	my @changes = Genesis::Env::NetworkClaims::claims_changes(
		record(ocf => '10.0.0.1-10.0.0.4', gone => '10.0.0.9'),
		record(ocf => '10.0.0.1-10.0.0.6', fresh => '10.0.0.20')
	);
	is_deeply(\@changes, [
		{network => 'fresh', subnet => 'ocfp-2', added => '10.0.0.20',          removed => ''},
		{network => 'gone',  subnet => 'ocfp-2', added => '',                   removed => '10.0.0.9'},
		{network => 'ocf',   subnet => 'ocfp-2', added => '10.0.0.5-10.0.0.6', removed => ''},
	], 'each change names its network, subnet, and addresses, sorted by network');
	is_deeply([Genesis::Env::NetworkClaims::claims_changes(record(ocf => '10.0.0.1-10.0.0.4'), record(ocf => '10.0.0.1-10.0.0.2,10.0.0.3-10.0.0.4'))], [],
		'a range that changed in text but not in addresses is no change');
};

subtest 'claims_summary - says what a write changes, or that it keeps the same addresses' => sub {
	my ($out, $err) = output_from {
		Genesis::Env::NetworkClaims::claims_summary('secret/exodus/x/network', record(ocf => '10.0.0.1-10.0.0.4'), record(ocf => '10.0.0.2-10.0.0.6'))
	};
	my $all = ($out.$err) =~ s/\s+/ /gr;
	like($all, qr{the network claims at secret/exodus/x/network change: ocf \(ocfp-2\): adds 10\.0\.0\.5-10\.0\.0\.6, removes 10\.0\.0\.1},
		'a change lists what it adds and removes');
	($out, $err) = output_from {
		Genesis::Env::NetworkClaims::claims_summary('secret/exodus/x/network', record(ocf => '10.0.0.1'), record(ocf => '10.0.0.1'))
	};
	like(($out.$err) =~ s/\s+/ /gr, qr{the network claims at secret/exodus/x/network keep the same addresses}, 'no change says so');
};

done_testing;
