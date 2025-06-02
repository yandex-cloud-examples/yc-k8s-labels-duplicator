#!/bin/bash
set -uo pipefail # -e removed to allow script to continue on non-critical errors

# Функция для вывода ошибок в stderr
function error() {
  echo "[ERROR] $@" >&2
}

# Функция проверки статуса node-группы
function check_node_group_status() {
  local node_group_id="$1"
  local status
  local status_output
  status_output=$(yc managed-kubernetes node-group get --id "$node_group_id" --format json 2>&1)
  if [[ $? -ne 0 ]]; then
    error "Failed to get status for node group $node_group_id. yc output: $status_output"
    return 1
  fi

  status=$(echo "$status_output" | jq -r '.status')

  if [[ "$status" == "RUNNING" ]]; then
    return 0
  else
    echo "[INFO] Node group $node_group_id has status $status, skipping" >&2 # Changed to INFO
    return 1
  fi
}

# Функция для применения меток к инстансу и его загрузочному диску
function apply_labels_to_instance_and_disk() {
  local instance_id="$1"
  local instance_name="$2"
  local label_str="$3"
  local current_folder_id="$4" # Renamed to avoid conflict with global FOLDER_ID

  echo "[INFO]   Adding labels '$label_str' to instance $instance_name (id $instance_id)..."
  if yc compute instance add-labels --folder-id "$current_folder_id" --id "$instance_id" --labels "$label_str" >/dev/null 2>&1; then
    echo "[INFO]   [+] Labels successfully added to instance $instance_name."
  else
    error "  [-] Failed to add labels to instance $instance_name (id $instance_id). yc exit code: $?."
    # Continue to process its disk, if possible
  fi

  # Получаем id загрузочного диска ВМ
  local instance_details_json
  instance_details_json=$(yc compute instance get --folder-id "$current_folder_id" --id "$instance_id" --format json 2>&1)
  if [[ $? -ne 0 ]]; then
    error "  [-] Failed to get details for instance $instance_name (id $instance_id) to find boot disk. yc output: $instance_details_json"
    return # Skip disk labeling for this instance
  fi

  local boot_disk_id
  boot_disk_id=$(echo "$instance_details_json" | jq -r '.boot_disk.disk_id')
  if [[ -n "$boot_disk_id" && "$boot_disk_id" != "null" ]]; then
    echo "[INFO]   Adding labels '$label_str' to disk $boot_disk_id for instance $instance_name..."
    if yc compute disk add-labels --folder-id "$current_folder_id" --id "$boot_disk_id" --labels "$label_str" >/dev/null 2>&1; then
      echo "[INFO]   [+] Labels successfully added to disk $boot_disk_id."
    else
      error "  [-] Failed to add labels to disk $boot_disk_id (for instance $instance_name). yc exit code: $?."
    fi
  else
    echo "[INFO]   Boot disk not found or has null ID for instance $instance_name ($instance_id) in details: $instance_details_json"
  fi
}

# Функция для обработки одной node-группы
function process_node_group() {
  local node_group_json="$1"
  local current_folder_id="$2" # Renamed to avoid conflict with global FOLDER_ID
  local node_group_id
  local instance_group_id
  local node_labels
  local labels_count
  local label_str
  local instances_json
  local instances_count
  local instance_id
  local instance_name

  node_group_id=$(echo "$node_group_json" | jq -r ".id")

  # Проверяем статус node-группы
  if ! check_node_group_status "$node_group_id"; then
    return # Skip this node group
  fi

  instance_group_id=$(echo "$node_group_json" | jq -r ".instance_group_id")

  # Берём метки из поля "labels" node-группы
  node_labels=$(echo "$node_group_json" | jq '.labels // {}') # Ensure it's an object even if null
  labels_count=$(echo "$node_labels" | jq 'length')

  # Если меток нет, пропускаем эту группу
  if (( labels_count == 0 )); then
    echo "[INFO] Node group $node_group_id has no labels, skipping"
    return # Skip this node group
  fi

  echo "[INFO] Processing node group id=$node_group_id with instance group id=$instance_group_id"

  # Формируем строку с метками вида key1=value1,key2=value2
  label_str=$(echo "$node_labels" | jq -r '
    to_entries
    | map("\(.key)=\(.value)")
    | join(",")
  ')

  # Копируем метки в node_labels node-группы
  echo "[INFO]   Adding labels '$label_str' to node group $node_group_id..."
  if yc managed-kubernetes node-group add-node-labels --folder-id "$current_folder_id" --id "$node_group_id" --labels "$label_str" >/dev/null 2>&1; then
    echo "[INFO]   [+] Labels successfully added to node group $node_group_id."
  else
    error "  [-] Failed to add labels to node group $node_group_id. yc exit code: $?."
    # Continue with this node group, as other operations (like instance labeling) might still be relevant
  fi

  # Получаем список ВМ, входящих в instance group node-группы
  instances_json=$(yc compute instance-group list-instances --folder-id "$current_folder_id" --id "$instance_group_id" --format json 2>&1)
  if [[ $? -ne 0 ]]; then
    error "  Failed to list instances for instance group $instance_group_id (node group $node_group_id). yc output: $instances_json"
    return # Skip instance processing for this node group
  fi

  instances_count=$(echo "$instances_json" | jq 'length')

  # Если ВМ нет — переходим к следующей node-группе
  if (( instances_count == 0 )); then
    echo "[INFO]   No instances found in instance group $instance_group_id"
    return # Skip instance processing
  fi

  # Копируем метки на каждую ВМ и ее загрузочный диск
  for ((j=0; j<instances_count; j++)); do
    instance_id=$(echo "$instances_json" | jq -r ".[$j].instance_id")
    instance_name=$(echo "$instances_json" | jq -r ".[$j].name")
    apply_labels_to_instance_and_disk "$instance_id" "$instance_name" "$label_str" "$current_folder_id"
  done
}

# --- Основной блок скрипта ---

# Пытаемся получить folder-id из конфигурации yc
folder_id_from_config=$(yc config get folder-id 2>/dev/null || true)
FOLDER_ID="" # Initialize FOLDER_ID

if [[ -n "$folder_id_from_config" ]]; then
  # Используем folder-id из yc config
  FOLDER_ID="$folder_id_from_config"
elif [[ -n "${FOLDER_ID_ENV:-}" ]]; then # Check a differently named env var to avoid conflict if script is sourced
  # Используем переменную окружения FOLDER_ID_ENV
  FOLDER_ID="$FOLDER_ID_ENV"
else
  # Если folder-id ни в конфиге, ни в окружении не найден — выходим с ошибкой
  error "folder-id not found in yc config or FOLDER_ID_ENV environment variable"
  exit 1
fi

echo "[INFO] Using folder-id: $FOLDER_ID"

# Получаем список всех node-групп в указанной папке в формате json
node_groups_json_list=$(yc managed-kubernetes node-group list --folder-id "$FOLDER_ID" --format json 2>&1) # Renamed to avoid conflict
if [[ $? -ne 0 ]]; then
  error "Failed to list node groups for folder $FOLDER_ID. yc output: $node_groups_json_list"
  exit 1
fi

groups_count=$(echo "$node_groups_json_list" | jq 'length')

# Если node-групп нет — завершаем скрипт
if (( groups_count == 0 )); then
  echo "[INFO] No node groups found in folder $FOLDER_ID."
  exit 0 # Exit gracefully if no groups
fi

echo "[INFO] Found $groups_count node group(s) to process."

# Перебираем все node-группы
for ((i=0; i<groups_count; i++)); do
  node_group_item_json=$(echo "$node_groups_json_list" | jq ".[$i]") # Renamed
  process_node_group "$node_group_item_json" "$FOLDER_ID"
done

echo "[INFO] Script finished."
