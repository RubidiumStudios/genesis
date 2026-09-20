#!perl
#
# Proves T293 and T294: the workplan describes the move to v3 by hand, is
# marked superseded by the design set, and no longer claims behaviour the
# design replaced.  T294's subtest is added by the task that follows.
#
use strict;
use warnings;
use Test::More;

my $WORKPLAN = 'workplans/Branch-based-Workflow-Architecture.md';

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or BAIL_OUT("cannot read $path: $!");
	local $/;
	my $body = <$fh>;
	close $fh;
	return $body;
}

# Returns the body of the one section whose heading matches, from the heading
# to the next heading of the same level or the end of the file.
sub section_of {
	my ($body, $pattern) = @_;
	my @parts = split /^(?=## )/m, $body;
	my ($match) = grep { (split /\n/, $_)[0] =~ $pattern } @parts;
	return $match // '';
}

subtest 'the migration section describes the move by hand' => sub {
	plan tests => 6;

	my $body = slurp($WORKPLAN);
	my $migration = section_of($body, qr/migration/i);

	like($migration, qr/\A## Migration from v2$/m,
		'the workplan has a "Migration from v2" section');

	like($migration, qr/never applied on top of a v2 one|moves to v3 by hand/,
		'it says a v3 pipeline is never applied on top of a v2 one');

	like($migration, qr/orphan branch.{0,80}cut from the existing branch's HEAD content/s,
		'control is a new orphan branch cut from the existing branch HEAD content');

	like($migration, qr/init branches.{0,60}pipeline-apply.{0,40}creates/s,
		'the deployment branches are the init branches pipeline-apply creates');

	ok($migration =~ /deleted, or renamed/ && $migration =~ /git branch -m/,
		'a branch named for an environment alone is deleted or renamed');

	like($migration, qr/fetches once with `--prune`/,
		'every existing clone then fetches once with --prune');
};

done_testing();
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
