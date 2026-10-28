#!/usr/bin/env perl
# fetch-kit takes an environment in place of a kit, and fetches the kit that
# environment names, read from its files without the kit itself, which is
# what is being fetched.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Exception;

use Genesis;
use Genesis::Commands;
use Genesis::Top;
use Genesis::Commands::Kit;

provide_rc();
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

require './bin/genesis';

subtest 'fetch-kit accepts an environment' => sub {
	my $scope = command_properties('fetch-kit')->{scope};
	ok((grep {$_ eq 'env'} ref($scope) ? @$scope : ($scope)),
		'fetch-kit is env-scoped, so an environment file may lead the command');
	ok((grep {$_ eq 'repo'} ref($scope) ? @$scope : ($scope)),
		'and still repo-scoped, so a bare fetch-kit still runs in a repository');
};

subtest 'an environment argument resolves to the kit it names' => sub {
	my $top = Genesis::Top->create(workdir(), 'vault', no_vault => 1);
	put_file($top->path('lab.yml'), <<EOF);
---
kit:
  name:    vault
  version: 2.0.1
genesis:
  env: lab
EOF
	# Hierarchical: the kit block comes from lab.yml alone.
	put_file($top->path('lab-west.yml'), <<EOF);
---
genesis:
  env: lab-west
EOF
	put_file($top->path('devkit.yml'), <<EOF);
---
kit:
  name:    dev
  version: latest
genesis:
  env: devkit
EOF

	is(Genesis::Commands::Kit::_kit_sig_for($top, 'lab'), 'vault/2.0.1',
		'an environment names its kit and version');
	is(Genesis::Commands::Kit::_kit_sig_for($top, 'lab-west.yml'), 'vault/2.0.1',
		'a file name is taken, and the kit is read through the hierarchy');
	is(Genesis::Commands::Kit::_kit_sig_for($top, 'vault/2.0.0'), 'vault/2.0.0',
		'a kit signature is left as it is');
	is(Genesis::Commands::Kit::_kit_sig_for($top, '2.0.0'), '2.0.0',
		'and so is a bare version');
	throws_ok {Genesis::Commands::Kit::_kit_sig_for($top, 'devkit')}
		qr/dev kit/, 'an environment on a dev kit has nothing to fetch';
};

done_testing;
