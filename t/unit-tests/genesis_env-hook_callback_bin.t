#!/usr/bin/env perl
# Proves T454: a hook calls back into the Genesis running it, never into a
# working tree.  A packed binary extracts its runtime to
# $GENESIS_HOME/.genesis and runs it from there, while the process's
# GENESIS_CALLBACK_BIN names the packed file, which in a pipeline task is the
# repository's .genesis/bin/genesis and goes with any branch the clone checks
# out.  Hooks are given the extracted runtime instead; the process's value,
# which embed copies, is left alone.
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use File::Temp ();

use Genesis::Env;

sub runtime {
	my $home = File::Temp->newdir();
	helper::mkdir_or_fail("$home/.genesis/lib");
	helper::put_file("$home/.genesis/genesis", 0755, "#!/bin/sh\n");
	helper::put_file("$home/.genesis/lib/Genesis.pm", "1;\n");
	return $home;
}

subtest 'running from the extracted runtime' => sub {
	my $home = runtime();
	local $ENV{GENESIS_HOME}         = "$home";
	local $ENV{GENESIS_CALLBACK_BIN} = '/clone/doomsday/.genesis/bin/genesis';
	local $INC{'Genesis.pm'}         = "$home/.genesis/lib/Genesis.pm";
	is(Genesis::Env::hook_callback_bin(), "$home/.genesis/genesis",
		'a hook calls back into the runtime');
	is($ENV{GENESIS_CALLBACK_BIN}, '/clone/doomsday/.genesis/bin/genesis',
		"and the process's own value is unchanged");
};

subtest 'running from anywhere else' => sub {
	my $home = runtime();
	local $ENV{GENESIS_HOME}         = "$home";
	local $ENV{GENESIS_CALLBACK_BIN} = '/src/genesis/bin/genesis';
	local $INC{'Genesis.pm'}         = '/src/genesis/lib/Genesis.pm';
	is(Genesis::Env::hook_callback_bin(), '/src/genesis/bin/genesis',
		"a hook is given the process's value");
};

done_testing;
