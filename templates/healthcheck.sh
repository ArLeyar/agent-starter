#!/usr/bin/env bash
# healthcheck.sh: проверяет всех агентов и пишет в личный канал владельца
# "агент X молчит", если что-то не так. Запускается от root по таймеру (раз в 10-15 минут),
# потому что сокет tmux чужого пользователя читает только он (или root).
#
# Что проверяется для каждого агента:
#   1. Сессия tmux жива.         Нет сессии: агент не запущен.
#   2. В сессии не голая оболочка. bash/zsh/sh на переднем плане: программа агента завершилась.
#   3. Журнал хаба обновлялся не позже MAX_LOG_AGE_H часов назад. Слабый сигнал:
#      в тихом чате журнал стоит и при здоровом агенте, поэтому порог большой.
#
# Повторное оповещение о том же агенте не чаще, чем раз в REALERT_MIN минут.
# Когда агент снова в порядке, приходит одно сообщение "агент X снова работает".
#
# Настройка: строки AGENTS ниже и переменные в начале. Строка агента:
#   <имя>:<пользователь linux>:<сессия tmux>:<алиас чата для журнала>
set -uo pipefail

AGENTS=(
  "personal:agent-personal:personal:owner-agent"
  "company:agent-company:company:owner-company"
  "chats:agent-chats:chats:owner-chats"
)
ALERT_USER=${ALERT_USER:-agent-personal}              # чьей очередью отправляется оповещение
ALERT_ALIAS=${ALERT_ALIAS:-owner-agent}               # личный канал владельца
HUB_DIR_REL=${HUB_DIR_REL:-tg-assistant/var}          # от домашней папки агента
MAX_LOG_AGE_H=${MAX_LOG_AGE_H:-72}
REALERT_MIN=${REALERT_MIN:-360}
STATE_DIR=${STATE_DIR:-/var/lib/agent-healthcheck}

mkdir -p -- "$STATE_DIR" || { echo "healthcheck: нет $STATE_DIR" >&2; exit 1; }

send_alert() { # send_alert <текст>: кладёт задание в очередь ALERT_USER атомарно
  local text=$1 home outbox
  home=$(getent passwd "$ALERT_USER" | cut -d: -f6)
  outbox="$home/$HUB_DIR_REL/outbox"
  [ -d "$outbox" ] || { echo "healthcheck: нет очереди $outbox" >&2; return 1; }
  # внутренняя оболочка (sh -c) сама раскрывает $1 и $$: одинарные кавычки нужны
  # shellcheck disable=SC2016
  printf '%s' "$text" | python3 -c '
import json, sys
print(json.dumps({"chat": sys.argv[1], "text": sys.stdin.read()}, ensure_ascii=False))
' "$ALERT_ALIAS" | runuser -u "$ALERT_USER" -- sh -c '
set -e
tmp=$(mktemp "$1/.healthcheck.XXXXXX")
cat >"$tmp"
mv "$tmp" "$1/healthcheck-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
' sh "$outbox"
}

problem_of() { # problem_of <польз.> <сессия> <алиас>: печатает причину или ничего
  local user=$1 session=$2 chat=$3 cmd home log age_h
  if ! runuser -u "$user" -- tmux has-session -t "$session" 2>/dev/null; then
    echo "сессия tmux $session не запущена"; return
  fi
  cmd=$(runuser -u "$user" -- tmux display-message -p -t "$session" '#{pane_current_command}' 2>/dev/null)
  case "$cmd" in
    bash|zsh|sh|dash|fish) echo "в сессии $session голая оболочка, программа агента завершилась"; return ;;
  esac
  home=$(getent passwd "$user" | cut -d: -f6)
  log="$home/$HUB_DIR_REL/logs/$chat.log"
  if [ -f "$log" ]; then
    age_h=$(( ($(date +%s) - $(stat -c %Y -- "$log")) / 3600 ))
    if [ "$age_h" -ge "$MAX_LOG_AGE_H" ]; then
      echo "журнал хаба $chat.log не обновлялся $age_h ч"; return
    fi
  else
    echo "нет журнала хаба $chat.log"
  fi
}

now=$(date +%s)
for row in "${AGENTS[@]}"; do
  IFS=: read -r name user session chat <<<"$row"
  state="$STATE_DIR/$name.last-alert"
  reason=$(problem_of "$user" "$session" "$chat")
  if [ -n "$reason" ]; then
    last=0; [ -f "$state" ] && last=$(cat -- "$state")
    if [ $(( now - last )) -ge $(( REALERT_MIN * 60 )) ]; then
      if send_alert "Агент $name молчит: $reason."; then
        echo "$now" >"$state"
      fi
    fi
  elif [ -f "$state" ]; then
    send_alert "Агент $name снова работает." && rm -f -- "$state"
  fi
done
