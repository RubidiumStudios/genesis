#!/usr/bin/env perl
# Proves T435 (D126): a commit line quotes its subject, and prints an
# outcome only where the commit's differs from its environment's, which is a
# held commit's.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use Test::More;

use Genesis::CI::Report;

$ENV{GENESIS_OUTPUT_COLUMNS} = 999;
$ENV{NOCOLOR} = 1;

sub rendered {
	my ($how, $record) = @_;
	my $out = '';
	open my $saved, '>&', \*STDERR or die "dup STDERR: $!";
	close STDERR;
	open STDERR, '>', \$out or die "capture STDERR: $!";
	my $ok = eval {
		$how eq 'preview'
			? Genesis::CI::Report::render_preview($record)
			: Genesis::CI::Report::render_run($record);
		1;
	};
	my $error = $@;
	close STDERR;
	open STDERR, '>&', $saved or die "restore STDERR: $!";
	close $saved;
	die $error unless $ok;
	return $out;
}

my $sha = sub {substr($_[0] x 40, 0, 40)};

sub a_record {
	my (%opts) = @_;
	return {environments => [{
		env            => 'qa',
		outcome        => $opts{outcome},
		outcome_detail => undef,
		error          => undef,
		certified      => undef,
		hold           => undef,
		pending        => [
			{control_commit => $sha->('a'), subject => 'Tune qa', outcome => $opts{word}},
			{control_commit => $sha->('b'), subject => 'Bump ops', outcome => $opts{word},
			 rides => [{control_commit => $sha->('c'), subject => 'Broken bump',
			            reason => 'qa declares the kit x/1, which the commit cccccccccc does not carry.'}]},
		],
		held => [{
			control_commit => $sha->('d'), subject => 'Shared change',
			outcome => 'held', reason => 'on-hold', hold_reason => 'change window',
		}],
	}]};
}

subtest 'a run' => sub {
	plan tests => 6;
	my $out = rendered(run => a_record(outcome => 'propagated', word => 'delivered'));
	like($out, qr/^\s*qa: propagated/m, 'the environment says propagated');
	like($out, qr/^\s*control\@aaaaaaa "Tune qa"\s*$/m,
		'a delivered commit quotes its subject and prints no word');
	like($out, qr/^\s*control\@bbbbbbb "Bump ops"\s*$/m, 'so does the next');
	like($out, qr/with control\@ccccccc "Broken bump".*\(qa declares the kit x\/1, which the commit cccccccccc does not carry\.\)/,
		'a riding commit is quoted, with its whole reason');
	like($out, qr/^\s*control\@ddddddd "Shared change"\s+held\b/m,
		'a held commit quotes its subject and says held');
	unlike($out, qr/\bdelivered\b/, 'and delivered is never printed');
};

subtest 'a preview' => sub {
	plan tests => 3;
	my $out = rendered(preview => a_record(outcome => undef));
	like($out, qr/^\s*qa: would propagate/m, 'the environment says would propagate');
	like($out, qr/^\s*control\@aaaaaaa "Tune qa"\s*$/m,
		'a commit it would deliver prints no word');
	unlike($out, qr/would deliver/, 'and would deliver is never printed');
};

done_testing;
