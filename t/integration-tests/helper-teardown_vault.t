#!/usr/bin/env perl
# teardown_vault stops the vaults a caller names, or every vault this process
# started when it names none.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Genesis qw/slurp/;

# The pid each vault was recorded under in this process's work area.
sub recorded_pid {
	my ($target) = @_;
	chomp(my $pid = slurp("$helper::TMP/vaults/$target.pid") // '');
	return $pid;
}

subtest 'a named vault is the one stopped' => sub {
	plan tests => 3;

	vault_start('helper-teardown-kept');
	vault_start('helper-teardown-named');
	my ($kept, $named) = map {recorded_pid($_)} qw/helper-teardown-kept helper-teardown-named/;

	teardown_vault('helper-teardown-named');
	my $deadline = time + 30;
	sleep 1 while kill(0, $named) && time < $deadline;

	ok(!kill(0, $named), 'the vault it named is stopped');
	ok(kill(0, $kept), 'and the one it did not name is still running');

	vault_start('helper-teardown-named');
	isnt(recorded_pid('helper-teardown-named'), $named,
		'and a later start of the named target starts a vault afresh');

	teardown_vault();
};

done_testing;
