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

subtest 'a gate written with no reason is present and empty' => sub {
	plan tests => 2;

	# An operator who writes the trailer and forgets the reason has still
	# set a gate, and the value atom alone cannot say so, because it prints
	# for an empty reason exactly what it prints for no trailer at all.  A
	# reader that could not tell the two apart would let the walk through a
	# hold somebody meant to set.
	my $h = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');

	my $blank = commit_on_control($h,
		files    => {'qa.yml' => "---\nkit: dev\n"},
		message  => 'change the schema and forget to say why',
		trailers => {'Genesis-Stage' => ''},
	);

	my $gated = Genesis::CI::Marker::trailers($git, $blank);
	ok(exists $gated->{stage},
		'the trailer the commit carries is present even with nothing after it');
	is($gated->{stage}, '',
		'and its reason is an empty string the caller can refuse');
};

subtest 'a key written twice comes back joined' => sub {
	plan tests => 2;

	# The trailers are written into the message itself, because one commit
	# carries the same key twice and the harness's trailers option is a hash.
	my $h = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');

	my $first = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change the schema',
	);
	my $second = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\nsecond: true\n"},
		message => 'change the schema again',
	);
	my $repeated = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\nthird: true\n"},
		message => "undo both schema changes\n\n".
			"Genesis-Release-Stage: $first\n".
			"Genesis-Release-Stage: $second\n",
	);

	my $released = Genesis::CI::Marker::trailers($git, $repeated);
	is($released->{release_stage}, "$first,$second",
		'the two values come back joined by the separator git is asked for');
	unlike($released->{release_stage}, qr/^[0-9a-f]{40}$/,
		'and the joined value is no longer a sha a caller can resolve');
};

subtest 'a commit this repository cannot resolve answers nothing' => sub {
	plan tests => 2;

	# A release trailer names a control commit by sha, so a caller asking
	# about a sha this copy has never fetched is an ordinary caller.  Git
	# writes its refusal on stderr and answers nothing on stdout, and a read
	# that merged the two would hand the complaint back as both values and
	# report a gate the commit never set.
	my $h = make_harness(envs => ['qa'], vault => 0);
	my $git = $h->git('a');

	my $absent = '0' x 40;
	is_deeply(Genesis::CI::Marker::trailers($git, $absent), {},
		'a sha the repository does not hold gives nothing at all');
	is_deeply(Genesis::CI::Marker::trailers($git, 'no-such-branch'), {},
		'and so does a ref that names nothing');
};

done_testing;
