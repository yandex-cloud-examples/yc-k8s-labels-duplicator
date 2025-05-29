### K8s Labels Duplicator

Terraform-проект, который разворачивает в *Yandex Cloud* облачную функцию. Эта функция вызывается по расписанию и автоматически копирует пользовательские метки (*labels*) node-групп кластеров Managed Kubernetes (mk8s) на связанные ресурсы:

- виртуальные машины, входящие в соответствующие группы узлов кластера.
- загрузочные диски этих виртуальных машин.
- *node\_labels* группы узлов кластера k8s (и далее автоматически на сами ноды кластера k8s).


 > *node\_labels* — пользовательские метки, назначаемые на группы узлов Managed Service for Kubernetes в Yandex Cloud. Подробнее об управлении метками *node\_labels* можно узнать в [документации](https://yandex.cloud/ru/docs/managed-kubernetes/operations/node-group/node-label-management#node-group-creation).
*node_labels* используются в проекте для автоматического добавления меток на ноды кластера k8s.

---

### Функционал

- Создаёт сервисный аккаунт с необходимыми правами (IAM роли) для работы с ресурсами Yandex Cloud.
- Загружает и развёртывает функцию на базе кода из папки `code/`.
- Настраивает [триггер по расписанию](https://yandex.cloud/ru/docs/functions/concepts/trigger/timer) (по умолчанию - ежеминутный запуск). Для запуска функции, например, раз в 2 минуты - меняем атрибут `cron_expression` на `0/2 * * * ? *` и т.д.
- Генерирует уникальные имена для ресурсов с помощью случайной строки, чтобы избежать конфликтов.

---
### Использование

1. Установите [YC CLI](https://cloud.yandex.com/docs/cli/quickstart)
2. Добавьте переменные окружения для аутентификации *terraform* в *Yandex Cloud*:
```bash
export YC_TOKEN=$(yc iam create-token)
export YC_CLOUD_ID=$(yc config get cloud-id)
export YC_FOLDER_ID=$(yc config get folder-id)
```
3. Клонируйте репозиторий и перейдите в папку проекта:
   ```bash
   git clone https://github.com/yandex-cloud-examples/yc-k8s-labels-duplicator
   cd yc-k8s-labels-duplicator
   ```
4. Настройте переменные с помощью файла `terraform.tfvars` или передайте необходимые переменные вручную:
```bash
folder_id = "your-folder-id"
```
5. Инициализируйте Terraform:
```tf
terraform init
```
6. Проверьте план изменений:
```tf
terraform plan
```
7. Примените конфигурацию:
```tf
terraform apply
```