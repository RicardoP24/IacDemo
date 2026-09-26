# IacDemo: secure multi-tenant platform on Amazon EKS

Five clients, each running two applications, used to live on separate servers. This project consolidates them
into **one Amazon EKS cluster with one namespace per client**, provisioned with **Terraform (AWS provider)**,
packaged with **Helm** and delivered through **GitOps with Argo CD** by a **Jenkins DevSecOps pipeline** whose host is
provisioned and hardened with **Ansible**. Security controls cover every layer: code, dependencies, IaC, images,
delivery, admission, network, edge (WAF), runtime (IDS/IPS), cloud (GuardDuty) and the CI host itself.

> Based on a real architecture study: migrating several clients hosted on different servers to a single
> Kubernetes cluster, isolated by namespace.

## Architecture

```mermaid
flowchart LR
    user((Internet)) --> waf["AWS WAF<br/>managed rules + rate limit"]
    waf --> alb["Shared ALB<br/>one path per tenant"]

    subgraph vpc["VPC 10.20.0.0/16 · eu-west-3 (Paris)"]
        alb
        subgraph eks["EKS · private subnets"]
            subgraph a["namespace client-a"]
                wa[web] --> aa[api]
            end
            subgraph e["namespaces client-b … client-e"]
                we[web] --> ae[api]
            end
            kyv["Kyverno<br/>admission control"]
            falco["Falco + Talon<br/>runtime IDS / IPS"]
            argo["Argo CD<br/>GitOps"]
        end
    end

    alb -->|/client-a/| wa
    alb -->|/client-b/ … /client-e/| we
    git[("Git repository<br/>desired state")] -. pulled by .-> argo
    argo -. syncs .-> a
    argo -. syncs .-> e
    ecr[("ECR<br/>immutable tags, KMS")] -. signed images .-> eks
    gd["GuardDuty<br/>EKS audit + runtime"] -. detects .-> eks
```

| Component | Choice |
|---|---|
| Infrastructure | Terraform: VPC (public/private subnets, NAT, flow logs), EKS 1.35 managed nodes (AL2023), ECR, WAFv2, GuardDuty, KMS |
| Platform | Terraform + Helm: AWS Load Balancer Controller, metrics-server, Kyverno, Falco + Falco Talon, Argo CD, tenant namespaces |
| Workloads | `helm/tenant-app`: `web` (nginx, unprivileged) + `api` (Python/Flask), one Argo CD Application per tenant |
| Delivery | GitOps: the pipeline commits the release (signed image digests) to Git; Argo CD pulls it and keeps the cluster in sync |
| CI | Jenkins configured as code (JCasC), SSH build agent, Docker-in-Docker over mutual TLS |
| CI host | Ansible: hardened RHEL 9 server running Docker Engine and the Jenkins stack, tested with Molecule |
| Identity | EKS access entries, EKS Pod Identity for add-ons, short-lived AWS role for the pipeline |

## Tenant isolation

Every tenant namespace is created by Terraform (`terraform/platform/tenants.tf`) **with its guardrails already in place**, before any workload is deployed:

| Guardrail | What it prevents |
|---|---|
| Pod Security Admission `restricted` | privileged pods, root, host access, privilege escalation |
| `ResourceQuota` + `LimitRange` | one client starving the others (noisy neighbour) |
| `NetworkPolicy` default deny (in + out) | any traffic not explicitly allowed; cross-tenant access |
| Workload policies: ALB → web → api | only the ALB subnets reach `web`; only `web` reaches `api` |
| Namespaced RBAC (`iacdemo:<tenant>:developers`) | a client's developers seeing other clients |
| Kyverno policies | untrusted registries, mutable tags, unsigned images, missing limits |
| Argo CD `AppProject` | delivering outside the tenant namespaces, cluster-scoped objects, or touching quotas and RBAC |

All five tenants share **one ALB** (IngressGroup, path `/<tenant>/`), which keeps cost flat as tenants are added.

## Defense in depth

| Layer | Control | Type |
|---|---|---|
| Source | Gitleaks on the full git history | gate |
| Source | Semgrep SAST (Python, Dockerfile, OWASP Top 10) | gate |
| Dependencies | Trivy SCA; `pip install --require-hashes` | gate |
| IaC | Checkov (Terraform, rendered manifests, Dockerfiles, Terraform plan, Ansible), hadolint, `terraform validate` | gate |
| Configuration | ansible-lint (`production` profile); Molecule converge + idempotence + verify | gate |
| Policies | Kyverno CLI tests for the admission policies | gate |
| Images | Trivy image scan (HIGH/CRITICAL), CycloneDX SBOM (Syft) | gate |
| Supply chain | cosign signature + signed SBOM attestation; ECR immutable tags; deploy by digest | prevent |
| Delivery | **Argo CD**: tenant namespaces and 7 resource kinds only; self-heal reverts manual drift; no Git credentials in the cluster | prevent |
| Admission | Kyverno: trusted registry, digest only, **signature verification**, resources | prevent |
| Edge | **AWS WAF**: IP reputation, OWASP common rules, known bad inputs (Log4j), SQLi, Linux, rate limit | **IPS (L7)** |
| Runtime | **Falco** (eBPF syscalls) with a custom "shell in tenant container" rule | **IDS** |
| Runtime | **Falco Talon** reacts to Falco: isolates the pod (NetworkPolicy) and labels it quarantined | **IPS** |
| Cloud | **GuardDuty**: VPC flow/DNS/CloudTrail, EKS audit logs, EKS runtime monitoring | **IDS** |
| Audit | EKS control-plane, VPC Flow Logs and WAF logs, KMS-encrypted, 365-day retention | detect |
| Post-deploy | WAF smoke test (SQLi/XSS must get HTTP 403) + OWASP ZAP baseline | gate |
| Hosts | IMDSv2 only with hop limit 1, encrypted EBS, nodes in private subnets | prevent |
| CI host | **Ansible**: SSH keys only, firewalld (SSH only), CIS-style sysctl, auditd, daily security updates, Docker from a fingerprint-verified repository | prevent |

## Pipeline

```mermaid
flowchart LR
    A[Gitleaks] --> B{{"parallel:<br/>pytest · Semgrep · Trivy SCA<br/>Checkov + hadolint · terraform validate<br/>ansible-lint · Kyverno policy tests"}}
    B --> C[Build images] --> D[Trivy image + SBOM]
    D --> E[Terraform plan<br/>+ Checkov on plan] --> F{{Manual approval}}
    F --> G[Apply infra] --> H[Push + cosign sign/attest]
    H --> I[Apply platform<br/>incl. Argo CD] --> J[Commit release<br/>to Git] --> J2[Argo CD sync<br/>5 tenants] --> K[WAF smoke test<br/>+ OWASP ZAP]
```

Branches other than `main` run every gate up to the image scan; nothing touches AWS.
`main` adds the plan, a **manual approval**, the release and the DAST. The pipeline never runs `kubectl apply` or
`helm install` against the tenants: it commits the release and waits until Argo CD reports every tenant **Synced and
Healthy at that commit**. A `DESTROY` parameter tears everything down in the right order (tenants → platform → infrastructure).

## GitOps delivery (Argo CD)

**CI pushes, CD pulls.** Jenkins builds, scans and signs the images, then commits their digests to
`gitops/release.yaml`. Argo CD, inside the cluster, reads the repository and applies it.

| Piece | Role |
|---|---|
| `helm/gitops` · ApplicationSet | one Application per file in `tenants/`: onboarding a client is one pull request |
| `helm/gitops` · AppProject | Argo CD may deploy only into the tenant namespaces, only the 7 kinds the tenant chart uses, nothing cluster-scoped |
| `gitops/release.yaml` | the only file the pipeline writes; rolling back is a `git revert` |
| `terraform/platform/argocd.tf` | Argo CD (chart pinned) with NetworkPolicies, Pod Security `restricted`, no public endpoint, read-only default role, no web terminal |

Each tenant is rendered from `tenants/<client>.yaml`, then `gitops/release.yaml`, then the infrastructure values
Terraform passes in (registry, WAF ARN, ALB subnets). Sync is automated with **prune** and **self-heal**: a manual
`kubectl` change is reverted within minutes.

The repository is public, so Argo CD holds **no Git credentials**. Jenkins commits with a token limited to this
repository, and recognises its own release commits so they do not trigger another release. `main` should be
protected: changes arrive through pull requests whose pipeline passed, and only the release bot pushes directly.

## Jenkins host (Ansible)

`ansible/` turns a fresh RHEL 9 server (RHEL, Rocky Linux, AlmaLinux or Oracle Linux) into the Jenkins host:

| Role | What it does |
|---|---|
| `hardening` | SSH keys only (no root, no passwords, local tunnels only), firewalld with SSH only, CIS-style kernel parameters, auditd rules (SSH, sudo, identities), daily security updates with dnf-automatic |
| `docker` | Docker Engine from Docker's repository with the signing key pinned by fingerprint; daemon with live-restore, `no-new-privileges` and log rotation; the Docker CLI is audited |
| `jenkins_stack` | copies `jenkins/`, generates the agent SSH key and admin password on the host (never logged), builds and starts the stack |

```bash
cd ansible
cp inventory.example.yml inventory.yml        # your host and user (git-ignored)
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml
```

`molecule test` runs the playbook twice on Rocky Linux 9 (systemd in Docker): the second run must change nothing,
then the result is verified. Container kernels cannot run firewalld or auditd, so those two are applied on real hosts only.

## Repository layout

```
├── Jenkinsfile                   # the pipeline
├── apps/
│   ├── api/                      # Flask API, tests, hashed requirements, non-root Dockerfile
│   └── web/                      # static front-end, hardened nginx config, unprivileged image
├── helm/
│   ├── tenant-app/               # web + api, one Argo CD Application per tenant
│   ├── cluster-policies/         # Kyverno policies + CLI tests
│   └── gitops/                   # Argo CD AppProject + ApplicationSet
├── gitops/release.yaml           # the release Argo CD deploys (written by the pipeline)
├── tenants/                      # client-a … client-e values (only what differs per client)
├── ansible/                      # Jenkins host: hardening, Docker, Jenkins stack + Molecule tests
├── terraform/
│   ├── bootstrap/                # state bucket (S3 native locking) + CI role
│   ├── infra/                    # VPC, EKS, ECR, WAF, GuardDuty, KMS
│   └── platform/                 # add-ons, Argo CD, tenant namespaces and guardrails
├── jenkins/                      # controller (JCasC), agent (toolchain), DinD, docker-compose
├── .checkov.yaml                 # scanner config; exceptions are inline, each with a reason
└── .zap/baseline.conf            # DAST rules that fail the build
```

## Running it

**Prerequisites:** an AWS account, Docker, Terraform ≥ 1.10, AWS CLI v2, cosign; Ansible ≥ 2.17 for a dedicated Jenkins host.

1. **Bootstrap** (once, with an administrator profile). Create an IAM user for Jenkins whose only permission is
   `sts:AssumeRole` on the CI role, then:
   ```bash
   terraform -chdir=terraform/bootstrap init
   terraform -chdir=terraform/bootstrap apply \
     -var state_bucket_name=<unique-bucket-name> \
     -var ci_principal_arn=arn:aws:iam::<account-id>:user/<jenkins-user>
   ```
2. **Signing key:** `cosign generate-key-pair` (keep `cosign.key` out of git; it goes into Jenkins).
3. **Jenkins**, either on your machine or on a RHEL 9 server provisioned by Ansible (see [Jenkins host](#jenkins-host-ansible)):
   ```bash
   cd jenkins && ./setup.sh && docker compose up -d --build   # UI: http://localhost:8080
   ```
   - Credentials: `aws-iacdemo` (AWS credentials of the Jenkins user), `cosign-key` (secret file), `cosign-password` (secret text),
     `github-release` (username + fine-grained token with *Contents: read and write* on this repository only).
   - Global properties: `TF_STATE_BUCKET`, `CI_ROLE_ARN`, `EKS_PUBLIC_ACCESS_CIDRS` (e.g. `["203.0.113.10/32"]`, your public IP).
4. **Run** the `iacdemo` job on `main` and approve. When it finishes, open `http://<alb-dns>/client-a/`.
   Argo CD's UI is not exposed; open it through the API server:
   ```bash
   kubectl -n argocd port-forward svc/argocd-server 8443:443                       # https://localhost:8443
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
   ```

### See the controls in action

```bash
# WAF (IPS): blocked at the edge
curl -i "http://<alb-dns>/client-a/?id=1'%20OR%20'1'='1"            # 403

# Kyverno: an image that is not ours, not signed, not pinned
kubectl -n client-a run test --image=nginx                          # denied

# Network isolation: client-b cannot reach client-a
kubectl -n client-b exec deploy/web -- wget -qO- -T 3 http://api.client-a:8080/api/info   # times out

# GitOps self-heal: a manual change is reverted
kubectl -n client-a delete deployment api
kubectl -n argocd get application client-a -w                     # OutOfSync, then Synced: the Deployment is back

# Runtime IDS/IPS: an interactive shell in a tenant pod
kubectl -n client-a exec -it deploy/api -- sh
kubectl -n client-a get pods -l iacdemo.io/quarantine=true         # isolated and labelled by Falco Talon
kubectl -n falco logs -l app.kubernetes.io/name=falco | grep "Shell in tenant container"
```

### Cost and teardown

Roughly **USD 6–8 per day** (EKS control plane, 3 × t3.medium, one NAT gateway, ALB, WAF; GuardDuty after its
30-day trial). Run the pipeline with **`DESTROY=true`** when you are done.

## Checks without AWS

Everything below runs locally and in the pipeline's gates:

```bash
terraform fmt -check -recursive terraform
for s in bootstrap infra platform; do terraform -chdir=terraform/$s init -backend=false && terraform -chdir=terraform/$s validate; done
checkov --config-file .checkov.yaml -d terraform --framework terraform
hadolint apps/*/Dockerfile jenkins/*/Dockerfile
semgrep scan --config p/python --config p/dockerfile --config p/owasp-top-ten apps/
trivy fs --scanners vuln --severity HIGH,CRITICAL apps/
(cd apps/api && pip install --require-hashes -r requirements-dev.txt && pytest)
helm lint helm/gitops --set-json 'tenants=["client-a"]'
checkov -d ansible --framework ansible
(cd ansible && ansible-lint --profile production && molecule test)     # molecule needs Docker
```

## Design decisions and trade-offs

| Decision | Why | In production |
|---|---|---|
| Namespace per tenant (soft multi-tenancy) | cost and operational simplicity for trusted clients | dedicated node pools or clusters for untrusted tenants |
| One shared ALB (IngressGroup) | one load balancer instead of five | same, with HTTPS (`ingress.certificateArn`) and a domain per tenant |
| Public EKS endpoint, CIDR allow-listed | Jenkins runs outside the VPC | private endpoint with in-VPC runners |
| CI role with AdministratorAccess | EKS needs to create IAM roles; the role is assume-only with 1 h sessions | least-privilege policy + permissions boundary |
| Single NAT gateway | cost | one NAT gateway per AZ |
| Kyverno at 1 replica per controller | demo sizing | 3 admission-controller replicas |
| DinD (privileged) for builds | isolates builds from the host's Docker daemon | ephemeral Kubernetes agents with rootless BuildKit |
| Signatures not sent to public Rekor | private images; digests would be public | private transparency log or keyless signing with OIDC |
| Falco Talon for automated response | upstream Falco response engine; last release is from February 2025 | evaluate its maturity before depending on it |
| Code and desired state in one repository | one place to read; the pipeline commits only `gitops/release.yaml` | a separate configuration repository, with promotion between environments by pull request |
| Argo CD admin user, no SSO | demo | OIDC SSO, admin disabled, RBAC per team |
| One hardened VM for Jenkins | simple to run and to reason about | ephemeral agents; a golden image built with Packer from the same Ansible roles |

## Next steps

- AWS Network Firewall (Suricata rules) for egress inspection
- Forward Falco and GuardDuty findings to a SIEM (Wazuh)
- External Secrets Operator for application secrets
- Karpenter for node autoscaling

---

Ricardo Pilartes da Silva · [LinkedIn](https://www.linkedin.com/in/ricardo-pilartes-da-silva-54243b221/) · [GitHub](https://github.com/RicardoP24)
