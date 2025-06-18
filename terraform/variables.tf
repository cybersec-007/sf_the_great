
variable "cloud_id" {
  type        = string
  description = "Yandex Cloud ID"
}
variable "folder_id" {
  type        = string
  description = "Yandex Cloud Folder ID"
}
variable "yc_token" {
  type        = string
  description = "OAuth or IAM token for YC"
}
variable "public_key_path" {
  type        = string
  description = "Path to public SSH key"
  default     = "~/.ssh/id_rsa.pub"
}
