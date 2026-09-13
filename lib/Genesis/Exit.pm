package Genesis::Exit;
# The one home of the named exit codes.  A caller that cannot tell a refusal
# from a partial result from a crash cannot act on any of them, and a pipeline
# job in particular needs to know whether to retry, to page someone, or to
# stop.  D97 opens the table with the three the propagate run spends, and D98
# makes every exit the design specifies name its cause here.
#
# The numbers come from sysexits.h where that file has the meaning, and from
# shell convention where it does not: nothing in sysexits names a deliberate
# decline, and 130 is the one number every shell user reads as "the user
# stopped it".
#
# Three numbers are deliberately absent.  A fatal system error stays a bare 1,
# usage and option errors stay 2, and the prerequisites check stays 86, all
# three being Genesis precedent a caller may already test for, and a code is
# never renumbered once shipped.
use strict;
use warnings;

use base 'Exporter';

# On request rather than by default: CONFIG and SOFTWARE are ordinary words,
# and a module that spends a code should have to say which one it means.
our @EXPORT = ();
our @EXPORT_OK = qw/
	TEMPFAIL
	DATAERR
	ABORTED
	NOPERM
	CONFIG
	UNAVAILABLE
	SOFTWARE
/;
our %EXPORT_TAGS = (all => [@EXPORT_OK]);

### The codes {{{

use constant {
	TEMPFAIL    => 75,
	DATAERR     => 65,
	ABORTED     => 130,
	NOPERM      => 77,
	CONFIG      => 78,
	UNAVAILABLE => 69,
	SOFTWARE    => 70,
};

# }}}

1;
# vim: fdm=marker:foldlevel=0:noet
