# Deploying and Packaging Applications into Kubernetes with Helm

A complete, real-world walkthrough of deploying production-grade DevOps tooling into an AWS EKS cluster using Helm — including JFrog Artifactory, Nginx Ingress Controller, cert-manager TLS, and a custom Helm chart for a tooling application. Every command here was executed and verified against a live cluster.

---

## Table of Contents

- [Environment](#environment)
- [Overview](#overview)
- [Tools Deployed](#tools-deployed)
- [Phase 1 — Infrastructure Provisioning with Terraform](#phase-1--infrastructure-provisioning-with-terraform)
- [Phase 2 — Cluster Verification and Helm Setup](#phase-2--cluster-verification-and-helm-setup)
- [Phase 3 — Deploy Custom Tooling App with Helm](#phase-3--deploy-custom-tooling-app-with-helm)
- [Phase 4 — Deploy Jenkins](#phase-4--deploy-jenkins)
- [Phase 5 — Fix Jenkins PVC (EBS CSI Driver)](#phase-5--fix-jenkins-pvc-ebs-csi-driver)
- [Phase 6 — Create the Tools Namespace and Deploy Artifactory](#phase-6--create-the-tools-namespace-and-deploy-artifactory)
- [Phase 7 — Deploy Nginx Ingress Controller](#phase-7--deploy-nginx-ingress-controller)
- [Phase 8 — Deploy cert-manager and Configure TLS](#phase-8--deploy-cert-manager-and-configure-tls)
- [Phase 9 — Create Artifactory Ingress with TLS](#phase-9--create-artifactory-ingress-with-tls)
- [Phase 10 — Remove Redundant Nginx Service and Verify](#phase-10--remove-redundant-nginx-service-and-verify)
- [Troubleshooting](#troubleshooting)
- [Architecture Notes](#architecture-notes)
- [Next Steps](#next-steps)

---

## Environment

| Item | Detail |
|---|---|
| Cluster name | `tooling-app-eks` |
| Region | `eu-west-2` (London) |
| Kubernetes version | `v1.29.15-eks-f69f56f` |
| Node count | 2 managed nodes |
| Helm version | `v3.20.1` |
| Domain | `qyonlimited.com` |
| Artifactory URL | `https://artifactory.qyonlimited.com` |

---

## Overview

This project provisions an EKS cluster with Terraform, then deploys a suite of DevOps tooling using Helm. The core goal is to stand up **JFrog Artifactory** as a private Docker image registry and Helm chart repository behind a secure HTTPS endpoint — satisfying a corporate security policy that prohibits pulling artifacts directly from the public internet into production systems.

The end-to-end architecture achieves:
- A single shared load balancer (via Nginx Ingress) serving all tools
- Automated TLS certificate provisioning via cert-manager + Let's Encrypt
- Artifactory accessible at `https://artifactory.qyonlimited.com` with a valid SSL certificate

---

## Tools Deployed

| Tool | Namespace | Purpose |
|---|---|---|
| Custom tooling app | `default` | Sample Helm chart deployment |
| Jenkins | `default` | CI server |
| JFrog Artifactory | `tools` | Private Docker registry + Helm chart repo |
| Nginx Ingress Controller | `tools` | Single shared load balancer entry point |
| cert-manager | `tools` | Automated Let's Encrypt TLS certificates |

---

## Phase 1 — Infrastructure Provisioning with Terraform

The EKS cluster and all supporting AWS resources (VPC, subnets, NAT gateway, IAM roles, security groups) were provisioned using Terraform.

```bash
cd ~/eks/terraform
terraform apply
```

Output confirming successful apply:

```
Apply complete! Resources: 55 added, 0 changed, 0 destroyed.
```

![alt text](/images2/1.png)


### Connect kubectl to the new cluster

```bash
aws eks update-kubeconfig \
  --name tooling-app-eks \
  --region eu-west-2
```

Expected output:

```
Updated context arn:aws:eks:eu-west-2:686255973523:cluster/tooling-app-eks in /home/princemax/.kube/config
```
![alt text](/images2/2.png)

### Verify nodes are ready

```bash
kubectl get nodes
```

```
NAME                                        STATUS   ROLES    AGE     VERSION
ip-10-0-11-51.eu-west-2.compute.internal    Ready    <none>   4m46s   v1.29.15-eks-f69f56f
ip-10-0-12-127.eu-west-2.compute.internal   Ready    <none>   4m46s   v1.29.15-eks-f69f56f
```
![alt text](/images2/3.png)

---

## Phase 2 — Cluster Verification and Helm Setup

### Verify Helm is installed

```bash
helm version
```

```
version.BuildInfo{Version:"v3.20.1", ...}
```

### Add all required Helm repositories

```bash
helm repo add jfrog https://charts.jfrog.io
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo add jenkins https://charts.jenkins.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
```

### Update repo index

```bash
helm repo update
```

---

## Phase 3 — Deploy Custom Tooling App with Helm

A custom Helm chart was created for a tooling application (`princemaxi/tooling-app`) to demonstrate Helm chart structure, dry-run validation, and the difference between `helm install` and `helm upgrade --install`.

### Chart structure

```
tooling-app/
├── Chart.yaml
├── charts/
├── templates/
│   ├── _helpers.tpl
│   ├── deployment.yaml
│   └── service.yaml
└── values.yaml
```

### `values.yaml`

```yaml
replicaCount: 3

image:
  repository: princemaxi/tooling-app
  tag: "1.0"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80

containerPort: 80
```

### `templates/deployment.yaml`

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

### Lint the chart

Always lint before deploying to catch syntax errors early:

```bash
helm lint .
```

```
==> Linting .
[INFO] Chart.yaml: icon is recommended
1 chart(s) linted, 0 chart(s) failed
```

### Dry-run to preview rendered manifests

```bash
helm install tooling-release . --dry-run --debug
```

This renders the full YAML that would be applied to the cluster without actually deploying anything — useful for verifying template output before committing.

### Install Tooling Realease

### Upgrading with the corrected image tag

Attempting `helm install` failed because a release named `tooling-release` already existed:

```bash
helm install tooling-release .
# Error: INSTALLATION FAILED: cannot re-use a name that is still in use
```

The correct approach is `helm upgrade --install`, which is idempotent:

```bash
helm upgrade --install tooling-release .
```

```
Release "tooling-release" has been upgraded. Happy Helming!
NAME: tooling-release
NAMESPACE: default
STATUS: deployed
REVISION: 2
```

### Verify all pods running

```bash
kubectl get pods
```

```
NAME                                          READY   STATUS    RESTARTS   AGE
tooling-release-deployment-64db48ccd8-cwqqb   1/1     Running   0          79s
tooling-release-deployment-64db48ccd8-mzgp7   1/1     Running   0          102s
tooling-release-deployment-64db48ccd8-s78hg   1/1     Running   0          88s
```
![alt text](/images2/4.png)

---

## Phase 4 — Deploy Jenkins

Jenkins was deployed into the `default` namespace using the official Jenkins Helm chart.

```bash
helm search repo jenkins
```

```
NAME             CHART VERSION   APP VERSION
jenkins/jenkins  5.9.22          2.555.2
```

```bash
helm install jenkins jenkins/jenkins
```

```
NAME: jenkins
LAST DEPLOYED: Tue Jun  2 11:29:07 2026
NAMESPACE: default
STATUS: deployed
REVISION: 1
```

### Retrieve the admin password

```bash
kubectl exec -it svc/jenkins -c jenkins -- \
  cat /run/secrets/additional/chart-admin-password
```

### Access Jenkins via port-forward

Port 8080 was already in use locally, so the local port was remapped to 8081:

```bash
# This failed — port 8080 already in use locally
kubectl port-forward svc/jenkins 8080:8080
# Error: unable to listen on port 8080: bind: address already in use

# Fix — map to a free local port
kubectl port-forward svc/jenkins 8081:8080
```

Access Jenkins at: `http://127.0.0.1:8081`

### Jenkins pod stuck in Pending

```bash
kubectl get pods
# jenkins-0   0/2   Pending   0   2m12s

kubectl get pvc
# NAME      STATUS    VOLUME   CAPACITY   STORAGECLASS   AGE
# jenkins   Pending                       gp2            5m20s
```

The PVC was stuck in `Pending` because the EBS CSI Driver was not installed on the cluster — EKS does not include it by default. The cluster lacked a controller capable of dynamically provisioning `gp2` EBS volumes.

---

## Phase 5 — Fix Jenkins PVC (EBS CSI Driver)

The EBS CSI Driver must be installed as an EKS addon to allow dynamic provisioning of EBS-backed PersistentVolumes. This was added to Terraform as a new file `eks-addons.tf`.

### Terraform configuration for EBS CSI Driver

```hcl
# eks-addons.tf

data "aws_eks_cluster" "eks" {
  name = "tooling-app-eks"
}

resource "aws_iam_role" "ebs_csi_driver_role" {
  name = "AmazonEKS_EBS_CSI_DriverRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::686255973523:oidc-provider/oidc.eks.eu-west-2.amazonaws.com/id/54A11C76B560DD747C07EF67D7153F7E"
      }
      Condition = {
        StringEquals = {
          "oidc.eks.eu-west-2.amazonaws.com/id/54A11C76B560DD747C07EF67D7153F7E:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver_policy_attachment" {
  role       = aws_iam_role.ebs_csi_driver_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = "tooling-app-eks"
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_driver_role.arn
}
```

> **Note:** A duplicate `data "aws_caller_identity" "current"` block caused an initial plan error. The block was removed from `eks-addons.tf` since it already existed in `data.tf`.

```bash
terraform plan   # verify 3 resources will be added
terraform apply
```

```
aws_iam_role.ebs_csi_driver_role: Creation complete after 2s
aws_iam_role_policy_attachment.ebs_csi_driver_policy_attachment: Creation complete after 1s
aws_eks_addon.ebs_csi_driver: Creation complete after 37s

Apply complete! Resources: 3 added, 0 changed, 0 destroyed.
```

### Verify PVC bound and Jenkins running

```bash
kubectl get pvc
```

```
NAME      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
jenkins   Bound    pvc-bbcf2c02-40a9-4f8e-b2d6-c666a3fcba72   8Gi        RWO            gp2            24m
```

```bash
kubectl get pods
```

```
NAME                                          READY   STATUS    RESTARTS   AGE
jenkins-0                                     2/2     Running   0          24m
tooling-release-deployment-64db48ccd8-cwqqb   1/1     Running   0          33m
tooling-release-deployment-64db48ccd8-mzgp7   1/1     Running   0          33m
tooling-release-deployment-64db48ccd8-s78hg   1/1     Running   0          33m
```

---

## Phase 6 — Create the Tools Namespace and Deploy Artifactory

All DevOps tooling from this point forward is deployed into the `tools` namespace.

### Create the namespace

```bash
kubectl create ns tools
```

### Add JFrog repo and update

```bash
helm repo add jfrog https://charts.jfrog.io
helm repo update
```
![alt text](/images2/5.png)

### Install Artifactory

```bash
helm upgrade --install artifactory jfrog/artifactory \
  --version 107.90.10 \
  -n tools
```

```
Release "artifactory" does not exist. Installing it now.
NAME: artifactory
NAMESPACE: tools
STATUS: deployed
REVISION: 1
```

![alt text](/images2/6.png)

> A warning about duplicate port definitions appeared during install — this is a known cosmetic issue with this chart version and does not affect functionality.

### Watch pods come up

```bash
kubectl get pods -n tools -w
```

The Artifactory pod (`artifactory-0`) starts with 0/8 containers ready and progresses to 8/8 over approximately 5 minutes. The chart deploys three components: the Artifactory application, PostgreSQL, and an Nginx proxy.

```
NAME                                             READY   STATUS    RESTARTS   AGE
artifactory-0                                    8/8     Running   1 (39m)    44m
artifactory-artifactory-nginx-5cd6bf49df-spxn8   1/1     Running   0          44m
artifactory-postgresql-0                         1/1     Running   0          44m
```

![alt text](/images2/7.png)

### Confirm the temporary LoadBalancer service

```bash
kubectl get svc artifactory-artifactory-nginx -n tools
```

```
NAME                            TYPE           CLUSTER-IP     EXTERNAL-IP
artifactory-artifactory-nginx   LoadBalancer   172.20.42.33   ae7394a90a007467fbcc80e05807961d-2067695073.eu-west-2.elb.amazonaws.com
```

This LoadBalancer is temporary. It will be replaced by the Ingress Controller in the next phase.

![alt text](/images2/8.png)

---

## Phase 7 — Deploy Nginx Ingress Controller

A single Nginx Ingress Controller creates one shared AWS load balancer for all tools — eliminating the need for a separate load balancer per application.

> **Important:** The ingress controller was installed into the `tools` namespace (not `ingress-nginx`) to keep all tooling in one namespace.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n tools
```

```
Release "ingress-nginx" does not exist. Installing it now.
NAME: ingress-nginx
NAMESPACE: tools
STATUS: deployed
REVISION: 1
```

![alt text](/images2/9.png)

### Verify services in the tools namespace

```bash
kubectl get svc -n tools
```

```
NAME                                 TYPE           CLUSTER-IP       EXTERNAL-IP
artifactory                          ClusterIP      172.20.222.25    <none>
artifactory-artifactory-nginx        LoadBalancer   172.20.42.33     ae7394a90...eu-west-2.elb.amazonaws.com
artifactory-postgresql               ClusterIP      172.20.66.181    <none>
ingress-nginx-controller             LoadBalancer   172.20.137.118   a0aec26b4...eu-west-2.elb.amazonaws.com
ingress-nginx-controller-admission   ClusterIP      172.20.243.59    <none>
```

### Verify DNS resolution of the ingress load balancer

```bash
nslookup a0aec26b465d44c4bacfad089ca9000d-2043132341.eu-west-2.elb.amazonaws.com
```

```
Name:   a0aec26b465d44c4bacfad089ca9000d-2043132341.eu-west-2.elb.amazonaws.com
Address: 18.171.131.188
```

![alt text](/images2/10.png)

A CNAME record pointing `artifactory.qyonlimited.com` to this load balancer was created in Route53.

![alt text](/images2/11.png)

---

## Phase 8 — Deploy cert-manager and Configure TLS

cert-manager automates the provisioning and renewal of TLS certificates from Let's Encrypt.

### Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace tools \
  --set installCRDs=true
```

```
cert-manager v1.20.2 has been deployed successfully!
```

![alt text](/images2/12.png)

> **Note:** `installCRDs` is deprecated in favour of `crds.enabled` in newer versions. The flag still works but produces a warning.

### Verify cert-manager pods

```bash
kubectl get pods -n tools | grep cert-manager
```

```
cert-manager-5fc8564cb8-wtnkl            1/1     Running   0   5m42s
cert-manager-cainjector-69c5ccb4c7-rzbjv 1/1     Running   0   5m42s
cert-manager-webhook-7f8cc9d46b-d7c8d    1/1     Running   0   5m42s
```

### Create the ClusterIssuer

The ClusterIssuer registers an ACME account with Let's Encrypt and handles HTTP-01 challenge validation through the Nginx ingress.

**First attempt failed** due to a stale ACME account reference in a pre-existing secret:

```
Warning  ErrUpdateACMEAccount  Failed to update ACME account: 400
urn:ietf:params:acme:error:accountDoesNotExist:
Account "https://acme-v02.api.letsencrypt.org/acme/acct/3398648326" not found
```

**Fix:** Delete the existing ClusterIssuer and its associated secret, then recreate cleanly:

```bash
kubectl delete clusterissuer letsencrypt-prod
kubectl delete secret letsencrypt-prod -n tools
```

Then recreate:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
```

### Verify ClusterIssuer is Ready

```bash
kubectl get clusterissuer
```

```
NAME               READY   AGE
letsencrypt-prod   True    49s
```

![alt text](/images2/13.png)

---

## Phase 9 — Create Artifactory Ingress with TLS

With cert-manager ready and DNS resolving correctly, create the Ingress resource for Artifactory. This routes external HTTPS traffic through the shared ingress controller to the Artifactory service, and triggers automatic certificate issuance.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: artifactory-ingress
  namespace: tools
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - artifactory.qyonlimited.com
    secretName: artifactory-tls
  rules:
  - host: artifactory.qyonlimited.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: artifactory
            port:
              number: 8082
EOF
```

> **Note:** The backend service is `artifactory` (the direct Artifactory service on port 8082), not `artifactory-artifactory-nginx`. This bypasses the built-in Nginx proxy since we are now using the cluster-wide ingress controller instead.

### Verify ingress and certificate

```bash
kubectl get ingress -n tools
```

```
NAME                        CLASS   HOSTS                         ADDRESS                                          PORTS
artifactory-ingress         nginx   artifactory.qyonlimited.com   a0aec26b...eu-west-2.elb.amazonaws.com          80, 443
cm-acme-http-solver-mqt4s   <none>  artifactory.qyonlimited.com                                                   80
```

![alt text](/images2/14.png)

The `cm-acme-http-solver-*` entry is cert-manager's temporary HTTP-01 challenge solver — it disappears once the certificate is issued.

```bash
kubectl get certificate -n tools
```

```
NAME              READY   SECRET            AGE
artifactory-tls   True    artifactory-tls   3m32s
```

`READY: True` confirms the TLS certificate was successfully issued by Let's Encrypt.

### Verify DNS resolution for the domain

```bash
nslookup artifactory.qyonlimited.com
```

```
artifactory.qyonlimited.com   canonical name = a0aec26b...eu-west-2.elb.amazonaws.com.
Address: 18.171.131.188
```

---

## Phase 10 — Remove Redundant Nginx Service and Verify

With the Ingress Controller handling all external traffic, the original `artifactory-artifactory-nginx` LoadBalancer service is no longer needed. Keeping it would incur unnecessary AWS load balancer costs.

```bash
kubectl delete svc artifactory-artifactory-nginx -n tools
```

### Final service state

```bash
kubectl get svc -n tools
```

```
NAME                                 TYPE           CLUSTER-IP       EXTERNAL-IP
artifactory                          ClusterIP      172.20.222.25    <none>
artifactory-postgresql               ClusterIP      172.20.66.181    <none>
cert-manager                         ClusterIP      172.20.193.115   <none>
ingress-nginx-controller             LoadBalancer   172.20.137.118   a0aec26b...eu-west-2.elb.amazonaws.com
ingress-nginx-controller-admission   ClusterIP      172.20.243.59    <none>
```

One load balancer remaining — the shared ingress controller. All other services are internal `ClusterIP` only.

### End-to-end HTTPS verification

```bash
curl -I https://artifactory.qyonlimited.com
```

```
HTTP/2 200
date: Wed, 03 Jun 2026 09:34:32 GMT
content-type: text/html; charset=UTF-8
strict-transport-security: max-age=31536000; includeSubDomains
x-content-type-options: nosniff
x-frame-options: SAMEORIGIN
```

`HTTP/2 200` with `strict-transport-security` confirms Artifactory is fully reachable over HTTPS with a valid, trusted TLS certificate.

![alt text](/images2/15.png)

### Final Helm release inventory

```bash
helm list -n tools
```

```
NAME          NAMESPACE  REVISION  CHART                  APP VERSION
artifactory   tools      1         artifactory-107.90.10  7.90.10
cert-manager  tools      1         cert-manager-v1.20.2   v1.20.2
ingress-nginx tools      1         ingress-nginx-4.15.1   1.15.1
```

### Access Artifactory via Web
```
https://artifactory.qyonlimited.com
```

![alt text](/images2/16.png)
![alt text](/images2/17.png)

---

## Troubleshooting

### `ImagePullBackOff` / `ErrImagePull`

Pods fail to start because the Docker image tag does not exist in the registry.

```bash
kubectl describe pod <pod-name>
# Look at Events section for the exact error message
```

Fix: update `values.yaml` with a valid image tag, then:

```bash
helm upgrade --install <release-name> .
```

Never use `kubectl apply -f values.yaml` — `values.yaml` is a Helm input file, not a Kubernetes manifest.

### `cannot re-use a name that is still in use`

Caused by using `helm install` when a release already exists. Always use:

```bash
helm upgrade --install <release-name> <chart>
```

### Jenkins PVC stuck in `Pending`

The EBS CSI Driver is not installed by default on EKS. Without it, PersistentVolumeClaims using the `gp2` StorageClass cannot be fulfilled.

Fix: install the `aws-ebs-csi-driver` EKS addon via Terraform (see Phase 5) or via the AWS console.

```bash
# Verify PVC status
kubectl get pvc

# Check events on the PVC
kubectl describe pvc jenkins
```

### `kubectl port-forward` — address already in use

```bash
# Port 8080 occupied — remap to a free local port
kubectl port-forward svc/jenkins 8081:8080
```

### ClusterIssuer `READY: False` — ACME account not found

The error `accountDoesNotExist` means cert-manager is trying to reuse a stale ACME account reference from a previous secret.

```bash
kubectl delete clusterissuer letsencrypt-prod
kubectl delete secret letsencrypt-prod -n tools
# Then recreate the ClusterIssuer from scratch
```

### Helm upgrade fails — `nil pointer evaluating interface`

When upgrading between significantly different chart versions (e.g. `107.90.10` to `107.146.x`), new chart templates may reference values not present in the existing release's values. Each missing value generates a nil pointer error.

The cleanest resolution is to avoid large version jumps and instead pin to the original chart version until a planned upgrade window. If upgrading is required, fetch the full default values for the target version and merge with your overrides:

```bash
helm show values jfrog/artifactory --version 107.146.15 > new-defaults.yaml
# Review and merge with your custom values, then:
helm upgrade artifactory jfrog/artifactory \
  --version 107.146.15 \
  --namespace tools \
  -f merged-values.yaml
```

### Duplicate Terraform resource error

```
Error: Duplicate data "aws_caller_identity" configuration
```

Caused by declaring a `data "aws_caller_identity"` block in a new file when one already exists in another `.tf` file. Resource names must be unique per type per module. Remove the duplicate declaration.

---

## Architecture Notes

### Why `helm upgrade --install` instead of `helm install`?

`helm upgrade --install` is idempotent. It installs if the release does not exist and upgrades if it does. This means it is always safe to run in CI pipelines — the command will never fail due to an existing release.

### Why Ingress instead of LoadBalancer per service?

| Approach | Load Balancers | Monthly cost impact | Management |
|---|---|---|---|
| `type: LoadBalancer` per service | One per app | High (multiplies with every tool) | High |
| Nginx Ingress Controller | One shared | Low (fixed regardless of tool count) | Low |

Deleting `artifactory-artifactory-nginx` after setting up the ingress eliminated one AWS Classic Load Balancer — a direct cost saving that compounds as more tools are added.

### Why the backend points to `artifactory` (port 8082) not `artifactory-artifactory-nginx`?

The Artifactory Helm chart bundles its own internal Nginx proxy (`artifactory-artifactory-nginx`) as the original external entry point. Once a cluster-wide Nginx Ingress Controller is in place, routing through the internal Nginx proxy is redundant. Pointing the Ingress directly to the `artifactory` service on port 8082 skips the intermediate hop and simplifies the traffic path:

```
Browser → Route53 → AWS ELB → ingress-nginx-controller → artifactory:8082
```

### How cert-manager automates TLS

cert-manager watches for Ingress resources annotated with `cert-manager.io/cluster-issuer`. When it detects one, it:

1. Creates a temporary HTTP-01 challenge solver pod and Ingress
2. Requests a certificate from Let's Encrypt
3. Let's Encrypt calls `http://<domain>/.well-known/acme-challenge/<token>` to verify domain ownership
4. cert-manager answers the challenge, receives the certificate, and stores it as a Kubernetes Secret
5. The Ingress controller picks up the Secret and serves it for HTTPS traffic

The certificate auto-renews before expiry with no manual intervention required.

---