# GitHub Actions GITHUB_OUTPUT multiline form (name<<DELIMITER … DELIMITER).
# https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#multiline-strings
github_output_heredoc() {
  local name="$1"
  local value="$2"
  # Random per-call delimiter prevents injection if $value contains a fixed sentinel.
  local delim
  delim="GHEOF_$(openssl rand -hex 16)"
  {
    printf '%s<<%s\n' "$name" "$delim"
    printf '%s\n' "$value"
    printf '%s\n' "$delim"
  } >> "$GITHUB_OUTPUT"
}
