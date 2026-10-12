#!/bin/bash
# ralph-kit の bin/ralph-setup.sh を呼ぶ中継（本体: https://github.com/shilokuma-inc/ralph-kit）。使い方は本体と同じ。
# このファイルは ralph-kit の install.sh が置く。直すときは、このリポジトリではなく ralph-kit を直す
exec "$(dirname "$0")/ralph-kit.sh" run ralph-setup "$@"
