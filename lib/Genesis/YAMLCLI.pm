package Genesis::YAMLCLI;
use strict;
use warnings;

use Genesis qw(warning run mkdir_or_fail);
use File::Path qw(make_path);
use Time::HiRes qw(gettimeofday);
use POSIX qw(strftime);
use Digest::SHA qw(sha256_hex);

# This module provides an abstraction over YAML processing tools (spruce/graft)
# with automatic fallback support and dual-mode comparison logging

sub new {
	my ($class, %opts) = @_;

	# Priority order:
	# 1. Command line option (--yaml-cli)
	# 2. Config file setting (yaml_cli)
	# 3. Default (spruce)

	my $preferred = $opts{processor};
	unless ($preferred) {
		eval { $preferred = Genesis->config->get('yaml_cli'); };
		$preferred ||= 'spruce';
	}
	
	my $self = {
		preferred => $preferred,
		warned => 0
	};
	
	if ($preferred eq 'dual') {
		# Dual mode: use spruce as the safe default but run both for comparison
		$self->{mode} = 'dual';
		$self->{actual} = 'spruce';  # Safe default for actual operations
		
		# Check both processors are available
		die "Dual mode requires both spruce and graft to be available\n"
			unless _check_processor('spruce') && _check_processor('graft');
			
		# Initialize logging for dual mode
		$self->{session_id} = _init_dual_session();
	} else {
		# Single processor mode with fallback
		my $fallback = $preferred eq 'spruce' ? 'graft' : 'spruce';
		
		# Check availability and set actual processor
		my $actual = _check_processor($preferred) ? $preferred :
		             _check_processor($fallback) ? $fallback :
		             undef;
		
		die "Neither spruce nor graft is available\n" unless $actual;
		
		$self->{mode} = 'single';
		$self->{actual} = $actual;
	}
	
	return bless $self, $class;
}

sub merge {
	my ($self, @args) = @_;
	return $self->_execute('merge', @args);
}

sub json {
	my ($self, @args) = @_;
	return $self->_execute('json', @args);
}

sub diff {
	my ($self, @args) = @_;
	return $self->_execute('diff', @args);
}

sub vaultinfo {
	my ($self, @args) = @_;
	return $self->_execute('vaultinfo', @args);
}

sub cli {
	my ($self) = @_;
	return $self->{actual};
}

sub _execute {
	my ($self, $command, @args) = @_;
	
	if ($self->{mode} eq 'dual') {
		return $self->_execute_dual($command, @args);
	} else {
		return $self->_execute_single($command, @args);
	}
}

sub _execute_single {
	my ($self, $command, @args) = @_;
	$self->_warn_fallback();
	
	# Extract run options if first arg is a hashref
	my $run_opts = {};
	if (ref($args[0]) eq 'HASH') {
		$run_opts = shift @args;
	}
	$run_opts->{onfailure} ||= "Failed to execute $command";
	
	return run($run_opts, $self->{actual}, $command, @args);
}

sub _execute_dual {
	my ($self, $command, @args) = @_;
	
	# Extract run options if first arg is a hashref
	my $run_opts = {};
	my @clean_args = @args;
	if (ref($args[0]) eq 'HASH') {
		$run_opts = shift @clean_args;
	}
	$run_opts->{onfailure} ||= "Failed to execute $command";
	
	# Create operation directory
	my $op_id = _generate_op_id($command, @clean_args);
	my $op_dir = "$ENV{HOME}/.genesis/logs/yaml-cli/$self->{session_id}/$op_id";
	make_path($op_dir) unless -d $op_dir;
	
	# Log the input
	_log_input($op_dir, $command, $run_opts, @clean_args);
	
	# Run spruce (safe default)
	my $start_spruce = [gettimeofday];
	my ($spruce_out, $spruce_rc, $spruce_err) = run({%$run_opts, passfail => 1}, 'spruce', $command, @clean_args);
	my $spruce_time = _elapsed_time($start_spruce);
	
	# Run graft
	my $start_graft = [gettimeofday];
	my ($graft_out, $graft_rc, $graft_err) = run({%$run_opts, passfail => 1}, 'graft', $command, @clean_args);
	my $graft_time = _elapsed_time($start_graft);
	
	# Log outputs
	_log_output($op_dir, 'spruce', $spruce_out, $spruce_rc, $spruce_err, $spruce_time);
	_log_output($op_dir, 'graft', $graft_out, $graft_rc, $graft_err, $graft_time);
	
	# Compare and log differences
	_log_comparison($op_dir, $spruce_out, $graft_out, $spruce_rc, $graft_rc);
	
	# Return spruce result (safe default) but fail if spruce failed
	if ($spruce_rc != 0) {
		die $run_opts->{onfailure} . "\n" if $run_opts->{onfailure};
		return wantarray ? ($spruce_out, $spruce_rc, $spruce_err) : $spruce_out;
	}
	
	return wantarray ? ($spruce_out, $spruce_rc, $spruce_err) : $spruce_out;
}

sub _check_processor {
	my ($name) = @_;
	return scalar(qx(which $name 2>/dev/null));
}

sub _warn_fallback {
	my ($self) = @_;
	if (!$self->{warned} && $self->{preferred} ne $self->{actual}) {
		warning("$self->{preferred} not found, falling back to $self->{actual}");
		$self->{warned} = 1;
	}
}

sub _init_dual_session {
	my $timestamp = strftime("%Y%m%d-%H%M%S", localtime);
	my $session_dir = "$ENV{HOME}/.genesis/logs/yaml-cli/$timestamp-$$";
	make_path($session_dir) unless -d $session_dir;
	
	# Create session info file
	open my $fh, '>', "$session_dir/session.info" or die "Cannot create session info: $!\n";
	print $fh "Session Started: " . localtime() . "\n";
	print $fh "Genesis Version: " . ($Genesis::VERSION || 'dev') . "\n";
	print $fh "PID: $$\n";
	print $fh "Mode: dual (spruce + graft)\n";
	close $fh;
	
	return "$timestamp-$$";
}

sub _generate_op_id {
	my ($command, @args) = @_;
	my $timestamp = strftime("%H%M%S", localtime);
	my ($sec, $usec) = gettimeofday;
	my $content = join('|', $command, @args);
	my $hash = substr(sha256_hex($content), 0, 8);
	return sprintf("%s-%06d-%s-%s", $timestamp, $usec, $command, $hash);
}

sub _elapsed_time {
	my ($start) = @_;
	my ($s1, $us1) = @$start;
	my ($s2, $us2) = gettimeofday;
	return sprintf("%.3f", ($s2 - $s1) + ($us2 - $us1) / 1000000);
}

sub _log_input {
	my ($dir, $command, $run_opts, @args) = @_;
	
	open my $fh, '>', "$dir/input.log" or return;
	print $fh "Command: $command\n";
	print $fh "Timestamp: " . localtime() . "\n";
	print $fh "Arguments:\n";
	for my $i (0..$#args) {
		print $fh "  [$i] $args[$i]\n";
	}
	print $fh "\nRun Options:\n";
	for my $key (sort keys %$run_opts) {
		my $val = $run_opts->{$key};
		$val = ref($val) ? '<complex>' : $val;
		print $fh "  $key: $val\n";
	}
	close $fh;
	
	# Save input files if they exist
	my $file_num = 0;
	for my $arg (@args) {
		next unless -f $arg && -r $arg;
		my $content = do { local $/; open my $in, '<', $arg or next; <$in> };
		open my $out, '>', "$dir/input-file-$file_num.yml" or next;
		print $out $content;
		close $out;
		$file_num++;
	}
}

sub _log_output {
	my ($dir, $processor, $stdout, $rc, $stderr, $time) = @_;
	
	# Main output file
	open my $fh, '>', "$dir/$processor.output" or return;
	print $fh $stdout || '';
	close $fh;
	
	# Error file
	if ($stderr) {
		open my $err_fh, '>', "$dir/$processor.error" or return;
		print $err_fh $stderr;
		close $err_fh;
	}
	
	# Metadata
	open my $meta_fh, '>', "$dir/$processor.meta" or return;
	print $meta_fh "Exit Code: $rc\n";
	print $meta_fh "Execution Time: ${time}s\n";
	print $meta_fh "Success: " . ($rc == 0 ? 'yes' : 'no') . "\n";
	close $meta_fh;
}

sub _log_comparison {
	my ($dir, $spruce_out, $graft_out, $spruce_rc, $graft_rc) = @_;
	
	open my $fh, '>', "$dir/comparison.log" or return;
	print $fh "Comparison Report\n";
	print $fh "================\n\n";
	
	# Exit code comparison
	print $fh "Exit Codes:\n";
	print $fh "  Spruce: $spruce_rc\n";
	print $fh "  Graft:  $graft_rc\n";
	print $fh "  Match:  " . ($spruce_rc == $graft_rc ? 'YES' : 'NO') . "\n\n";
	
	# Output comparison
	if (defined $spruce_out && defined $graft_out) {
		my $spruce_lines = [split /\n/, $spruce_out];
		my $graft_lines = [split /\n/, $graft_out];
		
		print $fh "Output Comparison:\n";
		print $fh "  Spruce lines: " . scalar(@$spruce_lines) . "\n";
		print $fh "  Graft lines:  " . scalar(@$graft_lines) . "\n";
		
		if ($spruce_out eq $graft_out) {
			print $fh "  Content: IDENTICAL\n";
		} else {
			print $fh "  Content: DIFFERENT\n";
			
			# Save diff
			open my $diff_fh, '>', "$dir/output.diff" or return;
			
			# Simple line-by-line diff
			my $max_lines = @$spruce_lines > @$graft_lines ? @$spruce_lines : @$graft_lines;
			for my $i (0..$max_lines-1) {
				my $s_line = $i < @$spruce_lines ? $spruce_lines->[$i] : undef;
				my $g_line = $i < @$graft_lines ? $graft_lines->[$i] : undef;
				
				if (!defined $s_line) {
					print $diff_fh "+graft:$i: $g_line\n";
				} elsif (!defined $g_line) {
					print $diff_fh "-spruce:$i: $s_line\n";
				} elsif ($s_line ne $g_line) {
					print $diff_fh "-spruce:$i: $s_line\n";
					print $diff_fh "+graft:$i: $g_line\n";
				}
			}
			close $diff_fh;
			
			print $fh "  Diff saved to: output.diff\n";
		}
	}
	
	close $fh;
}

1;

=head1 NAME

Genesis::YAMLCLI - YAML processing abstraction layer with dual-mode support

=head1 SYNOPSIS

	my $yaml = Genesis::YAMLCLI->new(processor => 'graft');
	my $yaml_dual = Genesis::YAMLCLI->new(processor => 'dual');
	
	$yaml->merge(@files);
	$yaml->json($file);
	$yaml->diff($file1, $file2);
	$yaml->vaultinfo($file);

=head1 DESCRIPTION

This module provides an abstraction layer over YAML processing tools,
supporting both spruce and graft with automatic fallback capabilities.

In dual mode, both processors are run for comparison and analysis, with
spruce used as the safe default for actual operations. All operations
are logged to ~/.genesis/logs/yaml-cli/ for later analysis.

=head1 METHODS

=head2 new(%opts)

Create a new YAMLCLI instance. Options:

=over

=item processor - Preferred YAML processor ('spruce', 'graft', or 'dual')

=back

If the preferred processor is not available, falls back to the alternative.
In dual mode, both processors must be available.

=head2 merge(@args)

Merge YAML files using the configured processor.

=head2 json(@args)

Convert YAML to JSON using the configured processor.

=head2 diff(@args)

Diff YAML files using the configured processor.

=head2 vaultinfo(@args)

Extract vault information using the configured processor.

=head2 cli()

Returns the name of the actual processor being used.

=cut