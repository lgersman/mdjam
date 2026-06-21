export const SET_OUTPUT_RE = /^::set-output name=([^:]+)::(.*)$/

export function scriptPreamble(captureFile: string): string[] {
  return [
    `_MDJAM_CAP="${captureFile}"`,
    `trap 'export -p > "$_MDJAM_CAP" 2>/dev/null || true' EXIT`,
  ]
}
