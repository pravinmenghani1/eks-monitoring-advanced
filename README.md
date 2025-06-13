# EKS Monitoring Advanced

This repository provides scripts and configurations to set up an Amazon EKS cluster with comprehensive monitoring using Prometheus and Grafana.

## Features

- EKS cluster with Kubernetes v1.31
- Complete node and pod monitoring
- Prometheus for metrics collection
- Grafana for visualization
- kube-state-metrics for Kubernetes state monitoring
- node-exporter for detailed node metrics

## Prerequisites

1. AWS CLI installed and configured with appropriate permissions
2. kubectl installed
3. An EC2 key pair for SSH access to the monitoring instance

## Quick Start

1. Clone this repository:
   ```
   git clone https://github.com/pravinmenghani1/eks-monitoring-advanced.git
   cd eks-monitoring-advanced/scripts
   ```

2. Make the scripts executable:
   ```
   chmod +x setup-eks-cluster.sh setup-monitoring.sh cleanup.sh
   ```

3. Set up the EKS cluster:
   ```
   ./setup-eks-cluster.sh [region] [cluster-name] [key-pair-name]
   ```
   
   Example:
   ```
   ./setup-eks-cluster.sh us-east-1 eks-monitoring eks
   ```

4. Set up monitoring (using the output from the previous step):
   ```
   ./setup-monitoring.sh [region] [cluster-name] [key-pair-name] [vpc-id] [subnet-id]
   ```
   
   Example:
   ```
   ./setup-monitoring.sh us-east-1 eks-monitoring eks vpc-1234567890abcdef0 subnet-1234567890abcdef0
   ```

## Monitoring Components

### External Monitoring (EC2 Instance)
- **Prometheus**: Collects and stores metrics
- **Grafana**: Visualizes metrics with dashboards
- **Node Exporter**: Collects host-level metrics from the monitoring instance

### Kubernetes Monitoring
- **kube-state-metrics**: Collects Kubernetes state metrics
- **Node Exporter DaemonSet**: Collects metrics from all EKS nodes
- **Prometheus Annotations**: Enables pod-level metrics collection

## Accessing Monitoring

After deployment completes, you'll see output with:
- **Prometheus URL**: http://[monitoring-instance-public-ip]:9090
- **Grafana URL**: http://[monitoring-instance-public-ip]:3000 (login: admin/admin)

## What's Being Monitored

1. **Node Metrics**:
   - CPU, memory, disk usage
   - Network traffic
   - System load

2. **Kubernetes Metrics**:
   - Pod status and resource usage
   - Deployment status
   - Node status
   - API server performance

3. **Application Metrics**:
   - Any pod with `prometheus.io/scrape: "true"` annotation

## Cleanup

When you're finished, run the cleanup script:

```
./cleanup.sh [cluster-name] [instance-id] [region] [vpc-id]
```

Example:
```
./cleanup.sh eks-monitoring i-1234567890abcdef0 us-east-1 vpc-1234567890abcdef0
```

## Customization

- To monitor additional applications, add Prometheus annotations to your deployments:
  ```yaml
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"  # Port where metrics are exposed
  ```

- To add custom Grafana dashboards, import them through the Grafana UI