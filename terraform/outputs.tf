
output "instance_ips" {
  value = { for k, v in yandex_compute_instance.nodes : k => v.network_interface.0.nat_ip_address }
}
