output "environments" {
  description = "Each environment's Worker name and public URL, by environment name."
  value = {
    for name in keys(var.environments) : name => {
      worker = cloudflare_worker.storybook[name].name
      url    = local.urls[name]
    }
  }
}
