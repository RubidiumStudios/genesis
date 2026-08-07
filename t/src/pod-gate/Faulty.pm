package Faulty;
# Error-path fixture: coverage and placement defects.  Each sub carries
# exactly one, and none interacts with another.  Keep it that way -- a
# fixture with entangled faults cannot tell you which check caught what.

use strict;
use warnings;

sub documented   { return 1 }   # fine
sub undocumented { return 1 }   # no =head2 anywhere

sub _private_but_public_section { return 1 }  # documented under METHODS
sub public_but_internal_section { return 1 }  # documented under INTERNAL METHODS

1;
