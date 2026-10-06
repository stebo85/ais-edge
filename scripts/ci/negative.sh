#!/usr/bin/env bash
# =============================================================================
# 2. Negative tests — every render guard must still fire.
# =============================================================================
# For each case in ci_negative_cases:
#   * `helm template` must FAIL, and
#   * its output must contain the guard's own message.
#
# Both halves matter. "It failed" alone is satisfied by a typo in the fixture,
# a chart that no longer exists, or an unrelated guard firing first — all of
# which would let the guard under test rot away unnoticed. Matching a
# distinctive fragment of the message is what makes the test about the guard.
#
# WHY THIS EXISTS AT ALL. Every guard here replaces a failure that is silent at
# runtime: alerts evaluated and discarded, a pipeline that stalls with no
# error, PHI reaching XNAT with nothing looking wrong, TLS verification
# disabled by an empty environment variable. A guard nobody tests is a guard
# that can silently stop working, at which point the silent failure is back and
# the chart still renders green.
#
# The guard CENSUS at the end catches the other direction: a guard added to a
# template with no negative test to go with it.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/values.sh
. "$HERE/values.sh"

HELM="$(ci_helm)"

ci_heading "negative render tests"
while IFS=$'\t' read -r name chart valuesfiles expected; do
  [ -n "$name" ] || continue
  args=()
  for v in $valuesfiles; do args+=(-f "$CI_VALUES_DIR/$v"); done
  release="mgmt"; ns="ais-mgmt"
  case "$chart" in */edge) release="edge"; ns="xnat-ingest" ;; esac

  rc=0
  out="$("$HELM" template "$release" "$REPO_ROOT/$chart" "${args[@]}" --namespace "$ns" 2>&1)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    ci_fail "$name RENDERED — the guard did not fire. Expected: $expected"
  elif printf '%s' "$out" | grep -qF -- "$expected"; then
    ci_pass "$name"
  else
    ci_fail "$name failed for the WRONG reason (expected to see: $expected)"
    printf '%s\n' "$out" | head -5 | sed 's/^/        /'
  fi
done < <(ci_negative_cases)


# =============================================================================
# Guard census
# =============================================================================
# Counts `fail` call sites per template file and compares against the numbers
# recorded below. A guard added without a negative test moves a count and this
# check says so by name.
#
# It is a coverage TRIPWIRE, not proof of coverage: it cannot tell that the
# right case was added, only that the guard population changed. Updating the
# number without adding a case defeats it, which is the one thing a reviewer
# has to watch for.
#
# When it fires: add the negative case to ci_negative_cases in
# scripts/ci/values.sh, then update the number here in the same commit.
ci_heading "guard census"

# file<TAB>expected fail-call-sites
expected_census() {
  cat <<'EOF'
charts/mgmt/templates/_helpers.tpl	29
charts/mgmt/templates/cert-issuers.yaml	8
charts/mgmt/templates/cert-sync.yaml	15
charts/mgmt/templates/edge-clusters.yaml	11
charts/mgmt/templates/observability.yaml	14
charts/mgmt/templates/s3-staged-reclaimer.yaml	2
charts/mgmt/templates/seaweedfs.yaml	2
charts/edge/templates/_helpers.tpl	43
EOF
}

# GUARDS THAT NO VALUES FILE CAN REACH, listed so the gap is visible rather
# than inferred from a count that happens to be one short. Each is a tripwire
# against a future EDIT to the template, not against a misconfiguration:
#
#   cert-sync.yaml, "no longer matches the selector .+-cert-sync-.+"
#     The CronJob name is built as <fullname>-cert-sync-<edge>, so the regex
#     matches for every non-empty release and edge name. It fires only if
#     someone changes that printf without changing the CertSyncStale rule that
#     selects on it. Reaching it from a values file would need an empty release
#     name, which helm rejects first.
#
# Count them here so the census total stays honest.
#   observability.yaml, "a __DP_*__ sentinel survived substitution"
#     The Loki rules file is read raw and only __SENTINEL__ tokens are replaced,
#     so a threshold an operator sets can reach the rule as a literal. This
#     guard fires only if someone ADDS a sentinel to the rules file without
#     adding the matching replace — a template edit, not a misconfiguration. No
#     values file can reach it, because every sentinel in the file today is
#     already substituted. Without the guard the rule would ship containing a
#     literal __DP_..._, Loki would reject the whole group at load time, and
#     every OTHER alert in that file would stop evaluating with it.
#   observability.yaml, "a __*__ sentinel survived substitution in
#   files/prometheus-rules/..."
#     The same tripwire for the Prometheus rule files, added with the
#     ReclaimerNotSucceeding sentinels. It matters MORE there: PromQL reads a
#     bare __NAME__ as a metric name, so an unfilled sentinel loads, reports
#     healthy and never fires. A template edit, not a misconfiguration.
UNREACHABLE_GUARDS=3

# Any template not listed above is expected to contain no guards at all. That
# half matters as much as the counts: a guard added to a file nobody watches is
# exactly the case the census is for.
declare -A EXPECTED=()
while IFS=$'\t' read -r f n; do [ -n "$f" ] && EXPECTED["$f"]="$n"; done < <(expected_census)

census_bad=0
while IFS= read -r f; do
  rel="${f#"$REPO_ROOT"/}"
  n="$(grep -c '{{-\? *fail ' "$f" || true)"
  want="${EXPECTED[$rel]:-0}"
  if [ "$n" != "$want" ]; then
    ci_fail "guard census: $rel has $n fail() call sites, expected $want — add a negative case to ci_negative_cases in scripts/ci/values.sh, then update expected_census in this file"
    census_bad=1
  fi
done < <(find "$REPO_ROOT/charts/mgmt/templates" "$REPO_ROOT/charts/edge/templates" -type f | sort)

if [ "$census_bad" -eq 0 ]; then
  total=0
  for k in "${!EXPECTED[@]}"; do total=$((total + EXPECTED[$k])); done
  tested="$(ci_negative_cases | grep -c . || true)"
  ci_pass "guard census unchanged ($total fail() call sites across ${#EXPECTED[@]} files; $tested negative cases, $UNREACHABLE_GUARDS guard not reachable from values)"
fi

ci_summary "negative"
