package MethodsAsFunctions;
# Error-path fixture: methods filed under a FUNCTIONS heading -- the
# converse of FunctionsAsMethods.pm.

use strict;
use warnings;

sub alpha { my ($self) = @_; return 1 }
sub beta  { my ($self) = @_; return 2 }
sub gamma { my ($self) = @_; return 3 }

1;
