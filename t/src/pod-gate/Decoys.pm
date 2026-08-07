package Decoys;
# Error-path fixture: text that looks like a sub declaration but is not one.
#
# This is the whole argument for parsing with PPI rather than grepping for
# /^sub \w+/.  A gate that hard-fails cannot afford to demand documentation
# for a sub that does not exist -- the author has nothing to write, and the
# only way out is to disable the gate.
#
# Only real_method is a real sub.  Everything else here must be ignored.

use strict;
use warnings;

my $template = <<'PERL';
sub sub_in_a_heredoc {
	return "not a real sub";
}
PERL

my $snippet = 'sub sub_in_a_single_quoted_string { }';
my $other   = "sub sub_in_a_double_quoted_string { }";

=head1 DOCUMENTATION

The line below sits inside POD and is not code:

    sub sub_in_a_pod_block {
        return 1;
    }

=cut

sub real_method {
	my ($self) = @_;
	return $template . $snippet . $other;
}

# sub sub_in_a_comment { }

1;
