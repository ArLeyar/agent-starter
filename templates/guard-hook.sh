#!/usr/bin/env bash
# PreToolUse-хук Claude Code для инструмента Bash: механическая проверка команды
# ДО запуска. Читает JSON из stdin (поле tool_input.command), печатает причину в
# stderr и завершается кодом 2, если команда запрещена (код 2 = блокировка, Claude
# видит причину). Код 0 без вывода = "решения нет", дальше работают обычные правила
# разрешений. Нужен python3 (есть в Ubuntu по умолчанию).
#
# Два режима:
#   1. Чёрный список (по умолчанию): запрещены опасные шаблоны из DENY ниже.
#      Шаблон ищется по всему тексту команды, поэтому ловит и `/bin/rm -rf`,
#      и `sh -c 'rm -rf ...'`, которые правило Bash(rm *) в settings.json пропускает.
#   2. Белый список (для узких ролей): если рядом лежит файл guard-allowlist.txt
#      (по одному регулярному выражению на строку; строки с # пропускаются), то
#      разрешены только команды, целиком подходящие под одно из выражений, и без
#      цепочек (; && || | ` $( > <). Остальное блокируется.
#
# Регулярные выражения: синтаксис Python (re). Проверка вручную:
#   echo '{"tool_input":{"command":"rm -rf /tmp/x"}}' | ./guard-hook.sh; echo $?
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
allowlist="$here/guard-allowlist.txt"

python3 -c '
import json, re, sys

DENY = [
    (r"\brm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*[rR]", "rm с -r/-R (рекурсивное удаление): использовать mv в ~/trash"),
    (r"\bgit\s+(-\S+\s+)*push\b.*(--force|--force-with-lease|\s-f\b)", "git push --force: принудительная отправка запрещена"),
    (r"\bgit\s+(-\S+\s+)*reset\s+--hard", "git reset --hard: потеря правок"),
    (r"\bgit\s+(-\S+\s+)*clean\s+-[a-zA-Z]*f", "git clean -f: удаление файлов вне git"),
    (r"api\.telegram\.org", "прямой вызов Bot API: отправка только скриптом tg-reply"),
    (r"\.tg-session|\.agent\.env|\.credentials\.json|auth\.json|\.ssh/", "чтение секретов и ключей запрещено"),
    (r"\bsudo\b", "sudo агенту не положен"),
    (r"(curl|wget)\b[^|;&]*\|\s*(ba|z)?sh\b", "запуск скачанного скрипта через конвейер"),
    (r"\b(mkfs|shutdown|reboot|poweroff)\b|\bdd\s+[^|;&]*of=/dev/", "системная команда запрещена"),
    (r"chmod\s+(-R\s+)?[0-7]*777", "chmod 777 запрещён"),
]
SHELL_CHAINS = re.compile(r"[;|&`<>\n]|\$\(")

try:
    data = json.load(sys.stdin)
    cmd = data["tool_input"]["command"]
    if not isinstance(cmd, str):
        raise TypeError("command не строка")
except Exception as e:
    # не удалось разобрать вход: молча пропустить нельзя
    print("guard-hook: не разобран вход хука (%s)" % e, file=sys.stderr)
    sys.exit(2)

for pattern, reason in DENY:
    if re.search(pattern, cmd):
        print("Заблокировано guard-hook: %s." % reason, file=sys.stderr)
        sys.exit(2)

allow_path = sys.argv[1]
try:
    with open(allow_path, encoding="utf-8") as f:
        rules = [l.strip() for l in f if l.strip() and not l.lstrip().startswith("#")]
except FileNotFoundError:
    sys.exit(0)

if SHELL_CHAINS.search(cmd):
    print("Заблокировано guard-hook (белый список): цепочки и подстановки запрещены.", file=sys.stderr)
    sys.exit(2)
if not any(re.fullmatch(r, cmd.strip()) for r in rules):
    print("Заблокировано guard-hook (белый список): команды нет в guard-allowlist.txt.", file=sys.stderr)
    sys.exit(2)
sys.exit(0)
' "$allowlist"
