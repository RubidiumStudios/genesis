#!/usr/bin/env perl
# Proves that the renderer prints an error message whole whatever braces it
# carries, and that the commit axis takes its words from the enum the module
# declares rather than from a literal written beside the line.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use Genesis::CI::Report;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

# The renderer speaks through info, which writes on standard error, so a row
# that weighs a printed word reads it back from there.  The handle is put back
# whether the render answered or died, because a row that left it redirected
# would swallow the whole file's diagnostics.
sub rendered {
	my ($record) = @_;
	my $out = '';
	open my $saved, '>&', \*STDERR or die "dup STDERR: $!";
	close STDERR;
	open STDERR, '>', \$out or die "capture STDERR: $!";
	my $ok = eval {Genesis::CI::Report::render_run($record); 1};
	my $error = $@;
	close STDERR;
	open STDERR, '>&', $saved or die "restore STDERR: $!";
	close $saved;
	return ($out, $ok ? undef : $error);
}

# One environment's record as the walk hands it over, with only the fields
# the renderer reads filled in.
sub a_record {
	my (%opts) = @_;
	return {environments => [{
		env            => 'qa',
		outcome        => $opts{outcome} // 'propagated',
		outcome_detail => undef,
		error          => $opts{error},
		hold           => undef,
		held           => $opts{held} // [],
		pending        => $opts{pending} // [],
	}]};
}

subtest 'an error message prints whole whatever braces it carries' => sub {
	plan tests => 2;

	# A YAML reader quotes the brace it was looking for, so the message an
	# operator has to read carries one that nothing in it closes.
	my $message = "could not be loaded: did not find expected ',' or '}'";

	my ($out, $died) = rendered(a_record(outcome => 'failed', error => $message));
	is($died, undef, 'the render answered');
	like($out, qr/\Q$message\E/, 'the message reaches the operator unaltered');
};

subtest 'the commit axis takes its words from the enum' => sub {
	plan tests => 3;

	my $commit = {
		control_commit => 'abcdef1234567890abcdef1234567890abcdef12',
		subject        => 'Tune qa',
	};

	my ($out, $died) = rendered(a_record(pending => [$commit]));
	is($died, undef, 'a commit the enum knows renders');
	like($out, qr/\bdelivered\b/, 'and reads with the enum word');

	my (undef, $refused) = rendered(
		a_record(pending => [{%$commit, outcome => 'shipped'}]));
	like($refused // '', qr/shipped/,
		'a word outside the enum is refused by name');
};

done_testing;
