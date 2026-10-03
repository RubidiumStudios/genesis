#!/usr/bin/env perl
# A cached manifest is found by a file name carrying its signature, so each
# manifest type signs what its merge reads.  An environment-only type reads
# the environment's hierarchy files and nothing else.  A type that merges the
# kit's files also reads whatever the blueprint picks, local ops files
# included, which only running the blueprint names.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use Genesis;
use Genesis::Top;

provide_rc();
$ENV{GENESIS_OUTPUT_COLUMNS} = 80;

my %FILES = (
	'us.yml'      => "---\nparams:\n  region: one\n",
	'us-west.yml' => "---\nkit:\n  name: dev\n  version: latest\n"
	               . "genesis:\n  env: us-west\n",
);

# A checkout of the same environment files, with its own local ops file.
sub checkout {
	my ($ops) = @_;
	my $top = make_top(name => 'thing', no_vault => 1);
	cp_kit('t/src/simple', $top);
	put_file($top->path($_), $FILES{$_}) for keys %FILES;
	put_file($top->path('ops/custom.yml'), $ops);
	return $top;
}

sub signatures {
	my ($top) = @_;
	my $provider = Genesis::Top->new($top->path, no_vault => 1)
		->load_env('us-west')->manifest_provider;
	return (
		environment => $provider->partial_environment->signature,
		vaultless   => $provider->vaultless_environment->signature,
		kit         => $provider->unevaluated->signature,
	);
}

subtest 'a local ops file is signed only where the kit is merged' => sub {
	plan tests => 3;

	my %one = signatures(checkout("---\n- type: remove\n  path: /a\n"));
	my %two = signatures(checkout("---\n- type: remove\n  path: /b\n"));

	is($two{environment}, $one{environment},
		'an environment-only manifest is shared by the two checkouts');
	is($two{vaultless}, $one{vaultless},
		'and so is the vaultless one the shape is read from');
	isnt($two{kit}, $one{kit},
		'while a manifest that merges the kit is not, since the blueprint may '
		.'pick the ops file that differs');
};

subtest 'a dev kit file is signed only where the kit is merged' => sub {
	plan tests => 2;

	my $top    = checkout("---\n- type: remove\n  path: /a\n");
	my %before = signatures($top);
	put_file($top->path('dev/manifest.yml'),
		slurp($top->path('dev/manifest.yml'))."\n# edited\n");
	my %after = signatures($top);

	is($after{environment}, $before{environment},
		'an environment-only manifest reads no kit file, so an edit leaves it');
	isnt($after{kit}, $before{kit},
		'while a manifest that merges the kit takes the edit');
};

done_testing;
