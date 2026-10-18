#!/usr/bin/env bash
set -u

OUT="diagnostics.txt"
{
  date
  kubectl get nodes -o wide
  kubectl get pods -A -o wide
  kubectl get svc -A
  kubectl get events -A --sort-by=.lastTimestamp
} > "$OUT" 2>&1

echo "Relatorio gerado em $OUT"
