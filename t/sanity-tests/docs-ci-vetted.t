#!perl
#
# Proves T295: the configuration reference names the refusal of
# genesis.pipeline.manual under a provider whose optional_git_triggers
# capability is false, and the pages under docs/ci no longer present the
# superseded configuration and command surface as the one an operator meets.
#
use strict;
use warnings;
use Test::More;

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or BAIL_OUT("cannot read $path: $!");
	local $/;
	my $body = <$fh>;
	close $fh;
	return $body;
}

# The pages are read from the tree rather than from a list written here, so
# that the guards below hold every page under docs/ci and not only the twelve
# that are there today.  The rows that are about one page still name it.
#
# A run from anywhere but the repository root lists nothing and would pass,
# which is a green that proves nothing, so the list is read once here and an
# empty one fails and ends this file.  A bail would end the whole run over
# one file's working directory.
my @PAGES = sort grep {length} split /\n/, qx(git ls-files docs/ci);
unless (@PAGES) {
	# The exit carries no status of its own, because Test::Builder sets one
	# from the failing row.
	fail('git ls-files docs/ci listed no page');
	done_testing();
	exit;
}

sub pages { return @PAGES }

# Returns the body of the one section whose heading matches, from the heading
# to the next heading of the same level or the end of the file.
sub section_of {
	my ($body, $pattern) = @_;
	my @parts = split /^(?=#{2,3} )/m, $body;
	my ($match) = grep { (split /\n/, $_)[0] =~ $pattern } @parts;
	return $match // '';
}

# The reference's opening points the reader at the workplan's "Migration from
# v2" section, which is written after this page by the step that rewrites the
# workplan.  No row below reads that pointer, and the workplan's own check is
# where it resolves.
#
# D72 made the key provider-conditional and said it was inert rather than an
# error under a provider that could not honour it, and that it was not refused
# as the configuration loaded.  D101 replaced that: a capability is what a
# provider can do, a key is the operator's choice inside that ability, and a
# key whose capability is false is refused by name.  optional_git_triggers is
# the capability that gates this key, and the manual provider declares all six
# false, so the two later rows are written to what the code does rather than to
# what D72 said it would do.
subtest 'the reference states the provider condition and the refusal' => sub {
	plan tests => 5;

	my $body = slurp('docs/ci/user/configuration-reference.md');
	my $manual = section_of($body, qr/^#{2,3} `?manual`?\s*$/);

	isnt($manual, '', 'the reference has a section for the manual key');

	like($manual, qr/valid only where the provider emits a triggering resource/,
		'it says the key is valid only where the provider emits a triggering resource');

	like($manual, qr/sets no pipeline at all/,
		'it says why, which is that the manual provider sets no pipeline at all');

	like($manual, qr/refused at configuration load/,
		'it says the key is refused at configuration load where the ability is absent');

	like($manual, qr/optional_git_triggers/,
		'it names the capability the refusal names');
};

subtest 'the pages name the surface the design left standing' => sub {
	plan tests => 5;

	my %body = map { $_ => slurp($_) } pages();
	my $all = join("\n", values %body);
	my $start = $body{'docs/ci/user/getting-started.md'};

	# ok rather than like, because a failing like would dump every page.
	ok($all =~ /genesis propagate/, 'the set names genesis propagate');
	ok($all =~ /genesis pipeline-apply/, 'the set names genesis pipeline-apply');
	ok($all =~ /genesis pipeline-status/, 'the set names genesis pipeline-status');

	ok($start =~ m{\.genesis/config} && $start =~ /genesis\.pipeline/,
		'getting started names .genesis/config and the environment block');

	my @stale = grep { $body{$_} =~ m{\.genesis/ci/} && $body{$_} !~ /removed|superseded|legacy/i } sort keys %body;
	is_deeply(\@stale, [],
		'no file presents the .genesis/ci/ directory as current');
};

subtest 'the prose these pages are held to' => sub {
	plan tests => 2;

	my %body = map { $_ => slurp($_) } pages();

	# The files are read as bytes, so the em dash is matched as the three
	# bytes UTF-8 spells it with rather than as a character.
	my $em_dash = "\xE2\x80\x94";
	my @dashed = grep { index($body{$_}, $em_dash) >= 0 } sort keys %body;
	is_deeply(\@dashed, [], 'no page under docs/ci carries an em dash');

	# The four retired commands are history rather than surface, so they are
	# named once, together, in the paragraph that says they are retired.
	my @retired = qw(
		ci-pipeline-deploy
		ci-show-changes
		ci-generate-cache
		ci-pipeline-run-errand
	);
	my $any = join('|', map {quotemeta} @retired);
	my @blocks = grep {/(?:$any)/} split(/\n[ \t]*\n/, $body{'docs/ci/user/cli-commands.md'});
	my $one = @blocks == 1 ? $blocks[0] : '';

	ok(
		$one ne ''
			&& !grep({index($one, $_) < 0} @retired)
			&& $one =~ /retired/i,
		'the four retired command names sit in one paragraph that calls them retired'
	) or diag(sprintf("%d paragraph(s) name a retired command, expected 1.", scalar @blocks));
};

done_testing();
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
