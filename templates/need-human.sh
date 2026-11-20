#!/usr/bin/env bash
# need-human.sh <агент> --text-file <путь|->
#
# Агент вызывает ОДИН РАЗ, когда упёрся в то, что может снять только человек
# (доступ, слово владельца, непонятное требование). Скрипт кладёт сообщение с
# пометкой "НУЖЕН ЧЕЛОВЕК" в очередь хаба, в личный канал владельца, и дописывает
# строку в локальный журнал. Молчаливое ожидание считается поломкой.
#
# Настройка через переменные окружения (значения по умолчанию подходят шагу 03 набора):
#   TG_OUTBOX    папка очереди хаба     (~/tg-assistant/var/outbox)
#   OWNER_ALIAS  алиас личного канала   (owner-agent)
#   NH_LOG       журнал вызовов         (~/.local/state/agent/need-human.log)
set -uo pipefail

die() { echo "need-human: $*" >&2; exit 1; }

[ $# -ge 3 ] || die "использование: need-human.sh <агент> --text-file <путь|->"
agent=$1
[ "$2" = "--text-file" ] || die "ожидался --text-file"
src=$3

case "$agent" in
  ''|*[!a-zA-Z0-9_-]*) die "имя агента: только латиница, цифры, - и _" ;;
esac

if [ "$src" = "-" ]; then
  text=$(cat)
else
  [ -r "$src" ] || die "файл не читается: $src"
  text=$(cat -- "$src")
fi

# пустой или состоящий из пробелов текст отклоняется
case "$text" in
  *[![:space:]]*) ;;
  *) die "пустой текст" ;;
esac

outbox=${TG_OUTBOX:-$HOME/tg-assistant/var/outbox}
alias_=${OWNER_ALIAS:-owner-agent}
log=${NH_LOG:-$HOME/.local/state/agent/need-human.log}

[ -d "$outbox" ] || die "нет папки очереди: $outbox"
mkdir -p -- "$(dirname -- "$log")" || die "не создать папку журнала"

message="НУЖЕН ЧЕЛОВЕК (${agent}): ${text}"

# имя файла уникально (время, процесс, случайное число); запись идёт во временный
# файл, а *.json появляется атомарным mv: хаб подхватывает только готовые задания
tmp=$(mktemp "$outbox/.need-human.XXXXXX") || die "не создать временный файл"
final="$outbox/need-human-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM.json"

if ! printf '%s' "$message" | python3 -c '
import json, sys
print(json.dumps({"chat": sys.argv[1], "text": sys.stdin.read()}, ensure_ascii=False))
' "$alias_" >"$tmp"; then
  rm -f -- "$tmp"
  die "не собрать JSON"
fi

mv -- "$tmp" "$final" || { rm -f -- "$tmp"; die "не положить задание в очередь"; }

first_line=${text%%$'\n'*}
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$agent" "$first_line" >>"$log" \
  || echo "need-human: задание в очереди, но журнал не записан" >&2

# QUEUED, а не "отправлено": доставку подтверждает только хаб (суффикс .sent_<номер>)
echo "QUEUED: $final"
