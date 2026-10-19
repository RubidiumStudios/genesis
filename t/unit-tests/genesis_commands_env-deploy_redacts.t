#!perl
# Proves deploy_redacts, the deploy's default for --redact.  Off a terminal
# the deploy redacts, unless the pipeline's task says CI_NO_REDACT, which
# the emitter sets from pipeline.unredacted (plumbing contract f9).  prove
# runs a row with STDOUT off a terminal, so every row here is the pipeline's
# case; the terminal arm is the -t test itself.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

use Genesis;
use Genesis::Commands;
use Genesis::Commands::Env qw/deploy_redacts/;

$ENV{NOCOLOR} = 1;

plan skip_all => 'STDOUT is a terminal' if -t STDOUT;

{
	local $ENV{CI_NO_REDACT};
	ok(deploy_redacts(), 'off a terminal the deploy redacts');
}
for my $off (qw/0 false/, '') {
	local $ENV{CI_NO_REDACT} = $off;
	ok(deploy_redacts(), "and still does with CI_NO_REDACT '$off'");
}
for my $on (qw/1 true/) {
	local $ENV{CI_NO_REDACT} = $on;
	ok(!deploy_redacts(), "but not with CI_NO_REDACT '$on'");
}

done_testing;
