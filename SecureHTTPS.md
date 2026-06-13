# Implementing Secure HTTPS with cert-manager and Let's Encrypt on EKS

A production-grade implementation of automated TLS certificate provisioning for Kubernetes workloads using cert-manager, Let's Encrypt, and AWS Route53 DNS-01 challenge validation via IRSA (IAM Roles for Service Accounts).

This document covers the complete implementation performed against a live EKS cluster, including every command executed, actual outputs, errors encountered, and their resolutions.

---

## Table of Contents

- [Implementing Secure HTTPS with cert-manager and Let's Encrypt on EKS](#implementing-secure-https-with-cert-manager-and-lets-encrypt-on-eks)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Architecture](#architecture)
  - [Prerequisites](#prerequisites)
  - [Environment](#environment)
  - [Step 1 — IAM Policy for Route53 Access](#step-1--iam-policy-for-route53-access)
  - [Step 2 — IAM Role with IRSA Trust Policy](#step-2--iam-role-with-irsa-trust-policy)
    - [2.1 Get the cluster OIDC issuer](#21-get-the-cluster-oidc-issuer)
    - [2.2 Create the trust policy](#22-create-the-trust-policy)
    - [2.3 Create the role and attach the policy](#23-create-the-role-and-attach-the-policy)
  - [Step 3 — Install cert-manager](#step-3--install-cert-manager)
    - [Verify all three pods are running](#verify-all-three-pods-are-running)
  - [Step 4 — Annotate Service Account and Configure fsGroup](#step-4--annotate-service-account-and-configure-fsgroup)
    - [4.1 Annotate the service account with the IAM role ARN](#41-annotate-the-service-account-with-the-iam-role-arn)
    - [4.2 Patch the deployment with fsGroup security context](#42-patch-the-deployment-with-fsgroup-security-context)
    - [4.3 Restart to pick up both changes](#43-restart-to-pick-up-both-changes)
  - [Step 5 — Configure RBAC for Token Creation](#step-5--configure-rbac-for-token-creation)
  - [Step 6 — Create the ClusterIssuer](#step-6--create-the-clusterissuer)
  - [Step 7 — Deploy the Artifactory Ingress with TLS](#step-7--deploy-the-artifactory-ingress-with-tls)
  - [Step 8 — Verify Certificate Issuance](#step-8--verify-certificate-issuance)
    - [8.1 Watch the certificate status](#81-watch-the-certificate-status)
    - [8.2 Inspect the issued certificate secret](#82-inspect-the-issued-certificate-secret)
    - [8.3 Verify ingress address](#83-verify-ingress-address)
  - [Step 9 — End-to-End HTTPS Verification](#step-9--end-to-end-https-verification)
    - [9.1 Curl verification](#91-curl-verification)
    - [9.2 Verbose certificate chain inspection](#92-verbose-certificate-chain-inspection)
    - [9.3 Browser verification](#93-browser-verification)
  - [Troubleshooting](#troubleshooting)
    - [Challenge stuck in `pending` — RBAC token error](#challenge-stuck-in-pending--rbac-token-error)
    - [ClusterIssuer `READY: False` — ACME account not found](#clusterissuer-ready-false--acme-account-not-found)
    - [Certificate `READY: False` after 10+ minutes](#certificate-ready-false-after-10-minutes)
    - [`curl` returns SSL error despite certificate being `Ready: True`](#curl-returns-ssl-error-despite-certificate-being-ready-true)
    - [`nano` or `kubectl apply` executed directly in the shell without a file](#nano-or-kubectl-apply-executed-directly-in-the-shell-without-a-file)
  - [Architecture Notes](#architecture-notes)
    - [Why DNS-01 over HTTP-01?](#why-dns-01-over-http-01)
    - [Why IRSA over static credentials?](#why-irsa-over-static-credentials)
    - [Certificate renewal](#certificate-renewal)
    - [The `proxy-body-size: 500m` annotation](#the-proxy-body-size-500m-annotation)

---

## Overview

This project enhances the security of the Artifactory deployment by implementing HTTPS using cert-manager to automatically request and manage TLS certificates from Let's Encrypt. cert-manager handles the full certificate lifecycle — issuance, storage as Kubernetes Secrets, and automatic renewal before expiry — with zero manual intervention once configured.

The implementation uses the **DNS-01 challenge method** via AWS Route53, which is more robust than HTTP-01 for EKS environments and supports wildcard certificates. Authentication to Route53 is handled securely through **IRSA** — no static AWS credentials are stored anywhere in the cluster.

**End result:** Artifactory is accessible at `https://artifactory.qyonlimited.com` with a valid, browser-trusted Let's Encrypt certificate, served over HTTP/2 with HSTS enforced.

---

## Architecture

```
User Browser
     │
     ▼ HTTPS (port 443)
Route53 DNS → AWS ELB (ingress-nginx-controller LoadBalancer)
     │
     ▼
Nginx Ingress Controller (tools namespace)
     │  TLS terminated here using Secret: artifactory.qyonlimited.com
     ▼
Artifactory Service (port 8082, ClusterIP)
     │
     ▼
Artifactory Pod (tools namespace)

Certificate Lifecycle:
cert-manager Controller
     │  Watches Ingress for cert-manager.io/cluster-issuer annotation
     ▼
ClusterIssuer (letsencrypt-prod)
     │  DNS-01 challenge via Route53
     ▼
Let's Encrypt ACME API
     │  Validates _acme-challenge TXT record in Route53
     ▼
Certificate issued → stored as Kubernetes TLS Secret
     │
     ▼
Nginx Ingress serves the certificate
```

![alt text](/images3/01.jpg)
![alt text](/images3/02.jpg)

**cert-manager components:**

| Component | Role |
|---|---|
| Controller | Manages certificate lifecycle, watches Ingress/Certificate resources |
| Webhook | Validates and mutates cert-manager CRD resources |
| CA Injector | Injects CA bundles into webhook configurations |

---

## Prerequisites

| Requirement | Detail |
|---|---|
| EKS cluster running | `kubectl get nodes` shows nodes in `Ready` state |
| Nginx Ingress Controller installed | Running in `tools` namespace |
| `tools` namespace created | `kubectl get ns tools` |
| Artifactory deployed | Pods running in `tools` namespace |
| Domain with Route53 Hosted Zone | DNS CNAME pointing to ingress controller LB |
| AWS CLI configured | `aws sts get-caller-identity` returns valid identity |
| Helm 3.x | `helm version` |

---

## Environment

| Item | Value |
|---|---|
| Cluster | `tooling-app-eks` |
| Region | `eu-west-2` |
| OIDC Provider ID | `62AD11A0952C72958CBED7D4C8E1E0D0` |
| AWS Account ID | `686255973523` |
| Domain | `qyonlimited.com` |
| Artifactory hostname | `artifactory.qyonlimited.com` |
| cert-manager version | `v1.15.3` |
| cert-manager namespace | `cert-manager` |
| IAM Role | `cert_manager_role` |
| IAM Policy | `CertManagerRoute53Policy` |

---

## Step 1 — IAM Policy for Route53 Access

cert-manager requires permission to create and delete TXT records in Route53 to complete the DNS-01 ACME challenge. The policy grants the minimum required permissions — no broader Route53 or IAM access is granted.

```bash
cat <<EOF > cert-manager-iam-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "route53:GetChange",
      "Resource": "arn:aws:route53:::change/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets"
      ],
      "Resource": "arn:aws:route53:::hostedzone/*"
    },
    {
      "Effect": "Allow",
      "Action": "route53:ListHostedZonesByName",
      "Resource": "*"
    }
  ]
}
EOF
```

```bash
aws iam create-policy \
  --policy-name CertManagerRoute53Policy \
  --policy-document file://cert-manager-iam-policy.json \
  --region eu-west-2
```

Output:

```json
{
    "Policy": {
        "PolicyName": "CertManagerRoute53Policy",
        "PolicyId": "ANPAZ7SALESJ563KJK6RY",
        "Arn": "arn:aws:iam::686255973523:policy/CertManagerRoute53Policy",
        "CreateDate": "2026-06-11T11:06:28+00:00"
    }
}
```

![alt text](/images3/1.png)

---

## Step 2 — IAM Role with IRSA Trust Policy

IRSA (IAM Roles for Service Accounts) allows the cert-manager pod to assume an IAM role using a projected Kubernetes service account token — no static credentials required anywhere in the cluster.

The trust policy scopes the role assumption to exactly one service account: `cert-manager` in the `cert-manager` namespace, authenticated via the cluster's OIDC provider.

### 2.1 Get the cluster OIDC issuer

```bash
aws eks describe-cluster \
  --name tooling-app-eks \
  --region eu-west-2 \
  --query "cluster.identity.oidc.issuer" \
  --output text
```

Output:

```
https://oidc.eks.eu-west-2.amazonaws.com/id/62AD11A0952C72958CBED7D4C8E1E0D0
```

![alt text](/images3/2.png)

### 2.2 Create the trust policy

```bash
cat <<EOF > cert-manager-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::686255973523:oidc-provider/oidc.eks.eu-west-2.amazonaws.com/id/62AD11A0952C72958CBED7D4C8E1E0D0"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.eu-west-2.amazonaws.com/id/62AD11A0952C72958CBED7D4C8E1E0D0:sub": "system:serviceaccount:cert-manager:cert-manager"
        }
      }
    }
  ]
}
EOF
```

### 2.3 Create the role and attach the policy

```bash
aws iam create-role \
  --role-name cert_manager_role \
  --assume-role-policy-document file://cert-manager-trust-policy.json
```

```bash
aws iam attach-role-policy \
  --role-name cert_manager_role \
  --policy-arn arn:aws:iam::686255973523:policy/CertManagerRoute53Policy
```

![alt text](/images3/3.png)

Role ARN for use in subsequent steps:

```
arn:aws:iam::686255973523:role/cert_manager_role
```

> **Note:** The OIDC provider ID changes with every new cluster. When the cluster is recreated with `terraform apply`, the trust policy must be updated with the new OIDC ID before cert-manager can assume the role.

---

## Step 3 — Install cert-manager

cert-manager is installed into its own dedicated namespace (`cert-manager`) — the standard production deployment pattern. This keeps cert-manager isolated from application tooling and is required for IRSA to function correctly with the service account scoping defined in Step 2.

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.15.3 \
  --set crds.enabled=true
```

Output:

```
NAME: cert-manager
LAST DEPLOYED: Thu Jun 11 12:21:40 2026
NAMESPACE: cert-manager
STATUS: deployed
REVISION: 1
cert-manager v1.15.3 has been deployed successfully!
```

![alt text](/images3/4.png)

### Verify all three pods are running

```bash
kubectl get pods --namespace cert-manager
```

```
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-98c64c5bd-jvkqp               1/1     Running   0          105s
cert-manager-cainjector-5f67bf667f-d45z5   1/1     Running   0          105s
cert-manager-webhook-749d497c97-762f9      1/1     Running   0          105s
```

![alt text](/images3/5.png)

> **Note:** `crds.enabled=true` is the current recommended flag. The older `--set installCRDs=true` still works but produces a deprecation warning in v1.15.x.

---

## Step 4 — Annotate Service Account and Configure fsGroup

### 4.1 Annotate the service account with the IAM role ARN

This annotation is the IRSA link — it instructs the EKS pod identity webhook to inject AWS credentials for the specified role into the cert-manager pod at runtime.

```bash
kubectl annotate serviceaccount cert-manager \
  --namespace cert-manager \
  eks.amazonaws.com/role-arn=arn:aws:iam::686255973523:role/cert_manager_role
```

Verify:

```bash
kubectl describe serviceaccount cert-manager -n cert-manager
```

Confirm the annotation appears:

```
Annotations:  eks.amazonaws.com/role-arn: arn:aws:iam::686255973523:role/cert_manager_role
              meta.helm.sh/release-name: cert-manager
              meta.helm.sh/release-namespace: cert-manager
```

![alt text](/images3/6.png)

### 4.2 Patch the deployment with fsGroup security context

The `fsGroup: 1001` setting ensures the cert-manager pod's filesystem is owned by the correct group, allowing it to read the projected service account token that the AWS SDK uses for IRSA authentication.

```bash
kubectl patch deployment cert-manager \
  --namespace cert-manager \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/securityContext","value":{"fsGroup":1001}}]'
```

![alt text](/images3/7.png)

### 4.3 Restart to pick up both changes

```bash
kubectl rollout restart deployment cert-manager -n cert-manager
kubectl rollout status deployment cert-manager -n cert-manager
```

```
deployment "cert-manager" successfully rolled out
```

```bash
kubectl get pods -n cert-manager
```

```
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-5569596486-5s54f              1/1     Running   0          10s
cert-manager-cainjector-5f67bf667f-d45z5   1/1     Running   0          8m31s
cert-manager-webhook-749d497c97-762f9      1/1     Running   0          8m31s
```

---

## Step 5 — Configure RBAC for Token Creation

During the DNS-01 challenge, cert-manager needs to create a short-lived token for the `cert-manager` service account in order to assume the IAM role via IRSA. By default, service accounts cannot create tokens for themselves — this ClusterRole explicitly grants that permission.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cert-manager-token-creator
rules:
- apiGroups: [""]
  resources: ["serviceaccounts/token"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["serviceaccounts"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cert-manager-token-creator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cert-manager-token-creator
subjects:
- kind: ServiceAccount
  name: cert-manager
  namespace: cert-manager
EOF
```

```
clusterrole.rbac.authorization.k8s.io/cert-manager-token-creator created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-token-creator created
```

> **Why this is needed:** The error `serviceaccounts "cert-manager" is forbidden: cannot create resource "serviceaccounts/token"` appears when this RBAC rule is missing. cert-manager uses the TokenRequest API to obtain a scoped token for the `cert-manager` service account — this is what gets exchanged with AWS STS for the Route53 IAM credentials.

---

## Step 6 — Create the ClusterIssuer

The ClusterIssuer registers an ACME account with Let's Encrypt and defines how challenges are solved. This configuration uses the DNS-01 solver with Route53, authenticated via the IRSA-enabled cert-manager service account.

Create `letsencrypt-issuer.yaml`:

```yaml
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
    - selector:
        dnsZones:
          - "qyonlimited.com"
      dns01:
        route53:
          region: eu-west-2
          role: "arn:aws:iam::686255973523:role/cert_manager_role"
          auth:
            kubernetes:
              serviceAccountRef:
                name: "cert-manager"
```

![alt text](/images3/8.png)

```bash
kubectl apply -f letsencrypt-issuer.yaml
```

Verify it becomes `Ready: True` — this confirms the ACME account was successfully registered with Let's Encrypt:

```bash
kubectl get clusterissuer
```

```
NAME               READY   AGE
letsencrypt-prod   True    69s
```

![alt text](/images3/9.png)

---

## Step 7 — Deploy the Artifactory Ingress with TLS

Create `artifactory-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: artifactory-ingress
  namespace: tools
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: 500m
    cert-manager.io/cluster-issuer: letsencrypt-prod
    cert-manager.io/private-key-rotation-policy: Always
  labels:
    name: artifactory
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - artifactory.qyonlimited.com
    secretName: artifactory.qyonlimited.com
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
```

![alt text](/images3/10.png)

**Key annotation notes:**

| Annotation | Purpose |
|---|---|
| `cert-manager.io/cluster-issuer: letsencrypt-prod` | Triggers cert-manager to manage a certificate for this Ingress |
| `cert-manager.io/private-key-rotation-policy: Always` | Rotates the private key on every renewal — production best practice |
| `nginx.ingress.kubernetes.io/proxy-body-size: 500m` | Raises the upload limit for artifact files; default is too low and causes `413 Request Entity Too Large` errors |

The `tls.secretName` value (`artifactory.qyonlimited.com`) is the name of the Kubernetes Secret that cert-manager will create and populate with the issued certificate and private key.

```bash
kubectl apply -f artifactory-ingress.yaml -n tools
```

```
ingress.networking.k8s.io/artifactory-ingress created
```

![alt text](/images3/11.png)

---

## Step 8 — Verify Certificate Issuance

### 8.1 Watch the certificate status

cert-manager immediately creates a `Certificate` resource when it detects the annotated Ingress. It starts `False` while the DNS-01 challenge is in progress and transitions to `True` once Let's Encrypt validates the TXT record.

```bash
kubectl get certificate -n tools -w
```

```
NAME                          READY   SECRET                        AGE
artifactory.qyonlimited.com   False   artifactory.qyonlimited.com   36s
artifactory.qyonlimited.com   True    artifactory.qyonlimited.com   16m
```

### 8.2 Inspect the issued certificate secret

```bash
kubectl get secret artifactory.qyonlimited.com -n tools
```

```
NAME                          TYPE                DATA   AGE
artifactory.qyonlimited.com   kubernetes.io/tls   2      26m
```

The secret contains two keys: `tls.crt` (the certificate chain) and `tls.key` (the private key). The Nginx Ingress Controller reads this secret and serves it for TLS termination.

### 8.3 Verify ingress address

```bash
kubectl get ingress -n tools
```

```
NAME                  CLASS   HOSTS                         ADDRESS                                                                   PORTS     AGE
artifactory-ingress   nginx   artifactory.qyonlimited.com   acb44b97613934a7789e2fdfe8e13e8f-1073219630.eu-west-2.elb.amazonaws.com   80, 443   48m
```

![alt text](/images3/12.png)

---

## Step 9 — End-to-End HTTPS Verification

### 9.1 Curl verification

```bash
curl -I https://artifactory.qyonlimited.com
```

![alt text](/images3/14.png)

```
HTTP/2 200
date: Thu, 11 Jun 2026 12:41:22 GMT
content-type: text/html; charset=UTF-8
strict-transport-security: max-age=31536000; includeSubDomains
x-content-type-options: nosniff
x-frame-options: SAMEORIGIN
x-xss-protection: 1; mode=block
content-security-policy: script-src 'self' 'unsafe-eval'; ...
```

`HTTP/2 200` with `strict-transport-security` confirms full HTTPS is working end-to-end with HSTS enforced.

### 9.2 Verbose certificate chain inspection

```bash
curl -vkI https://artifactory.qyonlimited.com
```

![alt text](/images3/15.png)

Key lines from output confirming a valid Let's Encrypt certificate:

```
* Server certificate:
*  subject: CN=artifactory.qyonlimited.com
*  start date: Jun 11 11:02:51 2026 GMT
*  expire date: Sep  9 11:02:50 2026 GMT
*  issuer: C=US; O=Let's Encrypt; CN=YR2
*   Certificate level 0: Public key type RSA (2048/112 Bits/secBits)
*   Certificate level 1: Public key type RSA (2048/112 Bits/secBits)
*   Certificate level 2: Public key type RSA (4096/152 Bits/secBits)
* using HTTP/2
< HTTP/2 200
```

The three certificate levels confirm the full chain is being served: leaf certificate → Let's Encrypt intermediate (YR2) → ISRG Root X1.

### 9.3 Browser verification

Navigate to `https://artifactory.qyonlimited.com` and click the padlock icon to confirm:

- Certificate issued by: **Let's Encrypt**
- Valid for: `artifactory.qyonlimited.com`
- Certificate authority chain: Let's Encrypt → ISRG Root X1

![alt text](/images3/13.png)
![alt text](/images3/16.png)

---

## Troubleshooting

### Challenge stuck in `pending` — RBAC token error

```
Error: serviceaccounts "cert-manager" is forbidden: User "system:serviceaccount:cert-manager:cert-manager"
cannot create resource "serviceaccounts/token"
```

The cert-manager service account lacks permission to create tokens for itself via the TokenRequest API. Apply the RBAC fix from Step 5, restart cert-manager, then delete and re-trigger the certificate:

```bash
kubectl rollout restart deployment cert-manager -n cert-manager
kubectl delete certificaterequest -n tools <request-name>
kubectl delete certificate -n tools artifactory.qyonlimited.com
kubectl apply -f artifactory-ingress.yaml -n tools
```

### ClusterIssuer `READY: False` — ACME account not found

```
Failed to update ACME account: accountDoesNotExist
```

A stale ACME account private key exists from a previous registration. Delete both the ClusterIssuer and its associated secret, then recreate:

```bash
kubectl delete clusterissuer letsencrypt-prod
kubectl delete secret letsencrypt-prod -n cert-manager
kubectl apply -f letsencrypt-issuer.yaml
```

### Certificate `READY: False` after 10+ minutes

Check the challenge and order resources for details:

```bash
kubectl get challenge -n tools
kubectl describe challenge -n tools
kubectl get order -n tools
kubectl describe order -n tools
```

Common causes: Route53 IAM permissions insufficient, OIDC trust policy references wrong cluster OIDC ID, or DNS propagation delay on the TXT record.

Verify the TXT record was created in Route53:

```bash
nslookup -type=TXT _acme-challenge.artifactory.qyonlimited.com 8.8.8.8
```

### `curl` returns SSL error despite certificate being `Ready: True`

If `curl -I` returns `SSL certificate problem: unable to get local issuer certificate` but `curl -vkI` shows the issuer as **Sophos** rather than **Let's Encrypt**, the request is being intercepted by a corporate SSL inspection proxy on the local network.

This is a local network issue, not a Kubernetes or cert-manager issue. Use `curl -vkI` to inspect the actual certificate chain from the server:

```bash
# Look for this line — confirms Let's Encrypt is serving the real cert
*  issuer: C=US; O=Let's Encrypt; CN=YR2
```

Access from outside the corporate network or test directly from within the cluster:

```bash
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- \
  curl -I https://artifactory.qyonlimited.com
```

### `nano` or `kubectl apply` executed directly in the shell without a file

YAML content pasted directly into the terminal without a heredoc or file is interpreted as shell commands, producing errors like `apiVersion:: command not found`. Always write YAML to a file first:

```bash
nano letsencrypt-issuer.yaml
# paste content, save with Ctrl+O, exit with Ctrl+X
kubectl apply -f letsencrypt-issuer.yaml
```

Or use a heredoc:

```bash
cat <<EOF > letsencrypt-issuer.yaml
apiVersion: cert-manager.io/v1
...
EOF
kubectl apply -f letsencrypt-issuer.yaml
```

---

## Architecture Notes

### Why DNS-01 over HTTP-01?

| | HTTP-01 | DNS-01 |
|---|---|---|
| Mechanism | Temporary pod serves a file at `/.well-known/acme-challenge/` | TXT record created in Route53 |
| Works if cluster is behind firewall | No | Yes |
| Supports wildcard certs | No | Yes |
| IAM required | No | Yes |
| Reliability on EKS | Moderate | High |
| Survives cluster rebuild | No | Yes (IAM role persists) |

![alt text](/images3/03.jpg)


### Why IRSA over static credentials?

Storing AWS access keys as Kubernetes Secrets is a security anti-pattern — they are long-lived, wide-scope, and require manual rotation. IRSA issues short-lived, scoped STS tokens tied to the specific service account and cluster OIDC provider. If the cluster is destroyed, the credentials automatically become invalid.

### Certificate renewal

cert-manager automatically renews certificates 30 days before expiry. Let's Encrypt certificates are valid for 90 days, so renewals occur at approximately 60 days. The renewal process is fully automated — cert-manager repeats the DNS-01 challenge, obtains a new certificate, and replaces the Kubernetes Secret. The Nginx Ingress Controller picks up the updated secret without any pod restarts.

### The `proxy-body-size: 500m` annotation

Without this annotation, Nginx enforces a 1MB default upload limit. Uploading Docker images or large JARs to Artifactory through the ingress will return `413 Request Entity Too Large`. Setting `proxy-body-size: 500m` raises this to 500MB for the Artifactory ingress specifically, without affecting other services.

---