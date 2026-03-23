#!/bin/bash
# Ralph Wiggum: Agent stream normalizer
#
# Converts backend-specific stream-json output into a lightweight normalized
# event shape that the Ralph parser can consume across Cursor and Qwen.

set -euo pipefail

BACKEND_RAW="${1:-cursor}"
WORKSPACE="${2:-.}"
BACKEND="$(printf '%s' "$BACKEND_RAW" | tr '[:upper:]' '[:lower:]')"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

safe_call_id() {
  printf '%s' "${1:-unknown}" | tr -c 'A-Za-z0-9._-' '_'
}

line_count() {
  local text="${1:-}"
  if [[ -z "$text" ]]; then
    echo "0"
    return
  fi
  printf '%s' "$text" | awk 'END { print NR+0 }'
}

tool_kind_from_name() {
  local tool_name="${1:-}"

  case "$tool_name" in
    "read_file"|"grep_search"|"glob"|"list_directory")
      printf '%s\n' "read"
      ;;
    "write_file"|"edit")
      printf '%s\n' "write"
      ;;
    "run_shell_command")
      printf '%s\n' "shell"
      ;;
    *)
      printf '%s\n' "other"
      ;;
  esac
}

extract_path_from_input() {
  local input_json="${1:-{}}"
  printf '%s' "$input_json" | jq -r '
    .path //
    .file_path //
    .filePath //
    .absolute_path //
    .absolutePath //
    .target_path //
    .targetPath //
    .target_file //
    .targetFile //
    .directory //
    .dir //
    empty
  ' 2>/dev/null || true
}

extract_command_from_input() {
  local input_json="${1:-{}}"
  printf '%s' "$input_json" | jq -r '
    .command //
    .cmd //
    .shell_command //
    .shellCommand //
    empty
  ' 2>/dev/null || true
}

extract_content_from_input() {
  local input_json="${1:-{}}"
  printf '%s' "$input_json" | jq -r '
    .content //
    .new_content //
    .newContent //
    .text //
    .replacement //
    .replace_with //
    empty
  ' 2>/dev/null || true
}

stringify_result_content() {
  local block_json="${1:-{}}"
  printf '%s' "$block_json" | jq -r '
    if (.content // empty) == empty then
      ""
    elif (.content | type) == "string" then
      .content
    elif (.content | type) == "array" then
      [
        .content[]? |
        if type == "string" then
          .
        elif type == "object" then
          (.text // .content // tostring)
        else
          tostring
        end
      ] | join("")
    else
      (.content | tostring)
    end
  ' 2>/dev/null || true
}

emit_system() {
  local backend="$1"
  local subtype="$2"
  local session_id="$3"
  local model="$4"
  local permission_mode="$5"

  jq -cn \
    --arg backend "$backend" \
    --arg subtype "$subtype" \
    --arg session_id "$session_id" \
    --arg model "$model" \
    --arg permission_mode "$permission_mode" \
    '{
      type: "system",
      subtype: $subtype,
      backend: $backend,
      session_id: $session_id,
      model: $model,
      permission_mode: $permission_mode
    }'
}

emit_assistant_text() {
  local backend="$1"
  local text="$2"

  jq -cn \
    --arg backend "$backend" \
    --arg text "$text" \
    '{type: "assistant_text", backend: $backend, text: $text}'
}

emit_result() {
  local backend="$1"
  local session_id="$2"
  local request_id="$3"
  local duration_ms="$4"

  jq -cn \
    --arg backend "$backend" \
    --arg session_id "$session_id" \
    --arg request_id "$request_id" \
    --argjson duration_ms "${duration_ms:-0}" \
    '{
      type: "result",
      backend: $backend,
      session_id: $session_id,
      request_id: $request_id,
      duration_ms: $duration_ms
    }'
}

emit_error() {
  local backend="$1"
  local message="$2"

  jq -cn \
    --arg backend "$backend" \
    --arg message "$message" \
    '{type: "error", backend: $backend, message: $message}'
}

emit_tool_call() {
  local backend="$1"
  local subtype="$2"
  local call_id="$3"
  local tool_name="$4"
  local tool_kind="$5"
  local path="$6"
  local command="$7"
  local bytes="$8"
  local lines="$9"
  local success="${10}"
  local exit_code="${11}"
  local stdout="${12}"
  local stderr="${13}"
  local content="${14}"
  local raw_output="${15}"

  jq -cn \
    --arg backend "$backend" \
    --arg subtype "$subtype" \
    --arg call_id "$call_id" \
    --arg tool_name "$tool_name" \
    --arg tool_kind "$tool_kind" \
    --arg path "$path" \
    --arg command "$command" \
    --argjson bytes "${bytes:-0}" \
    --argjson lines "${lines:-0}" \
    --argjson success "${success:-true}" \
    --argjson exit_code "${exit_code:-0}" \
    --arg stdout "$stdout" \
    --arg stderr "$stderr" \
    --arg content "$content" \
    --arg raw_output "$raw_output" \
    '{
      type: "tool_call",
      subtype: $subtype,
      backend: $backend,
      call_id: $call_id,
      tool_name: $tool_name,
      tool_kind: $tool_kind,
      path: $path,
      command: $command,
      bytes: $bytes,
      lines: $lines,
      success: $success,
      exit_code: $exit_code,
      stdout: $stdout,
      stderr: $stderr,
      content: $content,
      raw_output: $raw_output
    }'
}

store_qwen_tool_use() {
  local call_id="$1"
  local tool_name="$2"
  local input_json="$3"
  local meta_file="$TMP_DIR/$(safe_call_id "$call_id").json"

  jq -cn \
    --arg call_id "$call_id" \
    --arg tool_name "$tool_name" \
    --argjson input "$input_json" \
    '{call_id: $call_id, tool_name: $tool_name, input: $input}' > "$meta_file"
}

load_qwen_tool_use() {
  local call_id="$1"
  local meta_file="$TMP_DIR/$(safe_call_id "$call_id").json"

  if [[ -f "$meta_file" ]]; then
    cat "$meta_file"
  else
    printf '%s\n' '{"call_id":"","tool_name":"unknown","input":{}}'
  fi
}

handle_cursor_line() {
  local line="$1"
  local type=""

  if ! type=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null); then
    printf '%s\n' "$line"
    return
  fi

  case "$type" in
    "system")
      local subtype session_id model permission_mode
      subtype=$(printf '%s' "$line" | jq -r '.subtype // empty' 2>/dev/null) || subtype=""
      session_id=$(printf '%s' "$line" | jq -r '.session_id // .sessionId // .chatId // empty' 2>/dev/null) || session_id=""
      model=$(printf '%s' "$line" | jq -r '.model // "unknown"' 2>/dev/null) || model="unknown"
      permission_mode=$(printf '%s' "$line" | jq -r '.permissionMode // .permission_mode // empty' 2>/dev/null) || permission_mode=""
      emit_system "cursor" "$subtype" "$session_id" "$model" "$permission_mode"
      ;;
    "assistant")
      local text
      text=$(printf '%s' "$line" | jq -r '[.message.content[]? | .text // empty] | join("")' 2>/dev/null) || text=""
      if [[ -n "$text" ]]; then
        emit_assistant_text "cursor" "$text"
      fi
      ;;
    "result")
      local session_id request_id duration_ms
      session_id=$(printf '%s' "$line" | jq -r '.session_id // .sessionId // .chatId // empty' 2>/dev/null) || session_id=""
      request_id=$(printf '%s' "$line" | jq -r '.request_id // .requestId // empty' 2>/dev/null) || request_id=""
      duration_ms=$(printf '%s' "$line" | jq -r '.duration_ms // 0' 2>/dev/null) || duration_ms=0
      emit_result "cursor" "$session_id" "$request_id" "$duration_ms"
      ;;
    "error")
      local message
      message=$(printf '%s' "$line" | jq -r '.error.data.message // .error.message // .message // "Unknown error"' 2>/dev/null) || message="Unknown error"
      emit_error "cursor" "$message"
      ;;
    "tool_call")
      local subtype call_id path command bytes lines success exit_code stdout stderr content raw_output tool_name tool_kind
      subtype=$(printf '%s' "$line" | jq -r '.subtype // "completed"' 2>/dev/null) || subtype="completed"
      call_id=$(printf '%s' "$line" | jq -r '.call_id // .callId // .tool_call.call_id // .tool_call.callId // empty' 2>/dev/null) || call_id=""
      path=""
      command=""
      bytes=0
      lines=0
      success=true
      exit_code=0
      stdout=""
      stderr=""
      content=""
      raw_output=""
      tool_name="unknown"
      tool_kind="other"

      if printf '%s' "$line" | jq -e '.tool_call.readToolCall? != null' >/dev/null 2>&1; then
        tool_name="read_file"
        tool_kind="read"
        path=$(printf '%s' "$line" | jq -r '.tool_call.readToolCall.args.path // "unknown"' 2>/dev/null) || path="unknown"
        lines=$(printf '%s' "$line" | jq -r '.tool_call.readToolCall.result.success.totalLines // 0' 2>/dev/null) || lines=0
        bytes=$(printf '%s' "$line" | jq -r '.tool_call.readToolCall.result.success.contentSize // 0' 2>/dev/null) || bytes=0
      elif printf '%s' "$line" | jq -e '.tool_call.writeToolCall? != null' >/dev/null 2>&1; then
        tool_name="write_file"
        tool_kind="write"
        path=$(printf '%s' "$line" | jq -r '.tool_call.writeToolCall.args.path // "unknown"' 2>/dev/null) || path="unknown"
        lines=$(printf '%s' "$line" | jq -r '.tool_call.writeToolCall.result.success.linesCreated // 0' 2>/dev/null) || lines=0
        bytes=$(printf '%s' "$line" | jq -r '.tool_call.writeToolCall.result.success.fileSize // 0' 2>/dev/null) || bytes=0
      elif printf '%s' "$line" | jq -e '.tool_call.shellToolCall? != null' >/dev/null 2>&1; then
        tool_name="run_shell_command"
        tool_kind="shell"
        command=$(printf '%s' "$line" | jq -r '.tool_call.shellToolCall.args.command // "unknown"' 2>/dev/null) || command="unknown"
        exit_code=$(printf '%s' "$line" | jq -r '.tool_call.shellToolCall.result.exitCode // 0' 2>/dev/null) || exit_code=0
        stdout=$(printf '%s' "$line" | jq -r '.tool_call.shellToolCall.result.stdout // ""' 2>/dev/null) || stdout=""
        stderr=$(printf '%s' "$line" | jq -r '.tool_call.shellToolCall.result.stderr // ""' 2>/dev/null) || stderr=""
        raw_output="${stdout}${stderr}"
        content="$raw_output"
        bytes=${#raw_output}
        lines=$(line_count "$raw_output")
        if [[ "$exit_code" -ne 0 ]]; then
          success=false
        fi
      else
        tool_name=$(printf '%s' "$line" | jq -r '.tool_call.name // .tool_call.tool_name // "unknown"' 2>/dev/null) || tool_name="unknown"
        tool_kind=$(tool_kind_from_name "$tool_name")
      fi

      emit_tool_call "cursor" "$subtype" "$call_id" "$tool_name" "$tool_kind" "$path" "$command" "$bytes" "$lines" "$success" "$exit_code" "$stdout" "$stderr" "$content" "$raw_output"
      ;;
    *)
      printf '%s\n' "$line"
      ;;
  esac
}

handle_qwen_assistant() {
  local line="$1"
  local text
  text=$(printf '%s' "$line" | jq -r '
    [
      .message.content[]? |
      select((.type // "") == "text") |
      (.text // empty)
    ] | join("")
  ' 2>/dev/null) || text=""

  if [[ -n "$text" ]]; then
    emit_assistant_text "qwen" "$text"
  fi

  while IFS= read -r block; do
    [[ -n "$block" ]] || continue
    local block_type
    block_type=$(printf '%s' "$block" | jq -r '.type // empty' 2>/dev/null) || block_type=""
    if [[ "$block_type" != "tool_use" ]]; then
      continue
    fi

    local call_id tool_name input_json tool_kind path command content bytes lines
    call_id=$(printf '%s' "$block" | jq -r '.id // empty' 2>/dev/null) || call_id=""
    tool_name=$(printf '%s' "$block" | jq -r '.name // "unknown"' 2>/dev/null) || tool_name="unknown"
    input_json=$(printf '%s' "$block" | jq -c '.input // {}' 2>/dev/null) || input_json='{}'
    tool_kind=$(tool_kind_from_name "$tool_name")
    path=$(extract_path_from_input "$input_json")
    command=$(extract_command_from_input "$input_json")
    content=$(extract_content_from_input "$input_json")
    bytes=${#content}
    lines=$(line_count "$content")

    if [[ -n "$call_id" ]]; then
      store_qwen_tool_use "$call_id" "$tool_name" "$input_json"
    fi

    emit_tool_call "qwen" "started" "$call_id" "$tool_name" "$tool_kind" "$path" "$command" "$bytes" "$lines" true 0 "" "" "$content" ""
  done < <(printf '%s' "$line" | jq -c '.message.content[]? // empty' 2>/dev/null)
}

handle_qwen_user() {
  local line="$1"

  while IFS= read -r block; do
    [[ -n "$block" ]] || continue
    local block_type
    block_type=$(printf '%s' "$block" | jq -r '.type // empty' 2>/dev/null) || block_type=""
    if [[ "$block_type" != "tool_result" ]]; then
      continue
    fi

    local call_id meta_json tool_name input_json tool_kind path command content bytes lines is_error success exit_code stdout stderr
    call_id=$(printf '%s' "$block" | jq -r '.tool_use_id // empty' 2>/dev/null) || call_id=""
    meta_json=$(load_qwen_tool_use "$call_id")
    tool_name=$(printf '%s' "$meta_json" | jq -r '.tool_name // "unknown"' 2>/dev/null) || tool_name="unknown"
    input_json=$(printf '%s' "$meta_json" | jq -c '.input // {}' 2>/dev/null) || input_json='{}'
    tool_kind=$(tool_kind_from_name "$tool_name")
    path=$(extract_path_from_input "$input_json")
    command=$(extract_command_from_input "$input_json")
    content=$(stringify_result_content "$block")
    bytes=${#content}
    lines=$(line_count "$content")
    is_error=$(printf '%s' "$block" | jq -r '.is_error // false' 2>/dev/null) || is_error=false
    success=true
    exit_code=0
    stdout=""
    stderr=""

    if [[ "$tool_kind" == "write" ]]; then
      local input_content
      input_content=$(extract_content_from_input "$input_json")
      if [[ -n "$input_content" ]]; then
        bytes=${#input_content}
        lines=$(line_count "$input_content")
      fi
    fi

    if [[ "$tool_kind" == "shell" ]]; then
      if [[ "$is_error" == "true" ]]; then
        success=false
        exit_code=1
        stderr="$content"
      else
        stdout="$content"
      fi
    elif [[ "$is_error" == "true" ]]; then
      success=false
    fi

    emit_tool_call "qwen" "completed" "$call_id" "$tool_name" "$tool_kind" "$path" "$command" "$bytes" "$lines" "$success" "$exit_code" "$stdout" "$stderr" "$content" "$content"
  done < <(printf '%s' "$line" | jq -c '.message.content[]? // empty' 2>/dev/null)
}

handle_qwen_line() {
  local line="$1"
  local type=""

  if ! type=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null); then
    printf '%s\n' "$line"
    return
  fi

  case "$type" in
    "system")
      local subtype session_id model permission_mode
      subtype=$(printf '%s' "$line" | jq -r '.subtype // empty' 2>/dev/null) || subtype=""
      session_id=$(printf '%s' "$line" | jq -r '.session_id // .sessionId // .uuid // empty' 2>/dev/null) || session_id=""
      model=$(printf '%s' "$line" | jq -r '.model // "unknown"' 2>/dev/null) || model="unknown"
      permission_mode=$(printf '%s' "$line" | jq -r '.permission_mode // .permissionMode // empty' 2>/dev/null) || permission_mode=""
      emit_system "qwen" "$subtype" "$session_id" "$model" "$permission_mode"
      ;;
    "assistant")
      handle_qwen_assistant "$line"
      ;;
    "user")
      handle_qwen_user "$line"
      ;;
    "result")
      local session_id request_id duration_ms
      session_id=$(printf '%s' "$line" | jq -r '.session_id // .sessionId // empty' 2>/dev/null) || session_id=""
      request_id=$(printf '%s' "$line" | jq -r '.request_id // .requestId // empty' 2>/dev/null) || request_id=""
      duration_ms=$(printf '%s' "$line" | jq -r '.duration_ms // 0' 2>/dev/null) || duration_ms=0
      emit_result "qwen" "$session_id" "$request_id" "$duration_ms"
      ;;
    "error")
      local message
      message=$(printf '%s' "$line" | jq -r '.error.data.message // .error.message // .message // "Unknown error"' 2>/dev/null) || message="Unknown error"
      emit_error "qwen" "$message"
      ;;
    "stream_event")
      ;;
    *)
      printf '%s\n' "$line"
      ;;
  esac
}

main() {
  local line

  while IFS= read -r line; do
    case "$BACKEND" in
      "cursor")
        handle_cursor_line "$line"
        ;;
      "qwen")
        handle_qwen_line "$line"
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done
}

main "$@"
