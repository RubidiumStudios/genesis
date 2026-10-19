package Harness::Contract;

# Readers of the pipeline a dry pipeline-apply prints, for the plumbing
# contract's rows.  See Harness/Contract.pod.

use strict;
use warnings;

use Exporter qw/import/;
use Genesis qw/load_yaml/;
use Harness::Propagation;

our @EXPORT = qw/
	contract_harness dry_pipeline
	pipeline_job pipeline_resource plan_steps task_step branch_resource
/;

our $ENV_NAME = 'qa';
our $TYPE     = 'doomsday';
our $ROOT     = 'doomsday';

sub contract_harness {
	my (%opts) = @_;
	my $h = make_harness(envs => [$ENV_NAME], provider => 'concourse', vault => 0,
		type => $TYPE, root => $ROOT, embed => !$opts{no_binary});
	compilable_pipeline($h);
	$h->set_repo_config($_, $opts{config}{$_}) for sort keys %{$opts{config} || {}};
	write_env_file($h, $ENV_NAME, pipeline => $opts{pipeline}) if $opts{pipeline};
	return $h;
}

sub dry_pipeline {
	my ($h) = @_;
	my ($out, $err, $exit) = run_genesis($h, {dir => $ROOT}, 'pipeline-apply', '--dry-run', '--skip-vault');
	return (undef, "exit $exit: $err") unless $exit == 0;
	my $p = eval {load_yaml($out)};
	return ($p, $p ? '' : "not YAML: $@\n$out");
}

sub pipeline_job      {my ($p, $name) = @_; (grep {$_->{name} eq $name} @{$p->{jobs} || []})[0]}
sub pipeline_resource {my ($p, $name) = @_; (grep {$_->{name} eq $name} @{$p->{resources} || []})[0]}

sub plan_steps {
	my ($node) = @_;
	return () unless ref $node;
	return map {plan_steps($_)} @$node if ref $node eq 'ARRAY';
	my @inner = map {plan_steps($node->{$_})} grep {exists $node->{$_}} qw/plan do in_parallel ensure on_success on_failure/;
	return ((grep {exists $node->{$_}} qw/get put task/) ? $node : (), @inner);
}

sub task_step {my ($job) = @_; (grep {$_->{task}} plan_steps($job))[0]}

sub branch_resource {my ($p) = @_; pipeline_resource($p, "$ENV_NAME-branch")}

1;
