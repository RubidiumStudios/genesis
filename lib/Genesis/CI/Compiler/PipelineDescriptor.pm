package Genesis::CI::Compiler::PipelineDescriptor;
use strict;
use warnings;

use Genesis;
use Genesis::Top ();
use JSON::PP;

### Constructor {{{

# new - create a new pipeline descriptor {{{
sub new {
	my ($class, %opts) = @_;

	return bless({
		ast => $opts{ast},
		top => $opts{top},
	}, $class);
}

# }}}
# }}}
### Public Methods {{{

# describe - build fully-resolved generic pipeline from AST {{{
#
# Takes the domain-specific AST (with Genesis concepts like targets,
# integrations, workflows, configuration) and produces a fully-resolved
# generic pipeline description with resource_types, resources, jobs,
# and groups. This is the boundary between Genesis domain logic and
# generic CI generation.
#
# Returns: hashref { resource_types, resources, jobs, groups }
sub describe {
	my ($self) = @_;

	my $ast         = $self->{ast};
	my $config      = $ast->configuration || {};
	my $deploy_type = $ast->metadata->{deployment_type} || 'deployment';
	my $name        = $ast->metadata->{name} || 'genesis-pipeline';

	my @resources;
	my @resource_types = @{$self->_resource_types($ast)};
	my @jobs;
	my @groups;

	# Base resources
	push @resources, $self->_git_resource($ast);
	push @resources, @{$self->_notification_resources($ast)};

	# Task library resource (optional external git repo for custom tasks)
	if (my $tlr = $self->_task_library_resource($ast)) {
		push @resources, $tlr;
	}

	# Process each workflow
	for my $wf_name (sort $ast->workflow_names) {
		my $workflow = $ast->workflows->{$wf_name};
		my $wf_data  = $self->_extract_workflow_data($ast, $workflow);

		# Error early if bosh-upgrade locks are needed but locker is not configured.
		my $locker = $ast->integrations->{locker} || {};
		for my $env (@{$wf_data->{environments}}) {
			my $parent = $wf_data->{bosh_parent}{$env} || '';
			next unless $parent && ($wf_data->{bosh_upgrade_lock}{$env} // 1);
			bail(
				"Environment '%s' has a pipeline-managed BOSH director ('%s') but no\n".
				"locker integration is configured.\n".
				"Add a 'locker:' block to your integrations configuration, or set\n".
				"  genesis:\n    pipeline:\n      locks:\n        bosh_upgrade: false\n".
				"in %s.yml to opt out.",
				$env, $parent, $env
			) unless $locker->{url};
		}

		my @wf_job_names;
		my @notify_job_names;
		my @redeploy_job_names;
		for my $env (@{$wf_data->{environments}}) {
			my $alias         = $wf_data->{aliases}{$env} || $env;
			my $is_auto       = $wf_data->{auto}{$env};
			my $trigger_from  = $wf_data->{triggers}{$env};
			my $is_create_env = $self->_is_create_env($ast, $env);

			push @resources, @{$self->_env_resources(
				$ast, $env, $alias, $trigger_from, $is_create_env, $wf_data
			)};

			# Locker resources
			if ($locker->{url}) {
				push @resources, @{$self->_locker_resources(
					$ast, $env, $alias, $deploy_type, $is_create_env, $wf_data
				)};
			}

			# Signal resource
			my $signal_cfg = $self->_env_signal_config($ast, $env, $wf_data);
			if ($signal_cfg) {
				push @resources, $self->_signal_resource(
					$ast, $env, $alias, $signal_cfg
				);
			}

			my $notif_style_env = $self->_effective_notif_style($ast);
			unless ($is_auto || $notif_style_env eq 'minimal' || $notif_style_env eq 'none') {
				my $nj = $self->_notify_job(
					$ast, $env, $alias, $deploy_type, $trigger_from,
					$is_create_env, $wf_data
				);
				push @jobs, $nj;
				push @wf_job_names, $nj->{name};
				push @notify_job_names, $nj->{name};
			}

			my $dj = $self->_deploy_job(
				$ast, $env, $alias, $deploy_type, $is_auto,
				$trigger_from, $is_create_env, $wf_data
			);
			push @jobs, $dj;
			push @wf_job_names, $dj->{name};

			# Redeploy lane
			my $redeploy_mode = $wf_data->{redeploy}{$env} || '';
			if ($redeploy_mode) {
				if ($redeploy_mode eq 'cron') {
					my $start = $wf_data->{redeploy_cron_start}{$env} || '04:00';
					my $stop  = $wf_data->{redeploy_cron_stop}{$env}  || '05:00';
					push @resources, $self->_redeploy_resource(
						$ast, $env, $alias, $start, $stop
					);
				}
				my $rj = $self->_redeploy_job(
					$ast, $env, $alias, $deploy_type, $redeploy_mode,
					$is_create_env, $wf_data
				);
				push @jobs, $rj;
				push @redeploy_job_names, $rj->{name};
			}
		}

		# Auto-update resources and job
		my $auto_update = $config->{auto_update};
		if ($auto_update && defined $auto_update->{file}) {
			push @resources, @{$self->_auto_update_resources($ast)};
			push @jobs, $self->_auto_update_job($ast);
		}

		# Groups
		my $group_notifications = $self->_effective_notif_style($ast) eq 'grouped';
		my $custom_groups = $config->{groups};

		if (ref($custom_groups) eq 'HASH') {
			my @grouped_notifications;
			for my $group_name (sort keys %$custom_groups) {
				my @group_jobs;
				for my $member (@{$custom_groups->{$group_name}}) {
					my $member_alias = $wf_data->{aliases}{$member} || $member;
					push @group_jobs, "$member_alias-$deploy_type";
					if (!$wf_data->{auto}{$member}) {
						my $notify_name = "notify-$member_alias-$deploy_type-changes";
						if ($group_notifications) {
							push @grouped_notifications, $notify_name;
						} else {
							push @group_jobs, $notify_name;
						}
					}
				}
				push @groups, {
					name => $group_name,
					jobs => [sort @group_jobs],
				};
			}
			if ($group_notifications && @grouped_notifications) {
				my %seen;
				push @groups, {
					name => 'notifications',
					jobs => [sort grep { !$seen{$_}++ } @grouped_notifications],
				};
			}
		} else {
			my @group_jobs = sort @wf_job_names;
			if ($group_notifications && @notify_job_names) {
				my %notify = map { $_ => 1 } @notify_job_names;
				@group_jobs = grep { !$notify{$_} } @group_jobs;
				push @groups, {
					name => ($wf_name eq 'default') ? $name : $wf_name,
					jobs => [sort @group_jobs],
				};
				push @groups, {
					name => 'notifications',
					jobs => [sort @notify_job_names],
				};
			} else {
				push @groups, {
					name => ($wf_name eq 'default') ? $name : $wf_name,
					jobs => [sort @group_jobs],
				};
			}
		}

		if ($auto_update && defined $auto_update->{file}) {
			push @groups, {
				name => 'genesis-updates',
				jobs => ['update-genesis-assets'],
			};
		}

		if (@redeploy_job_names) {
			push @groups, {
				name => 'redeploy',
				jobs => [sort @redeploy_job_names],
			};
		}
	}

	my $pipeline = {
		resource_types => \@resource_types,
		resources      => \@resources,
		jobs           => \@jobs,
		groups         => \@groups,
	};

	# Include visualization and description in the pipeline
	$pipeline->{mermaid}     = $self->mermaid();
	$pipeline->{pipeline_md} = $self->pipeline_md();
	$pipeline->{description} = $self->description();

	return $pipeline;
}

# }}}
# mermaid - generate Mermaid flowchart LR source from AST workflow graph {{{
sub mermaid {
	my ($self) = @_;

	my $ast   = $self->{ast};
	my @lines = ("flowchart LR");

	for my $wf_name (sort $ast->workflow_names) {
		my $workflow = $ast->workflows->{$wf_name};
		my $wf_data  = $self->_extract_workflow_data($ast, $workflow);
		my $graph    = $workflow->{graph} || {};
		my $nodes    = $graph->{nodes}    || {};
		my $edges    = $graph->{edges}    || [];

		# Build outgoing edge map; track which nodes appear in any edge
		my (%out_edges, %in_any_edge);
		for my $edge (@$edges) {
			push @{$out_edges{$edge->{from}}}, $edge->{to};
			$in_any_edge{$edge->{from}} = 1;
			$in_any_edge{$edge->{to}}   = 1;
		}

		# Topological order gives a clean left-to-right layout
		my @order = @$edges
			? _topological_sort($graph)
			: sort @{$wf_data->{environments}};

		# Emit edges; node shapes are defined inline on first appearance
		my %shape_defined;
		for my $env (@order) {
			next unless $out_edges{$env};

			my $from_alias = $wf_data->{aliases}{$env} || $env;
			my $from_id    = _mermaid_id($from_alias);
			my $from_ref   = $shape_defined{$from_id}
				? $from_id
				: _mermaid_node_def($from_alias, $nodes->{$env},
				    $wf_data->{is_bosh_director}{$env});
			$shape_defined{$from_id} = 1;

			for my $to_env (@{$out_edges{$env}}) {
				my $to_alias = $wf_data->{aliases}{$to_env} || $to_env;
				my $to_id    = _mermaid_id($to_alias);
				my $to_ref   = $shape_defined{$to_id}
					? $to_id
					: _mermaid_node_def($to_alias, $nodes->{$to_env},
					    $wf_data->{is_bosh_director}{$to_env});
				$shape_defined{$to_id} = 1;
				push @lines, "  $from_ref --> $to_ref";
			}
		}

		# Isolated nodes (no edges) rendered standalone at the bottom
		for my $env (@order) {
			next if $in_any_edge{$env};
			my $alias = $wf_data->{aliases}{$env} || $env;
			push @lines, "  " . _mermaid_node_def($alias, $nodes->{$env},
				$wf_data->{is_bosh_director}{$env});
		}
	}

	return join("\n", @lines) . "\n";
}

# }}}
# pipeline_md - Markdown document wrapping the Mermaid flowchart {{{
sub pipeline_md {
	my ($self) = @_;

	my $name    = $self->{ast}->metadata->{name} || 'genesis-pipeline';
	my $mermaid = $self->mermaid();

	return "# Pipeline: $name\n\n\`\`\`mermaid\n${mermaid}\`\`\`\n";
}

# }}}
# description - generate human-readable pipeline description text {{{
sub description {
	my ($self) = @_;

	my $ast         = $self->{ast};
	my $name        = $ast->metadata->{name} || 'genesis-pipeline';
	my $deploy_type = $ast->metadata->{deployment_type} || 'deployment';

	my @lines;
	push @lines, "Pipeline: $name";

	for my $wf_name (sort $ast->workflow_names) {
		my $workflow = $ast->workflows->{$wf_name};
		my $wf_data  = $self->_extract_workflow_data($ast, $workflow);

		my @order;
		if ($workflow->{graph}) {
			@order = _topological_sort($workflow->{graph});
		} else {
			@order = @{$wf_data->{environments}};
		}

		push @lines, sprintf("Workflow: %s",
			$wf_name eq 'default' ? $name : $wf_name);

		my $signal_global = ($ast->configuration || {})->{status_signal};

		for my $env (@order) {
			my $alias     = $wf_data->{aliases}{$env} || $env;
			my $is_auto   = $wf_data->{auto}{$env};
			my $trigger   = $wf_data->{triggers}{$env};
			my $trigger_a = $trigger ? ($wf_data->{aliases}{$trigger} || $trigger) : '';

			my $mode   = $is_auto ? 'auto' : 'manual';
			my $source = $trigger_a ? " (triggered by $trigger_a)" : '';

			# Annotations: REDEPLOY, SIGNAL
			my @annot;
			my $redeploy_mode = $wf_data->{redeploy}{$env} || '';
			push @annot, 'REDEPLOY:' . uc($redeploy_mode) if $redeploy_mode;
			if ($signal_global) {
				my $ss = $wf_data->{status_signal}{$env} // '';
				unless ($ss =~ /^(false|no|0)$/i) {
					my $backend = ($ss =~ /^(file|s3|gcs)$/) ? $ss
						: ($signal_global->{backend} || 'file');
					push @annot, "SIGNAL:$backend";
				}
			}
			my $annot_str = @annot ? '  [' . join(', ', @annot) . ']' : '';

			push @lines, sprintf("  %-20s %s-$deploy_type  [%s]%s%s",
				$alias, $alias, $mode, $source, $annot_str);
		}
		push @lines, "";
	}

	return join("\n", @lines);
}

# }}}
# }}}
### Pipeline Building {{{

# _resource_types - build resource type definitions {{{
sub _resource_types {
	my ($self, $ast) = @_;

	my $config   = $ast->configuration || {};
	my $registry = $config->{registry} || {};
	my $prefix   = $registry->{uri} ? "$registry->{uri}/" : '';

	my %rs;
	if ($registry->{username}) {
		$rs{username} = $registry->{username};
		$rs{password} = _unwrap_ref($registry->{password});
	}

	my @types = map {{
		name   => $_->[0],
		type   => 'registry-image',
		source => { %rs, repository => "$prefix$_->[1]" },
	}} (
		['script',      'cfcommunity/script-resource'],
		['email',       'pcfseceng/email-resource'],
		['bosh-config', 'cfcommunity/bosh-config-resource'],
		['locker',      'cfcommunity/locker-resource'],
	);

	# slack-notification type only when Slack is configured and not suppressed
	if ($self->_effective_notif_style($ast) ne 'none') {
		my $has_slack = $ast->integrations->{slack}
			|| do {
				my $nn = $ast->integrations->{notifications} || [];
				scalar grep { ref($_) eq 'HASH' && ($_->{type}||'') eq 'slack' } @$nn;
			};
		if ($has_slack) {
			push @types, {
				name   => 'slack-notification',
				type   => 'registry-image',
				source => { %rs, repository => "${prefix}cfcommunity/slack-notification-resource" },
			};
		}
	}

	# Shuttle resource type for deployment status signals
	if (my $signal = $config->{status_signal}) {
		my $img = (ref $signal eq 'HASH' ? $signal->{image}     : undef)
			|| 'cfcommunity/shuttle-resource';
		my $tag = (ref $signal eq 'HASH' ? $signal->{image_tag} : undef)
			|| 'latest';
		push @types, {
			name   => 'shuttle',
			type   => 'registry-image',
			source => { %rs, repository => "$prefix$img", tag => $tag },
		};
	}

	return \@types;
}

# }}}
# _git_resource - build main git resource {{{
sub _git_resource {
	my ($self, $ast) = @_;

	my $sc     = $ast->integrations->{source_control} || {};
	my $uri    = $self->_git_uri($sc);
	my $branch = $sc->{default_branch} || $ast->branches->{Genesis::Top::CI_PIPELINE_CONTROL_KEY()} || 'main';

	my $source = { uri => $uri, branch => $branch };

	if ($sc->{auth}) {
		if (($sc->{auth}{type} || '') eq 'ssh-key') {
			$source->{private_key} = _unwrap_ref($sc->{auth}{private_key});
		} else {
			$source->{username} = _unwrap_ref($sc->{auth}{username});
			$source->{password} = _unwrap_ref($sc->{auth}{password});
		}
	}
	$source->{version_depth} = $sc->{version_depth} if $sc->{version_depth};

	return { name => 'git', type => 'git', icon => 'github', source => $source };
}

# }}}
# _task_library_resource - git resource for the external task library {{{
#
# Returns a git resource hashref when configuration.task_library is declared,
# undef otherwise.  The resource is named by resource_name (default 'tasks').
sub _task_library_resource {
	my ($self, $ast) = @_;
	my $tl = ($ast->configuration || {})->{task_library};
	return undef unless $tl && ref($tl) eq 'HASH' && $tl->{uri};

	my $name   = $tl->{resource_name} || 'tasks';
	my $branch = $tl->{branch}        || 'main';

	my %source = ( uri => $tl->{uri}, branch => $branch );

	if (my $auth = $tl->{auth}) {
		if (($auth->{type} || '') eq 'ssh-key') {
			$source{private_key} = _unwrap_ref($auth->{private_key});
		} else {
			$source{username} = _unwrap_ref($auth->{username}) || 'x-oauth-basic';
			$source{password} = _unwrap_ref($auth->{password});
		}
	}

	return {
		name   => $name,
		type   => 'git',
		icon   => 'source-repository',
		source => \%source,
	};
}

# }}}
# _task_library_get - get step for the task library resource {{{
#
# Returns { get => $name, trigger => false } when the library is configured,
# undef otherwise.
sub _task_library_get {
	my ($self, $ast) = @_;
	my $tl = ($ast->configuration || {})->{task_library};
	return undef unless $tl && ref($tl) eq 'HASH' && $tl->{uri};
	my $name = $tl->{resource_name} || 'tasks';
	return { get => $name, trigger => JSON::PP::false };
}

# }}}
# _task_library_path - resolve a task name to its file path in the library {{{
#
# Returns "<resource_name>/<path>/<name>.yml" (with path omitted when empty).
sub _task_library_path {
	my ($self, $ast, $task_name) = @_;
	my $tl = ($ast->configuration || {})->{task_library};
	return undef unless $tl && ref($tl) eq 'HASH' && $tl->{uri};
	my $rn   = $tl->{resource_name} || 'tasks';
	my $path = $tl->{path}          || '';
	return $path ? "$rn/$path/$task_name.yml" : "$rn/$task_name.yml";
}

# }}}
# _notification_resources - build slack/email resources {{{
sub _notification_resources {
	my ($self, $ast) = @_;

	my @resources;

	# Structured Slack config (new format or legacy-normalized)
	if ($self->_effective_notif_style($ast) ne 'none') {
		my $slack = $self->_resolve_slack_config($ast, undef);
		if ($slack) {
			push @resources, {
				name   => 'slack',
				type   => 'slack-notification',
				icon   => 'slack',
				source => { url => _unwrap_ref($slack->{webhook}) },
			};
		}
	}

	# Legacy email / other notification backends
	my $notifications = $ast->integrations->{notifications} || [];
	$notifications = [] unless ref($notifications) eq 'ARRAY';
	for my $notif (@$notifications) {
		next unless ref($notif) eq 'HASH';
		next if ($notif->{type} || '') eq 'slack';  # handled via integrations.slack
		if (($notif->{type} || '') eq 'email') {
			push @resources, {
				name   => 'email',
				type   => 'email',
				icon   => 'email-send-outline',
				source => {
					to   => $notif->{recipients},
					from => $notif->{from},
					smtp => $notif->{smtp},
				},
			};
		}
	}

	return \@resources;
}

# }}}
# _env_resources - build per-environment resources {{{
sub _env_resources {
	my ($self, $ast, $env, $alias, $trigger_from, $is_create_env, $wf_data) = @_;

	my @resources;
	my $sc   = $ast->integrations->{source_control} || {};
	my $uri  = $self->_git_uri($sc);
	my $br   = $sc->{default_branch} || $ast->branches->{Genesis::Top::CI_PIPELINE_CONTROL_KEY()} || 'main';
	my $root = $sc->{root} || '.';
	my $pr   = ($root eq '.') ? '' : "$root/";

	# Shared git source
	my %gs = (uri => $uri, branch => $br);
	if ($sc->{auth}) {
		if (($sc->{auth}{type} || '') eq 'ssh-key') {
			$gs{private_key} = _unwrap_ref($sc->{auth}{private_key});
		} else {
			$gs{username} = _unwrap_ref($sc->{auth}{username});
			$gs{password} = _unwrap_ref($sc->{auth}{password});
		}
	}

	# Changes resource
	my @paths;
	if ($trigger_from) {
		@paths = map { "$pr$_" } _unique_env_files($env, $trigger_from);
	} else {
		@paths = (
			(map { "$pr$_" } _env_file_patterns($env)),
			"${pr}ops/*", "${pr}kit-overrides.yml",
		);
	}
	push @resources, {
		name => "$alias-changes", type => 'git', icon => 'github',
		source => { %gs, paths => \@paths },
	};

	# Cache resource (triggered envs only)
	if ($trigger_from) {
		my @cpaths = map { "$pr.genesis/cached/$trigger_from/$_" }
			_shared_env_files($env, $trigger_from);
		push @cpaths, "$pr.genesis/cached/$trigger_from/ops/*";
		push @cpaths, "$pr.genesis/cached/$trigger_from/kit-overrides.yml";
		push @resources, {
			name => "$alias-cache", type => 'git', icon => 'github',
			source => { %gs, paths => \@cpaths },
		};
	}

	# BOSH config resources (non-create-env)
	unless ($is_create_env) {
		my $target = $ast->targets->{$env} || {};
		my $conn   = $target->{connection} || {};
		my $auth   = $conn->{auth} || {};
		my $tagged = ($ast->configuration || {})->{tagged};
		my %to = $tagged ? (tags => [$env]) : ();

		my $ocfp = ($ast->configuration || {})->{ocfp};
		my $config_name = 'default';
		if ($ocfp) {
			$config_name = $wf_data->{genesis_envs}{$env} || $env;
		}

		my %bs = (
			target        => $conn->{url},
			client        => $auth->{client_id},
			client_secret => _unwrap_ref($auth->{client_secret}),
			ca_cert       => _unwrap_ref($conn->{ca_cert}),
		);
		$bs{name} = $config_name if $ocfp;

		push @resources, {
			name => "$alias-cloud-config", type => 'bosh-config',
			icon => 'script-text', %to,
			source => { %bs, config => 'cloud', all => JSON::PP::true },
		};
		push @resources, {
			name => "$alias-runtime-config", type => 'bosh-config',
			icon => 'script-text', %to,
			source => { %bs, config => 'runtime', all => JSON::PP::true },
		};
	}

	return \@resources;
}

# }}}
# _locker_resources - build locker resources for an environment {{{
#
# Three cases:
#   Director  (is_bosh_director=1):  emits <alias>-bosh-lock as a shared named
#                                    lock; all children will acquire this resource.
#   Child     (bosh_parent set, bosh_upgrade_lock=1):  emits only the
#                                    deployment-lock — bosh-lock is the director's.
#   Standalone (no pipeline parent): emits per-env bosh-lock pointing to the
#                                    BOSH director URL (legacy behaviour).
#
# All cases emit <alias>-deployment-lock for intra-env deploy serialization.
sub _locker_resources {
	my ($self, $ast, $env, $alias, $deploy_type, $is_create_env, $wf_data) = @_;

	my @resources;
	my $locker = $ast->integrations->{locker} || {};
	return \@resources unless $locker->{url};

	my $tagged = ($ast->configuration || {})->{tagged};
	my %to = $tagged ? (tags => [$env]) : ();

	my %locker_source = (
		locker_uri          => _unwrap_ref($locker->{url}),
		username            => _unwrap_ref($locker->{username}),
		password            => _unwrap_ref($locker->{password}),
		skip_ssl_validation => $locker->{skip_ssl_validation} // JSON::PP::true,
		ca_cert             => $locker->{ca_cert},
	);

	my $bosh_parent    = $wf_data->{bosh_parent}{$env}       || '';
	my $bu_lock        = $wf_data->{bosh_upgrade_lock}{$env} // 1;
	my $is_director    = $wf_data->{is_bosh_director}{$env}  || 0;

	if ($is_director) {
		# Shared bosh-upgrade lock — children acquire this during their deploys.
		# Use lock_name (named lock) so no BOSH URL is required at pipeline-gen time.
		push @resources, {
			name   => "$alias-bosh-lock",
			type   => 'locker',
			icon   => 'shield-lock-outline',
			%to,
			source => { %locker_source, lock_name => "$alias-bosh-upgrade" },
		};
	} elsif (!$bosh_parent || !$bu_lock) {
		# Standalone or opted-out child: per-env bosh-lock using the BOSH URL.
		unless ($is_create_env) {
			my $target = $ast->targets->{$env} || {};
			my $conn   = $target->{connection} || {};
			push @resources, {
				name   => "$alias-bosh-lock",
				type   => 'locker',
				icon   => 'shield-lock-outline',
				%to,
				source => { %locker_source, bosh_lock => $conn->{url} },
			};
		}
	}
	# Children with bosh_parent + bosh_upgrade_lock: no own bosh-lock resource —
	# they acquire the director's <director-alias>-bosh-lock instead.

	push @resources, {
		name   => "$alias-deployment-lock",
		type   => 'locker',
		icon   => 'shield-lock-outline',
		%to,
		source => { %locker_source, lock_name => "$env-$deploy_type" },
	};

	return \@resources;
}

# }}}
# _notify_job - notification job for non-auto environments {{{
sub _notify_job {
	my ($self, $ast, $env, $alias, $deploy_type, $trigger_from,
		$is_create_env, $wf_data) = @_;

	my $config = $ast->configuration || {};
	my $tagged = $config->{tagged};
	my %to     = $tagged ? (tags => [$env]) : ();
	my $passed = $trigger_from ? $wf_data->{aliases}{$trigger_from} : '';
	my $passed_job = $passed ? "$passed-$deploy_type" : '';

	my @gets = ({ get => "$alias-changes", trigger => JSON::PP::true });
	push @gets, { get => "$alias-cache", trigger => JSON::PP::true }
		if $trigger_from;
	push @gets, { get => 'git', passed => [$passed_job], trigger => JSON::PP::false }
		if $passed_job && !$config->{'require-passed-caches'};

	unless ($is_create_env) {
		push @gets, { get => "$alias-cloud-config",   %to, trigger => JSON::PP::true };
		push @gets, { get => "$alias-runtime-config", %to, trigger => JSON::PP::true };
	}

	my $task_cfg = $self->_task_config($ast, $env, $alias, $trigger_from, $wf_data,
		{ command => 'ci-show-changes' });

	my $pipeline_name = $ast->metadata->{name} || 'genesis-pipeline';
	my $notif = $self->_notification_step($ast,
		"$pipeline_name: Changes staged for $env-$deploy_type",
		{ env => $env });

	my @plan = (
		{ in_parallel => \@gets },
		{ task => 'show-pending-changes', %to, config => $task_cfg },
	);
	push @plan, $notif if $notif;

	return {
		name   => "notify-$alias-$deploy_type-changes",
		public => JSON::PP::true,
		serial => JSON::PP::true,
		plan   => \@plan,
	};
}

# }}}
# _deploy_job - deployment job for an environment {{{
sub _deploy_job {
	my ($self, $ast, $env, $alias, $deploy_type, $is_auto,
		$trigger_from, $is_create_env, $wf_data) = @_;

	my $config     = $ast->configuration || {};
	my $sc         = $ast->integrations->{source_control} || {};
	my $root       = $sc->{root} || '.';
	my $tagged     = $config->{tagged};
	my %to         = $tagged ? (tags => [$env]) : ();
	my $name       = $ast->metadata->{name} || 'genesis-pipeline';
	my $trigger    = $is_auto ? JSON::PP::true : JSON::PP::false;
	my $passed     = $trigger_from ? $wf_data->{aliases}{$trigger_from} : '';
	my $passed_job = $passed ? "$passed-$deploy_type" : '';
	my $pass_cache  = $config->{'require-passed-caches'};
	my $inline      = $self->_effective_notif_style($ast) eq 'per-env';

	my $srcdir = $pass_cache
		? ($trigger_from ? "$alias-cache" : "$alias-changes")
		: 'git';
	my $bindir = $srcdir;
	$bindir .= "/$root" if $root ne '.';

	# Resource gets
	my @gets;
	if (!$is_create_env && $is_auto) {
		push @gets, { get => "$alias-cloud-config",   %to, trigger => JSON::PP::true };
		push @gets, { get => "$alias-runtime-config", %to, trigger => JSON::PP::true };
	}
	if ($is_auto || !$inline) {
		push @gets, { get => "$alias-changes", trigger => $trigger };
	} else {
		push @gets, { get => "$alias-changes", trigger => JSON::PP::false,
			passed => ["notify-$alias-$deploy_type-changes"] };
	}
	if ($trigger_from) {
		my %cg = (get => "$alias-cache",
			trigger => ($is_auto ? JSON::PP::true : JSON::PP::false));
		$cg{passed} = [$passed_job] if $pass_cache && $passed_job;
		push @gets, \%cg;
	}
	if ($trigger_from && !$pass_cache) {
		my $gp = ($is_auto || !$inline) ? $passed_job
			: "notify-$alias-$deploy_type-changes";
		push @gets, { get => 'git', passed => [$gp], trigger => JSON::PP::false }
			if $gp;
	}

	# Task library (optional external git resource with custom task files)
	if (my $tl_get = $self->_task_library_get($ast)) {
		push @gets, $tl_get;
	}

	# Deploy task
	my $deploy_task = {
		task => 'bosh-deploy', %to,
		config => $self->_task_config($ast, $env, $alias, $trigger_from, $wf_data,
			{ command => 'ci-pipeline-deploy',
			  genesis_bindir => $bindir, genesis_srcdir => $srcdir }),
		ensure => { put => 'git', params => { repository => 'out/git' } },
	};
	my @priv = @{$config->{task}{privileged} || []};
	$deploy_task->{privileged} = JSON::PP::true if grep { $_ eq $alias } @priv;

	# Cache task
	my $cache_task = {
		task => 'generate-cache', %to,
		config => $self->_cache_task_config($ast, $env, $alias, $trigger_from, $wf_data,
			{ genesis_bindir => $bindir, genesis_srcdir => $srcdir }),
	};

	# Locker steps
	my @lock_steps;
	my @unlock_steps;
	my $locker = $ast->integrations->{locker} || {};
	if ($locker->{url}) {
		my $bosh_parent = $wf_data->{bosh_parent}{$env}       || '';
		my $bu_lock     = $wf_data->{bosh_upgrade_lock}{$env} // 1;
		my $is_director = $wf_data->{is_bosh_director}{$env}  || 0;

		my $bosh_lock_alias;
		if ($bosh_parent && $bu_lock) {
			# Child: acquire director's shared bosh-lock
			$bosh_lock_alias = $wf_data->{aliases}{$bosh_parent} || $bosh_parent;
		} elsif ($is_director || !$is_create_env) {
			# Director or standalone non-create-env: acquire own bosh-lock
			$bosh_lock_alias = $alias;
		}

		if ($bosh_lock_alias) {
			push @lock_steps, {
				put => "$bosh_lock_alias-bosh-lock", %to,
				params => {
					lock_op => 'lock', key => 'dont-upgrade-bosh-on-me',
					locked_by => "$env-$deploy_type",
				},
			};
			push @unlock_steps, {
				put => "$bosh_lock_alias-bosh-lock", %to,
				params => {
					lock_op => 'unlock', key => 'dont-upgrade-bosh-on-me',
					locked_by => "$env-$deploy_type",
				},
			};
		}

		push @lock_steps, {
			put => "$alias-deployment-lock", %to,
			params => {
				lock_op => 'lock', key => 'i-need-to-deploy-myself',
				locked_by => "$env-$deploy_type",
			},
		};
		push @unlock_steps, {
			put => "$alias-deployment-lock", %to,
			params => {
				lock_op => 'unlock', key => 'i-need-to-deploy-myself',
				locked_by => "$env-$deploy_type",
			},
		};
	}

	# Build do block
	my @do;
	push @do, @lock_steps;
	push @do, { in_parallel => \@gets };
	push @do, $deploy_task;

	unless ($is_create_env) {
		for my $errand (@{$config->{errands} || []}) {
			my $tl_file = $self->_task_library_path($ast, $errand);
			push @do, $tl_file
				? { task => "$errand-errand", %to, file => $tl_file }
				: { task => "$errand-errand", %to,
				    config => $self->_errand_config($ast, $env, $errand, $bindir, $srcdir) };
		}
	}

	push @do, $cache_task;
	push @do, { put => 'git', params => { repository => 'cache-out/git' } };

	for my $push_env (@{$wf_data->{will_trigger}{$env} || []}) {
		my $pa = $wf_data->{aliases}{$push_env} || $push_env;
		if ($pass_cache) {
			push @do, { put => "$pa-cache",
				params => { repository => 'cache-out/git' } };
		} else {
			push @do, { get => "$pa-cache", %to };
		}
	}

	my %hooks = $self->_outcome_hooks($ast, $env, $alias, $deploy_type, $wf_data, 0);
	my $plan_step = {};
	$plan_step->{$_} = $hooks{$_} for sort keys %hooks;
	$plan_step->{ensure} = { do => \@unlock_steps } if @unlock_steps;
	$plan_step->{do} = \@do;

	return {
		name   => "$alias-$deploy_type",
		public => JSON::PP::true,
		serial => JSON::PP::true,
		plan   => [$plan_step],
	};
}

# }}}
# _redeploy_resource - Concourse time resource for cron-mode redeploy {{{
sub _redeploy_resource {
	my ($self, $ast, $env, $alias, $start, $stop) = @_;

	my $config = $ast->configuration || {};
	my $tagged = $config->{tagged};
	my %to = $tagged ? (tags => [$env]) : ();

	return {
		name   => "$alias-redeploy-cron",
		type   => 'time',
		icon   => 'clock-outline',
		%to,
		source => {
			start    => $start,
			stop     => $stop,
			location => 'UTC',
		},
	};
}

# }}}
# _redeploy_job - redeploy job for an environment {{{
#
# Redeploys an environment without change detection or cache generation.
# Trigger modes: manual (no auto-trigger), cron (time resource), signal (like manual).
sub _redeploy_job {
	my ($self, $ast, $env, $alias, $deploy_type, $trigger_mode,
		$is_create_env, $wf_data) = @_;

	my $config = $ast->configuration || {};
	my $sc     = $ast->integrations->{source_control} || {};
	my $root   = $sc->{root} || '.';
	my $tagged = $config->{tagged};
	my %to     = $tagged ? (tags => [$env]) : ();
	my $name   = $ast->metadata->{name} || 'genesis-pipeline';

	my $bindir = 'git';
	my $srcdir = "$alias-changes";
	$bindir .= "/$root" if $root ne '.';

	# Resource gets — no change-detection triggers
	my $signal_cfg = $self->_env_signal_config($ast, $env, $wf_data);
	my @gets;
	if ($trigger_mode eq 'cron') {
		push @gets, {
			get     => "$alias-redeploy-cron",
			trigger => JSON::PP::true,
		};
	} elsif ($trigger_mode eq 'signal' && $signal_cfg) {
		push @gets, {
			get     => "$alias-signal",
			trigger => JSON::PP::true,
			version => { status => 'success' },
		};
	}
	push @gets, { get => "$alias-changes", trigger => JSON::PP::false };
	push @gets, { get => 'git', trigger => JSON::PP::false }
		unless $config->{'require-passed-caches'};
	unless ($is_create_env) {
		push @gets, { get => "$alias-cloud-config",   %to, trigger => JSON::PP::false };
		push @gets, { get => "$alias-runtime-config", %to, trigger => JSON::PP::false };
	}

	# Task library
	if (my $tl_get = $self->_task_library_get($ast)) {
		push @gets, $tl_get;
	}

	# Deploy task — reuses ci-pipeline-deploy with no prior_env
	my $deploy_task = {
		task => 'bosh-redeploy', %to,
		config => $self->_task_config($ast, $env, $alias, undef, $wf_data,
			{ command        => 'ci-pipeline-deploy',
			  genesis_bindir => $bindir,
			  genesis_srcdir => $srcdir }),
		ensure => { put => 'git', params => { repository => 'out/git' } },
	};
	my @priv = @{$config->{task}{privileged} || []};
	$deploy_task->{privileged} = JSON::PP::true if grep { $_ eq $alias } @priv;

	# Locker steps — mirrors _deploy_job lock topology
	my @lock_steps;
	my @unlock_steps;
	my $locker = $ast->integrations->{locker} || {};
	if ($locker->{url}) {
		my $bosh_parent = $wf_data->{bosh_parent}{$env}       || '';
		my $bu_lock     = $wf_data->{bosh_upgrade_lock}{$env} // 1;
		my $is_director = $wf_data->{is_bosh_director}{$env}  || 0;

		my $bosh_lock_alias;
		if ($bosh_parent && $bu_lock) {
			$bosh_lock_alias = $wf_data->{aliases}{$bosh_parent} || $bosh_parent;
		} elsif ($is_director || !$is_create_env) {
			$bosh_lock_alias = $alias;
		}

		if ($bosh_lock_alias) {
			push @lock_steps, {
				put => "$bosh_lock_alias-bosh-lock", %to,
				params => {
					lock_op => 'lock', key => 'dont-upgrade-bosh-on-me',
					locked_by => "$env-redeploy",
				},
			};
			push @unlock_steps, {
				put => "$bosh_lock_alias-bosh-lock", %to,
				params => {
					lock_op => 'unlock', key => 'dont-upgrade-bosh-on-me',
					locked_by => "$env-redeploy",
				},
			};
		}

		push @lock_steps, {
			put => "$alias-deployment-lock", %to,
			params => {
				lock_op => 'lock', key => 'i-need-to-deploy-myself',
				locked_by => "$env-redeploy",
			},
		};
		push @unlock_steps, {
			put => "$alias-deployment-lock", %to,
			params => {
				lock_op => 'unlock', key => 'i-need-to-deploy-myself',
				locked_by => "$env-redeploy",
			},
		};
	}

	my @do;
	push @do, @lock_steps;
	push @do, { in_parallel => \@gets };
	push @do, $deploy_task;

	my %hooks = $self->_outcome_hooks($ast, $env, $alias, $deploy_type, $wf_data, 1);
	my $plan_step = {};
	$plan_step->{$_} = $hooks{$_} for sort keys %hooks;
	$plan_step->{ensure} = { do => \@unlock_steps } if @unlock_steps;
	$plan_step->{do} = \@do;

	return {
		name   => "redeploy-$alias",
		public => JSON::PP::true,
		serial => JSON::PP::true,
		plan   => [$plan_step],
	};
}

# }}}
# _env_signal_config - resolve effective signal config for an env {{{
#
# Returns a hashref with the merged global+per-env signal config, or undef
# if signals are not configured or explicitly disabled for this env.
sub _env_signal_config {
	my ($self, $ast, $env, $wf_data) = @_;

	my $global = ($ast->configuration || {})->{status_signal};
	return undef unless $global && ref($global) eq 'HASH';

	my $env_setting = $wf_data->{status_signal}{$env} // '';

	# Explicitly disabled for this env
	return undef if $env_setting =~ /^(false|no|0)$/i;

	# Effective backend: per-env backend override or global
	my $backend = $global->{backend} || 'file';
	$backend = $env_setting if $env_setting =~ /^(file|s3|gcs)$/;

	# Effective prefix: per-env override, or global-base/env, or just env name
	my $env_prefix    = $wf_data->{signal_prefix}{$env} || '';
	my $global_prefix = $global->{prefix} || '';
	my $prefix = $env_prefix
		|| ($global_prefix ? "$global_prefix/$env" : $env);

	return { %$global, backend => $backend, prefix => $prefix };
}

# }}}
# _signal_resource - build per-env signal (shuttle) resource {{{
sub _signal_resource {
	my ($self, $ast, $env, $alias, $signal_cfg) = @_;

	my $config  = $ast->configuration || {};
	my $tagged  = $config->{tagged};
	my %to      = $tagged ? (tags => [$env]) : ();
	my $backend = $signal_cfg->{backend} || 'file';
	my $prefix  = $signal_cfg->{prefix}  || $env;

	my %source = (backend => $backend, prefix => $prefix);

	if ($backend eq 's3') {
		$source{bucket}            = $signal_cfg->{bucket} || 'genesis-signals';
		$source{region}            = $signal_cfg->{region} || 'us-east-1';
		$source{access_key_id}     = _unwrap_ref($signal_cfg->{access_key_id});
		$source{secret_access_key} = _unwrap_ref($signal_cfg->{secret_access_key});
		$source{endpoint}          = $signal_cfg->{endpoint}
			if $signal_cfg->{endpoint};
	} elsif ($backend eq 'gcs') {
		$source{bucket}   = $signal_cfg->{bucket} || 'genesis-signals';
		$source{json_key} = _unwrap_ref($signal_cfg->{json_key});
	} elsif ($backend eq 'file') {
		my $base = $signal_cfg->{path} || '/tmp/genesis-signals';
		$source{path} = "$base/$prefix";
	}

	return {
		name   => "$alias-signal",
		type   => 'shuttle',
		icon   => 'broadcast',
		%to,
		source => \%source,
	};
}

# }}}
# _signal_put_step - build a put step to emit a deployment status signal {{{
sub _signal_put_step {
	my ($self, $alias, $status, $env, $deploy_type) = @_;
	return {
		put    => "$alias-signal",
		params => {
			status     => $status,
			deployment => "$env-$deploy_type",
		},
	};
}

# }}}
# _outcome_hooks - build on_success/on_failure/on_abort/on_error plan hooks {{{
#
# Combines notification steps (success/failure) with signal put steps (all four
# outcomes).  Returns a hash with only the keys that have actual content.
sub _outcome_hooks {
	my ($self, $ast, $env, $alias, $deploy_type, $wf_data, $is_redeploy) = @_;

	my $name      = $ast->metadata->{name} || 'genesis-pipeline';
	my $action    = $is_redeploy ? 'Redeploy of'    : 'Deployment to';
	my $ok_action = $is_redeploy ? 'redeployed'     : 'deployed';
	my $ok_msg    = "$name: Successfully ${ok_action} $env-$deploy_type";
	my $fail_msg  = "$name: $action $env-$deploy_type failed";

	my $signal_cfg  = $self->_env_signal_config($ast, $env, $wf_data);
	my $notif_style = $self->_effective_notif_style($ast);

	my %hooks;
	for my $outcome (qw(success failure abort error)) {
		my @steps;

		# Notifications: suppressed entirely for 'none'; success suppressed for 'minimal'
		if ($outcome eq 'success'
			&& $notif_style ne 'minimal' && $notif_style ne 'none') {
			my $notif = $self->_notification_step($ast, $ok_msg, { env => $env });
			push @steps, @{$notif->{in_parallel}} if $notif;
		} elsif ($outcome eq 'failure' && $notif_style ne 'none') {
			my $notif = $self->_notification_step($ast, $fail_msg,
				{ env => $env, is_failure => 1 });
			push @steps, @{$notif->{in_parallel}} if $notif;
		}

		# Signal: all four outcomes
		if ($signal_cfg) {
			push @steps, $self->_signal_put_step($alias, $outcome, $env, $deploy_type);
		}

		next unless @steps;
		$hooks{"on_$outcome"} = @steps == 1 ? $steps[0] : { in_parallel => \@steps };
	}

	return %hooks;
}

# }}}
# _auto_update_resources - build kit-release and genesis-release resources {{{
sub _auto_update_resources {
	my ($self, $ast) = @_;

	my $config      = $ast->configuration || {};
	my $auto_update = $config->{auto_update} || {};

	my @resources;
	push @resources, {
		name        => 'kit-release',
		icon        => 'package-variant',
		type        => 'github-release',
		check_every => $auto_update->{period} || '24h',
		source      => {
			user         => $auto_update->{org},
			repository   => "$auto_update->{kit}-genesis-kit",
			access_token => _unwrap_ref($auto_update->{kit_auth_token}
				|| $auto_update->{auth_token} || ''),
			($auto_update->{api_url}
				? (github_api_url => $auto_update->{api_url}) : ()),
		},
	};

	push @resources, {
		name        => 'genesis-release',
		type        => 'github-release',
		icon        => 'leaf',
		check_every => $auto_update->{period} || '24h',
		source      => {
			user         => 'genesis-community',
			repository   => 'genesis',
			access_token => _unwrap_ref($auto_update->{genesis_auth_token}
				|| $auto_update->{auth_token} || ''),
		},
	};

	return \@resources;
}

# }}}
# _auto_update_job - build update-genesis-assets job {{{
sub _auto_update_job {
	my ($self, $ast) = @_;

	my $config      = $ast->configuration || {};
	my $sc          = $ast->integrations->{source_control} || {};
	my $root        = $sc->{root} || '.';
	my $auto_update = $config->{auto_update} || {};
	my $task_cfg    = $config->{task} || {};
	my $reg         = $config->{registry} || {};
	my $pfx         = $reg->{uri} ? "$reg->{uri}/" : '';

	my $img_src = {
		repository => "$pfx" . ($task_cfg->{image} || 'genesiscommunity/concourse'),
		tag        => $task_cfg->{version} || 'latest',
	};
	if ($reg->{username}) {
		$img_src->{username} = $reg->{username};
		$img_src->{password} = _unwrap_ref($reg->{password});
	}

	my $git_genesis_dir = 'git';
	my $genesis_config_path = '';
	my $path_prefix = '';
	my $subdir_msg = '';
	if ($root ne '.') {
		$git_genesis_dir .= "/$root";
		$genesis_config_path = " -C '$root'";
		$path_prefix = "$root/";
		$subdir_msg = " under $root";
	}

	my $user_name = ($sc->{commit_author} ? $sc->{commit_author}{name}  : undef)
		|| 'Concourse Bot';
	my $user_email = ($sc->{commit_author} ? $sc->{commit_author}{email} : undef)
		|| 'concourse@pipeline';
	my $ci_label  = $auto_update->{label} || 'concourse';
	my $kit_name  = $auto_update->{kit};

	my $list_kits_task = {
		task   => 'list-kits',
		config => {
			platform       => 'linux',
			image_resource => { type => 'registry-image', source => $img_src },
			inputs         => [{ name => 'git' }],
			params         => { GENESIS_KIT_NAME => "$kit_name-genesis-kit" },
			run            => {
				dir  => $git_genesis_dir,
				path => 'sh',
				args => ['-ce', '.genesis/bin/genesis list-kits ${GENESIS_KIT_NAME} -u'],
			},
		},
	};

	my $pushd_cmd = ($root eq '.') ? '' : "pushd '$root' &> /dev/null\n";
	my $popd_cmd  = ($root eq '.') ? '' : "popd &> /dev/null\n";
	my $update_genesis_script = <<"SCRIPT";
chmod +x ../genesis-release/genesis
upstream="\$(../genesis-release/genesis -v 2>/dev/null | sed -e 's/Genesis v\\([^ ]*\\) .*/\\1/')"
current="\$('${path_prefix}.genesis/bin/genesis' -v 2>/dev/null | sed -e 's/Genesis v\\([^ ]*\\) .*/\\1/')"
if [[ -z "\$upstream" || ! "\$upstream" =~ ^[0-9]+(\\.[0-9]+){2}(-rc[0-9]+)?\$ ]]; then
  echo >&2 "Error: could not get upstream genesis version"
  exit 1
fi
if [[ -z "\$current" || ! "\$current" =~ ^[0-9]+(\\.[0-9]+){2}(-rc[0-9]+)?\$ ]]; then
  echo >&2 "Error: could not get embedded genesis version"
  exit 1
fi
if ../genesis-release/genesis ui-semver \$upstream ge \$current && \\
 ! ../genesis-release/genesis ui-semver \$current ge \$upstream ; then
  ../genesis-release/genesis${genesis_config_path} embed
  if ! git diff --stat --exit-code '${path_prefix}.genesis/bin/genesis'; then
    git config --global user.email "\${GITHUB_EMAIL}"
    git config --global user.name "\${GITHUB_USER}"
    git add '${path_prefix}.genesis/bin/genesis'
    git commit -m "[\${CI_LABEL}] bump genesis to \$('${path_prefix}.genesis/bin/genesis' version)${subdir_msg}"
  fi
fi
SCRIPT

	my $update_genesis_task = {
		task   => 'update-genesis',
		config => {
			platform       => 'linux',
			image_resource => { type => 'registry-image', source => $img_src },
			inputs         => [{ name => 'git' }, { name => 'genesis-release' }],
			outputs        => [{ name => 'git' }],
			params         => {
				CI_LABEL     => $ci_label,
				GITHUB_USER  => $user_name,
				GITHUB_EMAIL => $user_email,
			},
			run => { dir => 'git', path => 'bash', args => ['-ce', $update_genesis_script] },
		},
	};

	my $fetch_kit_script = <<"SCRIPT";
version="\$(cat ../kit-release/version)"
${pushd_cmd}if ! .genesis/bin/genesis --no-color list-kits \${GENESIS_KIT_NAME} | grep "v\$version\\\$"; then
  .genesis/bin/genesis fetch-kit \${GENESIS_KIT_NAME}/\$version
fi
sed -i'' "/^kit:/,/^  version:/{s/version.*/version: \$version/}" "\${KIT_VERSION_FILE}"
if git diff --stat --exit-code '.genesis/kits' "\${KIT_VERSION_FILE}"; then
  echo "No change detected - still using \${GENESIS_KIT_NAME}/\$version${subdir_msg}"
  exit 0
fi
git config --global user.email "\${GITHUB_EMAIL}"
git config --global user.name "\${GITHUB_USER}"
git add '.genesis/kits' "\${KIT_VERSION_FILE}"
${popd_cmd}git commit -m "[\${CI_LABEL}] bump kit \${GENESIS_KIT_NAME} to version \$version${subdir_msg}"
SCRIPT

	my $fetch_kit_task = {
		task   => 'fetch-kit',
		config => {
			platform       => 'linux',
			image_resource => { type => 'registry-image', source => $img_src },
			inputs         => [{ name => 'git' }, { name => 'kit-release' }],
			outputs        => [{ name => 'git' }],
			params         => {
				KIT_VERSION_FILE  => $auto_update->{file},
				GENESIS_KIT_NAME  => $kit_name,
				CI_LABEL          => $ci_label,
				GITHUB_AUTH_TOKEN => _unwrap_ref($auto_update->{kit_auth_token}
					|| $auto_update->{auth_token} || ''),
				GITHUB_USER       => $user_name,
				GITHUB_EMAIL      => $user_email,
			},
			run => { dir => 'git', path => 'bash', args => ['-ce', $fetch_kit_script] },
		},
	};

	return {
		name => 'update-genesis-assets',
		plan => [
			{
				in_parallel => [
					{ get => 'git' },
					{ get => 'kit-release', trigger => JSON::PP::true },
					{ get => 'genesis-release' },
				],
			},
			$list_kits_task,
			$update_genesis_task,
			$fetch_kit_task,
			{ put => 'git', params => { repository => 'git', rebase => JSON::PP::true } },
		],
	};
}

# }}}
# }}}
### Task Configuration {{{

# _task_config - common task configuration block {{{
sub _task_config {
	my ($self, $ast, $env, $alias, $trigger_from, $wf_data, $opts) = @_;

	my $config  = $ast->configuration || {};
	my $sc      = $ast->integrations->{source_control} || {};
	my $vault   = $ast->integrations->{vault} || {};
	my $root    = $sc->{root} || '.';
	my $cmd     = $opts->{command} || 'ci-pipeline-deploy';
	my $bindir  = $opts->{genesis_bindir} || 'git';
	my $srcdir  = $opts->{genesis_srcdir} || 'git';
	my $passed  = $trigger_from || '';

	my $task_cfg = $config->{task} || {};
	my $reg      = $config->{registry} || {};
	my $pfx      = $reg->{uri} ? "$reg->{uri}/" : '';

	my $img_src = {
		repository => "$pfx" . ($task_cfg->{image} || 'genesiscommunity/concourse'),
		tag        => $task_cfg->{version} || 'latest',
	};
	if ($reg->{username}) {
		$img_src->{username} = $reg->{username};
		$img_src->{password} = _unwrap_ref($reg->{password});
	}

	my %params = (
		GENESIS_HONOR_ENV    => 1,
		CI_NO_REDACT         => $config->{unredacted} || 0,
		CURRENT_ENV          => $env,
		PREVIOUS_ENV         => $passed || '~',
		CACHE_DIR            => "$alias-cache",
		OUT_DIR              => 'out/git',
		WORKING_DIR          => "$alias-changes",
		GIT_BRANCH           => $sc->{default_branch} || $ast->branches->{Genesis::Top::CI_PIPELINE_CONTROL_KEY()} || 'main',
		GIT_AUTHOR_NAME      => ($sc->{commit_author} ? $sc->{commit_author}{name}  : undef)
			|| 'Concourse Bot',
		GIT_AUTHOR_EMAIL     => ($sc->{commit_author} ? $sc->{commit_author}{email} : undef)
			|| 'concourse@pipeline',
		BOSH_NON_INTERACTIVE => 'true',
		VAULT_ADDR           => $vault->{url} || '',
	);

	if ($vault->{auth}) {
		$params{VAULT_ROLE_ID}   = _unwrap_ref($vault->{auth}{role_id});
		$params{VAULT_SECRET_ID} = _unwrap_ref($vault->{auth}{secret_id});
	}
	if ($vault->{options}) {
		$params{VAULT_SKIP_VERIFY}  = $vault->{options}{tls_verify} ? 'false' : 'true';
		$params{VAULT_NO_STRONGBOX} = '"true"' if $vault->{options}{no_strongbox};
	}
	$params{VAULT_NAMESPACE} = $vault->{namespace} if $vault->{namespace};

	if ($sc->{auth}) {
		if (($sc->{auth}{type} || '') eq 'ssh-key') {
			$params{GIT_PRIVATE_KEY} = _unwrap_ref($sc->{auth}{private_key});
		} else {
			$params{GIT_USERNAME} = _unwrap_ref($sc->{auth}{username});
			$params{GIT_PASSWORD} = _unwrap_ref($sc->{auth}{password});
		}
	}
	$params{GIT_GENESIS_ROOT} = $root if $root ne '.';
	$params{DEBUG}            = $config->{debug} if $config->{debug};

	my @inputs = ({ name => "$alias-changes" });
	push @inputs, { name => "$alias-cache" } if $passed;
	push @inputs, { name => 'git' } unless $config->{'require-passed-caches'};

	# Task library input — expose library files to the running task
	if (my $tl = $config->{task_library}) {
		if (ref($tl) eq 'HASH' && $tl->{uri}) {
			my $rn   = $tl->{resource_name} || 'tasks';
			my $path = $tl->{path}          || '';
			push @inputs, { name => $rn };
			$params{GENESIS_TASK_LIBRARY_PATH} = $path ? "$rn/$path" : $rn;
		}
	}

	return {
		platform       => 'linux',
		image_resource => { type => 'registry-image', source => $img_src },
		params         => \%params,
		run            => { path => "$bindir/.genesis/bin/genesis", args => [$cmd] },
		inputs         => \@inputs,
		outputs        => [{ name => 'out' }],
	};
}

# }}}
# _cache_task_config - cache generation task config {{{
sub _cache_task_config {
	my ($self, $ast, $env, $alias, $trigger_from, $wf_data, $opts) = @_;

	my $config = $ast->configuration || {};
	my $sc     = $ast->integrations->{source_control} || {};
	my $root   = $sc->{root} || '.';
	my $bindir = $opts->{genesis_bindir} || 'git';
	my $srcdir = $opts->{genesis_srcdir} || 'git';

	my $task_cfg = $config->{task} || {};
	my $reg      = $config->{registry} || {};
	my $pfx      = $reg->{uri} ? "$reg->{uri}/" : '';

	my $img_src = {
		repository => "$pfx" . ($task_cfg->{image} || 'genesiscommunity/concourse'),
		tag        => $task_cfg->{version} || 'latest',
	};
	if ($reg->{username}) {
		$img_src->{username} = $reg->{username};
		$img_src->{password} = _unwrap_ref($reg->{password});
	}

	my %params = (
		GENESIS_HONOR_ENV => 1,
		CI_NO_REDACT      => $config->{unredacted} || 0,
		CURRENT_ENV       => $env,
		WORKING_DIR       => 'out/git',
		OUT_DIR           => 'cache-out/git',
		GIT_BRANCH        => $sc->{default_branch} || $ast->branches->{Genesis::Top::CI_PIPELINE_CONTROL_KEY()} || 'main',
		GIT_AUTHOR_NAME   => ($sc->{commit_author} ? $sc->{commit_author}{name}  : undef)
			|| 'Concourse Bot',
		GIT_AUTHOR_EMAIL  => ($sc->{commit_author} ? $sc->{commit_author}{email} : undef)
			|| 'concourse@pipeline',
	);

	if ($trigger_from) {
		$params{PREVIOUS_ENV} = $trigger_from;
		$params{CACHE_DIR}    = 'out/git';
	}

	if ($sc->{auth}) {
		if (($sc->{auth}{type} || '') eq 'ssh-key') {
			$params{GIT_PRIVATE_KEY} = _unwrap_ref($sc->{auth}{private_key});
		} else {
			$params{GIT_USERNAME} = _unwrap_ref($sc->{auth}{username});
			$params{GIT_PASSWORD} = _unwrap_ref($sc->{auth}{password});
		}
	}
	$params{GIT_GENESIS_ROOT} = $root if $root ne '.';
	$params{DEBUG} = $config->{debug} if $config->{debug};

	return {
		platform       => 'linux',
		image_resource => { type => 'registry-image', source => $img_src },
		params         => \%params,
		run            => { path => "$bindir/.genesis/bin/genesis",
			args => ['ci-generate-cache'] },
		inputs         => [{ name => 'out' }, { name => $srcdir }],
		outputs        => [{ name => 'cache-out' }],
	};
}

# }}}
# _errand_config - errand task config {{{
sub _errand_config {
	my ($self, $ast, $env, $errand_name, $bindir, $srcdir) = @_;

	my $config = $ast->configuration || {};
	my $vault  = $ast->integrations->{vault} || {};
	my $sc     = $ast->integrations->{source_control} || {};
	my $root   = $sc->{root} || '.';

	my $task_cfg = $config->{task} || {};
	my $reg      = $config->{registry} || {};
	my $pfx      = $reg->{uri} ? "$reg->{uri}/" : '';

	my $img_src = {
		repository => "$pfx" . ($task_cfg->{image} || 'genesiscommunity/concourse'),
		tag        => $task_cfg->{version} || 'latest',
	};
	if ($reg->{username}) {
		$img_src->{username} = $reg->{username};
		$img_src->{password} = _unwrap_ref($reg->{password});
	}

	my %params = (
		GENESIS_HONOR_ENV => 1,
		CI_NO_REDACT      => $config->{unredacted} || 0,
		CURRENT_ENV       => $env,
		ERRAND_NAME       => $errand_name,
		VAULT_ADDR        => $vault->{url} || '',
	);
	if ($vault->{auth}) {
		$params{VAULT_ROLE_ID}   = _unwrap_ref($vault->{auth}{role_id});
		$params{VAULT_SECRET_ID} = _unwrap_ref($vault->{auth}{secret_id});
	}
	if ($vault->{options}) {
		$params{VAULT_SKIP_VERIFY}  = $vault->{options}{tls_verify} ? 'false' : 'true';
		$params{VAULT_NO_STRONGBOX} = '"true"' if $vault->{options}{no_strongbox};
	}
	$params{VAULT_NAMESPACE} = $vault->{namespace} if $vault->{namespace};
	$params{DEBUG} = $config->{debug} if $config->{debug};

	my $subdir = ($root eq '.') ? '' : "/$root";

	my @inputs = ({ name => 'out' }, { name => $srcdir });

	# Task library input for errands
	if (my $tl = $config->{task_library}) {
		if (ref($tl) eq 'HASH' && $tl->{uri}) {
			my $rn   = $tl->{resource_name} || 'tasks';
			my $path = $tl->{path}          || '';
			push @inputs, { name => $rn };
			$params{GENESIS_TASK_LIBRARY_PATH} = $path ? "$rn/$path" : $rn;
		}
	}

	return {
		platform       => 'linux',
		image_resource => { type => 'registry-image', source => $img_src },
		params         => \%params,
		run            => {
			path => "../../$bindir/.genesis/bin/genesis",
			dir  => "out/git$subdir",
			args => ['ci-pipeline-run-errand'],
		},
		inputs => \@inputs,
	};
}

# }}}
# _effective_notif_style - resolve the active notification style {{{
#
# Returns: 'per-env' | 'grouped' | 'minimal' | 'none'
# Sources: integrations.slack.style (new format), or legacy
# configuration.notifications.style mapped to per-env/grouped.
sub _effective_notif_style {
	my ($self, $ast) = @_;

	my $slack = $ast->integrations->{slack};
	return $slack->{style} || 'per-env' if $slack;

	# Legacy fallback: check notifications array + configuration style flag
	my $notifs = $ast->integrations->{notifications} || [];
	$notifs = [] unless ref($notifs) eq 'ARRAY';
	my ($sn) = grep { ref($_) eq 'HASH' && ($_->{type} || '') eq 'slack' } @$notifs;
	if ($sn) {
		my $old = ($ast->configuration || {})->{notifications}{style} || 'inline';
		return $old eq 'grouped' ? 'grouped' : 'per-env';
	}

	return 'none';
}

# }}}
# _resolve_slack_config - return effective Slack config for an env {{{
#
# Returns a merged hashref (global + per-env override) or undef when Slack
# is not configured or style is 'none'.
sub _resolve_slack_config {
	my ($self, $ast, $env) = @_;

	my $slack = $ast->integrations->{slack};

	# Legacy fallback: build from old notifications array
	unless ($slack) {
		my $notifs = $ast->integrations->{notifications} || [];
		$notifs = [] unless ref($notifs) eq 'ARRAY';
		my ($sn) = grep { ref($_) eq 'HASH' && ($_->{type} || '') eq 'slack' } @$notifs;
		return undef unless $sn;
		my $old = ($ast->configuration || {})->{notifications}{style} || 'inline';
		$slack = {
			webhook             => $sn->{webhook},
			channel             => $sn->{channel},
			username            => $sn->{username},
			icon_url            => $sn->{icon},
			style               => $old eq 'grouped' ? 'grouped' : 'per-env',
			mentions_on_failure => [],
			per_env_overrides   => {},
		};
	}

	return undef if ($slack->{style} || 'per-env') eq 'none';

	# Merge per-env override
	my %cfg = %$slack;
	if ($env) {
		my $override = ($slack->{per_env_overrides} || {})->{$env} || {};
		$cfg{$_} = $override->{$_} for keys %$override;
	}

	return \%cfg;
}

# }}}
# _notification_step - build notification plan step {{{
#
# opts: { env => '', is_failure => 0 }
# Returns { in_parallel => [...] } or undef.
sub _notification_step {
	my ($self, $ast, $message, $opts) = @_;
	$opts ||= {};
	my $env        = $opts->{env}        // '';
	my $is_failure = $opts->{is_failure} // 0;

	my $slack = $self->_resolve_slack_config($ast, $env);
	return undef unless $slack;

	my $text = $message;
	if ($is_failure && @{$slack->{mentions_on_failure} || []}) {
		$text = join(' ', @{$slack->{mentions_on_failure}}) . ': ' . $text;
	}

	my @steps = ({
		put    => 'slack',
		params => {
			channel  => $slack->{channel},
			username => $slack->{username} || 'runwaybot',
			icon_url => $slack->{icon_url} || $slack->{icon},
			text     => $text,
		},
	});

	return { in_parallel => \@steps };
}

# }}}
# }}}
### Internal Helpers {{{

# _extract_workflow_data - extract unified data from any workflow type {{{
sub _extract_workflow_data {
	my ($self, $ast, $workflow) = @_;

	my $graph = $workflow->{graph} || {};
	my $nodes = $graph->{nodes} || {};
	my $edges = $graph->{edges} || [];

	my (%will_trigger, %triggers, %auto, %aliases, %genesis_envs,
	    %redeploy, %redeploy_cron_start, %redeploy_cron_stop,
	    %status_signal, %signal_prefix,
	    %bosh_parent, %bosh_upgrade_lock, %is_bosh_director);

	for my $edge (@$edges) {
		push @{$will_trigger{$edge->{from}}}, $edge->{to};
		$triggers{$edge->{to}} = $edge->{from};
	}
	for my $n (keys %$nodes) {
		my $nd = $nodes->{$n};
		$auto{$n}                = 1 if $nd->{auto};
		$aliases{$n}             = $nd->{alias}               || $n;
		$genesis_envs{$n}        = $nd->{genesis_env}         || $n;
		$redeploy{$n}            = $nd->{redeploy}            || '';
		$redeploy_cron_start{$n} = $nd->{redeploy_cron_start} || '';
		$redeploy_cron_stop{$n}  = $nd->{redeploy_cron_stop}  || '';
		$status_signal{$n}       = $nd->{status_signal}       // '';
		$signal_prefix{$n}       = $nd->{signal_prefix}       || '';
		$bosh_parent{$n}         = $nd->{bosh_parent}         || '';
		$bosh_upgrade_lock{$n}   = $nd->{bosh_upgrade_lock}   // 1;
	}
	# Derive which envs are pipeline BOSH directors (referenced as bosh_parent)
	for my $n (keys %bosh_parent) {
		my $parent = $bosh_parent{$n};
		$is_bosh_director{$parent} = 1 if $parent;
	}

	if ($workflow->{_legacy}) {
		my $leg = $workflow->{_legacy};
		%auto         = map { $_ => 1 } @{$leg->{auto_envs} || []};
		%aliases      = %{$leg->{aliases}      || \%aliases};
		%genesis_envs = %{$leg->{genesis_envs} || \%genesis_envs};
		%will_trigger = %{$leg->{will_trigger} || \%will_trigger};
		%triggers     = ref($leg->{triggers}) eq 'HASH'
			? %{$leg->{triggers}} : %triggers;
	}

	return {
		environments        => (@$edges ? [_topological_sort($graph)] : [sort keys %$nodes]),
		auto                => \%auto,
		aliases             => \%aliases,
		genesis_envs        => \%genesis_envs,
		will_trigger        => \%will_trigger,
		triggers            => \%triggers,
		redeploy            => \%redeploy,
		redeploy_cron_start => \%redeploy_cron_start,
		redeploy_cron_stop  => \%redeploy_cron_stop,
		status_signal       => \%status_signal,
		signal_prefix       => \%signal_prefix,
		bosh_parent         => \%bosh_parent,
		bosh_upgrade_lock   => \%bosh_upgrade_lock,
		is_bosh_director    => \%is_bosh_director,
	};
}

# }}}
# _git_uri - build git URI from source_control config {{{
sub _git_uri {
	my ($self, $source_control) = @_;

	my $provider = $source_control->{provider} || '';
	my $repo     = $source_control->{repository} || '';

	if ($provider eq 'github') {
		return sprintf("git\@github.com:%s.git", $repo);
	} elsif ($provider eq 'gitlab') {
		return sprintf("git\@gitlab.com:%s.git", $repo);
	} elsif ($source_control->{uri}) {
		return $source_control->{uri};
	} else {
		return $repo;
	}
}

# }}}
# _unwrap_ref - unwrap secret_ref hash or return scalar {{{
sub _unwrap_ref {
	my ($value) = @_;
	return undef unless defined $value;
	if (ref($value) eq 'HASH' && exists $value->{secret_ref}) {
		return "(($value->{secret_ref}))";
	}
	return $value;
}

# }}}
# _is_create_env - check if target is a create-env deployment {{{
sub _is_create_env {
	my ($self, $ast, $env) = @_;
	my $target = $ast->targets->{$env} || {};
	return 1 if ($target->{type} || '') eq 'bosh-create-env';
	return 1 if grep { $_ eq 'create-env' } @{$target->{tags} || []};
	return 0;
}

# }}}
# _env_file_patterns - compute potential environment files {{{
sub _env_file_patterns {
	my ($env_name) = @_;
	my @parts = split /-/, $env_name;
	my @patterns;
	my $prefix = '';
	for my $part (@parts) {
		$prefix .= ($prefix ? '-' : '') . $part;
		push @patterns, "$prefix.yml";
	}
	return @patterns;
}

# }}}
# _unique_env_files - files unique to env (not shared with predecessor) {{{
sub _unique_env_files {
	my ($env, $trigger_from) = @_;
	my @ep = split /-/, $env;
	my @tp = split /-/, $trigger_from;

	my $common = 0;
	for my $i (0 .. $#tp) {
		last if $i > $#ep || $tp[$i] ne $ep[$i];
		$common++;
	}

	my @unique;
	my $prefix = '';
	for my $i (0 .. $#ep) {
		$prefix .= ($prefix ? '-' : '') . $ep[$i];
		push @unique, "$prefix.yml" if $i >= $common;
	}
	return @unique;
}

# }}}
# _shared_env_files - files shared between env and its predecessor {{{
sub _shared_env_files {
	my ($env, $trigger_from) = @_;
	my @ep = split /-/, $env;
	my @tp = split /-/, $trigger_from;

	my @shared;
	my $prefix = '';
	for my $i (0 .. $#tp) {
		last if $i > $#ep || $tp[$i] ne $ep[$i];
		$prefix .= ($prefix ? '-' : '') . $tp[$i];
		push @shared, "$prefix.yml";
	}
	return @shared;
}

# }}}
# _mermaid_id - sanitize a string for use as a Mermaid node identifier {{{
sub _mermaid_id {
	my ($name) = @_;
	(my $id = $name) =~ s/[^a-zA-Z0-9_]/_/g;
	return $id;
}

# }}}
# _mermaid_node_def - node reference with optional gate shape annotation {{{
sub _mermaid_node_def {
	my ($alias, $node, $is_director) = @_;
	$node ||= {};
	my $id = _mermaid_id($alias);

	my @labels;
	push @labels, 'DIRECTOR' if $is_director;
	push @labels, 'PR'       if $node->{require_pr};
	push @labels, 'MANUAL'   if $node->{manual};
	push @labels, 'REDEPLOY' if $node->{redeploy};

	return @labels
		? "$id([$alias\\n" . join('+', @labels) . "])"
		: $id;
}

# }}}
# _topological_sort - standard topological sort on a workflow graph {{{
sub _topological_sort {
	my ($graph) = @_;

	my @sorted;
	my %visited;
	my %temp_mark;

	my $visit;
	$visit = sub {
		my ($node) = @_;
		return if $visited{$node};
		bail("Cycle detected in workflow graph at node '%s'", $node)
			if $temp_mark{$node};
		$temp_mark{$node} = 1;
		for my $edge (@{$graph->{edges} || []}) {
			$visit->($edge->{to}) if $edge->{from} eq $node;
		}
		delete $temp_mark{$node};
		$visited{$node} = 1;
		unshift @sorted, $node;
	};

	for my $node (sort keys %{$graph->{nodes} || {}}) {
		$visit->($node) unless $visited{$node};
	}
	return @sorted;
}

# }}}
# }}}

1;

=head1 NAME

Genesis::CI::Compiler::PipelineDescriptor - Genesis-specific pipeline builder

=head1 DESCRIPTION

Genesis::CI::Compiler::PipelineDescriptor is the boundary between Genesis
domain logic and generic CI pipeline generation. It takes a Genesis CI
compiler AST (which contains Genesis-specific concepts like BOSH targets,
vault integrations, deployment workflows) and produces a fully-resolved
generic pipeline description with resource_types, resources, jobs, and groups.

This description is platform-agnostic and can be serialized by any CI
provider (Concourse, GitHub Actions, etc.) into platform-specific format.

All Genesis-specific knowledge lives here: deployment jobs, cache
generation, locker integration, auto-update, notification wiring, etc.

=head1 SYNOPSIS

  my $descriptor = Genesis::CI::Compiler::PipelineDescriptor->new(
    ast => $ast,
    top => $top_obj,
  );

  # Build the fully-resolved pipeline
  my $pipeline = $descriptor->describe();
  # $pipeline = {
  #   resource_types => [...],
  #   resources      => [...],
  #   jobs           => [...],
  #   groups         => [...],
  # }

  # Or get visualization/description
  my $mermaid = $descriptor->mermaid();      # raw flowchart LR block
  my $md      = $descriptor->pipeline_md(); # Markdown document with fenced block
  my $txt     = $descriptor->description();

=head1 SEE ALSO

Genesis::CI::Compiler::AST, Genesis::CI::Compiler::PipelineProvider

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
