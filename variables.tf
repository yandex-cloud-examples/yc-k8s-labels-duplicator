variable "folder_id" {
  description = "Folder id for k8s-labels-duplicator infrastructure"
  type        = string
}

variable "labels_duplicator_sa_roles" {
  description = "Roles that are needed for k8s-labels-duplicator service account"
  type        = list(string)
  default     = ["functions.functionInvoker", "compute.editor", "k8s.editor"]
}