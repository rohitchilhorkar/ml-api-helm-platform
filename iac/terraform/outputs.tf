output "release_name" {
  value = helm_release.ml_api.name
}

output "release_status" {
  value = helm_release.ml_api.status
}

output "release_namespace" {
  value = helm_release.ml_api.namespace
}
