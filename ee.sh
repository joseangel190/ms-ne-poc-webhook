#!/usr/bin/env bash
set -euo pipefail

# ---------------- CONFIG ----------------
ORG="joseangel190"
ROOT_REPO="ms-ne-poc-webhook"
ROOT_REF="main"

# ---------------- STATE ----------------
declare -A VISITED
GRAPH='{}'

# ---------------- UTILS ----------------
repo_type() {
  [[ $1 == ms-* ]] && echo "ms" && return
  [[ $1 == api-* ]] && echo "api" && return
  echo "unknown"
}

github_get_ephemeral() {
  local repo=$1
  local ref=$2

  curl -s \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3.raw" \
    "https://api.github.com/repos/${ORG}/${repo}/contents/ephemeral.yml?ref=${ref}"
}

# ------------- CORE LOGIC --------------
process_repo() {
  local repo=$1
  local ref=$2

  [[ -n "${VISITED[$repo]:-}" ]] && return
  VISITED[$repo]=1

  local type
  type=$(repo_type "$repo")

  local deps_list=()

  if [[ "$type" == "ms" ]]; then
    local eph
    eph=$(github_get_ephemeral "$repo" "$ref")

    local deps_len
    deps_len=$(echo "$eph" | yq '.dependencies | length')

    for ((i=0; i<deps_len; i++)); do
      local dep_obj dep_repo dep_ref dep_type

      dep_obj=$(echo "$eph" | yq -o=json ".dependencies[$i]")
      dep_repo=$(echo "$dep_obj" | jq -r '.repo')
      dep_ref=$(echo "$dep_obj" | jq -r '.ref')
      dep_type=$(repo_type "$dep_repo")

      deps_list+=("$dep_repo")

      # -------- API --------
      if [[ "$dep_type" == "api" ]]; then
        GRAPH=$(jq \
          --arg repo "$dep_repo" \
          --argjson base "$dep_obj" \
          '. + {
            ($repo): (
              $base
              | . + { type: "api", deps: [] }
            )
          }' <<<"$GRAPH")
      fi

      # -------- MS --------
      if [[ "$dep_type" == "ms" ]]; then
        process_repo "$dep_repo" "$dep_ref"
      fi
    done

    # deps como JSON válido
    local deps_json
    deps_json=$(printf '%s\n' "${deps_list[@]}" | jq -R . | jq -s .)

    # Nodo MS actual
    GRAPH=$(jq \
      --arg repo "$repo" \
      --arg ref "$ref" \
      --argjson deps "$deps_json" \
      '. + {
        ($repo): (
          { repo: $repo, ref: $ref }
          | . + { type: "ms", deps: $deps }
        )
      }' <<<"$GRAPH")
  fi
}

# ---------------- BUILD GRAPH ----------------
process_repo "$ROOT_REPO" "$ROOT_REF"

# ---------------- ORDER GRAPH (DFS) ----------------
jq -n \
  --arg root "$ROOT_REPO" \
  --argjson graph "$GRAPH" '
  def walk(repo):
    [repo] +
    (
      ($graph[repo].deps // [])
      | map(
          if ($graph[.] | .type) == "ms"
          then walk(.)
          else [.]
          end
        )
      | add
    );

  (walk($root)) as $order
  | (reduce $order[] as $r ({}; . + { ($r): $graph[$r] })) as $ordered
  | {
      root_id: $root,
      graph: $ordered
    }
'
