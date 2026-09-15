#!/usr/bin/env perl
# Proves T80, the trailer reader: the gate's reason, the release's sha, and
# nothing at all for a commit that carries neither.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use_ok 'Genesis::CI::Marker';

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the gate, its release, and a commit carrying neither' => sub {
	plan tests => 6;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');

	my $gate = commit_on_control($h,
		files    => {'qa.yml' => "---\nkit: dev\n"},
		message  => 'change the database schema',
		trailers => {'Genesis-Stage' => 'hold: migrate the database'},
	);
	my $plain_gate = commit_on_control($h,
		files    => {'qa.yml' => "---\nkit: dev\nnext: true\n"},
		message  => 'change the schema again',
		trailers => {'Genesis-Stage' => 'run the data fix first'},
	);
	my $release = commit_on_control($h,
		files    => {'qa.yml' => "---\nkit: dev\nthird: true\n"},
		message  => 'undo the schema change',
		trailers => {'Genesis-Release-Stage' => $gate},
	);
	my $ordinary = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\nfourth: true\n"},
		message => 'change qa',
	);

	my $gated = Genesis::CI::Marker::trailers($git, $gate);
	is($gated->{stage}, 'hold: migrate the database',
		'the hold form comes back as the trailer writes it');
	ok(!exists $gated->{release_stage},
		'and the key the commit does not carry is absent');

	is(Genesis::CI::Marker::trailers($git, $plain_gate)->{stage},
		'run the data fix first',
		'the plain gate form comes back the same way');

	is(Genesis::CI::Marker::trailers($git, $release)->{release_stage}, $gate,
		"the release names the gate's control commit");
	ok(!exists Genesis::CI::Marker::trailers($git, $release)->{stage},
		'and carries no stage of its own');

	is_deeply(Genesis::CI::Marker::trailers($git, $ordinary), {},
		'a commit carrying neither trailer gives nothing at all');
};

done_testing;
