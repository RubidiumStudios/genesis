#!/usr/bin/env perl
# Proves that the renderer prints an error message whole whatever braces it
# carries, that the commit axis takes its words from the enum the module
# declares rather than from a literal written beside the line, and that an
# environment arriving with no outcome of its own settles into the one the
# qualifier answers for it.
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
#
# The outcome is taken through an exists check rather than a defined-or.  A
# row that means to reach the qualifier has to hand the renderer a null
# outcome, since that is the only thing _settle fills in, and a defined-or
# would have turned the null back into propagated and settled nothing.
#
# The certified key is always written, to undef where the row passed none,
# because the qualifier's head guard asks whether the record defines it at
# all.  A builder that left the key out where it had no value would hand that
# guard a record it could not tell from one carrying an explicit undef, and
# the branchless row below would then pass against a guard weakened from a
# defined check to an exists one.
sub a_record {
	my (%opts) = @_;
	return {environments => [{
		env            => 'qa',
		outcome        => (exists $opts{outcome}
			? $opts{outcome} : 'propagated'),
		outcome_detail => undef,
		error          => $opts{error},
		certified      => $opts{certified},
		hold           => $opts{hold},
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
	plan tests => 5;

	my $commit = {
		control_commit => 'abcdef1234567890abcdef1234567890abcdef12',
		subject        => 'Tune qa',
	};

	my ($out, $died) =
		rendered(a_record(pending => [{%$commit, outcome => 'delivered'}]));
	is($died, undef, 'a commit the enum knows renders');
	like($out, qr/\bdelivered\b/, 'and reads with the enum word');

	# A commit nothing wrote a word onto is one that went nowhere, and the
	# axis says nothing about it rather than reading it the word for the one
	# thing that did not happen to it.
	#
	# The error is captured and weighed as it is on either side of this,
	# because a render that raised would leave the text short of the word
	# and the assertion under it would read that as the word being absent
	# by design.
	my ($bare, $bare_died) = rendered(a_record(pending => [$commit]));
	is($bare_died, undef, 'a commit with no word of its own renders');
	unlike($bare, qr/\bdelivered\b/,
		'and a commit with no word of its own is not called delivered');

	my (undef, $refused) = rendered(
		a_record(pending => [{%$commit, outcome => 'shipped'}]));
	like($refused // '', qr/shipped/,
		'a word outside the enum is refused by name');
};

# The three rows below reach held_qualifier the way a run reaches it, which is
# through _settle, so each hands the renderer a record whose outcome is null.
# A record that arrives carrying an outcome never meets the qualifier at all,
# because _settle answers early on one, so a row that composed a held record
# and rendered it would have proved nothing about the wording.
#
# The last two carry a certified state, which is what keeps them clear of the
# branchless reading that stands at the head of the qualifier.  They are the
# fence around how narrow that reading is: a head that answered for any
# environment rather than for one the walk never read would take both of these
# with it.
subtest 'an environment the walk never read settles as awaiting the apply' => sub {
	plan tests => 3;

	my $record = a_record(outcome => undef);
	my (undef, $died) = rendered($record);
	is($died, undef, 'the render answered');

	my $env = $record->{environments}[0];
	is($env->{outcome}, 'held', 'the environment settles as held');
	is($env->{outcome_detail}, Genesis::CI::Report::AWAITING_APPLY,
		'with the awaiting phrase beside it');
};

subtest 'a standing hold is still what a settled environment reads' => sub {
	plan tests => 2;

	my $record = a_record(outcome => undef,
		certified => {state => 'certified'},
		hold      => {reason => 'waiting on the change window'});
	my (undef, $died) = rendered($record);
	is($died, undef, 'the render answered');
	is($record->{environments}[0]{outcome_detail},
		'needs clearing (waiting on the change window)',
		'an environment the walk did read reads its own hold');
};

subtest 'an approved pull request is still what a settled environment reads' => sub {
	plan tests => 2;

	my $record = a_record(outcome => undef,
		certified => {state => 'certified'},
		held      => [{
			reason         => 'awaiting-merge',
			number         => 42,
			control_commit => 'abcdef1234567890abcdef1234567890abcdef12',
			subject        => 'Tune qa',
		}]);
	my (undef, $died) = rendered($record);
	is($died, undef, 'the render answered');
	is($record->{environments}[0]{outcome_detail}, 'awaiting merge (#42)',
		'an environment the walk did read reads the merge it waits on');
};

done_testing;
