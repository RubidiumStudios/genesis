package Genesis::Hook::Addon;
use strict;
use warnings;

use parent qw(Genesis::Hook);

use Genesis;

sub init {
	my ($class, %opts) = @_;
	$class->check_for_required_args(\%opts, qw/env kit script args/);
	my $obj = $class->SUPER::init(%opts);

	# Deal with help option if present
	if ($opts{help}) {
		$obj->help;
		exit 0;
	}

	return $obj;
}

sub help {
	my ($self, %addons) = @_;

	if ($self->can('cmd_details')) {
		my $cmd_details = $self->cmd_details();
		if (ref $cmd_details eq 'HASH') {
			$self->kit_bug(
				"This kit has incorrectly defined multiple commands in %s - hooks/addon.pm ".
				"is the only addon that can define multiple commands.",
				$self->{file} =~ s{^.*(hooks/addon\.pm)$}{$1}r
			) unless $self->{file} =~ /hooks\/addon\.pm$/;
			$addons{$_} = $cmd_details->{$_} for keys %$cmd_details;
		} else {
			# Help text is what the kit chose to print, and it can expand
			# configuration values, so the terminal shows it and a log file
			# records only that it was withheld.
			info("\n#Gu{%s}", $self->{label});
			info({private => 1},
				"[[  >>%s\n",
				join("\n[[  >>", split("\n",$self->cmd_details()))
			);
			return 1;
		}
	}

	# Loook for any extended addon hooks
	my @module_files =
		map {substr($_,length($self->kit->path())+1)}
		grep { /\/addon-[^.]*(.pm)?$/ } # ignore disabled or other invalidly named files
		glob($self->kit->path("hooks/addon-*"));

	foreach my $file (@module_files) {
		my $cmd = $file =~ s{^.*hooks/addon-(.*?)(\.pm)?$}{$1}r;
		if ($file !~ /\.pm$/) {
			next if in_array($file.'.pm', @module_files); # prefer perl modules over other files
			# run the help command on the bash script; what it printed on
			# either stream is kept from the log, so a failure is described
			# by how the script ended.
			my ($out, $rc) = run({
				interactive => 0, stderr => 0
			},
			'cd "$1"; source .helper; hook=$2; shift 2; $hook "$@"',
			$self->kit->path, $file, 'help'
			);
			trace("Addon %s gave no help: its help command %s", $file, Genesis::Kit::_hook_ended($rc)) if $rc;
			$addons{$cmd} = $out unless $rc;
		} else {
			# load_hook_module traces where a module that fails to load
			# died, and a cmd_details that dies is described the same way.
			my $class = eval {$self->load_hook_module($file, $self->kit)};
			unless ($class) {
				trace("Addon module %s gave no help: it could not be loaded", $file);
				next;
			}
			next unless $class->can('cmd_details');
			my $loaded = eval {
				my ($cmd) = $file =~ m{addon-(.*)\.pm};
				# FIXME: Initializing the subcommand addons with the current env is a hack,
				# 			but it is needed to ensure that the addon's cmd_details method
				# 			can access the environment variables and other context.
				local $ENV{GENESIS_ADDON_SCRIPT} = $cmd;
				$addons{"$cmd"} = $class->cmd_details() // 'No help available';
				1;
			};
			trace("Addon module %s gave no help: %s", $file, Genesis::Hook::load_failure($@)) unless $loaded;
		}
	}

	unless (keys %addons) {
		info(
			"No addons are defined for the %s kit.",
			$self->env->kit->id
		);
		return 0
	}

	my ($label, $short, $msg);
	info "\nThe following addons are defined for the #C{%s} kit:", $self->env->kit->id;

	foreach my $cmd (sort keys %addons) {
		$label = $cmd =~ s/~/\|/r;
		info("\n  #Gu{%s}", $label);
		info({private => 1}, "[[    >>%s", join("\n[[    >>", split("\n",$addons{$cmd})));
	}
	print STDERR "\n";
	return $self->done(1);
}

use Getopt::Long ();
sub parse_options {
	my ($self, $opt_defn, %opts) = @_;
	require Genesis::Commands;
	Getopt::Long::Configure(
		qw(no_ignore_case bundling no_pass_through auto_abbrev permute)
	);
	# Getopt::Long quotes a value it refuses, and an addon's operands can
	# be credentials, so its warnings become the top-level parser's words.
	my ($ok, @problems) = Genesis::Commands::get_options_quietly($self->{args}, \%opts, @$opt_defn);
	bail(
		"Error parsing command line arguments for %s: %s.",
		$self->label, @problems ? join("; ", @problems) : 'the options could not be parsed'
	) unless $ok;
	# Getopt::Long has already refused any unknown flag, so what is left
	# looking like one followed a --, and is an operand that can be a
	# credential: the refusal gives only its length.
	my $bad_opts = join(", ", map {Genesis::traced_arg({redact => $_})} grep {/^-/} @{$self->{args}});
	bail("Unknown option(s) passed to %s: %s", $self->label, $bad_opts) if $bad_opts;
	return wantarray ? %opts : \%opts;
}


sub vault {
	my $self = shift;
	return $self->{vault} ||= $self->env->secrets_store->service;
}

sub results {
	return 1;
}
1;
