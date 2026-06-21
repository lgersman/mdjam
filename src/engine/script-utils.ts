export const SET_OUTPUT_RE = /^::set-output name=([^:]+)::(.*)$/

export function scriptPreamble(captureFile: string): string[] {
  return [
    `_MDRUN_CAP="${captureFile}"`,
    `trap 'export -p > "$_MDRUN_CAP" 2>/dev/null || true' EXIT`,
  ]
}
