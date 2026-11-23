#!/usr/bin/env bash
# Verify the planner against real tree objects, with no remote or member checkout.
set -euo pipefail

planner="$(cd "$(dirname "$0")" && pwd)/umbrella-pins.py"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cd "$fixture"
git init --quiet
git config user.name fixture
git config user.email fixture@example.invalid
git commit --quiet --allow-empty -m initial
pin=$(git rev-parse HEAD)
git config -f .gitmodules submodule.example.path 'nested/private member'
git config -f .gitmodules submodule.example.url https://github.com/example/recorded-only.git
git add .gitmodules
git update-index --add --cacheinfo "160000,$pin,nested/private member"
git commit --quiet -m matched
python3 "$planner" | jq -e --arg pin "$pin" '. == [{path:"nested/private member",slug:"example/recorded-only",sha:$pin}]'

expect_failure() {
    if python3 "$planner" >result 2>reason; then
        echo "unexpectedly accepted $1" >&2
        exit 1
    fi
    grep -F "$1" reason
}

git config -f .gitmodules submodule.missing.path missing
git config -f .gitmodules submodule.missing.url https://github.com/example/missing
git add .gitmodules
git commit --quiet -m missing
expect_failure "declared without gitlink: ['missing']"
git config -f .gitmodules --remove-section submodule.missing
git add .gitmodules
git update-index --add --cacheinfo "160000,$pin,orphan"
git commit --quiet -m extra
expect_failure "gitlink without declaration: ['orphan']"
