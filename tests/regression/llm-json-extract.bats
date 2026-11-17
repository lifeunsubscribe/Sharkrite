#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/llm-json.sh
#
# llm_extract_json_object — the one place a classifier's free-text answer is
# turned into a JSON object. The object is found by parsing, so packaging
# (code fence, pretty-printing, surrounding prose) and braces inside string
# values do not matter. An empty result is the caller's "unparseable" signal.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/utils/llm-json.sh"
  set +u; set +o pipefail  # bats needs its own error handling
}

@test "extract: compact object comes back unchanged" {
  run llm_extract_json_object '{"verdict":"resolved","reason":"guard added"}' verdict
  [ "$status" -eq 0 ]
  [ "$output" = '{"verdict":"resolved","reason":"guard added"}' ]
}

@test "extract: fenced pretty-printed object with braces in a string value" {
  local _answer
  _answer=$(printf '%s\n' '```json' '{' '  "verdict": "still-open",' \
    '  "reason": "tabIndex={isPending ? -1 : 0} conditional unchanged"' '}' '```' \
    'Prose after the fence, with a stray } brace.')
  run llm_extract_json_object "$_answer" verdict
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<< "$output")" = "still-open" ]
  [ "$(jq -r .reason <<< "$output")" = "tabIndex={isPending ? -1 : 0} conditional unchanged" ]
}

@test "extract: prose braces before the object and non-ASCII text are skipped over" {
  run llm_extract_json_object 'I read {the handler} — here: {"verdict":"partially-resolved","reason":"é {x}"} done' verdict
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<< "$output")" = "partially-resolved" ]
}

@test "extract: an object without the key is passed over for a later one that has it" {
  run llm_extract_json_object '{"note":1} {"verdict":"trivial","confidence":0.9}' verdict
  [ "$status" -eq 0 ]
  [ "$(jq -r .confidence <<< "$output")" = "0.9" ]
}

@test "extract: nested objects stay inside the outer object" {
  run llm_extract_json_object '{"meta":{"a":1},"verdict":"trivial"}' verdict
  [ "$status" -eq 0 ]
  [ "$(jq -c .meta <<< "$output")" = '{"a":1}' ]
}

@test "extract: no object, wrong key, or empty input prints nothing and returns 0" {
  run llm_extract_json_object 'No JSON here.' verdict
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run llm_extract_json_object '{"answer":"resolved"}' verdict
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run llm_extract_json_object '' verdict
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "extract: a brace-heavy answer with no match stays bounded" {
  local _big="" _i
  for _i in 1 2 3 4 5 6 7 8; do _big="${_big}$(printf '{}%.0s' $(seq 1 500))"; done
  SECONDS=0
  run llm_extract_json_object "$_big" verdict
  [ "$status" -eq 0 ] && [ -z "$output" ]
  [ "$SECONDS" -lt 10 ]
}
