package Genesis::CI::Compiler::PipelineDescriptor;
use strict;
use warnings;

use Genesis;
use Genesis::Exit qw/CONFIG/;
use Genesis::Top ();
use Genesis::CI::ProviderCompiler;
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
# The boundary from Genesis concepts to generic CI: returns
# { resource_types, resources, jobs, groups }.
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

	# Each deployment's _ran event, which propagate triggers on
	my @ran_names;

	# Whether there are redeploy jobs, and where they sit (D136).
	my $redeploy = $self->_redeploy_settings($ast);
	my @redeploy_job_names;

	# Process each workflow
	for my $wf_name (sort $ast->workflow_names) {
		my $workflow = $ast->workflows->{$wf_name};
		my $wf_data  = $self->_extract_workflow_data($ast, $workflow);

		# Error early if bosh-upgrade locks are needed but locker is not configured.
		my $locker = $ast->integrations->{locker} || {};
		for my $env (@{$wf_data->{environments}}) {
			my $parent = $wf_data->{bosh_parent}{$env} || '';
			next unless $parent && ($wf_data->{bosh_upgrade_lock}{$env} // 1);
			bail({exitcode => CONFIG},
				"Environment '%s' has a pipeline-managed BOSH director ('%s') but no ".
				"locker is configured.  Its deploy takes the director's lock, so add a ".
				"#C{pipeline.locker} block with its #C{url} to .genesis/config.",
				$env, $parent
			) unless $locker->{url};
		}

		my @wf_job_names;
		my @notify_job_names;
		for my $env (@{$wf_data->{environments}}) {
			my $alias         = $wf_data->{aliases}{$env} || $env;
			my $is_auto       = $wf_data->{auto}{$env};
			my $trigger_from  = $wf_data->{triggers}{$env};
			my $is_create_env = $self->_is_create_env($ast, $env);

			push @resources, @{$self->_env_resources(
				$ast, $env, $alias, $trigger_from, $is_create_env, $wf_data
			)};

			# Locker resources, one per pool however many jobs hold it
			if ($locker->{url}) {
				my %have = map {($_->{name} => 1)} @resources;
				push @resources, grep {!$have{$_->{name}}} @{$self->_locker_resources(
					$ast, $env, $alias, $deploy_type, $is_create_env, $wf_data
				)};
			}

			# Propagate wakes on every deploy, a tail's included: a deploy
			# releases its own gate or hold as well as a follower's (c5, D134).
			if (my $ran = $self->_ran_resource($ast, $wf_data->{deployment_name}{$env})) {
				push @resources, $ran;
				push @ran_names, $ran->{name};
			}
			# The redeploy's event, which propagation never reads, and its
			# request queue (contract a7, a8; D127), where redeploys are on (D136).
			if ($redeploy->{enabled}) {
				if (my $redone = $self->_redeployed_resource($ast, $wf_data->{deployment_name}{$env})) {
					push @resources, $redone;
				}
				if (my $run = $self->_run_resource($ast, $wf_data->{deployment_name}{$env})) {
					push @resources, $run;
				}
			}

			# Signal resource
			my $signal_cfg = $self->_env_signal_config($ast, $env, $wf_data);
			if ($signal_cfg) {
				push @resources, $self->_signal_resource(
					$ast, $env, $alias, $signal_cfg
				);
			}

			my $notif_style_env = $self->notification_style($ast);
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

			# One redeploy job per environment, beside its deploy, manual until
			# Stage 6 gives it its triggers (contract b3, 2026-10-28; Q44), or
			# none where pipeline.redeploy.enabled is false (b9, D136).
			if ($redeploy->{enabled}) {
				my $rj = $self->_redeploy_job(
					$ast, $env, $alias, $deploy_type, $wf_data
				);
				push @jobs, $rj;
				push @redeploy_job_names, $rj->{name};
				push @wf_job_names, $rj->{name} unless $redeploy->{grouped};
			}
		}

		# Each director's config checks, heard by a notify job of its own that
		# no deploy or redeploy shares (D146, contract a16, c10).
		my ($bc_resources, $bc_jobs, $bc_envs) = $self->_bosh_config_checks($ast, $wf_data);
		my %have_resource = map {($_->{name} => 1)} @resources;
		my %have_job      = map {($_->{name} => 1)} @jobs;
		push @resources, grep {!$have_resource{$_->{name}}} @$bc_resources;
		for my $job (grep {!$have_job{$_->{name}}} @$bc_jobs) {
			push @jobs, $job;
			push @wf_job_names, $job->{name};
			push @notify_job_names, $job->{name};
		}

		# Auto-update resources and job
		my $auto_update = $config->{auto_update};
		if ($auto_update && $auto_update->{enabled}) {
			push @resources, @{$self->_auto_update_resources($ast)};
			push @jobs, $self->_auto_update_job($ast);
		}

		# Groups
		my $group_notifications = $self->notification_style($ast) eq 'grouped';
		my $custom_groups = $config->{groups};

		if (ref($custom_groups) eq 'HASH') {
			my @grouped_notifications;
			for my $group_name (sort keys %$custom_groups) {
				my @group_jobs;
				for my $member (@{$custom_groups->{$group_name}}) {
					my $member_alias = $wf_data->{aliases}{$member} || $member;
					push @group_jobs, "deploy-$member_alias";
					push @group_jobs, "redeploy-$member_alias"
						if $redeploy->{enabled} && !$redeploy->{grouped};
					if (!$wf_data->{auto}{$member}) {
						my $notify_name = _notify_job_name($member_alias);
						if ($group_notifications) {
							push @grouped_notifications, $notify_name;
						} else {
							push @group_jobs, $notify_name;
						}
					}
				}
				# A director's config job goes with the environments on it.
				my %member = map {($_ => 1)} @{$custom_groups->{$group_name}};
				for my $bc (sort keys %$bc_envs) {
					next unless grep {$member{$_}} @{$bc_envs->{$bc}};
					push @{$group_notifications ? \@grouped_notifications : \@group_jobs}, $bc;
				}
				my %seen_job;
				@group_jobs = grep {!$seen_job{$_}++} @group_jobs;
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

		if ($auto_update && $auto_update->{enabled}) {
			push @groups, {
				name => 'genesis-updates',
				jobs => ['update-genesis-assets'],
			};
		}

	}

	# Every redeploy in one group, after the deployments' (b9, D136).
	push @groups, {name => 'redeploys', jobs => [sort @redeploy_job_names]}
		if $redeploy->{grouped} && @redeploy_job_names && @groups;

	# One propagate job per pipeline, on control, in its own group after the
	# deployments' where there are groups at all (contract b2, c4).
	push @resources, $self->_control_resource($ast);
	push @jobs, $self->_propagate_job($ast, \@ran_names);
	push @groups, {name => 'propagation', jobs => ['propagate']} if @groups;

	# The control-branch resource only where a job uses it, decided by
	# reference so it stays right as those jobs change.
	my $referenced = _referenced_resources(\@jobs);
	@resources = grep { $_->{name} ne 'git' || $referenced->{git} } @resources;

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
			push @{ $out_edges{$edge->{from}} }, $edge->{to};
			$in_any_edge{$edge->{from}} = 1;
			$in_any_edge{$edge->{to}}   = 1;
		}

		# Topological order gives a clean left-to-right layout
		my @order = @$edges
			? Genesis::CI::ProviderCompiler->topological_sort($graph)
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
			@order = Genesis::CI::ProviderCompiler->topological_sort($workflow->{graph});
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

			push @lines, sprintf("  %-20s deploy-%s  [%s]%s%s",
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

	my $config = $ast->configuration || {};

	my @types = map {{
		name   => $_->[0],
		type   => 'registry-image',
		source => $self->_image_source($ast, undef, $_->[1]),
	}} (
		['script',      'cfcommunity/script-resource'],
		['email',       'pcfseceng/email-resource'],
		['bosh-config', 'cfcommunity/bosh-config-resource'],
		['locker',      'cfcommunity/locker-resource'],
	);

	# slack-notification type only when Slack is configured and not suppressed
	if ($self->notification_style($ast) ne 'none') {
		my $has_slack = $ast->integrations->{slack}
			|| do {
				my $nn = $ast->integrations->{notifications} || [];
				scalar grep { ref($_) eq 'HASH' && ($_->{type}||'') eq 'slack' } @$nn;
			};
		if ($has_slack) {
			push @types, {
				name   => 'slack-notification',
				type   => 'registry-image',
				source => $self->_image_source($ast, undef, 'cfcommunity/slack-notification-resource'),
			};
		}
	}

	# The shuttle every _ran event and request queue rides (contract a18)
	if (my $shuttle = $ast->integrations->{shuttle}) {
		push @types, {
			name   => 'shuttle',
			type   => 'registry-image',
			source => $self->_image_source($ast, $shuttle->{image}, 'klaue/shuttle-resource',
				$shuttle->{image_tag} || 'latest'),
		};
	} elsif (my $signal = $config->{status_signal}) {
		my $img = ref $signal eq 'HASH' ? $signal->{image} : undef;
		my $tag = (ref $signal eq 'HASH' ? $signal->{image_tag} : undef)
			|| 'latest';
		push @types, {
			name   => 'shuttle',
			type   => 'registry-image',
			source => $self->_image_source($ast, $img, 'cfcommunity/shuttle-resource', $tag),
		};
	}

	return \@types;
}

# }}}
# _image_source - an image's registry-image source, through the registry (D137) {{{
sub _image_source {
	my ($self, $ast, $named, $default, $tag) = @_;
	my $registry = ($ast->configuration || {})->{registry} || {};
	my $uri      = $registry->{uri};
	my ($host)   = ($uri // '') =~ m{^([^/]+)};
	undef $named if defined $named && $named eq $default;

	my $repository = defined $named ? $named : $uri ? "$uri/$default" : $default;
	my $pulled_through = $uri && defined $registry->{username}
		&& (!defined $named || $named =~ m{^\Q$host\E/});
	return {
		repository => $repository,
		(defined $tag ? (tag => $tag) : ()),
		($pulled_through ? (
			username => _unwrap_ref($registry->{username}),
			password => _unwrap_ref($registry->{password}),
		) : ()),
	};
}

# }}}
# _worker_tags - the tags on a step that reaches an environment's network (D139, contract b5) {{{
sub _worker_tags {
	my ($self, $ast, $env, $wf_data) = @_;
	my $tags = ($wf_data->{worker_tags} || {})->{$env} || [];
	# A legacy ci.yml's tagged: true named each environment's workers after it.
	$tags = [$env] if !@$tags && ($ast->configuration || {})->{tagged};
	return @$tags ? (tags => [@$tags]) : ();
}

# }}}
# _job_public - whether a job's build log is public (D138, contract b4) {{{
sub _job_public {
	my ($self, $ast) = @_;
	return ($ast->configuration || {})->{public} ? JSON::PP::true : JSON::PP::false;
}

# }}}
# _task_image_source - the image every emitted task runs in (contract e8) {{{
sub _task_image_source {
	my ($self, $ast) = @_;
	my $task = ($ast->configuration || {})->{task} || {};
	return $self->_image_source($ast, $task->{image}, 'genesiscommunity/concourse',
		$task->{version} || 'latest');
}

# }}}
# _git_resource - build main git resource {{{
sub _git_resource {
	my ($self, $ast) = @_;

	my $sc     = $ast->integrations->{source_control} || {};
	my $uri    = Genesis::CI::ProviderCompiler->git_uri($sc);
	my $branch = $sc->{default_branch} || $ast->branches->{Genesis::Top::CI_PIPELINE_CONTROL_KEY()} || 'main';

	my $source = { uri => $uri, branch => $branch, _git_credential($sc) };
	$source->{version_depth} = $sc->{version_depth} if $sc->{version_depth};

	return { name => 'git', type => 'git', icon => 'github', source => $source };
}

# }}}
# _control_resource - the control branch propagate reads and triggers on {{{
sub _control_resource {
	my ($self, $ast) = @_;
	return { %{$self->_git_resource($ast)}, name => 'control-branch',
		$self->_git_checks($ast, 'control_check_every') };
}

# }}}
# branch_resource_name - the resource an environment's deployment branch is (contract a1, D144) {{{
sub branch_resource_name {
	my ($class, $alias) = @_;
	return "$alias-branch";
}

# }}}
# _check_request_params - what propagate needs to ask Concourse to check a branch (D144) {{{
sub _check_request_params {
	my ($self, $ast) = @_;
	my $config = $ast->configuration || {};
	return () unless ($config->{git} || {})->{webhooks};
	my $ci = $config->{concourse} || {};
	return (
		GENESIS_CONCOURSE_URL           => $ci->{url},
		GENESIS_CONCOURSE_TEAM          => $ci->{team},
		GENESIS_CONCOURSE_PIPELINE      => $ast->metadata->{name},
		GENESIS_CONCOURSE_WEBHOOK_TOKEN => _unwrap_ref({secret_ref => WEBHOOK_TOKEN_REF()}),
		($ci->{insecure} ? (GENESIS_CONCOURSE_INSECURE => 1) : ()),
	);
}

# }}}
# _git_checks - how a git resource learns its branch moved (D143) {{{
sub _git_checks {
	my ($self, $ast, $interval_key) = @_;
	my $git = ($ast->configuration || {})->{git} || {};
	return (
		(defined $git->{$interval_key} ? (check_every => $git->{$interval_key}) : ()),
		($git->{webhooks} ? (webhook_token => _unwrap_ref({secret_ref => WEBHOOK_TOKEN_REF()})) : ()),
	);
}

# }}}
# _ran_resource - a deployment's _ran event on the shuttle, or undef without one {{{
#
# The resource's own keys only (contract a8, a9); auth names the vault path
# holding both S3 credentials, under their own names.
sub _ran_resource {
	my ($self, $ast, $dn) = @_;
	return $self->_shuttle_resource($ast, $dn, 'deployed', "${dn}_deployed", 'bullhorn');
}

# _redeployed_resource - the deployment's redeploy event (contract a8, D127) {{{
sub _redeployed_resource {
	my ($self, $ast, $dn) = @_;
	return $self->_shuttle_resource($ast, $dn, 'redeployed', "${dn}_redeployed", 'bullhorn-outline');
}

# }}}
# _run_resource - the deployment's redeploy request queue (contract a7, D127) {{{
sub _run_resource {
	my ($self, $ast, $dn) = @_;
	return $self->_shuttle_resource($ast, $dn, 'redeploy', "redeploy_$dn", 'inbox-arrow-down');
}

# }}}
# _shuttle_resource - one stream on the configured shuttle (contract a9) {{{
sub _shuttle_resource {
	my ($self, $ast, $dn, $stream, $name, $icon) = @_;
	my $shuttle = $ast->integrations->{shuttle} or return;
	return unless $dn;
	my %source = (
		bucket       => $shuttle->{bucket},
		path         => "$dn/$stream",
		seed_version => JSON::PP::true,
		(map {defined $shuttle->{$_} ? ($_ => $shuttle->{$_}) : ()} qw/region endpoint/),
		($shuttle->{tls_skip_verify} ? (tls_skip_verify => JSON::PP::true) : ()),
		($shuttle->{auth} ? (map {($_ => _unwrap_ref({secret_ref => "$shuttle->{auth}:$_"}))}
			qw/access_key_id secret_access_key/) : ()),
	);
	return { name => $name, type => 'shuttle', icon => $icon, source => \%source };
}

# }}}

# }}}
# _propagate_job - the one job that runs genesis propagate {{{
sub _propagate_job {
	my ($self, $ast, $ran_names) = @_;

	# The pull requests the run opened or updated, sent whatever the run's
	# outcome; an empty summary sends nothing (D132, contract e4, e13, d11).
	my $pipeline_name = $ast->metadata->{name} || 'genesis-pipeline';
	my $notif = $self->_notification_step($ast,
		"$pipeline_name: Propagation opened pull requests for review:\n\$TEXT_FILE_CONTENT",
		{ text_file => SUMMARY_FILE(), kind => 'pull_request' });
	my $root = ($ast->integrations->{source_control} || {})->{root} || '.';
	my $up   = join('/', ('..') x (1 + ($root eq '.' ? 0 : scalar(grep {length} split m{/}, $root))));
	my $token = $self->_pull_request_token($ast);

	return {
		name   => 'propagate',
		public => $self->_job_public($ast),
		serial => JSON::PP::true,
		plan   => [
			{ get => 'control-branch', trigger => JSON::PP::true },
			(map {+{ get => $_, trigger => JSON::PP::true }} @{$ran_names || []}),
			{ task => 'propagate', config => $self->_task_config($ast, undef, undef, undef, {}, {
				input => 'control-branch',
				params => {
					($token ? (GITHUB_AUTH_TOKEN => $token) : ()),
					$self->_check_request_params($ast),
				},
				$notif
					? (cli_args => ['propagate', '--summary-file', "$up/".SUMMARY_FILE()],
					   outputs  => [{ name => SUMMARY_OUTPUT() }])
					: (cli_args => ['propagate']),
			}) },
		],
		($notif ? (ensure => $notif) : ()),
	};
}

# }}}
# _redeploy_settings - pipeline.redeploy, defaulted (D136, contract b9) {{{
sub _redeploy_settings {
	my ($self, $ast) = @_;
	my $block   = $ast->integrations->{redeploy} || {};
	my $enabled = $block->{enabled} // 1;
	# A string the loader would have refused, read as the loader reads it.
	$enabled = 0 if !ref($enabled) && $enabled =~ /^(?:false|no|off|0)$/i;
	return {
		enabled => $enabled ? 1 : 0,
		grouped => ($block->{style} // 'inline') eq 'grouped' ? 1 : 0,
	};
}

# }}}
# _pull_request_token - the token propagate opens pull requests with (f8) {{{
sub _pull_request_token {
	my ($self, $ast) = @_;
	my @pr = sort grep {$_} map {
		my $nodes = (($ast->workflows->{$_} || {})->{graph} || {})->{nodes} || {};
		map {$nodes->{$_}{require_pr} ? $_ : ()} keys %$nodes;
	} $ast->workflow_names;
	return undef unless @pr;

	my $sc = $ast->integrations->{source_control} || {};
	return _unwrap_ref($sc->{api_token}) if $sc->{api_token};
	my $auth = $sc->{auth}
		? Genesis::Top::credential_components(source_control => $sc->{auth}) : {};
	return _unwrap_ref($auth->{password}) if defined $auth->{password};

	bail({exitcode => CONFIG},
		"%s %s by pull request, which propagate opens with a GitHub token, and ".
		"the clone's credential is not one.  Set #C{pipeline.source_control.api_token} ".
		"in .genesis/config to the vault #C{path:key} of a token that can open ".
		"pull requests on the repository.",
		join(', ', map {"#C{$_}"} @pr), @pr == 1 ? 'delivers' : 'deliver');
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
	if ($self->notification_style($ast) ne 'none') {
		my $slack = $self->_resolve_slack_config($ast, undef);
		if ($slack) {
			push @resources, {
				name   => 'slack',
				type   => 'slack-notification',
				icon   => 'slack',
				source => { url => _unwrap_ref($slack->{webhook}) },
				# So a manual deploy's messages can name who started it (D135).
				expose_build_created_by => JSON::PP::true,
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
	my $uri  = Genesis::CI::ProviderCompiler->git_uri($sc);
	my $br   = $sc->{default_branch} || $ast->branches->{Genesis::Top::CI_PIPELINE_CONTROL_KEY()} || 'main';

	# Shared git source
	my %gs = (uri => $uri, branch => $br, _git_credential($sc));

	# The env branch is the change signal, and no deploy writes it: no filter.
	push @resources, {
		name => $self->branch_resource_name($alias), type => 'git', icon => 'github',
		source => {%gs, branch => $wf_data->{branches}{$env}},
		$self->_git_checks($ast, 'check_every'),
	};

	return \@resources;
}

# }}}
# _bosh_config_checks - each director's config checks and the job that hears them (D146, D148) {{{
#
# Returns (\@resources, \@jobs, \%envs), %envs naming each job's environments.
sub _bosh_config_checks {
	my ($self, $ast, $wf_data) = @_;

	my ($tracked, $tags) = $self->_tracked_by_director($ast, $wf_data);
	my %tracked = %$tracked;
	my %tags    = %$tags;

	my %icon = (cloud => 'cloud', runtime => 'run-fast', cpi => 'chip');
	my $pipeline_name = $ast->metadata->{name} || 'genesis-pipeline';
	my (@resources, @jobs, %envs);
	for my $director (sort keys %tracked) {
		my %by_tag = map {(join(',', @{$tags{$director}{$_}}) => 1)} keys %{$tags{$director}};
		bail({exitcode => CONFIG},
			"The BOSH configs of the #C{%s} director are checked from one worker, ".
			"and the environments tracking them name different ".
			"#C{genesis.pipeline.provider.tag}s: %s.  Give them the same tag.",
			$director, join(', ', map {
				"#C{$_} ".(join(', ', @{$tags{$director}{$_}}) || 'none')
			} sort keys %{$tags{$director}})
		) if keys %by_tag > 1;
		my @tags = @{(values %{$tags{$director}})[0]};
		my %to   = @tags ? (tags => [@tags]) : ();

		# The director's own credentials, published under one name (D148).
		my %ref = map {($_ => _unwrap_ref({secret_ref => "bosh/$director:$_"}))}
			qw/url ca_cert client client_secret/;
		my @types = grep {$tracked{$director}{$_}} qw/cloud runtime cpi/;
		my @names = map {"$director-bosh-$_-config"} @types;
		push @resources, map {+{
			name   => "$director-bosh-$_-config",
			type   => 'bosh-config',
			icon   => $icon{$_},
			%to,
			source => {
				target        => $ref{url},
				ca_cert       => $ref{ca_cert},
				client        => $ref{client},
				client_secret => $ref{client_secret},
				config        => $_,
				all           => JSON::PP::true,
			},
		}} @types;

		my $notif = $self->_notification_step($ast,
			"$pipeline_name: A BOSH config on the $director director changed; see "._build_link().
			" for which.\n".join('', map {
				"• $_ config: ".join(', ', sort @{$tracked{$director}{$_}})."\n"
			} @types).
			"Each environment renders against its director's configs, so redeploy those ".
			"under the one that changed to pick the change up.",
			{ kind => 'bosh_configs' });

		my $name = "notify-$director-bosh-configs";
		push @jobs, {
			name   => $name,
			public => $self->_job_public($ast),
			serial => JSON::PP::true,
			plan   => [
				{ in_parallel => [map {+{ get => $_, trigger => JSON::PP::true, %to }} @names] },
				($notif ? ($notif) : ()),
			],
		};
		my %on = map {map {($_ => 1)} @$_} values %{$tracked{$director}};
		$envs{$name} = [sort keys %on];
	}
	return (\@resources, \@jobs, \%envs);
}

# }}}
# _tracked_by_director - which environments track which of a director's configs {{{
#
# Returns (\%tracked, \%tags): director => type => [envs], and
# director => env => its worker tags.
sub _tracked_by_director {
	my ($self, $ast, $wf_data) = @_;
	my (%tracked, %tags);
	for my $env (@{$wf_data->{environments}}) {
		my $director = $wf_data->{bosh_env}{$env};
		next unless $director && !$self->_is_create_env($ast, $env);
		my $types = $self->_bosh_config_types($ast, $env, $wf_data);
		next unless @$types;
		push @{$tracked{$director}{$_}}, $env for @$types;
		my %to = $self->_worker_tags($ast, $env, $wf_data);
		$tags{$director}{$env} = $to{tags} || [];
	}
	return (\%tracked, \%tags);
}

# }}}
# tracked_directors - each director a check reads, with the environments tracking it (D149) {{{
sub tracked_directors {
	my ($self) = @_;
	my $ast = $self->{ast};
	my %envs;
	for my $wf_name ($ast->workflow_names) {
		my $wf_data = $self->_extract_workflow_data($ast, $ast->workflows->{$wf_name});
		my ($tracked) = $self->_tracked_by_director($ast, $wf_data);
		for my $director (keys %$tracked) {
			$envs{$director}{$_} = 1 for map {@$_} values %{$tracked->{$director}};
		}
	}
	return {map {($_ => [sort keys %{$envs{$_}}])} keys %envs};
}

# }}}
# _lock_pools - an environment's lock pools, director first, own last {{{
sub _lock_pools {
	my ($self, $env, $wf_data) = @_;
	my $director = $wf_data->{director_pool}{$env} // '';
	return (($director ? ([$director, 'dont-upgrade-bosh-on-me']) : ()),
		[$wf_data->{deployment_name}{$env}, 'i-need-to-deploy-myself']);
}

# }}}
# _locker_resources - one locker resource per pool an environment holds {{{
#
# Named <pool>-lock with lock_name <pool> (contract a10, a11, g8), so every
# job holding a pool shares one resource; describe drops the repeats.
sub _locker_resources {
	my ($self, $ast, $env, $alias, $deploy_type, $is_create_env, $wf_data) = @_;

	my $locker = $ast->integrations->{locker} || {};
	return [] unless $locker->{url};

	my %locker_source = (
		locker_uri          => _unwrap_ref($locker->{url}),
		username            => _unwrap_ref($locker->{username}),
		password            => _unwrap_ref($locker->{password}),
		skip_ssl_validation => $locker->{skip_ssl_validation} ? JSON::PP::true : JSON::PP::false,
		ca_cert             => $locker->{ca_cert},
	);

	return [map {+{
		name   => "$_->[0]-lock",
		type   => 'locker',
		icon   => 'shield-lock-outline',
		source => { %locker_source, lock_name => $_->[0] },
	}} $self->_lock_pools($env, $wf_data)];
}

# }}}
# _notify_job_name - notify-<env>, as deploy-<env> (contract b1, b8) {{{
sub _notify_job_name {
	my ($alias) = @_;
	return "notify-$alias";
}

# }}}
# _build_link, _job_link - Slack links from the build metadata (D122, T443) {{{
#
# The Slack resource expands Concourse's build metadata in its text, so the
# variables are written literally and become the posting build's own URL.
use constant JOBS_URL =>
	'$ATC_EXTERNAL_URL/teams/$BUILD_TEAM_NAME/pipelines/$BUILD_PIPELINE_NAME/jobs';
# The notify task's summary, an output of its own, as the staged put reads it.
use constant SUMMARY_OUTPUT => 'summary';
use constant SUMMARY_FILE   => 'summary/summary.txt';
use constant STARTED_BY     => ', started by $BUILD_CREATED_BY';
# The webhook token's reference, as path:key under the pipeline scope (D143, D145).
use constant WEBHOOK_TOKEN_REF => 'webhook:token';

# Each Slack message's kind, as the shortcode it begins with (D131).
our %NOTIFICATION_EMOJI = (
	staged       => ':inbox_tray:',
	not_offered  => ':no_entry:',
	success      => ':white_check_mark:',
	redeployed   => ':recycle:',
	failure      => ':x:',
	error        => ':warning:',
	abort        => ':black_square_for_stop:',
	pull_request => ':twisted_rightwards_arrows:',
	deploy_started   => ':rocket:',
	redeploy_started => ':arrows_counterclockwise:',
	bosh_configs     => ':gear:',
);
sub _build_link {
	return '<'.JOBS_URL.'/$BUILD_JOB_NAME/builds/$BUILD_NAME|$BUILD_JOB_NAME #$BUILD_NAME>';
}
sub _job_link {
	my ($job) = @_;
	return '<'.JOBS_URL."/$job|$job>";
}

# }}}
# _notify_job - notification job for non-auto environments {{{
sub _notify_job {
	my ($self, $ast, $env, $alias, $deploy_type, $trigger_from,
		$is_create_env, $wf_data) = @_;

	my $config = $ast->configuration || {};
	my %to     = $self->_worker_tags($ast, $env, $wf_data);
	my $name   = _notify_job_name($alias);

	# The branch the deploy reads is the only input and trigger (contract
	# c13); pending-changes says what deploying it would change (e12, D123),
	# and writes its summary to an output the staged message sends (D122).
	# The task runs from the root, so the output is reached back up from it.
	my $root     = ($ast->integrations->{source_control} || {})->{root} || '.';
	my $up       = join('/', ('..') x (1 + ($root eq '.' ? 0 : scalar(grep {length} split m{/}, $root))));
	my $task_cfg = $self->_task_config($ast, $env, $alias, $trigger_from, $wf_data, {
		cli_args => [$env, 'pending-changes', '--summary-file', "$up/".SUMMARY_FILE],
		outputs  => [{ name => SUMMARY_OUTPUT }],
	});

	my $pipeline_name = $ast->metadata->{name} || 'genesis-pipeline';
	my $notif = $self->_notification_step($ast,
		"$pipeline_name: Changes are staged to be deployed to $env-$deploy_type.\n".
		"\$TEXT_FILE_CONTENT\n".
		"See "._build_link()." for the change summary, then schedule and run a deploy via ".
		_job_link("deploy-$alias"),
		{ env => $env, text_file => SUMMARY_FILE, kind => 'staged' });

	my @plan = (
		{ in_parallel => [{ get => $self->branch_resource_name($alias), trigger => JSON::PP::true }] },
		{ task => 'show-pending-changes', %to, config => $task_cfg },
	);
	push @plan, $notif if $notif;

	# A version no one hears of cannot be deployed under inline, so say so,
	# and why: the preview writes its summary on a block and on an error
	# alike (D129).
	my $unknown = $self->_notification_step($ast,
		"$pipeline_name: Could not offer the changes staged for $env-$deploy_type for deploy.\n".
		"\$TEXT_FILE_CONTENT\nSee "._build_link(),
		{ env => $env, is_failure => 1, text_file => SUMMARY_FILE, kind => 'not_offered' });

	return {
		name   => $name,
		public => $self->_job_public($ast),
		serial => JSON::PP::true,
		plan   => \@plan,
		($unknown ? (on_failure => $unknown, on_error => $unknown) : ()),
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
	my %to         = $self->_worker_tags($ast, $env, $wf_data);
	my $name       = $ast->metadata->{name} || 'genesis-pipeline';
	my $trigger    = $is_auto ? JSON::PP::true : JSON::PP::false;
	my $passed     = $trigger_from ? $wf_data->{aliases}{$trigger_from} : '';
	my $passed_job = $passed ? "deploy-$passed" : '';
	my $pass_cache  = $config->{'require-passed-caches'};
	my $inline      = $self->notification_style($ast) eq 'per-env';

	my $srcdir = $pass_cache
		? ($trigger_from ? "$alias-cache" : "$alias-changes")
		: 'git';
	my $bindir = $srcdir;
	$bindir .= "/$root" if $root ne '.';

	# The env's branch is the only input and the only trigger: it carries the
	# env's files, and a tracked config change redeploys instead.
	my @gets;
	if ($is_auto || !$inline) {
		push @gets, { get => $self->branch_resource_name($alias), trigger => $trigger };
	} else {
		push @gets, { get => $self->branch_resource_name($alias), trigger => JSON::PP::false,
			passed => [_notify_job_name($alias)] };
	}

	# The predecessor's _deployed, read for nothing and triggering nothing;
	# passed is what has Concourse draw the line from its deploy (c14, c3).
	if ($trigger_from) {
		my $prev = $self->_ran_resource($ast, $wf_data->{deployment_name}{$trigger_from});
		push @gets, { get => $prev->{name}, trigger => JSON::PP::false,
			passed => [$passed_job] } if $prev;
	}

	# Task library (optional external git resource with custom task files)
	if (my $tl_get = $self->_task_library_get($ast)) {
		push @gets, $tl_get;
	}

	# Deploy task -- the same command an operator would run by hand.  No
	# commit-back: the deploy's own state lands in exodus.
	my $deploy_task = {
		task => 'bosh-deploy', %to,
		config => $self->_task_config($ast, $env, $alias, $trigger_from, $wf_data,
			{ cli_args => [$env, 'deploy', '-SFy'],
			  genesis_bindir => $bindir, genesis_srcdir => $srcdir }),
	};
	my @priv = @{$config->{task}{privileged} || []};
	$deploy_task->{privileged} = JSON::PP::true if grep { $_ eq $alias } @priv;

	my $dn = $wf_data->{deployment_name}{$env};
	my ($lock_steps, $unlock_steps) = $self->_lock_steps($ast, $env, $wf_data);
	my @lock_steps   = @$lock_steps;
	my @unlock_steps = @$unlock_steps;

	# Build do block
	my @do;
	push @do, @lock_steps;
	push @do, { in_parallel => \@gets };
	push @do, $self->_start_step($ast, $env, $deploy_type, 0, !$is_auto);
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

	# Cache generation and downstream cache fan-out belonged to the
	# copy-files-within-one-branch propagation model.  Branch propagation
	# replaces both; the cascade arrives in its own right later.

	my %hooks = $self->_outcome_hooks($ast, $env, $alias, $deploy_type, $wf_data, 0);
	my $plan_step = {};
	$plan_step->{$_} = $hooks{$_} for sort keys %hooks;
	$plan_step->{ensure} = { do => \@unlock_steps } if @unlock_steps;
	$plan_step->{do} = \@do;

	return {
		name   => "deploy-$alias",
		public => $self->_job_public($ast),
		serial => JSON::PP::true,
		($dn ? (serial_groups => [$dn]) : ()),
		plan   => [$plan_step],
	};
}

# }}}
# _start_step - a deploy's or a redeploy's start, announced (D135, d12) {{{
#
# A list of one step or of none, so a plan can splice it in where it goes.
# The try keeps a Slack failure from failing the job before it deploys.
sub _start_step {
	my ($self, $ast, $env, $deploy_type, $is_redeploy, $by_person) = @_;
	my $style = $self->notification_style($ast);
	return () if $style eq 'none' || $style eq 'minimal';

	my $name = $ast->metadata->{name} || 'genesis-pipeline';
	my $notif = $self->_notification_step($ast,
		sprintf("%s: Concourse started %s %s-%s (%s)%s", $name,
			$is_redeploy ? 'redeploying' : 'deploying', $env, $deploy_type, _build_link(),
			$by_person ? STARTED_BY : ''),
		{ env => $env, kind => $is_redeploy ? 'redeploy_started' : 'deploy_started' })
		or return ();
	return { try => $notif->{in_parallel}[0] };
}

# }}}
# _lock_steps - the locker puts a deploying job takes and gives back {{{
#
# Each pool in order, released in reverse (contract g4, g5), locked by the
# deployment's name, shared by deploy and redeploy (g1, g2).
sub _lock_steps {
	my ($self, $ast, $env, $wf_data) = @_;

	# Untagged: the locker lives beside Concourse, not in the environment's
	# network (D139).
	my (@lock, @unlock);
	my $locker = $ast->integrations->{locker} || {};
	my $dn     = $wf_data->{deployment_name}{$env};
	if ($locker->{url}) {
		for my $pool ($self->_lock_pools($env, $wf_data)) {
			my ($name, $key) = @$pool;
			push @lock, { put => "$name-lock",
				params => { lock_op => 'lock', key => $key, locked_by => $dn } };
			unshift @unlock, { put => "$name-lock",
				params => { lock_op => 'unlock', key => $key, locked_by => $dn } };
		}
	}
	return (\@lock, \@unlock);
}

# }}}
# _redeploy_job - the redeploy job for an environment, manual for now {{{
#
# Redeploys what the environment last deployed: `deploy --redeploy` reads the
# deployed commit from exodus and checks it out from the branch, which is
# the job's one input and never its trigger (contract b3, c11, e3).  It
# takes the deploy's locks and queue (g1, g2, g9), and its outcome hooks put
# _ran on success and never run_propagate (d3, d4).  Its triggers and the
# queue's hand-back are Stage 6 (Q44).
sub _redeploy_job {
	my ($self, $ast, $env, $alias, $deploy_type, $wf_data) = @_;

	my $config = $ast->configuration || {};
	my %to     = $self->_worker_tags($ast, $env, $wf_data);
	my $dn     = $wf_data->{deployment_name}{$env};

	# A request on its queue is its one trigger, where there is a shuttle to
	# carry it (contract c7).
	my $run  = $self->_run_resource($ast, $dn);
	my @gets = (
		($run ? ({ get => $run->{name}, trigger => JSON::PP::true }) : ()),
		{ get => $self->branch_resource_name($alias), trigger => JSON::PP::false },
	);
	if (my $tl_get = $self->_task_library_get($ast)) {
		push @gets, $tl_get;
	}

	my $task = {
		task => 'bosh-redeploy', %to,
		config => $self->_task_config($ast, $env, $alias, undef, $wf_data,
			{ cli_args => [$env, 'deploy', '--redeploy', '-SFy'] }),
	};
	my @priv = @{$config->{task}{privileged} || []};
	$task->{privileged} = JSON::PP::true if grep { $_ eq $alias } @priv;

	my ($lock_steps, $unlock_steps) = $self->_lock_steps($ast, $env, $wf_data);

	my %hooks = $self->_outcome_hooks($ast, $env, $alias, $deploy_type, $wf_data, 1);

	# The request is handed back, never put, so the job cannot re-trigger
	# itself: returned on success, returned failed otherwise (contract d5).
	# Concourse refuses two gets of one name in a job, so each hand-back
	# gets the queue under a name of its own.
	if ($run) {
		my %back = (
			on_success => ['returned', { return => JSON::PP::true }],
			on_failure => ['failed',   { return => JSON::PP::true, fail => JSON::PP::true }],
			on_error   => ['errored',  { return => JSON::PP::true, fail => JSON::PP::true }],
		);
		for my $hook (sort keys %back) {
			my ($as, $params) = @{$back{$hook}};
			my $step  = { get => "$run->{name}-$as", resource => $run->{name}, params => $params };
			my $have  = $hooks{$hook};
			my @steps = !$have ? ()
				: $have->{in_parallel} ? @{$have->{in_parallel}} : ($have);
			$hooks{$hook} = @steps ? { in_parallel => [@steps, $step] } : $step;
		}
	}

	my $plan_step = {};
	$plan_step->{$_} = $hooks{$_} for sort keys %hooks;
	$plan_step->{ensure} = { do => $unlock_steps } if @$unlock_steps;
	$plan_step->{do} = [@$lock_steps, { in_parallel => \@gets },
		$self->_start_step($ast, $env, $deploy_type, 1), $task];

	return {
		name   => "redeploy-$alias",
		public => $self->_job_public($ast),
		serial => JSON::PP::true,
		($dn ? (serial_groups => [$dn]) : ()),
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
	my $action    = $is_redeploy ? 'redeploy of'    : 'deployment to';
	my $ok_action = $is_redeploy ? 'redeployed'     : 'deployed';
	my $link = ' ('._build_link().')';
	# Only a person starts a manual deploy, so its messages can name them (D135).
	$link .= STARTED_BY if !$is_redeploy && !$wf_data->{auto}{$env};
	my %msg = (
		success => ["$name: Concourse successfully ${ok_action} $env-$deploy_type$link", 0],
		failure => ["$name: Concourse $action $env-$deploy_type failed$link", 1],
		error   => ["$name: Concourse $action $env-$deploy_type errored$link", 1],
		abort   => ["$name: Concourse $action $env-$deploy_type was aborted$link", 0],
	);

	my $signal_cfg  = $self->_env_signal_config($ast, $env, $wf_data);
	my $notif_style = $self->notification_style($ast);

	my %hooks;
	for my $outcome (qw(success failure abort error)) {
		my @steps;

		# Notifications: none for 'none'; 'minimal' keeps only those that mention
		my ($text, $is_failure) = @{$msg{$outcome}};
		if ($notif_style ne 'none' && ($is_failure || $notif_style ne 'minimal')) {
			my $kind = $outcome eq 'success' && $is_redeploy ? 'redeployed' : $outcome;
			my $notif = $self->_notification_step($ast, $text,
				{ env => $env, is_failure => $is_failure, kind => $kind });
			push @steps, @{$notif->{in_parallel}} if $notif;
		}

		# The deployment's event, named for the job that wrote it, on success
		# alone (contract d2, d3, d6; D127)
		my $dn = $wf_data->{deployment_name}{$env};
		if ($outcome eq 'success' && $dn && $ast->integrations->{shuttle}) {
			my $event = $is_redeploy ? "${dn}_redeployed" : "${dn}_deployed";
			push @steps, { put => $event, get_params => { skip => JSON::PP::true } };
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
# _auto_update_resources - build kit-release, genesis-release, and optional
# git-autoupdate resources based on the active auto_update flags {{{
sub _auto_update_resources {
	my ($self, $ast) = @_;

	my $config      = $ast->configuration || {};
	my $auto_update = $config->{auto_update} || {};
	my $sc          = $ast->integrations->{source_control} || {};
	my $period      = $auto_update->{period} || '24h';
	my $api_url     = $auto_update->{api_url};
	my $auth_token  = _unwrap_ref($auto_update->{auth_token} || '');

	my @resources;

	# kit-release: GitHub release feed for the configured kit
	if ($auto_update->{update_kit} // 1) {
		push @resources, {
			name        => 'kit-release',
			icon        => 'package-variant',
			type        => 'github-release',
			check_every => $period,
			source      => {
				user         => $auto_update->{org},
				repository   => "$auto_update->{kit}-genesis-kit",
				access_token => _unwrap_ref($auto_update->{kit_auth_token} || $auth_token),
				($api_url ? (github_api_url => $api_url) : ()),
			},
		};
	}

	# genesis-release: GitHub release feed for the genesis binary
	if ($auto_update->{update_genesis} // 1) {
		push @resources, {
			name        => 'genesis-release',
			type        => 'github-release',
			icon        => 'leaf',
			check_every => $period,
			source      => {
				user         => 'genesis-community',
				repository   => 'genesis',
				access_token => _unwrap_ref($auto_update->{genesis_auth_token} || $auth_token),
			},
		};
	}

	# git-autoupdate: separate push resource when target_branch differs from
	# the pipeline control branch (e.g., operator wants commits on a dedicated branch)
	my $control_branch = $sc->{default_branch}
		|| $ast->branches->{Genesis::Top::CI_PIPELINE_CONTROL_KEY()}
		|| 'main';
	my $target_branch = $auto_update->{target_branch} || '';
	if ($target_branch && $target_branch ne $control_branch) {
		my $uri = Genesis::CI::ProviderCompiler->git_uri($sc);
		my %source = (uri => $uri, branch => $target_branch, _git_credential($sc));
		push @resources, {
			name   => 'git-autoupdate',
			type   => 'git',
			icon   => 'source-branch',
			source => \%source,
		};
	}

	return \@resources;
}

# }}}
# _auto_update_job - build update-genesis-assets job {{{
#
# Emits three optional task steps, each guarded by a flag:
#   list-kits        a pre-flight check that the kit version is
#                    available (under update_kit)
#   update-genesis   embeds a newer genesis binary (under update_genesis)
#   fetch-kit        seds the kit version and commits it (under
#                    update_kit)
#
# The push target defaults to the pipeline control branch via 'git'.  When
# target_branch is set to a different branch, a dedicated 'git-autoupdate'
# resource (emitted by _auto_update_resources) is used for the put step.
sub _auto_update_job {
	my ($self, $ast) = @_;

	my $config         = $ast->configuration || {};
	my $sc             = $ast->integrations->{source_control} || {};
	my $root           = $sc->{root} || '.';
	my $auto_update    = $config->{auto_update} || {};
	my $update_kit     = $auto_update->{update_kit}     // 1;
	my $update_genesis = $auto_update->{update_genesis} // 1;

	my $img_src = $self->_task_image_source($ast);

	# Path helpers for repos rooted in a subdirectory
	my $git_genesis_dir     = 'git';
	my $genesis_config_path = '';
	my $path_prefix         = '';
	my $subdir_msg          = '';
	if ($root ne '.') {
		$git_genesis_dir     .= "/$root";
		$genesis_config_path  = " -C '$root'";
		$path_prefix          = "$root/";
		$subdir_msg           = " under $root";
	}
	my $pushd_cmd = ($root eq '.') ? '' : "pushd '$root' &> /dev/null\n";
	my $popd_cmd  = ($root eq '.') ? '' : "popd &> /dev/null\n";

	my $user_name  = ($sc->{commit_author} ? $sc->{commit_author}{name}  : undef)
		|| 'Concourse Bot';
	my $user_email = ($sc->{commit_author} ? $sc->{commit_author}{email} : undef)
		|| 'concourse@pipeline';
	my $ci_label   = $auto_update->{label} || $auto_update->{commit_label} || 'concourse';
	my $kit_name   = $auto_update->{kit}   || '';

	# Determine which git resource receives the auto-commit push
	my $control_branch = $sc->{default_branch}
		|| $ast->branches->{Genesis::Top::CI_PIPELINE_CONTROL_KEY()}
		|| 'main';
	my $target_branch = $auto_update->{target_branch} || '';
	my $push_resource = ($target_branch && $target_branch ne $control_branch)
		? 'git-autoupdate'
		: 'git';

	# -----------------------------------------------------------------------
	# in_parallel gets, which include only the resources that are enabled
	# kit-release and genesis-release both trigger when their flag is set.
	# -----------------------------------------------------------------------
	my @parallel_gets = ({ get => 'git' });
	push @parallel_gets, { get => 'kit-release',     trigger => JSON::PP::true }
		if $update_kit;
	push @parallel_gets, { get => 'genesis-release', trigger => JSON::PP::true }
		if $update_genesis;

	# -----------------------------------------------------------------------
	# list-kits, a pre-flight confirming the kit version is in the registry
	# -----------------------------------------------------------------------
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

	# -----------------------------------------------------------------------
	# update-genesis, which embeds a newer genesis binary where upstream
	# is ahead of the embedded one
	# -----------------------------------------------------------------------
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

	# -----------------------------------------------------------------------
	# fetch-kit, which reads the kit version from a GitHub release, seds
	# the version file, and commits it where it changed
	# -----------------------------------------------------------------------
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

	# -----------------------------------------------------------------------
	# Assemble the plan, taking in only the steps for enabled features
	# -----------------------------------------------------------------------
	my @plan = ({ in_parallel => \@parallel_gets });
	push @plan, $list_kits_task      if $update_kit;
	push @plan, $update_genesis_task if $update_genesis;
	push @plan, $fetch_kit_task      if $update_kit;
	push @plan, {
		put    => $push_resource,
		params => { repository => $push_resource, rebase => JSON::PP::true },
	};

	return {
		name   => 'update-genesis-assets',
		public => $self->_job_public($ast),
		serial => JSON::PP::true,
		plan   => \@plan,
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
	# Every task runs the root's embedded CLI, from the root, with the command
	# an operator would type; the retired ci-* commands have no caller.
	my $cli     = $opts->{cli_args};
	bug("_task_config was given no cli_args, so no command to run") unless $cli && @$cli;
	my $input   = $opts->{input} || $self->branch_resource_name($alias);

	my $img_src = $self->_task_image_source($ast);

	my %params = (
		# The pipeline running, not an operator: every pre-flight gate reads
		# it, and Service::BOSH keeps HTTPS_PROXY under it.
		GENESIS_PIPELINE_TASK => 1,
		# A task has no terminal, so Genesis would wrap at 80 (contract f10).
		GENESIS_OUTPUT_COLUMNS => 120,
		CI_NO_REDACT     => $config->{unredacted} || 0,
		GIT_AUTHOR_NAME  => ($sc->{commit_author} ? $sc->{commit_author}{name}  : undef)
			|| 'Concourse Bot',
		GIT_AUTHOR_EMAIL => ($sc->{commit_author} ? $sc->{commit_author}{email} : undef)
			|| 'concourse@pipeline',
		VAULT_ADDR       => $vault->{url} || '',
	);

	# Each component under the variable Service::Vault::Remote reads it from.
	if ($vault->{auth}) {
		my $auth = Genesis::Top::credential_components(vault => $vault->{auth});
		my %var  = (role_id => 'VAULT_ROLE_ID', secret_id => 'VAULT_SECRET_ID', token => 'VAULT_AUTH_TOKEN');
		$params{$var{$_}} = _unwrap_ref($auth->{$_}) for grep {$var{$_}} sort keys %$auth;
	}
	if ($vault->{options}) {
		$params{VAULT_SKIP_VERIFY}  = $vault->{options}{tls_verify} ? 'false' : 'true';
		$params{VAULT_NO_STRONGBOX} = '"true"' if $vault->{options}{no_strongbox};
	}
	$params{VAULT_NAMESPACE} = $vault->{namespace} if $vault->{namespace};

	if ($sc->{auth}) {
		my $auth = Genesis::Top::credential_components(source_control => $sc->{auth});
		if (defined $auth->{private_key}) {
			$params{GIT_PRIVATE_KEY} = _unwrap_ref($auth->{private_key});
		} else {
			$params{GIT_USERNAME} = _unwrap_ref($auth->{username});
			$params{GIT_PASSWORD} = _unwrap_ref($auth->{password});
		}
	}
	$params{DEBUG} = $config->{debug} if $config->{debug};
	%params = (%params, %{$opts->{params} || {}});

	# A task reads one branch, the env's own for a deploy and control for
	# propagate: its trigger and its source of record.
	my @inputs = ({ name => $input });

	# Task library input, which exposes the library files to the task
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
		run            => { path => '.genesis/bin/genesis', args => $cli,
		                    dir  => $input . ($root eq '.' ? '' : "/$root") },
		inputs         => \@inputs,
		($opts->{outputs} ? (outputs => $opts->{outputs}) : ()),
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

	my $img_src = $self->_task_image_source($ast);

	my %params = (
		GENESIS_PIPELINE_TASK => 1,
		GENESIS_OUTPUT_COLUMNS => 120,
		CI_NO_REDACT      => $config->{unredacted} || 0,
		CURRENT_ENV       => $env,
		ERRAND_NAME       => $errand_name,
		VAULT_ADDR        => $vault->{url} || '',
	);
	# Each component under the variable Service::Vault::Remote reads it from.
	if ($vault->{auth}) {
		my $auth = Genesis::Top::credential_components(vault => $vault->{auth});
		my %var  = (role_id => 'VAULT_ROLE_ID', secret_id => 'VAULT_SECRET_ID', token => 'VAULT_AUTH_TOKEN');
		$params{$var{$_}} = _unwrap_ref($auth->{$_}) for grep {$var{$_}} sort keys %$auth;
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
# notification_style - resolve the active notification style {{{
#
# Returns: 'per-env' | 'parallel' | 'grouped' | 'minimal' | 'none'
# Sources: integrations.slack.style (new format), or legacy
# configuration.notifications.style mapped to per-env/grouped.
#
# Published rather than private, because the Concourse compiler's
# description of a pipeline names the style and had been reaching in for
# it.  A reader that answers a question about the AST alone is fair for
# anyone holding a descriptor to ask.
sub notification_style {
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
# opts: { env => '', is_failure => 0, kind => '' }
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
	# A message's kind leads it, so a run of them reads at a glance (D131).
	$text = "$NOTIFICATION_EMOJI{$opts->{kind}} $text"
		if $opts->{kind} && $NOTIFICATION_EMOJI{$opts->{kind}};

	# An app's webhook fixes its channel, name and icon; only a legacy one
	# honours them, so each is sent only where written.
	# Silent keeps the resource's curl trace out of the log (d9, d10).
	my %params = (text => $text, silent => JSON::PP::true);
	$params{text_file} = $opts->{text_file} if $opts->{text_file};
	$params{channel}  = $slack->{channel}  if $slack->{channel};
	$params{username} = $slack->{username} if $slack->{username};
	my $icon = $slack->{icon_url} || $slack->{icon};
	$params{icon_url} = $icon if $icon;

	my @steps = ({ put => 'slack', params => \%params });

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

	my (%will_trigger, %triggers, %auto, %aliases, %genesis_envs, %branches,
	    %deployment_name, %director_pool,
	    %redeploy, %redeploy_cron_start, %redeploy_cron_stop,
	    %status_signal, %signal_prefix,
	    %bosh_parent, %bosh_upgrade_lock, %is_bosh_director,
	    %track_bosh_configs, %worker_tags, %bosh_env);

	for my $edge (@$edges) {
		push @{ $will_trigger{$edge->{from}} }, $edge->{to};
		$triggers{$edge->{to}} = $edge->{from};
	}
	for my $n (keys %$nodes) {
		my $nd = $nodes->{$n};
		$auto{$n}                = 1 if $nd->{auto};
		$aliases{$n}             = $nd->{alias}               || $n;
		$genesis_envs{$n}        = $nd->{genesis_env}         || $n;
		$branches{$n}            = $nd->{branch};
		$deployment_name{$n}     = $nd->{deployment_name};
		$director_pool{$n}       = $nd->{director_pool} // '';
		$redeploy{$n}          = $nd->{redeploy}            || '';
		$redeploy_cron_start{$n} = $nd->{redeploy_cron_start} || '';
		$redeploy_cron_stop{$n}  = $nd->{redeploy_cron_stop}  || '';
		$status_signal{$n}       = $nd->{status_signal}       // '';
		$signal_prefix{$n}       = $nd->{signal_prefix}       || '';
		$bosh_parent{$n}         = $nd->{bosh_parent}         || '';
		$bosh_upgrade_lock{$n}   = $nd->{bosh_upgrade_lock}   // 1;
		$track_bosh_configs{$n}  = $nd->{track_bosh_configs}
			if defined $nd->{track_bosh_configs};
		$worker_tags{$n}         = $nd->{worker_tags} || [];
		# The environment is its own director unless it names one, as in Env.
		$bosh_env{$n}            = exists $nd->{bosh_env} ? $nd->{bosh_env} : $genesis_envs{$n};
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
		environments        => (@$edges
			? [Genesis::CI::ProviderCompiler->topological_sort($graph)]
			: [sort keys %$nodes]),
		auto                => \%auto,
		aliases             => \%aliases,
		genesis_envs        => \%genesis_envs,
		branches            => \%branches,
		deployment_name     => \%deployment_name,
		director_pool       => \%director_pool,
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
		track_bosh_configs  => \%track_bosh_configs,
		worker_tags         => \%worker_tags,
		bosh_env            => \%bosh_env,
	};
}

# }}}
# _referenced_resources - resource names any job actually uses {{{
#
# Walks job plans for get/put steps and task inputs.  Steps nest
# arbitrarily (do, in_parallel, try, ensure, on_success and friends), so
# the walk is structural rather than keyed on known step types.
sub _referenced_resources {
	my ($node, $seen) = @_;
	$seen ||= {};

	if (ref($node) eq 'ARRAY') {
		_referenced_resources($_, $seen) for @$node;
	} elsif (ref($node) eq 'HASH') {
		$seen->{$node->{get}} = 1 if defined $node->{get} && !ref $node->{get};
		$seen->{$node->{put}} = 1 if defined $node->{put} && !ref $node->{put};
		$seen->{$_->{name}} = 1
			for grep { ref eq 'HASH' && defined $_->{name} }
				@{ $node->{inputs} || [] };
		_referenced_resources($node->{$_}, $seen)
			for grep { ref $node->{$_} } keys %$node;
	}

	return $seen;
}

# }}}
# _normalize_bosh_config_types - coerce track_bosh_configs to a list of types {{{
#
# Accepts: undef/false/""/0 → []
#          true/yes/1       → [cloud, runtime]
#          [cloud,runtime,cpi] (arrayref) → filtered list
#          "cloud,runtime"  (comma string) → split and filtered
sub _normalize_bosh_config_types {
	my ($val) = @_;
	return [] unless defined $val && $val ne '';
	if (ref($val) eq 'ARRAY') {
		return [grep { /^(?:cloud|runtime|cpi)$/ } @$val];
	}
	my $s = lc("$val");
	return []                   if $s =~ /^(?:false|no|0)$/;
	return ['cloud', 'runtime'] if $s =~ /^(?:true|yes|1)$/;
	my @types = split /[\s,]+/, $s;
	return [grep { /^(?:cloud|runtime|cpi)$/ } @types];
}

# }}}
# _bosh_config_types - resolve track_bosh_configs for an env (per-env then global) {{{
sub _bosh_config_types {
	my ($self, $ast, $env, $wf_data) = @_;
	my $track = $wf_data->{track_bosh_configs} || {};
	my $val = exists $track->{$env}
		? $track->{$env}
		: ($ast->configuration || {})->{track_bosh_configs};
	return _normalize_bosh_config_types($val);
}

# }}}
# _git_credential - a git resource's credential keys, from the source-control block {{{
sub _git_credential {
	my ($sc) = @_;
	my $auth = Genesis::Top::credential_components(source_control => $sc->{auth});
	return map {($_ => _unwrap_ref($auth->{$_}))}
		grep {defined $auth->{$_}} qw/private_key username password/;
}

# }}}
# _unwrap_ref - unwrap secret_ref hash or return scalar {{{
sub _unwrap_ref {
	my ($value) = @_;
	return undef unless defined $value;
	# How a reference is spelled is the compiler base's to say, because a
	# provider that spells one differently overrides it there.  What is
	# this file's is that a value which is not a reference is written as
	# it stands, a locker URL being a URL rather than a secret.
	return Genesis::CI::ProviderCompiler->secret_ref($value)
		if ref($value) eq 'HASH' && exists $value->{secret_ref};
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

What is not Genesis-specific comes off L<Genesis::CI::ProviderCompiler>,
which is where the clone URI of a source control declaration, the order a
workflow graph is walked in, and the spelling of a secret reference are
settled. This file asks that class for each of them rather than keeping
its own answer, so a provider that spells one of them differently
overrides it in one place and is obeyed here.

Each environment's deploy job is named C<deploy-E<lt>aliasE<gt>>, and its
redeploy job C<redeploy-E<lt>aliasE<gt>>, the alias defaulting to the
environment's name (plumbing contract rows b1 and b3).  One C<propagate>
job per pipeline runs C<genesis propagate> on the C<control-branch>
resource, which triggers it (b2, c4).

Each deploy holds two locker pools, its director's then its own, as the
first steps of its plan, and releases them in reverse in its C<ensure>
(D22).  Its own pool is its deployment name, C<E<lt>envE<gt>-E<lt>typeE<gt>>, held
with C<i-need-to-deploy-myself>, and its director's is
C<E<lt>bosh_envE<gt>-bosh>, held with C<dont-upgrade-bosh-on-me>, and absent for
a create-env environment.  ASTBuilder names both from the environment,
loaded from control with its kit: C<Env::use_create_env> and
C<Env::bosh_env> (D22, noted 2026-10-19).  Every pool is one C<E<lt>poolE<gt>-lock> resource, however many
jobs hold it, and the deploy is in C<serial_groups: [E<lt>dnE<gt>]>.

Where C<pipeline.shuttle> is set, each deployment has two events named for
the job that writes them (D127), C<E<lt>dnE<gt>_deployed> on the path
C<E<lt>dnE<gt>/deployed> and C<E<lt>dnE<gt>_redeployed> on
C<E<lt>dnE<gt>/redeployed>, and the redeploy's request queue
C<redeploy_E<lt>dnE<gt>> on C<E<lt>dnE<gt>/redeploy>, each a C<shuttle> resource
with C<seed_version>.  The deploy puts C<_deployed> and the redeploy
C<_redeployed>, on success alone, with no params; the propagate job triggers
on the C<_deployed> of every deployment, a tail's included, since a deploy
releases its own gate or hold as well as a follower's (D134), and never on a
C<_redeployed>, a redeploy delivering nothing (D23, D25, D75, D127).  A
deploy whose environment names a C<prior_env> gets that deployment's
C<_deployed> without triggering, C<passed> its deploy, which is what has
Concourse draw the chain; a seeded version never passed it, so the deploy
waits until its predecessor has deployed through the pipeline once
(contract c14, revised 2026-10-30).  Propagate's get of it carries no
C<passed>, since it triggers and a new pipeline's propagate would wait on a
deploy only it can feed.  The redeploy triggers on its queue and hands each request back in its outcome
hooks.  C<auth> names the vault path holding the S3 C<access_key_id> and
C<secret_access_key>.

Where C<pipeline.notifications.slack> is set, every Slack message begins with
the shortcode C<%NOTIFICATION_EMOJI> gives its kind, ahead of the mentions
(D131); a deploy and a redeploy announce their start from inside their own
plans, after their locks and gets and just before their task, through
C<_start_step>, in a C<try> so a Slack failure cannot stop the deploy (D135,
contract d12); and the propagate task writes the pull requests it opened or updated
to its C<summary> output with C<--summary-file>, which the job sends from its
C<ensure>; the Slack resource sends nothing for an empty summary (D132,
contract e4, e13, d11).

C<pipeline.redeploy> governs the redeploy jobs, through
C<_redeploy_settings> (D136, contract b9): C<enabled>, true by default, emits
each environment's C<redeploy-E<lt>envE<gt>> job, queue and event, and false
emits none of them; C<style: grouped> lists every redeploy job in one
C<redeploys> group after the deployments' groups and before C<propagation>,
where C<inline>, the default, leaves each beside its deploy.

Every job's C<public> comes from C<pipeline.provider.public>, false unless
set, through C<_job_public> (D138, contract b4).

C<pipeline.provider.git> sets, through C<_git_checks>, how C<control-branch> and
each deployment branch's resource learn their branch moved (D143):
C<webhooks> puts C<webhook_token: ((webhook.token))> on all of them, the
reference C<WEBHOOK_TOKEN_REF> names, and C<control_check_every> and
C<check_every> their polling intervals apart.  A deployment branch's resource is
named by C<branch_resource_name>, which propagate reads too (D144).

An environment's C<genesis.pipeline.provider.tag> goes, through
C<_worker_tags>, on the steps that reach its network alone: the task of its
deploy, redeploy and notify jobs, its errands, and its BOSH-config check
(D139, contract b5).  Lock puts, shuttle and Slack puts, branch gets and
C<propagate> carry none, those services sitting beside Concourse.  A legacy
C<ci.yml>'s C<tagged: true> gives each environment its own name as the tag,
placed the same way.

A director's configs are checked once per director and config type, through
C<_bosh_config_checks> (D146, contract a16, c10): a C<bosh-config> resource
C<E<lt>bosh_envE<gt>-bosh-E<lt>typeE<gt>-config> with C<all: true>, for each
type an environment on the director names in C<track_bosh_configs>, the
director being the node's C<bosh_env> or the environment itself, and none for a
create-env environment. Its source reads the director with the references
C<((bosh/E<lt>bosh_envE<gt>.url))>, C<.ca_cert>, C<.client> and
C<.client_secret>, which the director's owner publishes and the apply's secret
check verifies (D148). One job per director, C<notify-E<lt>bosh_envE<gt>-bosh-configs>,
gets its checks with C<trigger: true> and sends one Slack message of kind
C<bosh_configs> naming the director, each type with the environments on it,
and the build, whose inputs show which changed; without Slack it only gets.
No deploy or redeploy gets a check. The environments tracking a director must
agree on their worker tag, which goes on its resources and the job's gets, and
the compile refuses at C<CONFIG> where they do not, naming each environment and
its tag. The job is grouped as an environment's notify job is, and under
custom groups goes in each group holding an environment on its director.
C<tracked_directors> answers each such director with the environments tracking
it, which C<pipeline-apply> reads to copy each director's credentials from its
exodus record (D149).

Where C<pipeline.registry> is set, every image the compiler names by default,
each resource type, the default task image and the default shuttle image, is
pulled through its C<uri>, and each such source carries the registry's
C<username> and C<password> references, through C<_image_source> (D137,
contract a18, e8).  An image the operator names, C<task.image> or
C<shuttle.image>, is taken as written, and carries the credentials only when
its repository begins with the registry's host; one equal to the compiler's
default counts as the default, since the schema fills the default in.  A
legacy C<ci.yml> named its task image relative to the registry, so
ASTBuilder prefixes it there and the rule above then finds it under the host.

Where an environment sets C<require_pr>, the propagate task carries
C<GITHUB_AUTH_TOKEN> from C<pipeline.source_control.api_token>, else from an
C<https> clone credential's password; with an C<ssh> credential and no
C<api_token> the compile is refused at C<CONFIG>, naming the key and the
environments (contract f8).

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

Genesis::CI::Compiler::AST, Genesis::CI::ProviderCompiler

=cut

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
