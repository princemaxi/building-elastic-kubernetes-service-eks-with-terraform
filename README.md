# 🚀 Building Amazon Elastic Kubernetes Service with Terraform & Deploying Applications with Helm

## 📌 Project Overview

This project demonstrates how to provision a fully functional Amazon EKS (Elastic Kubernetes Service) cluster using Terraform, and deploy applications using Helm.

It covers:

- Infrastructure provisioning with Terraform
- Remote state management using S3
- VPC and networking setup
- EKS cluster deployment
- Fixing common Terraform + Kubernetes integration issues
- Deploying applications using Helm (including Jenkins)

## ⚙️ Technology Stack & Versions
| Tool         | Version Requirement |
| ------------ | ------------------- |
| Terraform    | >= 1.5              |
| AWS Provider | ~> 5.0              |
| EKS Module   | ~> 20.0             |
| Kubernetes   | 1.28                |
| Docker       | Docker Hub          |

⚠️ These versions ensure compatibility with the latest AWS and Terraform features.

## Step-by-Step Implementation

## 🚀 Phase 1: Provisioning Amazon EKS with Terraform
### 📌 Overview

This phase focuses on provisioning a fully functional Amazon Elastic Kubernetes Service (EKS) cluster using Terraform with modern best practices.

We implement:

- Remote state management using S3
- A highly available VPC architecture
- Managed Kubernetes control plane (EKS)
- Managed node groups (no deprecated self-managed nodes)
- Secure and simplified authentication

### 🧱 Project Structure

The project is organized into modular Terraform configuration files for clarity and scalability.

```
eks/
├── backend.tf          # Remote state configuration (S3)
├── provider.tf         # AWS provider configuration
├── variables.tf        # Input variables
├── terraform.tfvars    # Variable values
├── network.tf          # VPC and networking resources
├── data.tf             # AWS data sources
├── eks.tf              # EKS cluster configuration
├── locals.tf           # Local values (optional/future use)
```

```bash
mkdir eks
cd eks
```

![alt text](/images/1.png)

### 1.0 Versioning (version.tf)
```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```
![alt text](/images/2.png)

### 1.1 🪣 Remote State Management (S3 Backend)

Terraform state is stored remotely in an S3 bucket to enable:

- Team collaboration
- State locking (when DynamoDB is added later)
- Version control of infrastructure

#### Create S3 Bucket
```bash
aws s3 mb s3://steghub-eks-terraform-state
```

#### Enable Versioning (Optional)

```bash
aws s3api put-bucket-versioning \
  --bucket steghub-eks-terraform-state \
  --versioning-configuration Status=Enabled
```

#### Create DynamoDB Table (for State Locking)
```bash
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-west-1
```

✅ What this does:
- Creates a table called terraform-locks
- Uses LockID as the primary key (required by Terraform)
- Uses on-demand billing (no capacity planning needed)

![alt text](/images/10.png)

### 1.2 Backend Configuration (backend.tf)
```hcl
terraform {
  backend "s3" {
    bucket         = "steghub-eks-terraform-state"
    key            = "eks/terraform.tfstate"
    region         = "eu-west-2"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

![alt text](/images/3.png)

### 1.3 🌍 AWS Provider Configuration (provider.tf)

Defines the AWS region where all resources will be deployed.

```hcl
provider "aws" {
  region = "eu-west-2"
}
```
![alt text](/images/4.png)

### 1.4 📡 Data Sources (data.tf)

Used to dynamically fetch AWS environment details.

```hcl
data "aws_availability_zones" "available" {}

data "aws_caller_identity" "current" {}
```
![alt text](/images/5.png)

#### Purpose:

- Availability zones → distribute infrastructure for high availability
- Caller identity → useful for account-aware configurations

### 1.5 🌐 Networking (network.tf)

We use the official Terraform VPC module to create a production-ready network.

#### Key Features
- Custom CIDR block
- Public and private subnets
- NAT Gateway for outbound internet access
- DNS support enabled
- Kubernetes-compatible subnet tagging
- Allocates a static IP for NAT Gateway

```hcl
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-nat-eip"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.name_prefix}-vpc"
  cidr = var.main_network_block

  azs = data.aws_availability_zones.available.names

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  reuse_nat_ips       = true
  external_nat_ip_ids = [aws_eip.nat.id]

  enable_dns_hostnames = true

  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}
```
![alt text](/images/6.png)

#### Subnet Design
| Subnet Type | Purpose               |
| ----------- | --------------------- |
| Public      | Load balancers        |
| Private     | Worker nodes (secure) |

#### Kubernetes Tagging

```hcl
"kubernetes.io/cluster/${var.cluster_name}" = "shared"
```
This allows Kubernetes to automatically discover AWS resources.

### 1.6 ☸️ EKS Cluster Configuration (eks.tf)

We use the official EKS Terraform module with modern features.

Key Improvements Over Older Setups

- ✅ Managed Node Groups (no EC2 manual setup)
- ✅ Simplified authentication
- ✅ Reduced operational overhead

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.29"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_irsa = true

  cluster_endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]

      min_size     = 2
      max_size     = 5
      desired_size = 2

      capacity_type = "ON_DEMAND"

      ami_type = "AL2023_x86_64_STANDARD"
    }
  }

  tags = {
    Environment = var.iac_environment_tag
  }
}
```
![alt text](/images/7.png)

### 1.7 🧮 Variables 

#### variables.tf
Defines reusable inputs:
```hcl
variable "cluster_name" {
  type = string
}

variable "iac_environment_tag" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "main_network_block" {
  type = string
}
```
![alt text](/images/8.png)

#### terraform.tfvars

Provides actual values:
```hcl
cluster_name        = "tooling-app-eks"
iac_environment_tag = "dev"
name_prefix         = "steghub"
main_network_block  = "10.0.0.0/16"
```
![alt text](/images/9.png)

### 1.8 🔄 Deployment Steps

#### 1. Initialize Terraform
```bash
terraform init
```

![alt text](/images/11.png)

#### 2. Review Execution Plan
```bash
terraform plan
```

Expected: `Plan: ~30–55 resources to add`


#### 3. Apply Configuration
```bash
terraform apply
```
Confirm when prompted:

`yes`

`⏳ Provisioning time: 10–15 minutes`

![alt text](/images/12.png)

### 1.9 🔑 Connect to the Cluster

After successful deployment:
```bash
aws eks update-kubeconfig \
  --name tooling-app-eks \
  --region eu-west-2
```

![alt text](/images/13.png)

#### ✅ Validation

Check if worker nodes are running:
```bash
kubectl get nodes
```

Expected output: `2 nodes in Ready state`

![alt text](/images/14.png)

## 🎯 Outcome

At the end of this phase, you will have:

- ✅ A production-ready VPC
- ✅ A fully managed EKS cluster
- ✅ Auto-scaling worker nodes
- ✅ Secure and simplified access configuration
- ✅ Infrastructure defined as code (IaC)

---

## 🚀 Phase 2: Application Deployment with Helm

### 📌 Overview

In this phase, we deploy a containerized application to our Kubernetes cluster using Helm, the industry-standard package manager for Kubernetes.

#### Helm enables:

- Reusable deployment templates
- Version-controlled application releases
- Simplified upgrades and rollbacks
- Consistent multi-environment deployments

### 🎯 Objectives
- Install and configure Helm
- Create a custom Helm chart
- Template Kubernetes manifests dynamically
- Deploy application to EKS cluster
- Perform upgrades and rollbacks

### ✅ Prerequisites

Before proceeding, ensure you have:

- A running Kubernetes cluster (e.g., Amazon EKS from Phase 1)
- kubectl configured and connected
- A Docker image pushed to a registry (e.g., Docker Hub)

### 🧩 2.1 Install Helm

Helm is installed using the official script (recommended method):
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

#### Verify Installation
```bash
helm version
```

Expected output: `version.BuildInfo{Version:"v3.x.x", ...}`

![alt text](/images/15.png)

### 📁 2.2 Create a Helm Chart

Generate a new Helm chart:
```bash
helm create tooling-app
```

![alt text](/images/16.png)

#### Generated Structure
```
tooling-app/
├── Chart.yaml        # Chart metadata
├── values.yaml       # Default configuration values
├── templates/        # Kubernetes manifest templates
└── charts/           # Dependencies (if any)
```

### 🧹 2.3 Clean Up Default Templates

Navigate to templates directory:
```bash
cd tooling-app/templates
```

#### Remove unused files:
```bash
rm -rf tests NOTES.txt hpa.yaml ingress.yaml serviceaccount.yaml
```

**Keep Only:**
- deployment.yaml
- service.yaml
- _helpers.tpl

🧠 This ensures a minimal, clean chart tailored to your application.

### ⚙️ 2.4 Configure values.yaml

Update application configuration:

```yaml
replicaCount: 3

image:
  repository: your-dockerhub-username/tooling-app
  tag: "1.0.0"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80

containerPort: 80
```

![alt text](/images/17.png)

#### Key Concepts
| Field            | Purpose                   |
| ---------------- | ------------------------- |
| replicaCount     | Number of pod replicas    |
| image.repository | Docker image location     |
| image.tag        | Version of the app        |
| service.type     | Kubernetes service type   |
| containerPort    | Port exposed by container |

### 🧠 2.5 Update Deployment Template

#### Edit:
```bash
nano templates/deployment.yaml
```

#### Replace with:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-deployment
  labels:
    app: {{ include "tooling-app.name" . }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ include "tooling-app.name" . }}
  template:
    metadata:
      labels:
        app: {{ include "tooling-app.name" . }}
    spec:
      containers:
        - name: {{ include "tooling-app.name" . }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.containerPort }}
```

#### 💡 What This Does
- Uses Helm templating ({{ }}) to inject dynamic values
- Makes deployments reusable across environments
- Enables version-based upgrades

### 🌐 2.6 Update Service Template

#### Edit:
```bash
nano templates/service.yaml
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-service
spec:
  type: {{ .Values.service.type }}
  selector:
    app: {{ include "tooling-app.name" . }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.containerPort }}
```

### 🔧 2.7 Fix Helper Template
#### Edit:
```bash
nano templates/_helpers.tpl
```

#### Ensure:
```yaml
{{- define "tooling-app.name" -}}
tooling-app
{{- end -}}
```

### 🧪 2.8 Validate Helm Chart
```bash
helm lint .
```
✔️ Checks for syntax and best practice issues

![alt text](/images/18.png)

### 👀 2.9 Dry Run (Preview Deployment)
```bash
helm install tooling-release . --dry-run --debug
```
![alt text](/images/19.png)

- ✔️ Simulates deployment without applying changes
- ✔️ Helps catch errors early

### 🚀 2.10 Deploy Application
```bash
helm install tooling-release .
```
This creates a Helm release named tooling-release.

### 🔍 2.11 Verify Deployment
```bash
kubectl get pods
kubectl get svc
helm list
```

![alt text](/images/20.png)

#### Expected Outcome
- Pods running successfully
- Service created
- Helm release listed

### 🔄 2.12 Upgrade Application

Update image version in `values.yaml`:
```yaml
tag: "1.1.0"
```
![alt text](/images/21.png)

Apply upgrade:
```bash
helm upgrade tooling-release .
```

![alt text](/images/22.png)

🔁 Helm performs rolling updates automatically.

### ❌ 2.13 Rollback Deployment

If something breaks:
```bash
helm rollback tooling-release 1
```
✔️ Restores previous working version instantly

### 🗑️ 2.14 Uninstall Application
```bash
helm uninstall tooling-release
```
✔️ Removes all Kubernetes resources created by the chart

## 🎯 Outcome

At the end of this phase, you will have:

- ✅ A reusable Helm chart
- ✅ A deployed application on Kubernetes
- ✅ Version-controlled deployments
- ✅ Ability to upgrade and rollback safely
- ✅ Production-ready deployment workflow

## 🔥 Key DevOps Takeaways
- Helm abstracts Kubernetes complexity
- Infrastructure and applications are fully codified
- Deployments become repeatable and predictable
- Rollbacks reduce downtime risk significantly

---

## 🚀 Phase 3: CI/CD Setup with Jenkins on Kubernetes (Helm)
### 📌 Overview

In this final phase, we deploy Jenkins on our Kubernetes cluster using Helm to establish a foundation for CI/CD pipelines.

This phase demonstrates:

- Deploying Jenkins via Helm
- Accessing and configuring Jenkins securely
- Understanding multi-container pods
- Debugging real-world Kubernetes access and 
security issues

### 🎯 Objectives
- Install Jenkins using Helm charts
- Access Jenkins securely
- Understand Kubernetes pod architecture
- Troubleshoot authentication and access issues
- Prepare for CI/CD pipeline integration

### ✅ Prerequisites

Ensure the following are available:

- Running Kubernetes cluster (EKS from Phase 1)
- Helm installed (from Phase 2)
- kubectl configured and connected
- Proper AWS IAM permissions

### 🚀 3.1 Add Jenkins Helm Repository
```bash
helm repo add jenkins https://charts.jenkins.io
```

### 🔄 3.2 Update Helm Repositories
```bash
helm repo update
```

### 🔍 3.3 Search for Jenkins Chart (Optional)
```bash
helm search repo jenkins
```

Expected output: `jenkins/jenkins`

![alt text](/images/23.png)

### 🚀 3.4 Install Jenkins
```bash
helm install jenkins jenkins/jenkins
```
#### 📦 What This Does
- Creates a Helm release named jenkins
- Deploys:
  - Jenkins controller pod
  - Kubernetes services
  - Persistent Volume Claims (PVCs)
  - Required configurations

### 🔍 3.5 Verify Deployment

#### Check Helm Release
```bash
helm list
```

![alt text](/images/24.png)

#### Check Pods
```bash
kubectl get pods
```

![alt text](/images/25.png)

#### Expected: `jenkins-0   2/2   Running`

#### Check Services
```bash
kubectl get svc
```

### 🔐 3.6 Retrieve Admin Password
```bash
kubectl exec -it svc/jenkins -c jenkins -- cat /run/secrets/additional/chart-admin-password
```

### 🌐 3.7 Access Jenkins UI

#### Use port forwarding:
```bash
kubectl port-forward svc/jenkins 8080:8080
```
![alt text](/images/26.png)

#### Open in browser:
```
http://localhost:8080
```

#### Login Credentials
- Username: `admin`
- Password: Retrieved from above

![alt text](/images/27.png)
![alt text](/images/28.png)

### ⚠️ 3.8 Understanding Multi-Container Pods

Jenkins pods contain multiple containers.
```bash
kubectl logs jenkins-0 -c jenkins
```

#### Containers in Jenkins Pod

| Container     | Purpose                           |
| ------------- | --------------------------------- |
| jenkins       | Main application                  |
| config-reload | Sidecar for configuration updates |


### 🧠 3.9 Inspect Pod Details
```bash
kubectl describe pod jenkins-0
```

#### Useful For:
- Debugging errors
- Viewing events
- Checking mounted volumes
- Understanding container lifecycle

### ⚙️ 3.10 Set Default Kubernetes Context
View Contexts
```bash
kubectl config get-contexts
```
Set Active Context
```bash
kubectl config use-context <your-cluster-name>
```
Confirm
```bash
kubectl config current-context
```

### 🧩 3.11 Verify Persistent Storage
```bash
kubectl get pvc
```

✔️ Confirms Jenkins data persistence

### 🔄 3.12 Upgrade Jenkins Configuration

Example:
```bash
helm upgrade jenkins jenkins/jenkins --set controller.serviceType=ClusterIP
```

### 🗑️ 3.13 Uninstall Jenkins
```bash
helm uninstall jenkins
```

## 🎯 Final Outcome

At the end of this phase, we now have:

- ✅ Jenkins deployed on Kubernetes
- ✅ Secure access to Jenkins UI
- ✅ Persistent storage configured
- ✅ Hands-on troubleshooting experience
- ✅ Foundation for CI/CD pipelines

## 🚀 Project Completion Summary

Across all phases, this project demonstrates:

- Infrastructure provisioning with Terraform
- Kubernetes cluster setup (EKS)
- Application deployment using Helm
- CI/CD tooling integration with Jenkins
- Real-world debugging and problem-solving

---

## 🛠️ Troubleshooting

### 1. Jenkins Pod Stuck in `Pending`

**Symptoms:**

* `kubectl get pods` shows:

  ```
  jenkins-0   0/2   Pending
  ```
* `kubectl describe pod jenkins-0` shows:

  ```
  Node: <none>
  ```

**Cause:**

* Jenkins requires persistent storage (PVC), but the volume was not provisioned.

---

### 2. PersistentVolumeClaim (PVC) in `Pending`

**Check:**

```bash
kubectl get pvc
```

**Output:**

```
jenkins   Pending   gp2
```

**Cause:**

* Kubernetes could not provision an EBS volume.

---

### 3. EBS CSI Driver CrashLoopBackOff

**Check:**

```bash
kubectl get pods -n kube-system | grep ebs
```

**Output:**

```
ebs-csi-controller   CrashLoopBackOff
```

**Root Cause:**

* Missing IAM permissions for the EBS CSI driver.

---

### 4. IAM Permission Error

**Check logs:**

```bash
kubectl logs <ebs-csi-controller-pod> -n kube-system -c ebs-plugin
```

**Error:**

```
UnauthorizedOperation: not authorized to perform ec2:DescribeAvailabilityZones
```

**Cause:**

* The node IAM role does not have required EC2 permissions.

---

### ✅ Solution

1. Create IAM policy for EBS CSI driver:

```bash
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-ebs-csi-driver/master/docs/example-iam-policy.json

aws iam create-policy \
  --policy-name AmazonEBSCSIDriverPolicy \
  --policy-document file://example-iam-policy.json
```

2. Attach policy using IAM Service Account (IRSA):

```bash
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster <cluster-name> \
  --attach-policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AmazonEBSCSIDriverPolicy \
  --approve
```

3. Restart CSI driver:

```bash
kubectl delete pod -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
```

---

### ✅ Expected Result

```bash
kubectl get pvc
```

```
jenkins   Bound
```

```bash
kubectl get pods
```

```
jenkins-0   2/2   Running
```

---

### 5. ImagePullBackOff (Tooling App)

**Symptoms:**

```
ImagePullBackOff
```

**Cause:**

* Incorrect image name/tag or private repository without access.

**Fix:**

* Verify image exists:

  ```bash
  docker pull <image-name>
  ```
* Ensure correct tag in Helm `values.yaml`
* If private repo, configure imagePullSecrets

---

### 💡 Key Insight

This issue followed a dependency chain:

```
IAM Permissions → EBS CSI Driver → PVC → Jenkins Pod
```

A failure at the IAM level prevents storage provisioning, which blocks pod scheduling.

---
