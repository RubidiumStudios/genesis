#!perl
#
# Proves T293 and T294: the workplan describes the move to v3 by hand, is
# marked superseded by the design set, and no longer claims behaviour the
# design replaced.  The first subtest reads the migration section and the
# second reads the status line, the conflict table, and the recovery section.
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

subtest 'the workplan is superseded and its claims are corrected' => sub {
	plan tests => 8;

	my $body = slurp($WORKPLAN);

	like($body, qr/^\*\*Status:\*\* Superseded by the pipeline propagation design set/m,
		'the status line says the design set supersedes it');

	my $conflict = section_of($body, qr/conflict handling/i);
	like($conflict, qr/held with the reason `ancestor-overlap`/,
		'the ancestor row names the hold and its reason');
	unlike($conflict, qr/entry point|cascade/i,
		'the ancestor row names neither the retired term nor the retired run');
	like($conflict, qr/holds what it cannot deliver and continues/,
		'a per-environment failure holds and the run continues');

	my $recovery = section_of($body, qr/recovery/i);
	like($recovery, qr/replays control forward from/,
		'a re-run replays control forward from each branch newest marker');
	unlike($recovery, qr/idempotency skip/,
		'the idempotency skip claim is gone');

	ok($body =~ /append-only/ && $body =~ /never force-pushes/,
		'control and every deployment branch on R are append-only');
	like($body, qr/never carries a local commit outside a propagation activity/,
		'the deployment branch is derived state');
};

done_testing();
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
