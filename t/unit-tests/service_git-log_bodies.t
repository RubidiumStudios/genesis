#!/usr/bin/env perl
# The body walk log_subjects gains.  No row of the matrix proves it alone,
# and T79, T80, T81, and T85 all stand on it, so what is asserted here is the
# primitive's own contract.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'the line walk is what it was' => sub {
	plan tests => 2;

	my $h = make_harness(envs => ['qa'], vault => 0);
	commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => 'change qa',
	);

	my $git = $h->git('a');
	my @lines = $git->log_subjects($h->control, limit => 1);
	like($lines[0], qr/^[0-9a-f]{40} change qa$/,
		'the default format still gives one line of sha and subject');

	my ($subject) = $git->log_subjects($h->control, limit => 1, format => '%s');
	is($subject, 'change qa', 'and a caller-supplied format still gives lines');
};

subtest 'the body walk returns whole messages' => sub {
	plan tests => 5;

	my $h = make_harness(envs => ['qa'], vault => 0);
	my $sha = commit_on_control($h,
		files   => {'qa.yml' => "---\nkit: dev\n"},
		message => "change qa\n\nthe reason, on a line of its own\nand a third line\n",
	);

	my $git = $h->git('a');
	my @records = $git->log_subjects($h->control, body => 1, limit => 1);

	is(scalar @records, 1, 'one record for one commit');

	# The shape is asserted before anything is read out of it, and the
	# reads below go through a guarded copy, so a walk that still answers
	# with lines fails these assertions rather than dying on a string used
	# as a hash reference.
	is(ref $records[0], 'HASH', 'and the entry is a record rather than a line');
	my $record = ref $records[0] eq 'HASH' ? $records[0] : {};

	is($record->{sha}, $sha, 'the record carries the full sha');
	like($record->{message} // '', qr/\Achange qa\n/,
		'the message opens with the subject');
	like($record->{message} // '', qr/^the reason, on a line of its own$/m,
		'and carries the body the line walk cannot show');
};

subtest 'the pathspec scopes both walks' => sub {
	plan tests => 5;

	my $h = make_harness(envs => ['qa'], vault => 0);
	commit_on_control($h, files => {'qa.yml'    => "---\nkit: dev\n"},
		message => 'change qa');
	commit_on_control($h, files => {'other.yml' => "---\nkit: dev\n"},
		message => 'change something else');

	my $git = $h->git('a');
	my @lines = $git->log_subjects($h->control, paths => ['qa.yml']);
	is(scalar(grep {/change something else/} @lines), 0,
		'the line walk skips the commit that touched nothing in the pathspec');

	# An empty list satisfies the negation above, so the positive assertion
	# beside it is what fails if the pathspec ever drops everything rather
	# than only the commit it means to drop.
	is(scalar(grep {/ change qa$/} @lines), 1,
		'and keeps the commit that did touch it');

	my @records = $git->log_subjects($h->control, body => 1, paths => ['qa.yml']);
	is(scalar(grep {ref $_ ne 'HASH'} @records), 0,
		'the body walk answers with records under a pathspec too');
	is(scalar(grep {ref $_ eq 'HASH' && $_->{message} =~ /change something else/} @records), 0,
		'and so does the body walk');

	# The body walk's two negations are open the same way, so this says what
	# the walk must return rather than what it must not.
	is(scalar(grep {ref $_ eq 'HASH' && $_->{message} =~ /\Achange qa\n/} @records), 1,
		'and it keeps the commit that did touch the pathspec');
};

done_testing;
