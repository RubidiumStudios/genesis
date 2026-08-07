package BadSyntax;
# Error-path fixture: its .pod does not parse.  Kept apart from the other
# faults because unparseable POD can swallow whatever follows it.

use strict;
use warnings;

sub thing { return 1 }

1;
