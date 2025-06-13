#!/bin/bash
set -e

echo "EKS Monitoring - Setting up Prometheus and Grafana"
echo "------------------------------------------------"

# Check for AWS CLI
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed. Please install it first."
    exit 1
fi

# Set variables
REGION=${1:-us-east-1}
CLUSTER_NAME=${2:-eks-monitoring}
KEY_NAME=${3:-eks}
VPC_ID=${4}
SUBNET_ID=${5}

if [ -z "$VPC_ID" ] || [ -z "$SUBNET_ID" ]; then
    echo "Error: VPC_ID and SUBNET_ID are required."
    echo "Usage: $0 REGION CLUSTER_NAME KEY_NAME VPC_ID SUBNET_ID"
    exit 1
fi

echo "Using the following configuration:"
echo "Region: $REGION"
echo "Cluster Name: $CLUSTER_NAME"
echo "Key Pair: $KEY_NAME"
echo "VPC ID: $VPC_ID"
echo "Subnet ID: $SUBNET_ID"
echo ""

# Deploy kube-state-metrics to the cluster
echo "Deploying kube-state-metrics..."
kubectl apply -f ../kubernetes/kube-state-metrics.yaml

# Create security group for monitoring
echo "Creating security group for monitoring..."
MONITORING_SG=$(aws ec2 create-security-group \
  --group-name monitoring-sg \
  --description "Security group for monitoring instance" \
  --vpc-id $VPC_ID \
  --query GroupId \
  --output text)

# Allow SSH, Prometheus and Grafana access
aws ec2 authorize-security-group-ingress \
  --group-id $MONITORING_SG \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
  --group-id $MONITORING_SG \
  --protocol tcp \
  --port 9090 \
  --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
  --group-id $MONITORING_SG \
  --protocol tcp \
  --port 3000 \
  --cidr 0.0.0.0/0

# Create IAM role for monitoring
echo "Creating IAM role for monitoring..."
MONITORING_ROLE=$(aws iam get-role --role-name monitoring-role --query Role.Arn --output text 2>/dev/null || \
  aws iam create-role \
    --role-name monitoring-role \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --query Role.Arn --output text && \
  aws iam put-role-policy \
    --role-name monitoring-role \
    --policy-name eks-access \
    --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["eks:DescribeCluster","eks:ListClusters"],"Resource":"*"}]}')

# Create instance profile
PROFILE_NAME="monitoring-profile"
aws iam create-instance-profile --instance-profile-name $PROFILE_NAME 2>/dev/null || true
aws iam add-role-to-instance-profile --instance-profile-name $PROFILE_NAME --role-name monitoring-role 2>/dev/null || true

# Wait for instance profile to propagate
echo "Waiting for IAM instance profile to propagate..."
sleep 15

# Get latest Amazon Linux 2023 AMI
echo "Finding latest Amazon Linux 2023 AMI..."
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)

# Create user data script
echo "Creating user data script..."
cat > monitoring-userdata.sh << EOT
#!/bin/bash
# Update system
dnf update -y
dnf install -y wget git jq

# Install Prometheus
wget https://github.com/prometheus/prometheus/releases/download/v2.45.0/prometheus-2.45.0.linux-amd64.tar.gz
tar xzf prometheus-2.45.0.linux-amd64.tar.gz
mv prometheus-2.45.0.linux-amd64/prometheus /usr/local/bin/
mv prometheus-2.45.0.linux-amd64/promtool /usr/local/bin/
mkdir -p /etc/prometheus
mkdir -p /var/lib/prometheus

# Install node_exporter
wget https://github.com/prometheus/node_exporter/releases/download/v1.6.1/node_exporter-1.6.1.linux-amd64.tar.gz
tar xzf node_exporter-1.6.1.linux-amd64.tar.gz
mv node_exporter-1.6.1.linux-amd64/node_exporter /usr/local/bin/

# Create node_exporter service
cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Install Grafana
cat > /etc/yum.repos.d/grafana.repo << 'EOF'
[grafana]
name=grafana
baseurl=https://packages.grafana.com/oss/rpm
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://packages.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF

dnf install -y grafana

# Install kubectl
curl -LO "https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/

# Install AWS CLI
dnf install -y unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install

# Configure kubectl for EKS
aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME}

# Create RBAC for Prometheus
cat > prometheus-rbac.yaml << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus-monitor
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus-role
rules:
- apiGroups: [""]
  resources: ["nodes", "nodes/proxy", "services", "endpoints", "pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions", "apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["pods", "nodes"]
  verbs: ["get", "list", "watch"]
EOF

kubectl apply -f prometheus-rbac.yaml --validate=false

# Wait for token to be created
sleep 10

# Get token and certificate
TOKEN=\$(kubectl get secret -n kube-system \$(kubectl get serviceaccount prometheus-monitor -n kube-system -o jsonpath='{.secrets[0].name}') -o jsonpath='{.data.token}' | base64 --decode)
CA_CERT=\$(kubectl get secret -n kube-system \$(kubectl get serviceaccount prometheus-monitor -n kube-system -o jsonpath='{.secrets[0].name}') -o jsonpath='{.data.ca\.crt}')
CLUSTER_ENDPOINT=\$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

# Save token and certificate
echo "\$TOKEN" > /etc/prometheus/k8s-token
echo "\$CA_CERT" | base64 --decode > /etc/prometheus/ca.crt

# Create Prometheus configuration
cat > /etc/prometheus/prometheus.yml << EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
  
  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
      
  - job_name: 'kubernetes-api'
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/ca.crt
      insecure_skip_verify: true
    bearer_token_file: /etc/prometheus/k8s-token
    static_configs:
      - targets: ['\${CLUSTER_ENDPOINT#https://}']
  
  - job_name: 'kubernetes-nodes'
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/ca.crt
      insecure_skip_verify: true
    bearer_token_file: /etc/prometheus/k8s-token
    kubernetes_sd_configs:
    - role: node
      api_server: \${CLUSTER_ENDPOINT}
      tls_config:
        ca_file: /etc/prometheus/ca.crt
        insecure_skip_verify: true
      bearer_token_file: /etc/prometheus/k8s-token
    relabel_configs:
    - action: labelmap
      regex: __meta_kubernetes_node_label_(.+)
    - target_label: __address__
      replacement: \${CLUSTER_ENDPOINT#https://}
    - source_labels: [__meta_kubernetes_node_name]
      regex: (.+)
      target_label: __metrics_path__
      replacement: /api/v1/nodes/\\\${1}/proxy/metrics
      
  - job_name: 'kubernetes-pods'
    kubernetes_sd_configs:
    - role: pod
      api_server: \${CLUSTER_ENDPOINT}
      tls_config:
        ca_file: /etc/prometheus/ca.crt
        insecure_skip_verify: true
      bearer_token_file: /etc/prometheus/k8s-token
    bearer_token_file: /etc/prometheus/k8s-token
    tls_config:
      ca_file: /etc/prometheus/ca.crt
      insecure_skip_verify: true
    relabel_configs:
    - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
      action: keep
      regex: true
    - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
      action: replace
      target_label: __metrics_path__
      regex: (.+)
    - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
      action: replace
      regex: ([^:]+)(?::\d+)?;(\d+)
      replacement: \$1:\$2
      target_label: __address__
      
  - job_name: 'kubernetes-state-metrics'
    kubernetes_sd_configs:
    - role: endpoints
      namespaces:
        names:
        - kube-system
      api_server: \${CLUSTER_ENDPOINT}
      tls_config:
        ca_file: /etc/prometheus/ca.crt
        insecure_skip_verify: true
      bearer_token_file: /etc/prometheus/k8s-token
    bearer_token_file: /etc/prometheus/k8s-token
    tls_config:
      ca_file: /etc/prometheus/ca.crt
      insecure_skip_verify: true
    relabel_configs:
    - source_labels: [__meta_kubernetes_service_name]
      action: keep
      regex: kube-state-metrics
    - action: labelmap
      regex: __meta_kubernetes_service_label_(.+)
EOF

# Create Prometheus service
cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=root
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus/
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Start services
systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter
systemctl enable prometheus
systemctl start prometheus
systemctl enable grafana-server
systemctl start grafana-server

# Configure Grafana with Prometheus data source
sleep 10
curl -s -X POST -H "Content-Type: application/json" -d '{
  "name":"Prometheus",
  "type":"prometheus",
  "url":"http://localhost:9090",
  "access":"proxy",
  "isDefault":true
}' http://admin:admin@localhost:3000/api/datasources

# Import Node Exporter dashboard
curl -s -X POST -H "Content-Type: application/json" -d '{
  "dashboard": {
    "id": null,
    "title": "Node Exporter Dashboard",
    "tags": ["node"],
    "timezone": "browser",
    "schemaVersion": 16,
    "version": 0
  },
  "folderId": 0,
  "overwrite": false
}' http://admin:admin@localhost:3000/api/dashboards/db

# Import Kubernetes dashboard
curl -s -X POST -H "Content-Type: application/json" -d '{
  "dashboard": {
    "id": null,
    "title": "Kubernetes Cluster",
    "tags": ["kubernetes"],
    "timezone": "browser",
    "schemaVersion": 16,
    "version": 0
  },
  "folderId": 0,
  "overwrite": false
}' http://admin:admin@localhost:3000/api/dashboards/db

# Print completion message
echo "Monitoring setup complete!"
echo "Prometheus URL: http://\$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):9090"
echo "Grafana URL: http://\$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):3000 (login: admin/admin)"
EOT

# Launch EC2 instance
echo "Launching monitoring instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t2.micro \
  --key-name $KEY_NAME \
  --security-group-ids $MONITORING_SG \
  --subnet-id $SUBNET_ID \
  --user-data file://monitoring-userdata.sh \
  --iam-instance-profile Arn=$(aws iam get-instance-profile --instance-profile-name $PROFILE_NAME --query "InstanceProfile.Arn" --output text) \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Waiting for monitoring instance to be running..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo ""
echo "Monitoring setup complete!"
echo "----------------------------"
echo "EKS Cluster: $CLUSTER_NAME (Kubernetes v1.31)"
echo "Monitoring Instance: $PUBLIC_IP"
echo ""
echo "Prometheus URL: http://$PUBLIC_IP:9090"
echo "Grafana URL: http://$PUBLIC_IP:3000 (login: admin/admin)"
echo ""
echo "To check your pods:"
echo "kubectl get pods"
echo ""
echo "To clean up when you're done, run:"
echo "./cleanup.sh $CLUSTER_NAME $INSTANCE_ID $REGION $VPC_ID"