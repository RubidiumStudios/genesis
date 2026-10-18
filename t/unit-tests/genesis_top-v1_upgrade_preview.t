#!perl
# Proves T408: a preview writes nothing, so it does not run the version 1
# upgrade, which rewrites .genesis/config as it loads (runbook finding 30).
# It refuses, naming a command that upgrades the file, and leaves it as it was.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;
use Test::Output;
use Test::Exit;
use File::Path qw/make_path/;

use Genesis qw/slurp mkfile_or_fail pushd popd/;
use Genesis::Commands;
use Genesis::Exit qw/CONFIG/;
use Genesis::Top;
provide_rc();

$ENV{NOCOLOR} = 1;
$ENV{GENESIS_OUTPUT_COLUMNS} = 999;

require './bin/genesis';

subtest 'a preview refuses to upgrade a version 1 configuration' => sub {
	plan tests => 3;

	my $repo = workdir('v1-preview');
	make_path("$repo/.genesis");
	mkfile_or_fail("$repo/.genesis/config", "deployment_type: bosh\n");
	my $before = slurp("$repo/.genesis/config");
	$Genesis::RC->set('automatic_config_upgrade', 'yes');

	pushd $repo;
	prepare_command('pipeline-describe');
	build_command_environment;
	local $ENV{GENESIS_IGNORE_EVAL} = 1;
	my $code;
	my $err = stderr_from {$code = exit_code {Genesis::Top->new($repo)->type}};
	popd;

	is($code, CONFIG, 'the preview refuses at CONFIG');
	like($err =~ s/\s+/ /gr, qr/version 1.*preview writes nothing.*genesis config/,
		'saying why, and naming a command that upgrades the file');
	is(slurp("$repo/.genesis/config"), $before, 'and leaves the file as it was');
};

done_testing;
