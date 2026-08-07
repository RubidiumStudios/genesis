package PodGate::Extract;

use strict;
use warnings;

use PPI;
use File::Basename qw/basename/;
use Exporter qw/import/;

our @EXPORT_OK = qw/extract_module/;

# Positional placeholder names for subs that read @_ by index.  Such a sub
# tells us how many arguments it takes but not what they are called, so the
# first is assumed to be the invocant and the rest are numbered.
my @POSITIONAL = qw/$self $arg1 $arg2 $arg3 $arg4 $arg5/;

# Perl calls these; nobody documents them as API.  Named once, on purpose --
# the reference implementation repeats the list at six call sites and one of
# them drifted, which is how a documented DESTROY came to read as POD for a
# method that did not exist.  Marked here, exempted by the checks.
my %SPECIAL = map {$_ => 1} qw/BEGIN END DESTROY AUTOLOAD/;

sub extract_module {
	my ($file) = @_;

	die "PodGate::Extract: cannot read $file\n" unless -f $file && -r $file;
	my $doc = PPI::Document->new($file)
		or die "PodGate::Extract: cannot parse $file: ".PPI::Document->errstr."\n";

	return {
		methods => [map {_method($_)} grep {$_->name} @{$doc->find('PPI::Statement::Sub') || []}],
		context => _context($doc, $file),
	};
}

sub _method {
	my ($sub) = @_;
	my $code = $sub->content;

	return {
		name          => $sub->name,
		line          => $sub->line_number,
		code          => $code,
		is_private    => ($sub->name =~ /^_/) ? 1 : 0,
		is_special    => $SPECIAL{$sub->name} ? 1 : 0,
		params        => _params($sub, $code),
		defaults      => _defaults($sub),
		die_messages  => _die_messages($code),
		has_wantarray => ($code =~ /\bwantarray\b/)          ? 1 : 0,
		has_mutations => ($code =~ /\$self->\{[^}]+\}\s*=[^=]/) ? 1 : 0,
		returns       => _returns($code),
	};
}

# Four ways a sub can take arguments, tried in the order that recovers the
# most information.  Only the first that yields anything is used -- a sub
# that unpacks @_ and then also touches $_[0] is described by the unpacking.
sub _params {
	my ($sub, $code) = @_;

	my $sig = $sub->find_first('PPI::Structure::Signature')
	       || $sub->find_first('PPI::Token::Prototype');
	if ($sig) {
		my $text = $sig->content;
		$text =~ s/^\(//;
		$text =~ s/\)$//;
		my @named = grep {defined}
			map {/^\s*([\$\@\%]\w+)/ ? $1 : undef} split(/,/, $text);
		return \@named if @named;
	}

	if ($code =~ /my\s*\(([^)]+)\)\s*=\s*\@_/) {
		my @named = grep {/^[\$\@\%]/} map {s/^\s+|\s+$//gr} split(/,/, $1);
		return \@named if @named;
	}

	my @shifts;
	push @shifts, $1 while $code =~ /my\s+([\$\@\%]\w+)\s*=\s*shift\b/g;
	return \@shifts if @shifts;

	# Index access names nothing, but the highest index still fixes the
	# arity, which is what signature_arity needs to check the POD against.
	my %seen;
	$seen{$1} = 1 while $code =~ /\$_\[(\d+)\]/g;
	if (%seen) {
		my ($max) = sort {$b <=> $a} keys %seen;
		return [map {$POSITIONAL[$_] // "\$arg$_"} 0 .. $max];
	}

	return [];
}

sub _defaults {
	my ($sub) = @_;
	my %defaults;

	my $sig = $sub->find_first('PPI::Structure::Signature')
	       || $sub->find_first('PPI::Token::Prototype');
	return \%defaults unless $sig;

	my $text = $sig->content;
	$text =~ s/^\(//;
	$text =~ s/\)$//;
	for my $part (split /,/, $text) {
		next unless $part =~ /^\s*([\$\@\%]\w+)\s*=\s*(.+?)\s*$/;
		$defaults{$1} = $2;
	}
	return \%defaults;
}

# A die inside a signal handler unwinds to a surrounding alarm or eval and
# never reaches the caller.  Reporting it would send the author off to
# document something no caller can observe.
sub _die_messages {
	my ($code) = @_;
	(my $scan = $code) =~ s/\$SIG\{\w+\}\s*=\s*sub\s*\{.*?\}//gs;

	my @messages;
	push @messages, $1 while $scan =~ /\b(?:die|croak|bail|bug)\s*\(?\s*"((?:[^"\\]|\\.)*)"/g;
	push @messages, $1 while $scan =~ /\b(?:die|croak|bail|bug)\s*\(?\s*'((?:[^'\\]|\\.)*)'/g;
	push @messages, $1 while $scan =~ /\b(?:die|croak|bail|bug)\s+sprintf\s*\(\s*"((?:[^"\\]|\\.)*)"/g;
	return \@messages;
}

sub _returns {
	my ($code) = @_;
	my @returns;
	while ($code =~ /\breturn\b\s+(.{1,80})/g) {
		my $expr = $1;
		$expr =~ s/;\s*$//;
		$expr =~ s/\s+$//;
		push @returns, $expr;
	}
	return \@returns;
}

sub _context {
	my ($doc, $file) = @_;

	my (@overloads, @inheritance, @globals, @mixin_includes);

	for my $inc (@{$doc->find('PPI::Statement::Include') || []}) {
		my $mod = $inc->module // next;
		push @overloads,   $inc->content if $mod eq 'overload';
		push @inheritance, $inc->content if $mod eq 'base' || $mod eq 'parent';
	}

	for my $var (@{$doc->find('PPI::Statement::Variable') || []}) {
		push @globals, $var->content if $var->type eq 'our';
	}

	# Mixins are pulled in by path, not by module name, so there is no
	# Include statement to read -- the source line is all there is.
	for my $line (split /\n/, $doc->content) {
		if ($line =~ /\bdo\b/ && $line =~ m{/_(\w+)\.pm}) {
			push @mixin_includes, "_$1";
		} elsif ($line =~ /\brequire\s+([\w:]+::_\w+)/) {
			push @mixin_includes, $1;
		}
	}

	# A mixin has no package of its own: its subs land in whichever package
	# does the file.  The underscore alone is not enough -- Genesis has
	# real modules under names beginning with an underscore.
	my $has_package = $doc->find_first('PPI::Statement::Package') ? 1 : 0;
	my $is_mixin = (basename($file) =~ /^_/ && !$has_package) ? 1 : 0;

	return {
		overloads       => \@overloads,
		inheritance     => \@inheritance,
		package_globals => \@globals,
		mixin_includes  => \@mixin_includes,
		is_mixin        => $is_mixin,
	};
}

1;
