package PodGate::Pod;

use strict;
use warnings;

use Exporter qw/import/;

our @EXPORT_OK = qw/parse_pod parse_pod_text/;

# A =head2 names a method when its text is a bare identifier and nothing
# else.  Genesis' POD also uses =head2 for prose headings ("Notes on
# argument handling", "The bosh configs subcommands"); reading those as
# methods invents names like "Notes" and "The", and the gate then demands
# the module define them.
my $METHOD_HEADING = qr/^([A-Za-z_]\w*)$/;

# Contract blocks are bold lead-ins rather than headings, deliberately:
# =head3 would nest, and a nested heading is what breaks attribution.
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

			if ($heading =~ $METHOD_HEADING) {
				my $name = $1;
				$methods{$name} = {
					name    => $name,
					section => $section,
					body    => $body,
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
		methods        => \%methods,
		prose_headings => \@prose_headings,
	};
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
