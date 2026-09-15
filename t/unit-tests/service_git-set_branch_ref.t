#!/usr/bin/env perl
# The forced write onto a local branch, which I2 admits for the pre-flight's
# reset of a marker-only commit and for the session's abort and for nothing
# else.  It moves a branch the working tree is not standing on, and it
# refuses the branch the tree is standing on, because git's own `branch -f`
# refuses there and a ref that disagreed with the tree beside it would be
# worse than a refusal.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Harness::Propagation;

use Test::More;

use Genesis;
use Genesis::Exit qw/SOFTWARE/;
use Service::Git;

$ENV{GENESIS_OUTPUT_COLUMNS} = 80;
$ENV{NOCOLOR} = 1;

subtest 'it forces a branch the tree is not standing on' => sub {
	plan tests => 3;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $slug = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $slug);
	my $stranded = local_only_commit($h, $slug, marker => 0,
		message => 'a commit the remote never had');
	# The commit helper leaves copy A standing on the branch, and the write
	# below is exactly the one that refuses there.
	stand_on($h, $h->control);

	my $tracking = ref_in($h->a, "refs/remotes/origin/$slug");
	isnt(ref_in($h->a, "refs/heads/$slug"), $tracking,
		'the branch starts somewhere the tracking ref is not');

	my $git = $h->git('a');
	is($git->set_branch_ref($slug, "refs/remotes/origin/$slug"), $git,
		'the write answers with the handle');
	is(ref_in($h->a, "refs/heads/$slug"), $tracking,
		'and the branch now stands where the tracking ref stands');
};

subtest 'it refuses the branch the working tree is standing on' => sub {
	plan tests => 4;

	my $h    = make_harness(envs => ['qa'], vault => 0);
	my $slug = $h->slug('qa');

	init_branch($h, 'qa');
	refresh($h, 'a', $slug);
	local_only_commit($h, $slug, marker => 0,
		message => 'a commit the remote never had');
	# Left standing on the branch on purpose, which is the state the
	# refusal is about.
	my $before = ref_in($h->a, "refs/heads/$slug");

	my ($err, $exit) = bail_from(sub {
		$h->git('a')->set_branch_ref($slug, "refs/remotes/origin/$slug")});

	like($err, qr/Refusing\s+to\s+force/, 'the write refuses');
	like($err, qr/\Q$slug\E/, 'and names the branch');
	is($exit, SOFTWARE, 'and exits SOFTWARE, because this is a defect');
	is(ref_in($h->a, "refs/heads/$slug"), $before,
		'and the branch did not move');
};

# The assertion helper, which lives beside its test because it is about what
# this file means rather than about what a tree holds.  A row that weighs an
# exit code cannot read one out of this process, since bail dies rather than
# exits whenever it is reached from inside an eval, and a test file always
# is.  The refusal is caught where the code raises it and the code it would
# have exited with is read off the arguments it was composed with.
sub bail_from {
	my ($code) = @_;

	my @raised;
	{
		no warnings 'redefine', 'once';
		local *Service::Git::bail = sub {push @raised, [@_]; die "refused\n"};
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
