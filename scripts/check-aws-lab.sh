#!/usr/bin/env bash
set -u

OUT="aws-lab-resources.txt"
: > "$OUT"

capture() {
  echo >> "$OUT"
  echo "===== $1 =====" >> "$OUT"
  shift
  "$@" >> "$OUT" 2>&1 || true
}

capture "IDENTIDADE" aws sts get-caller-identity
capture "EKS" aws eks list-clusters
capture "EC2 ATIVAS" aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name,IP:PublicIpAddress}' --output table
capture "LOAD BALANCERS" aws elbv2 describe-load-balancers --query 'LoadBalancers[].{Name:LoadBalancerName,Type:Type,DNS:DNSName}' --output table
capture "NAT GATEWAYS" aws ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'NatGateways[].{Id:NatGatewayId,State:State}' --output table
echo "Relatorio gerado: $OUT"
