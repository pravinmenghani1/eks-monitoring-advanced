#!/bin/bash
set -e

echo "EKS Monitoring Advanced Setup"
echo "----------------------------"

# Check for AWS CLI
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed. Please install it first."
    exit 1
fi

# Set variables
REGION=${1:-us-east-1}
CLUSTER_NAME=${2:-eks-monitoring}
KEY_NAME=${3:-eks}

echo "Using the following configuration:"
echo "Region: $REGION"
echo "Cluster Name: $CLUSTER_NAME"
echo "Key Pair: $KEY_NAME"
echo ""

# Get recommended availability zones for EKS
echo "Finding recommended availability zones for EKS..."
if [ "$REGION" == "us-east-1" ]; then
    # Hardcode recommended AZs for us-east-1 to avoid e zone
    AZ1="us-east-1a"
    AZ2="us-east-1b"
else
    # For other regions, get first two AZs
    AZ1=$(aws ec2 describe-availability-zones \
        --region $REGION \
        --query 'AvailabilityZones[0].ZoneName' \
        --output text)
    AZ2=$(aws ec2 describe-availability-zones \
        --region $REGION \
        --query 'AvailabilityZones[1].ZoneName' \
        --output text)
fi

echo "Using availability zones: $AZ1, $AZ2"

# Create VPC
echo "Creating VPC for EKS..."
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block 10.0.0.0/16 \
    --region $REGION \
    --query Vpc.VpcId \
    --output text)

# Add name tag to VPC
aws ec2 create-tags \
    --resources $VPC_ID \
    --tags Key=Name,Value=$CLUSTER_NAME-vpc

# Enable DNS hostnames
aws ec2 modify-vpc-attribute \
    --vpc-id $VPC_ID \
    --enable-dns-hostnames

# Create subnets
echo "Creating subnets..."
SUBNET1_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block 10.0.1.0/24 \
    --availability-zone $AZ1 \
    --region $REGION \
    --query Subnet.SubnetId \
    --output text)

SUBNET2_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block 10.0.2.0/24 \
    --availability-zone $AZ2 \
    --region $REGION \
    --query Subnet.SubnetId \
    --output text)

# Add name tags to subnets
aws ec2 create-tags \
    --resources $SUBNET1_ID \
    --tags Key=Name,Value=$CLUSTER_NAME-subnet-1

aws ec2 create-tags \
    --resources $SUBNET2_ID \
    --tags Key=Name,Value=$CLUSTER_NAME-subnet-2

# Create Internet Gateway
echo "Creating Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway \
    --region $REGION \
    --query InternetGateway.InternetGatewayId \
    --output text)

# Add name tag to IGW
aws ec2 create-tags \
    --resources $IGW_ID \
    --tags Key=Name,Value=$CLUSTER_NAME-igw

# Attach IGW to VPC
aws ec2 attach-internet-gateway \
    --internet-gateway-id $IGW_ID \
    --vpc-id $VPC_ID \
    --region $REGION

# Create route table
ROUTE_TABLE_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --region $REGION \
    --query RouteTable.RouteTableId \
    --output text)

# Add name tag to route table
aws ec2 create-tags \
    --resources $ROUTE_TABLE_ID \
    --tags Key=Name,Value=$CLUSTER_NAME-rtb

# Create route to IGW
aws ec2 create-route \
    --route-table-id $ROUTE_TABLE_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $IGW_ID \
    --region $REGION

# Associate route table with subnets
aws ec2 associate-route-table \
    --route-table-id $ROUTE_TABLE_ID \
    --subnet-id $SUBNET1_ID \
    --region $REGION

aws ec2 associate-route-table \
    --route-table-id $ROUTE_TABLE_ID \
    --subnet-id $SUBNET2_ID \
    --region $REGION

# Enable auto-assign public IP on subnets
aws ec2 modify-subnet-attribute \
    --subnet-id $SUBNET1_ID \
    --map-public-ip-on-launch

aws ec2 modify-subnet-attribute \
    --subnet-id $SUBNET2_ID \
    --map-public-ip-on-launch

# Create EKS cluster
echo "Creating EKS cluster (this will take about 15 minutes)..."
aws eks create-cluster \
  --region $REGION \
  --name $CLUSTER_NAME \
  --kubernetes-version 1.31 \
  --role-arn $(aws iam get-role --role-name eksClusterRole --query Role.Arn --output text 2>/dev/null || \
    aws iam create-role \
      --role-name eksClusterRole \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      --query Role.Arn --output text && \
    aws iam attach-role-policy --role-name eksClusterRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy) \
  --resources-vpc-config subnetIds=$SUBNET1_ID,$SUBNET2_ID,securityGroupIds=$(aws ec2 create-security-group \
    --group-name eks-cluster-sg \
    --description "EKS cluster security group" \
    --vpc-id $VPC_ID \
    --query GroupId --output text)

# Wait for cluster to be active
echo "Waiting for EKS cluster to become active..."
aws eks wait cluster-active --name $CLUSTER_NAME --region $REGION

# Configure kubectl
echo "Configuring kubectl..."
aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME

# Create node group
echo "Creating node group..."
NODE_ROLE_ARN=$(aws iam get-role --role-name eksNodeRole --query Role.Arn --output text 2>/dev/null || \
  aws iam create-role \
    --role-name eksNodeRole \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --query Role.Arn --output text && \
  aws iam attach-role-policy --role-name eksNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy && \
  aws iam attach-role-policy --role-name eksNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy && \
  aws iam attach-role-policy --role-name eksNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly)

aws eks create-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name $CLUSTER_NAME-nodes \
  --node-role $NODE_ROLE_ARN \
  --subnets $SUBNET1_ID $SUBNET2_ID \
  --scaling-config minSize=2,maxSize=2,desiredSize=2 \
  --instance-types t3.small \
  --region $REGION

# Wait for node group to be active
echo "Waiting for node group to become active..."
aws eks wait nodegroup-active --cluster-name $CLUSTER_NAME --nodegroup-name $CLUSTER_NAME-nodes --region $REGION

# Deploy sample application with Prometheus annotations
echo "Deploying sample application with Prometheus annotations..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "80"
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
EOF

echo "EKS cluster setup complete!"
echo "Cluster Name: $CLUSTER_NAME"
echo "Region: $REGION"
echo "VPC ID: $VPC_ID"
echo ""
echo "To set up monitoring, run:"
echo "./setup-monitoring.sh $REGION $CLUSTER_NAME $KEY_NAME $VPC_ID $SUBNET1_ID"