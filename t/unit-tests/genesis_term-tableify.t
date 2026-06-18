#!perl
use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't';
use helper;

use_ok 'Genesis::Term';
use Genesis::Term qw/tableify decolorize/;

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

my $simple = <<'MD';
| Name | Age |
|:-----|----:|
| Alice | 30 |
| Bob   | 5  |
MD

# strip_ansi: helper to make assertions against the visible content
# regardless of whether colour markers were rendered.
sub strip_ansi { (my $s = $_[0]) =~ s/\e\[[0-9;]*m//g; $s }

# ---------------------------------------------------------------------------
# Structural shape: heavy top, header, light divider, rows, heavy bottom
# ---------------------------------------------------------------------------

subtest 'shape: heavy top, light header rule, heavy bottom' => sub {
	my $out = strip_ansi(tableify($simple));
	my @lines = split /\n/, $out;

	# 5 lines: top rule, header, header divider, 2 data rows, bottom rule
	is(scalar(@lines), 6, 'six lines: top, header, divider, 2 rows, bottom');

	like($lines[0], qr/^\x{2501}+$/, 'top rule is heavy (━)');
	like($lines[1], qr/Name.+Age/,    'header row carries header text');
	like($lines[2], qr/^\x{2500}+$/, 'header divider is light (─)');
	like($lines[3], qr/Alice/,         'first data row');
	like($lines[4], qr/Bob/,           'second data row');
	like($lines[5], qr/^\x{2501}+$/, 'bottom rule is heavy (━)');
};

subtest 'no edges, no column dividers, no inter-row dividers' => sub {
	my $out = strip_ansi(tableify($simple));
	unlike($out, qr/[\x{2503}\x{250F}\x{2513}\x{2517}\x{251B}\x{2533}\x{2523}\x{252B}\x{253B}\x{254B}]/,
		'no box-drawing edge/divider glyphs leak through');
};

subtest 'all rule lines share the same width' => sub {
	my $out = strip_ansi(tableify($simple));
	my @lines = split /\n/, $out;
	my $top    = length $lines[0];
	my $div    = length $lines[2];
	my $bottom = length $lines[-1];
	is($div,    $top, 'header divider width matches top rule');
	is($bottom, $top, 'bottom rule width matches top rule');
};

# ---------------------------------------------------------------------------
# Header is bold (and so are the colour overrides)
# ---------------------------------------------------------------------------

subtest 'header defaults to bold via [1m...[0m' => sub {
	my $out = tableify($simple);
	# Header line is the 2nd line of output; locate it and confirm it
	# is surrounded by the bold-on / reset SGRs.
	my @lines = split /\n/, $out;
	like($lines[1], qr/\e\[1m.*\e\[0m/, 'header line wrapped in [1m/[0m');
};

# ---------------------------------------------------------------------------
# Alignment honoured from markdown separator row
# ---------------------------------------------------------------------------

subtest 'right-align marker is honoured for numeric columns' => sub {
	my $md = <<'MD';
| Name | Age |
|:-----|----:|
| Alice | 30 |
| Bob   |  5 |
MD
	my $out = strip_ansi(tableify($md));
	my @lines = split /\n/, $out;
	# Both data rows' Age column should end at the same column boundary.
	my ($r1) = $lines[3] =~ /(.{2})\s*$/; # last two chars before trailing pad
	my ($r2) = $lines[4] =~ /(.{2})\s*$/;
	is($r1, '30', 'first row Age aligns to right edge');
	is($r2, ' 5', 'second row Age is right-padded with a leading space');
};

# ---------------------------------------------------------------------------
# Cell content fits without truncation
# ---------------------------------------------------------------------------

subtest 'column widths fit the widest cell' => sub {
	my $md = <<'MD';
| Short | Wide                    |
|:------|:------------------------|
| a     | this is a long sentence |
MD
	my $out = strip_ansi(tableify($md));
	like($out, qr/this is a long sentence/, 'long cell is preserved unwrapped');
};

# ---------------------------------------------------------------------------
# Optional colour markers
# ---------------------------------------------------------------------------

subtest 'line option colours rules' => sub {
	local $ENV{NOCOLOR} = 0;
	my $out = tableify($simple, line => 'Ki');
	my @lines = split /\n/, $out;
	like($lines[0], qr/\e\[[0-9;]+m\x{2501}+\e\[0m/,
		'top rule wrapped in csprintf ANSI');
	like($lines[2], qr/\e\[[0-9;]+m\x{2500}+\e\[0m/,
		'header divider wrapped in csprintf ANSI');
	like($lines[-1], qr/\e\[[0-9;]+m\x{2501}+\e\[0m/,
		'bottom rule wrapped in csprintf ANSI');
};

subtest 'header option overrides the default bold' => sub {
	local $ENV{NOCOLOR} = 0;
	my $out = tableify($simple, header => 'C');
	my @lines = split /\n/, $out;
	# When header is set, the default [1m wrap goes away in favour of
	# the csprintf colour wrap (which adds its own SGRs).
	unlike($lines[1], qr/\e\[1m Name/, 'no plain [1m wrap when header colour set');
	like(  $lines[1], qr/\e\[[0-9;]+m.*Name.*\e\[0m/, 'header coloured');
};

subtest 'row + other_row produce zebra striping' => sub {
	local $ENV{NOCOLOR} = 0;
	my $md = <<'MD';
| K |
|:--|
| a |
| b |
| c |
| d |
MD
	my $out = tableify($md, row => 'W', other_row => 'Ki');
	my @lines = split /\n/, $out;
	# Data rows are lines 3..6 (0-indexed); even index uses row, odd uses other_row.
	like($lines[3], qr/\e\[[0-9;]+m a /, 'row 0 coloured');
	like($lines[4], qr/\e\[[0-9;]+m b /, 'row 1 coloured (other_row marker)');
	# row 0 and row 1 use different markers, so their SGR prefixes differ
	my ($sgr0) = $lines[3] =~ /^(\e\[[0-9;]+m)/;
	my ($sgr1) = $lines[4] =~ /^(\e\[[0-9;]+m)/;
	isnt($sgr0, $sgr1, 'zebra stripes use distinct SGR prefixes');
};

subtest 'empty colour marker disables a default' => sub {
	my $out = tableify($simple, header => '');
	my @lines = split /\n/, $out;
	unlike($lines[1], qr/\e\[1m/, 'empty header marker suppresses the bold default');
};

# ---------------------------------------------------------------------------
# ASCII fallback under GENESIS_NO_UTF8 / GENESIS_NO_BOXES
# ---------------------------------------------------------------------------

subtest 'ASCII fallback uses = for heavy and - for light rules' => sub {
	local $ENV{GENESIS_NO_UTF8} = 1;
	my $out = strip_ansi(tableify($simple));
	my @lines = split /\n/, $out;
	like($lines[0],  qr/^=+$/, 'top rule is `=` in ASCII mode');
	like($lines[2],  qr/^-+$/, 'header divider is `-` in ASCII mode');
	like($lines[-1], qr/^=+$/, 'bottom rule is `=` in ASCII mode');
};

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

subtest 'empty input yields empty output' => sub {
	is(tableify(''), '', 'empty string in -> empty string out');
};

subtest 'header-only input still renders the frame' => sub {
	my $out = strip_ansi(tableify("| A | B |\n|:--|:--|\n"));
	my @lines = split /\n/, $out;
	# top, header, header divider, bottom -> 4 lines (plus the final trailing newline)
	is(scalar(@lines), 4, 'four lines when there are no data rows');
};

done_testing;
