package PodGate::Pod;

use strict;
use warnings;

use Exporter qw/import/;

our @EXPORT_OK = qw/parse_pod parse_pod_text/;

# A =head2 names a method when its text is an identifier, optionally
# followed by an argument list, and nothing else.  Most of the tree heads
# methods with their signature -- "=head2 deploy($env_name, $reason)".
#
# The trailing anchor is what keeps prose out.  Genesis also heads prose
# with =head2 ("Notes on argument handling", "The C<bosh configs>
# subcommands"); matching a leading word alone would invent methods called
# "Notes" and "The" and then demand the module define them.
my $METHOD_HEADING = qr/^([A-Za-z_]\w*)\s*(?:\([^)]*\))?$/;

# Contract blocks are bold lead-ins rather than headings, deliberately:
# =head3 would nest, and a nested heading is what breaks attribution.
# What a =head2 means depends on the section it sits under, and only three
# kinds matter:
#
#   api        documents a sub that must exist in this file
#   interface  documents a sub that may live in a subclass instead
#   prose      documents something that is not a sub at all
#
# Classifying by section rather than by heading text is what keeps the
# overload docs ("=head2 Stringification"), the bash helper library in
# Genesis::Helpers, and every future prose section from being read as
# missing Perl subs.
# A grammar rather than a keyword search, so a prose heading that happens
# to contain the word METHODS is not mistaken for an API section:
#
#     [QUALIFIER ...] (METHODS|FUNCTIONS) [ - CATEGORY | (CATEGORY) ]
#
# The trailing " - CATEGORY" form exists to group a large API -- some
# modules carry enough functions that one flat list is unreadable. The
# parenthesised form is the same idea, spelled the way the tree already
# spells it in one place.
#
# Order matters: the interface rules run first so INTERNAL METHODS is not
# read as api. INTERNAL has to sit with the noun, or INTERNAL BASH
# HELPERS -- shell functions, not subs -- is dragged in with it.
# Enumerated, not "any capitalised word".  An open-ended prefix makes
# NOTES ON METHODS an API section, and the gate then demands subs to back
# a paragraph of prose.
my $QUALIFIER = qr/(?:(?:CLASS|INSTANCE|HELPER)\s+)*/;
my $CATEGORY  = qr/(?:\s+-\s+[A-Z0-9][A-Z0-9 -]*|\s*\([^)]*\))?/;
my $NOUN      = qr/(?:METHODS|FUNCTIONS)/;

my @SECTION_KIND = (
	[qr/^${QUALIFIER}INTERNAL\s+${QUALIFIER}${NOUN}${CATEGORY}$/ => 'interface'],
	[qr/^${QUALIFIER}ABSTRACT\s+${QUALIFIER}${NOUN}${CATEGORY}$/ => 'interface'],
	[qr/^OVERRIDE\s+POINTS$/                                     => 'interface'],
	[qr/^${QUALIFIER}${NOUN}${CATEGORY}$/                        => 'api'],
	[qr/^CONSTRUCTORS?$/                                         => 'api'],
);

my %CONTRACT = (
	has_params   => qr/^B<Parameters:>/m,
	has_returns  => qr/^B<Returns:>/m,
	has_errors   => qr/^B<(?:Errors|Throws|Raises):>/m,
	has_examples => qr/^B<Examples?:>/m,
);

sub parse_pod {
	my ($file) = @_;
	die "PodGate::Pod: cannot read $file\n" unless -f $file && -r $file;
	open my $fh, '<:encoding(UTF-8)', $file
		or die "PodGate::Pod: cannot open $file: $!\n";
	my $text = do {local $/; <$fh>};
	close $fh;
	return parse_pod_text($text, $file);
}

sub parse_pod_text {
	my ($text, $file) = @_;
	$file //= '(text)';

	my (%head1, @head1_order, %methods, @prose_headings);
	my $section = '';          # nearest enclosing =head1
	my $cursor;                # method currently accumulating body text

	# Attribution follows the nearest enclosing =head1 only.  Any other
	# heading level is content within that section, not a boundary -- a
	# =head3 between two methods must not evict the second from METHODS.
	for my $chunk (split /^(?==\w+)/m, $text) {
		if ($chunk =~ /^=head1\s+(.+?)\s*$/m) {
			$section = $1;
			push @head1_order, $section unless exists $head1{$section};
			$head1{$section} //= '';
			$cursor = undef;
			(my $body = $chunk) =~ s/^=head1\s+.+?\n//;
			$head1{$section} .= $body;
			next;
		}

		if ($chunk =~ /^=head2\s+(.+?)\s*$/m) {
			my $heading = $1;
			(my $body = $chunk) =~ s/^=head2\s+.+?\n//;

			my $kind = _section_kind($section);
			if ($kind ne 'prose' && $heading =~ $METHOD_HEADING) {
				my $name = $1;
				$methods{$name} = {
					name         => $name,
					section      => $section,
					section_kind => $kind,
					is_interface => ($kind eq 'interface') ? 1 : 0,
					body         => $body,
				};
				$cursor = $name;
			} else {
				# Recorded rather than dropped: a prose heading is a
				# legitimate construct, but a silent one is how "The
				# C<bosh configs> subcommands" became a method called
				# "The" and stayed that way.
				push @prose_headings, $heading;
				$cursor = undef;
			}
			next;
		}

		# Any other directive, including =head3, is body text belonging to
		# whatever it sits inside.
		if (defined $cursor) {
			$methods{$cursor}{body} .= $chunk;
		} elsif (length $section) {
			$head1{$section} .= $chunk;
		}
	}

	for my $m (values %methods) {
		$m->{$_} = ($m->{body} =~ $CONTRACT{$_}) ? 1 : 0 for keys %CONTRACT;
		$m->{params} = _documented_params($m->{body});
	}

	return {
		file           => $file,
		head1          => \%head1,
		head1_order    => \@head1_order,
		section_kind   => {map {$_ => _section_kind($_)} @head1_order},
		methods        => \%methods,
		prose_headings => \@prose_headings,
	};
}

sub _section_kind {
	my ($section) = @_;
	return 'prose' unless defined $section && length $section;
	for my $rule (@SECTION_KIND) {
		return $rule->[1] if $section =~ $rule->[0];
	}
	return 'prose';
}

# Parameter names come from the =item entries of the =over list that follows
# the Parameters lead-in.  Reading every =item in the body would also pick up
# unrelated lists further down the entry.
sub _documented_params {
	my ($body) = @_;
	return [] unless $body =~ /^B<Parameters:>(.*?)(?=^B<\w+:?>|\z)/msx;
	my $block = $1;
	my @params;
	push @params, $1 while $block =~ /^=item\s+C<([\$\@\%][\w:]+)>/mg;
	return \@params;
}

1;
