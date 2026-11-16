#!/usr/bin/env bash
set -euo pipefail
VERSION="${1:?usage: gen-cilium.sh <cilium-chart-version>}"
cd "$(dirname "$0")"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
{
  printf 'apiVersion: v1alpha1\nkind: KubeInlineManifestConfig\nname: cilium\nmanifest: |\n'
  helm template cilium cilium/cilium --version "$VERSION" --namespace kube-system \
    -f ../infra/cilium/values.yaml \
    | sed -E 's/\$\{([A-Za-z_][A-Za-z0-9_]*)\}\//$\1\//g' \
    | sed 's/^/  /'
} > patches/60-cilium-inline.yaml
# talstomize expands every ${VAR} from the environment and has no escape syntax.
# The sed above rewrites shell-style "${VAR}/" to the equivalent "$VAR/"; fail if anything is left.
if grep -n '\${' patches/60-cilium-inline.yaml; then
  echo "ERROR: \${...} left in the manifest; talstomize build would fail" >&2
  exit 1
fi
# This file is committed to a public repo: it must not contain generated secrets.
if grep -nE '^  kind: Secret|\.key:' patches/60-cilium-inline.yaml; then
  echo "ERROR: the manifest contains a Secret or private key; do not commit it" >&2
  exit 1
fi
