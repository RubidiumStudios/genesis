#!perl
use strict;
use warnings;

use Test::More;
use lib 'lib';

$ENV{GENESIS_TESTING} = "yes";
$ENV{GENESIS_LIB}     ||= 'lib';

use_ok 'Genesis::CI::Layout';

### ============================================================ ###
### parse() — tokenizer and rule dispatch
### ============================================================ ###

subtest 'simple linear chain' => sub {
	my $layout = Genesis::CI::Layout->parse("sandbox -> preprod -> prod");

	is_deeply [sort @{$layout->{envs}}], [qw(preprod prod sandbox)],
		"envs contains all three";

	is_deeply $layout->{will_trigger}{sandbox}, ['preprod'],
		"sandbox triggers preprod";
	is_deeply $layout->{will_trigger}{preprod}, ['prod'],
		"preprod triggers prod";
	ok !exists $layout->{will_trigger}{prod},
		"prod triggers nothing";

	is $layout->{triggers}{preprod}, 'sandbox', "preprod triggered by sandbox";
	is $layout->{triggers}{prod},    'preprod', "prod triggered by preprod";
	ok !exists $layout->{triggers}{sandbox}, "sandbox has no trigger";
};

subtest 'semicolon-separated rules' => sub {
	my $layout = Genesis::CI::Layout->parse("sandbox -> preprod ; preprod -> prod");

	is_deeply [sort @{$layout->{envs}}], [qw(preprod prod sandbox)],
		"envs from semicolon rules";
	is $layout->{triggers}{preprod}, 'sandbox', "trigger inversion correct";
	is $layout->{triggers}{prod},    'preprod', "trigger inversion correct";
};

subtest 'newline as rule separator' => sub {
	my $layout = Genesis::CI::Layout->parse("sandbox -> preprod\npreprod -> prod");

	is_deeply [sort @{$layout->{envs}}], [qw(preprod prod sandbox)],
		"envs from newline-separated rules";
	is $layout->{triggers}{prod}, 'preprod', "trigger inversion works across newlines";
};

subtest 'comment stripping' => sub {
	my $layout = Genesis::CI::Layout->parse(
		"# this is a comment\n" .
		"sandbox -> preprod # inline comment\n" .
		"preprod -> prod"
	);

	is_deeply [sort @{$layout->{envs}}], [qw(preprod prod sandbox)],
		"comments stripped, envs correct";
};

subtest 'auto directive — basic pattern match' => sub {
	my $layout = Genesis::CI::Layout->parse(
		"auto sandbox*\n" .
		"sandbox -> preprod -> prod"
	);

	is_deeply $layout->{auto}, ['sandbox'],
		"auto matches sandbox via glob pattern";
	is_deeply [sort @{$layout->{envs}}], [qw(preprod prod sandbox)],
		"envs still contains all environments";
};

subtest 'auto directive — multiple patterns' => sub {
	my $layout = Genesis::CI::Layout->parse(
		"auto sandbox*\n" .
		"auto preprod*\n" .
		"sandbox -> preprod -> prod"
	);

	is_deeply [sort @{$layout->{auto}}], [qw(preprod sandbox)],
		"both auto patterns matched";
};

subtest 'auto directive — pattern matches nothing (warning only, no error)' => sub {
	# A pattern that matches nothing should warn but not die
	my $layout;
	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };

	eval {
		$layout = Genesis::CI::Layout->parse(
			"auto nomatch*\n" .
			"sandbox -> preprod"
		);
	};
	ok !$@, "no die on unmatched auto pattern";
	ok defined $layout, "layout still returned";
	is_deeply $layout->{auto}, [], "auto is empty when pattern matches nothing";
};

subtest 'auto directive — with known_envs for expansion' => sub {
	my $layout = Genesis::CI::Layout->parse(
		"auto sandbox*\n" .
		"sandbox -> preprod",
		known_envs => [qw(sandbox preprod prod staging)],
	);

	is_deeply $layout->{auto}, ['sandbox'],
		"auto expanded against known_envs";
};

subtest 'fan-out — parallel chains from one env' => sub {
	my $layout = Genesis::CI::Layout->parse(
		"sandbox -> preprod\n" .
		"sandbox -> staging"
	);

	is_deeply [sort @{$layout->{will_trigger}{sandbox}}], [qw(preprod staging)],
		"sandbox triggers both preprod and staging";

	is $layout->{triggers}{preprod}, 'sandbox', "preprod triggered by sandbox";
	is $layout->{triggers}{staging}, 'sandbox', "staging triggered by sandbox";
};

subtest 'isolated env — no edges' => sub {
	my $layout = Genesis::CI::Layout->parse("sandbox");

	is_deeply $layout->{envs}, ['sandbox'], "isolated env is in envs list";
	is_deeply $layout->{will_trigger}, {}, "no will_trigger for isolated env";
	is_deeply $layout->{triggers},     {}, "no triggers for isolated env";
	is_deeply $layout->{auto},         [], "no auto by default";
};

### ============================================================ ###
### Error cases
### ============================================================ ###

subtest 'error — auto with no arguments' => sub {
	eval { Genesis::CI::Layout->parse("auto") };
	like $@, qr/auto.*argument/i, "dies with helpful message";
};

subtest 'error — missing target after ->' => sub {
	eval { Genesis::CI::Layout->parse("sandbox ->") };
	like $@, qr/missing target/i, "dies on missing -> target";
};

subtest 'error — invalid token in chain (not ->)' => sub {
	eval { Genesis::CI::Layout->parse("sandbox foo preprod") };
	like $@, qr/invalid|expecting/i, "dies on bad separator token";
};

subtest 'error — unknown env with known_envs provided' => sub {
	eval {
		Genesis::CI::Layout->parse(
			"totally-unknown -> preprod",
			known_envs => [qw(sandbox preprod prod)],
		);
	};
	like $@, qr/totally-unknown/i, "dies on env not in known_envs";
};

subtest 'error — double trigger (env triggered by two envs)' => sub {
	eval {
		Genesis::CI::Layout->parse(
			"sandbox -> prod\n" .
			"preprod -> prod"
		);
	};
	like $@, qr/prod.*triggered.*more than once|already.*triggered/i,
		"dies on duplicate trigger of same env";
};

subtest 'error — unrecognized directive without known_envs' => sub {
	# Without known_envs, any identifier is valid as an env name.
	# Only truly invalid tokens (e.g. bare ->) should fail.
	eval { Genesis::CI::Layout->parse("->") };
	like $@, qr/invalid|unrecognized|unexpected/i,
		"dies on bare -> as first token";
};

### ============================================================ ###
### Returned data structure completeness
### ============================================================ ###

subtest 'all four keys always present in result' => sub {
	my $layout = Genesis::CI::Layout->parse("sandbox -> preprod");

	ok exists $layout->{auto},         "auto key present";
	ok exists $layout->{envs},         "envs key present";
	ok exists $layout->{will_trigger}, "will_trigger key present";
	ok exists $layout->{triggers},     "triggers key present";

	is ref($layout->{auto}),         'ARRAY', "auto is arrayref";
	is ref($layout->{envs}),         'ARRAY', "envs is arrayref";
	is ref($layout->{will_trigger}), 'HASH',  "will_trigger is hashref";
	is ref($layout->{triggers}),     'HASH',  "triggers is hashref";
};

done_testing;
