#!/usr/bin/env bash
# Re-apply after ansible-galaxy collection install of community.zabbix 4.2.0.
# Upstream still imports ansible.module_utils._text (removed in ansible-core 2.24).
set -euo pipefail

patched=0
while IFS= read -r -d '' root; do
  find "${root}/plugins" -type f -name '*.py' -print0 | xargs -0 sed -i \
    -e 's/from ansible\.module_utils\._text import/from ansible.module_utils.common.text.converters import/g' \
    -e 's/from ansible\.module_utils\.basic import to_text/from ansible.module_utils.common.text.converters import to_text/g'
  patched=$((patched + 1))
  printf 'Patched community.zabbix text imports under %s\n' "${root}"
done < <(find \
  "${HOME}/.ansible/collections/ansible_collections/community/zabbix" \
  "${PYENV_ROOT:-${HOME}/.pyenv}/versions"/*/lib/python*/site-packages/ansible_collections/community/zabbix \
  -maxdepth 0 -type d -print0 2>/dev/null)

if [[ "${patched}" -eq 0 ]]; then
  echo "Error: no community.zabbix collection installs found to patch" >&2
  exit 1
fi
