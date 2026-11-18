#!/usr/bin/env bash
# Generate one fault variant per invariant from runner.qnt.
#
# The honest model has seven fault switches, all false. Each variant flips exactly one, so the
# diff against runner.qnt is one line and the invariant that must fail is unambiguous.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out="$here/broken"
mkdir -p "$out"

flip() {
  local name="$1" flag="$2"
  sed "s/^  pure val $flag = false$/  pure val $flag = true/" "$here/runner.qnt" > "$out/$name.qnt"
  if ! grep -q "^  pure val $flag = true$" "$out/$name.qnt"; then
    echo "variants: $flag is not a single false switch in runner.qnt" >&2
    exit 1
  fi
  echo "variants: $out/$name.qnt"
}

flip double_complete FAULT_double_complete
flip run_uncovered FAULT_run_uncovered
flip early_report FAULT_early_report
flip ignore_capacity FAULT_ignore_capacity
flip ignore_fail_fast FAULT_ignore_fail_fast
flip retry_without_child FAULT_retry_without_child
flip weak_child FAULT_weak_child
