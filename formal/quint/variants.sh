#!/usr/bin/env bash
# Generate one fault variant per fault switch from runner.qnt and matrix.qnt.
#
# Every switch in an honest model is false. Each variant flips exactly one, so the diff against
# its model is one line and the invariant that must fail is unambiguous.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$here/broken" "$here/broken-matrix"

flip_from() {
  local model="$1" out="$2" name="$3" flag="$4"
  sed "s/^  pure val $flag = false$/  pure val $flag = true/" "$here/$model.qnt" > "$out/$name.qnt"
  if ! grep -q "^  pure val $flag = true$" "$out/$name.qnt"; then
    echo "variants: $flag is not a single false switch in $model.qnt" >&2
    exit 1
  fi
  echo "variants: $out/$name.qnt"
}

flip() { flip_from runner "$here/broken" "$@"; }
flip_matrix() { flip_from matrix "$here/broken-matrix" "$@"; }

flip double_complete FAULT_double_complete
flip run_uncovered FAULT_run_uncovered
flip early_report FAULT_early_report
flip ignore_capacity FAULT_ignore_capacity
flip ignore_fail_fast FAULT_ignore_fail_fast
flip retry_without_child FAULT_retry_without_child
flip weak_child FAULT_weak_child

flip_matrix sweep_writes_status FAULT_sweep_writes_status
flip_matrix sweep_from_failed_exclusive FAULT_sweep_from_failed_exclusive
flip_matrix tail_skips_one FAULT_tail_skips_one
flip_matrix failed_sweep_complete FAULT_failed_sweep_complete
flip_matrix trust_unverified FAULT_trust_unverified
flip_matrix report_early FAULT_report_early
flip_matrix ignore_capacity FAULT_ignore_capacity
flip_matrix sweep_cached_row FAULT_sweep_cached_row
flip_matrix drop_without_cause FAULT_drop_without_cause
flip_matrix tail_ignores_focus FAULT_tail_ignores_focus
