output "environments" {
  description = "Each environment's Worker name and public URL, by environment name."
  value = {
    for name in keys(var.environments) : name => {
      worker = cloudflare_worker.web[name].name
      url    = local.urls[name]
    }
  }
}

output "previews" {
  description = "The previews' GitHub environment and the Worker they're previews of; null without previews."
  value = var.previews == null ? null : {
    environment = var.previews.environment
    worker      = cloudflare_worker.web[var.previews.worker_of].name
  }
}
