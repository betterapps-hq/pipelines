output "default_branch_ruleset_id" {
  description = "The default branch's ruleset's ID."
  value       = github_repository_ruleset.default_branch.ruleset_id
}

output "release_tags_ruleset_id" {
  description = "The release tags' ruleset's ID, or null when release_tag_pattern is null."
  value       = one(github_repository_ruleset.release_tags[*].ruleset_id)
}
