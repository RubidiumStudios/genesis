#!perl
# Proves T11: the two git forms the declared floor puts off limits stay out of
# the tree.  Both post-date 2.34.1, so either one would pass on a developer's
# newer git and fail on the floor CI runs.
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;
use Test::More;

$ENV{NOCOLOR} = 1;

# An assertion helper, beside the test that uses it.  A file is read whole
# rather than line by line, because an argument list is often spread over
# several lines, and neither option is the offence on its own: `status
# --porcelain` is everywhere and is older than the floor, and the name of
# either form can be written in prose about it.  So a match counts only
# where the git command it belongs to sits within the same stretch of
# source, and every trailing comment is taken out of the text first, with
# the line breaks left where they were so a finding still names its line.
sub forbidden_forms_in {
	my (@files) = @_;
	my $top = $ENV{GENESIS_TOPDIR};

	my @found;
	for my $file (@files) {
		open my $fh, '<', $file or die "cannot read $file: $!\n";
		my $text = do {local $/; <$fh>};
		close $fh;

		# Stop at the data section: Genesis::Helpers carries the kit helper
		# bash script in its __DATA__ block, and a git command written there
		# runs out of a kit hook rather than out of Genesis itself.
		$text = substr($text, 0, $-[0])
			if $text =~ /^__(?:DATA|END)__[ \t]*$/m;

		$text = join("\n", map {strip_comment($_)} split(/\n/, $text, -1));

		my $short = $file;
		$short =~ s{^\Q$top\E/}{} if defined $top;

		while ($text =~ /ahead-behind/g) {
			my $at = pos($text);
			next unless near($text, $at) =~ /\bgit\b/;
			push @found, sprintf('%s:%d for-each-ref ahead-behind',
				$short, 1 + (substr($text, 0, $at) =~ tr/\n//));
		}

		while ($text =~ /--porcelain/g) {
			my $at = pos($text);
			next unless near($text, $at) =~ /\bfetch\b/;
			push @found, sprintf('%s:%d fetch --porcelain',
				$short, 1 + (substr($text, 0, $at) =~ tr/\n//));
		}
	}
	return sort @found;
}

# The stretch of source an argument list can reasonably spread over, which
# is what tells a real invocation apart from a mention of the same words.
sub near {
	my ($text, $at) = @_;
	my $from = $at > 240 ? $at - 240 : 0;
	return substr($text, $from, 480);
}

# The forms a run found, with the file and the line taken off, so the two
# are compared as a set and not in whatever order the file names sorted in.
sub forms_of {
	my (@found) = @_;
	return sort map {my $form = $_; $form =~ s/^\S+:\d+ //; $form} @found;
}

subtest 'the scan reports both forms where they appear' => sub {
	plan tests => 2;

	my $dir = helper::workdir;
	helper::put_file("$dir/ahead.pm", <<'EOS');
sub divergence {
	my ($self, $branch) = @_;
	return run({dir => $self->{path}},
		'git', 'for-each-ref', '--format=%(ahead-behind:HEAD)', $branch);
}
EOS
	helper::put_file("$dir/fetch.pm", <<'EOS');
sub fetch_porcelain {
	my ($self, $branch) = @_;
	return run({dir => $self->{path}},
		'git', 'fetch', '--porcelain', 'origin', $branch);
}
EOS

	my @found = forbidden_forms_in("$dir/ahead.pm", "$dir/fetch.pm");
	is(scalar(@found), 2, 'both forms are caught');
	is_deeply([forms_of(@found)],
		['fetch --porcelain', 'for-each-ref ahead-behind'],
		'and each is named by the form it used')
		or diag(join("\n", map {"  $_"} @found));
};

# A guard rather than a row that starts red: neither form appears under lib/
# today, so this subtest is green the moment it is written, and its job is to
# stay green as the divergence work below reaches for a git query.  Its red
# was shown by hand before the commit, once for each form, by writing the form
# into a sub under lib/ and watching the scan name the file and the form.
subtest 'neither form is in the tree' => sub {
	plan tests => 1;

	my @found = forbidden_forms_in(sweep_files());
	is_deeply(\@found, [],
		'nothing under lib/ reaches past the declared git floor')
		or diag(join("\n", map {"  $_"} @found));
};

done_testing;
