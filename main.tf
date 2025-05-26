data "archive_file" "labels_duplicator_func_code" {
  type        = "zip"
  source_dir  = "${path.module}/code/"
  output_path = "${path.module}/code.zip"
}

resource "random_string" "prefix" {
  length  = 10
  upper   = false
  lower   = true
  numeric = true
  special = false
}

resource "yandex_iam_service_account" "labels_duplicator_sa" {
  folder_id = var.folder_id
  name      = "k8s-labels-duplicator-sa-${random_string.prefix.result}"
}

resource "yandex_resourcemanager_folder_iam_member" "labels_duplicator_sa_roles" {
  for_each = toset(var.labels_duplicator_sa_roles)
  folder_id = var.folder_id
  role      = each.key
  member    = "serviceAccount:${yandex_iam_service_account.labels_duplicator_sa.id}"
}

resource "yandex_function" "labels_duplicator" {
  folder_id          = var.folder_id
  name               = "k8s-labels-duplicator-${random_string.prefix.result}"
  description        = "k8s-labels-duplicator function"
  runtime            = "bash-2204"
  entrypoint         = "k8s_labels_duplicator.sh"
  memory             = "128"
  execution_timeout  = "600"
  service_account_id = yandex_iam_service_account.labels_duplicator_sa.id
  environment = {
    FOLDER_ID = var.folder_id
  }
  user_hash = data.archive_file.labels_duplicator_func_code.output_base64sha256
  content {
    zip_filename = data.archive_file.labels_duplicator_func_code.output_path
  }
}

resource "yandex_function_trigger" "labels_duplicator_trigger" {
  name      = "k8s-labels-duplicator-trigger-${random_string.prefix.result}"

  function {
    id                 = yandex_function.labels_duplicator.id
    service_account_id = yandex_iam_service_account.labels_duplicator_sa.id
  }

  timer {
    cron_expression = "* * * * ? *"
  }
  depends_on = [
    yandex_resourcemanager_folder_iam_member.labels_duplicator_sa_roles
  ]
}