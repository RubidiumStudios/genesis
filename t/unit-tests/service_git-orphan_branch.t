#!/usr/bin/env perl
# The two refusals the orphan creation makes before it writes anything.  D42
# has pipeline-apply cut a missing deployment branch as an orphan root commit,
# and the creation never moves a branch that is already there and never writes
# a root commit with no message on it.  Each refusal comes before the first
# object is hashed, so the repository is left exactly as it was found.
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

subtest 'it refuses to recreate a branch that is already there' => sub {
	plan tests => 4;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $slug = $h->slug('qa');
	init_branch($h, 'qa');

	my $before = ref_in($h->a, "refs/heads/$slug");
	my $heads  = heads_in($h);

	my ($err) = raised_from(sub {
		$h->git('a')->create_orphan_branch($slug,
			files   => {init => "a second beginning\n"},
			message => 'Initialize it all over again')});

	like($err, qr/Refusing\s+to\s+recreate/, 'the creation refuses');
	like($err, qr/\Q$slug\E/, 'and names the branch it was asked for');
	is(ref_in($h->a, "refs/heads/$slug"), $before,
		'and the branch that was there did not move');
	is_deeply(heads_in($h), $heads, 'and no other ref was written');
};

subtest 'it refuses a creation that carries no message' => sub {
	plan tests => 3;

	my $h     = make_harness(envs => ['qa'], vault => 0);
	my $slug  = $h->slug('qa');
	my $heads = heads_in($h);

	my ($err) = raised_from(sub {
		$h->git('a')->create_orphan_branch($slug,
			files => {init => "a beginning with nothing said about it\n"})});

	like($err, qr/with\s+no\s+message/, 'the creation refuses');
	like($err, qr/\Q$slug\E/, 'and names the branch it was called for');
	is_deeply(heads_in($h), $heads, 'and no ref was written');
};

# The assertion helper, which lives beside its test because it is about what
# this file means rather than about what a tree holds.  A row here cannot read
# a refusal out of this process the ordinary way, since bail and bug each die
# rather than exit whenever they are reached from inside an eval, and a test
# file always is.  Both are caught where the code raises them, and the message
# is composed from the arguments they were handed, so a row reads the words the
# operator would have been shown.
sub raised_from {
	my ($code) = @_;

	my @raised;
	{
		no warnings 'redefine', 'once';
		local *Service::Git::bail = sub {push @raised, [@_]; die "refused\n"};
		local *Service::Git::bug  = sub {push @raised, [@_]; die "refused\n"};
		eval {$code->(); 1};
	}
	unless (@raised) {
		diag("nothing was raised; the code died of: $@") if $@;
		return ('', undef);
	}

	my @args = @{$raised[0]};
	my $opts = ref($args[0]) eq 'HASH' ? shift(@args) : {};
	my ($format, @rest) = @args;

	return (sprintf($format, @rest), $opts->{exitcode});
}

done_testing;

# vim: ts=2 sw=2 sts=2 noet
