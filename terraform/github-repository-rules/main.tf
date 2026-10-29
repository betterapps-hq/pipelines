# The default branch takes changes only through pull requests: squashed, with every review thread resolved and the
# required checks passing, but no approvals, since GitHub doesn't let authors approve their own. Nobody force-pushes
# to it or deletes it, and nobody bypasses any of that unless bypass_actors says so.
resource "github_repository_ruleset" "default_branch" {
  repository  = var.repository
  name        = var.branch_ruleset_name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  dynamic "bypass_actors" {
    for_each = var.bypass_actors
    content {
      actor_type  = bypass_actors.value.actor_type
      actor_id    = bypass_actors.value.actor_id
      bypass_mode = bypass_actors.value.bypass_mode
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      required_approving_review_count   = 0
      required_review_thread_resolution = true
      allowed_merge_methods             = ["squash"]
      dismiss_stale_reviews_on_push     = false
      require_code_owner_review         = false
      require_last_push_approval        = false
    }

    # GitHub takes no empty list of checks, so the rule is left out when there are none.
    dynamic "required_status_checks" {
      for_each = length(var.required_checks) > 0 ? [var.required_checks] : []
      content {
        strict_required_status_checks_policy = false
        do_not_enforce_on_create             = false

        dynamic "required_check" {
          for_each = toset(required_status_checks.value)
          content {
            context = required_check.value
          }
        }
      }
    }
  }
}

# Release tags can be pushed, but once they are, nobody moves or deletes them, so a commit SHA a caller pinned to a
# version always means that version. There's no bypass.
resource "github_repository_ruleset" "release_tags" {
  count       = var.release_tag_pattern == null ? 0 : 1
  repository  = var.repository
  name        = var.tag_ruleset_name
  target      = "tag"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["refs/tags/${var.release_tag_pattern}"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    update           = true
    non_fast_forward = true
  }
}
