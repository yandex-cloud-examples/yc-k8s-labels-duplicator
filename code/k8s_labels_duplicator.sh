#!/bin/bash
set -euo pipefail

# Функция для вывода ошибок в stderr
function error() {
  echo "$@" >&2
}

# Пытаемся получить folder-id из конфигурации yc
folder_id_from_config=$(yc config get folder-id 2>/dev/null || true)

if [[ -n "$folder_id_from_config" ]]; then
  # Используем folder-id из yc config
  FOLDER_ID="$folder_id_from_config"
elif [[ -n "${FOLDER_ID:-}" ]]; then
  # Используем уже существующую переменную окружения FOLDER_ID (например, передана из контекста функции)
  :
else
  # Если folder-id ни в конфиге, ни в окружении не найден — выходим с ошибкой
  echo "Error: folder-id is not set neither in yc config nor environment variable FOLDER_ID" >&2
  exit 1
fi

echo "Using folder-id: $FOLDER_ID"

# Получаем список всех node-групп в указанной папке в формате json
node_groups_json=$(yc managed-kubernetes node-group list --folder-id "$FOLDER_ID" --format json)
groups_count=$(echo "$node_groups_json" | jq 'length')

# Если node-групп нет — завершаем скрипт с ошибкой
if (( groups_count == 0 )); then
  error "No node groups found"
  exit 1
fi

# Перебираем все node-группы
for ((i=0; i<groups_count; i++)); do
  node_group=$(echo "$node_groups_json" | jq ".[$i]")
  node_group_id=$(echo "$node_group" | jq -r ".id")
  instance_group_id=$(echo "$node_group" | jq -r ".instance_group_id")

  # Берём метки из поля "labels" node-группы
  node_labels=$(echo "$node_group" | jq '.labels // {}')
  labels_count=$(echo "$node_labels" | jq 'length')

  # Если меток нет, пропускаем эту группу
  if (( labels_count == 0 )); then
    echo "Node group $node_group_id has no labels, skipping"
    continue
  fi

  echo "Processing node group id=$node_group_id with instance group id=$instance_group_id"

  # Получаем список ВМ, входящих в instance group node-группы
  instances_json=$(yc compute instance-group list-instances --folder-id "$FOLDER_ID" --id "$instance_group_id" --format json)
  instances_count=$(echo "$instances_json" | jq 'length')

  # Если ВМ нет — переходим к следующей node-группе
  if (( instances_count == 0 )); then
    echo "  No instances found in instance group $instance_group_id"
    continue
  fi

  # Формируем строку с метками вида key1=value1,key2=value2
  label_str=$(echo "$node_labels" | jq -r '
    to_entries
    | map("\(.key)=\(.value)")
    | join(",")
  ')

  # Копируем метки в node_labels node-группы
  echo "  Adding labels $label_str to node group $node_group_id..."
  yc managed-kubernetes node-group add-node-labels --folder-id "$FOLDER_ID" --id "$node_group_id" --labels "$label_str" >/dev/null 2>&1
  echo "  Labels added to node group $node_group_id"

  # Копируем метки на каждую ВМ и ее загрузочный диск
  for ((j=0; j<instances_count; j++)); do
    instance_id=$(echo "$instances_json" | jq -r ".[$j].instance_id")
    instance_name=$(echo "$instances_json" | jq -r ".[$j].name")

    echo "  Adding labels $label_str to instance $instance_name (id $instance_id)..."
    yc compute instance add-labels --folder-id "$FOLDER_ID" --id "$instance_id" --labels "$label_str" >/dev/null 2>&1
    echo "  Labels added to instance $instance_name"

    # Получаем id загрузочного диска ВМ
    boot_disk_id=$(yc compute instance get --folder-id "$FOLDER_ID" --id "$instance_id" --format json | jq -r '.boot_disk.disk_id')

    if [[ -n "$boot_disk_id" && "$boot_disk_id" != "null" ]]; then
      echo "  Adding labels $label_str to disk $boot_disk_id..."
      yc compute disk add-labels --folder-id "$FOLDER_ID" --id "$boot_disk_id" --labels "$label_str" >/dev/null 2>&1
      echo "  Labels added to disk $boot_disk_id"
    else
      echo "  Boot disk not found for instance $instance_name ($instance_id)"
    fi
  done
done
