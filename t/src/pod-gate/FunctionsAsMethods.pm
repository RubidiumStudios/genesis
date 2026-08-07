package FunctionsAsMethods;
# Error-path fixture: plain functions filed under a METHODS heading.
#
# Perl draws no syntactic line between a method and a function -- the
# difference is whether the sub takes an invocant -- so the heading is the
# only place the distinction is recorded, and copying another module's
# skeleton is an easy way to get it wrong.

use strict;
use warnings;

sub alpha { return 1 }
sub beta  { return 2 }
sub gamma { return 3 }

1;
