#!/usr/bin/env bash
# tg-watch.sh <алиас>: наблюдатель за журналом чата с собственным указателем обработанного.
#
# Зачем. Пока агент выключен, хаб продолжает писать в журнал. Голый `tail -f -n 0`
# пропускает всё, что накопилось за простой. Этот скрипт хранит байтовую позицию
# "до сюда агент получил записи" и при каждом запуске начинает с неё.
#
# Что делает:
#   1. Первый запуск (нет файла указателя): запоминает текущий конец журнала, старую
#      историю не выдаёт.
#   2. Дальше: ждёт, пока в журнале появятся полные новые строки, печатает записи с
#      позиции указателя (записи [OWN] отбрасываются вместе с телом), сохраняет новую
#      позицию и ЗАВЕРШАЕТСЯ. Агент после обработки запускает его снова.
#   3. Нет новых записей TG_WATCH_MAX секунд (по умолчанию 1500): завершается молча,
#      чтобы агент перезапустил наблюдатель до срока, который есть у Monitor.
#   4. Журнал стал короче указателя (ротация, очистка): чтение с начала.
#
# Граница: указатель двигается в момент выдачи записей агенту, а не в момент, когда
# агент их выполнил. Запись "в журнале" и запись "обработана" остаются разными вещами:
# после сбоя агент сверяет хвост журнала с тем, что уже ответил.
#
# Установка: ~/bin/tg-watch.sh, chmod 700. Запуск агентом: Monitor с командой
# `~/bin/tg-watch.sh owner-agent`.
#
# Переменные (значения по умолчанию подходят шагу 03 набора):
#   TG_HUB_DIR      папка хаба                      (~/tg-assistant)
#   TG_WATCH_STATE  папка указателей                (~/.local/state/agent/offsets)
#   TG_WATCH_POLL   пауза между проверками, секунды (5)
#   TG_WATCH_MAX    предел ожидания, секунды        (1500)
set -uo pipefail

die() { echo "tg-watch: $*" >&2; exit 2; }

alias_=${1:-}
case "$alias_" in
  ''|*[!a-zA-Z0-9_-]*) die "использование: tg-watch.sh <алиас> (латиница, цифры, - и _)" ;;
esac

hub=${TG_HUB_DIR:-$HOME/tg-assistant}
log="$hub/var/logs/$alias_.log"
state_dir=${TG_WATCH_STATE:-$HOME/.local/state/agent/offsets}
state="$state_dir/$alias_.offset"
poll=${TG_WATCH_POLL:-5}
max_wait=${TG_WATCH_MAX:-1500}

(umask 077; mkdir -p -- "$state_dir") || die "не создать $state_dir"

size_of() { stat -c %s -- "$log" 2>/dev/null || echo 0; }

if [ ! -f "$state" ]; then
  (umask 077; size_of >"$state")
fi
off=$(cat -- "$state" 2>/dev/null)
case "$off" in ''|*[!0-9]*) off=0 ;; esac

deadline=$(( SECONDS + max_wait ))
while [ "$SECONDS" -lt "$deadline" ]; do
  sz=$(size_of)
  [ "$sz" -lt "$off" ] && off=0
  if [ "$sz" -gt "$off" ]; then
    # завершающий x защищает хвостовые переводы строки от обрезки подстановкой
    data=$(tail -c +"$((off + 1))" -- "$log" | head -c "$((sz - off))"; printf x)
    data=${data%x}
    partial=${data##*$'\n'}          # недописанная последняя строка (может быть пустой)
    complete=${data%"$partial"}      # только целые строки
    if [ -n "$complete" ]; then
      bytes=$(printf '%s' "$complete" | wc -c)
      out=$(printf '%s' "$complete" | awk '/^--- /{skip=($0 ~ /\[OWN\]/)} !skip{print}')
      off=$(( off + bytes ))
      printf '%s' "$off" >"$state.tmp" && mv -- "$state.tmp" "$state"
      if [ -n "$out" ]; then
        printf '%s\n' "$out"
        exit 0
      fi
      continue
    fi
  fi
  sleep "$poll"
done
exit 0
