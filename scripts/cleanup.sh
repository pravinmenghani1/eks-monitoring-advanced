#!/bin/bash
set -e

CLUSTER_NAME=${1:-eks-monitoring}
INSTANCE_ID=${2}
REGION=${3:-us-east-1}
VPC_ID=${4}

echo "EKS Monitoring - Cleanup"
echo "------------------------"
echo "Cleaning up resources for cluster: $CLUSTER_NAME"
echo "Region: $REGION"

# Terminate EC2 instance if provided
if [ ! -z "$INSTANCE_ID" ]; then
  echo "Terminating monitoring instance..."
  aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID --region $REGION
fi

# Delete node group
echo "Deleting node group..."
aws eks delete-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name $CLUSTER_NAME-nodes \
  --region $REGION 2>/dev/null || true

echo "Waiting for node group to be deleted..."
aws eks wait nodegroup-deleted \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name $CLUSTER_NAME-nodes \
  --region $REGION 2>/dev/null || true

# Delete EKS cluster
echo "Deleting EKS cluster..."
aws eks delete-cluster --name $CLUSTER_NAME --region $REGION 2>/dev/null || true

echo "Waiting for cluster to be deleted..."
aws eks wait cluster-deleted --name $CLUSTER_NAME --region $REGION 2>/dev/null || true

# Clean up IAM roles
echo "Cleaning up IAM roles..."
aws iam detach-role-policy --role-name eksClusterRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy 2>/dev/null || true
aws iam delete-role --role-name eksClusterRole 2>/dev/null || true

aws iam detach-role-policy --role-name eksNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy 2>/dev/null || true
aws iam detach-role-policy --role-name eksNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy 2>/dev/null || true
aws iam detach-role-policy --role-name eksNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly 2>/dev/null || true
aws iam delete-role --role-name eksNodeRole 2>/dev/null || true

aws iam remove-role-from-instance-profile --instance-profile-name monitoring-profile --role-name monitoring-role 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name monitoring-profile 2>/dev/null || true
aws iam delete-role-policy --role-name monitoring-role --policy-name eks-access 2>/dev/null || true
aws iam delete-role --role-name monitoring-role 2>/dev/null || true

# Clean up VPC resources if VPC_ID is provided
if [ ! -z "$VPC_ID" ]; then
  echo "Cleaning up VPC resources..."
  
  # Get all subnets in the VPC
  SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[*].SubnetId" \
    --output text)
  
  # Get all route tables associated with the VPC
  ROUTE_TABLES=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[*].RouteTableId" \
    --output text)
  
  # Get all security groups in the VPC
  SECURITY_GROUPS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text)
  
  # Get internet gateway for the VPC
  IGW_ID=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query "InternetGateways[*].InternetGatewayId" \
    --output text)
  
  # Delete all security groups (except default)
  for SG_ID in $SECURITY_GROUPS; do
    echo "Deleting security group $SG_ID..."
    aws ec2 delete-security-group --group-id $SG_ID 2>/dev/null || true
  done
  
  # Delete all subnets
  for SUBNET_ID in $SUBNETS; do
    echo "Deleting subnet $SUBNET_ID..."
    aws ec2 delete-subnet --subnet-id $SUBNET_ID 2>/dev/null || true
  done
  
  # Delete all non-main route tables
  for RT_ID in $ROUTE_TABLES; do
    # Check if it's the main route table
    IS_MAIN=$(aws ec2 describe-route-tables \
      --route-table-id $RT_ID \
      --query "RouteTables[*].Associations[?Main==\`true\`]" \
      --output text)
    
    if [ -z "$IS_MAIN" ]; then
      echo "Deleting route table $RT_ID..."
      aws ec2 delete-route-table --route-table-id $RT_ID 2>/dev/null || true
    fi
  done
  
  # Detach and delete internet gateway
  if [ ! -z "$IGW_ID" ]; then
    echo "Detaching and deleting internet gateway $IGW_ID..."
    aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID 2>/dev/null || true
  fi
  
  # Delete VPC
  echo "Deleting VPC $VPC_ID..."
  aws ec2 delete-vpc --vpc-id $VPC_ID 2>/dev/null || true
fi

echo "Cleanup complete!"