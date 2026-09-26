// IacDemo: secure CI/CD for a multi-tenant EKS platform
//
//   secrets scan -> tests / SAST / SCA / IaC + Ansible scan / policy tests -> build -> image scan + SBOM
//   -> [main + approval] Terraform infra -> push + sign images -> Terraform platform (incl. Argo CD)
//   -> GitOps release commit (signed digests) -> Argo CD syncs 5 tenants x 2 apps -> DAST + WAF smoke test
//
// CI pushes, CD pulls: this pipeline never deploys workloads itself. It commits the release to
// gitops/release.yaml and Argo CD, running inside the cluster, applies it.
//
// Jenkins configuration (Manage Jenkins):
//   Credentials:        aws-iacdemo (AWS keys that can only sts:AssumeRole), cosign-key (file), cosign-password (text),
//                       github-release (username + fine-grained token: Contents read/write on this repository only)
//   Global properties:  TF_STATE_BUCKET, CI_ROLE_ARN, EKS_PUBLIC_ACCESS_CIDRS (JSON list, e.g. ["203.0.113.10/32"])

// Runs the body with short-lived credentials of the CI role (1h session).
// The Jenkins credential itself can do nothing except assume that role.
def withAwsRole(Closure body) {
    withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-iacdemo',
                      accessKeyVariable: 'AWS_ACCESS_KEY_ID', secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
        writeFile file: '.aws/config', text: """[profile iacdemo]
role_arn = ${env.CI_ROLE_ARN}
credential_source = Environment
role_session_name = jenkins-${env.BUILD_NUMBER}
duration_seconds = 3600
region = ${env.AWS_REGION}
"""
        withEnv(["AWS_CONFIG_FILE=${env.WORKSPACE}/.aws/config", 'AWS_PROFILE=iacdemo',
                 "KUBECONFIG=${env.WORKSPACE}/.kube/config"]) {
            body()
        }
    }
}

def tfInit(String stack) {
    sh """
        terraform -chdir=terraform/${stack} init -input=false -reconfigure \
            -backend-config="bucket=\${TF_STATE_BUCKET}" -backend-config="region=\${AWS_REGION}"
    """
}

pipeline {
    agent { label 'devsecops' }

    options {
        timestamps()
        ansiColor('xterm')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 90, unit: 'MINUTES')
    }

    parameters {
        booleanParam(name: 'DEPLOY', defaultValue: true,
                     description: 'main branch only: provision AWS and deploy the tenants (manual approval required)')
        booleanParam(name: 'DESTROY', defaultValue: false,
                     description: 'main branch only: tear down tenants, platform and infrastructure (manual approval required)')
    }

    environment {
        AWS_REGION         = 'eu-west-3'
        AWS_DEFAULT_REGION = 'eu-west-3'
        TF_IN_AUTOMATION   = 'true'
        TF_INPUT           = '0'
        TF_VAR_state_bucket            = "${env.TF_STATE_BUCKET}"
        TF_VAR_eks_public_access_cidrs = "${env.EKS_PUBLIC_ACCESS_CIDRS}"
        SEVERITY    = 'HIGH,CRITICAL'
        DAST_TENANT = 'client-a'
        RELEASE_FILE      = 'gitops/release.yaml'
        RELEASE_BOT       = 'iacdemo-release-bot'
        RELEASE_BOT_EMAIL = 'iacdemo-release-bot@users.noreply.github.com'
    }

    stages {
        stage('Init') {
            steps {
                script {
                    env.IMAGE_TAG = sh(script: 'git rev-parse --short=12 HEAD', returnStdout: true).trim()
                    env.ON_MAIN = (env.BRANCH_NAME == 'main').toString()

                    // The release commit pushed by this pipeline triggers a new build: skip it, or
                    // every release would start another one. Only commits by the release bot that
                    // touch nothing but the release file qualify.
                    def author = sh(script: 'git log -1 --format=%ae', returnStdout: true).trim()
                    def changed = sh(script: 'git diff --name-only HEAD~1 HEAD', returnStdout: true).trim()
                    env.RELEASE_COMMIT = (author == env.RELEASE_BOT_EMAIL && changed == env.RELEASE_FILE).toString()
                    if (env.RELEASE_COMMIT == 'true') {
                        currentBuild.description = 'GitOps release commit: already built, nothing to do'
                    }

                    env.DO_DEPLOY = (env.ON_MAIN == 'true' && params.DEPLOY && !params.DESTROY && env.RELEASE_COMMIT != 'true').toString()
                    env.DO_DESTROY = (env.ON_MAIN == 'true' && params.DESTROY).toString()
                    env.RUN_GATES = (env.DO_DESTROY != 'true' && env.RELEASE_COMMIT != 'true').toString()
                    if (env.DO_DEPLOY == 'true' || env.DO_DESTROY == 'true') {
                        ['TF_STATE_BUCKET', 'CI_ROLE_ARN', 'EKS_PUBLIC_ACCESS_CIDRS'].each { name ->
                            if (!env."${name}") {
                                error("Global property ${name} is not set (see README > Jenkins configuration)")
                            }
                        }
                    }
                }
                sh 'mkdir -p reports/rendered'
            }
        }

        stage('Secrets scan (Gitleaks)') {
            when { expression { env.RUN_GATES == 'true' } }
            steps {
                // Whole git history, not just the current tree.
                sh 'gitleaks git --no-banner --redact --report-format sarif --report-path reports/gitleaks.sarif .'
            }
        }

        stage('Quality & security gates') {
            when { expression { env.RUN_GATES == 'true' } }
            parallel {
                stage('Unit tests') {
                    steps {
                        dir('apps/api') {
                            sh '''
                                python3 -m venv .venv
                                .venv/bin/pip install --quiet --require-hashes -r requirements-dev.txt
                                .venv/bin/pytest --junitxml=../../reports/pytest.xml
                            '''
                        }
                    }
                }

                stage('SAST (Semgrep)') {
                    steps {
                        sh '''
                            semgrep scan --metrics=off --error \
                                --config p/python --config p/dockerfile --config p/owasp-top-ten \
                                --exclude .venv \
                                --sarif --output reports/semgrep.sarif apps/
                        '''
                    }
                }

                stage('SCA (Trivy)') {
                    steps {
                        sh '''
                            trivy fs --quiet --scanners vuln --ignore-unfixed --severity "$SEVERITY" \
                                --skip-dirs apps/api/.venv --format sarif --output reports/trivy-deps.sarif apps/
                            trivy fs --quiet --scanners vuln --ignore-unfixed --severity "$SEVERITY" \
                                --skip-dirs apps/api/.venv --exit-code 1 apps/
                        '''
                    }
                }

                stage('IaC & Kubernetes scan') {
                    steps {
                        sh '''
                            hadolint --failure-threshold warning \
                                apps/api/Dockerfile apps/web/Dockerfile jenkins/agent/Dockerfile jenkins/controller/Dockerfile

                            # Render every tenant exactly as it will be deployed (placeholder digests/ARNs).
                            ZERO="sha256:$(printf '%064d' 0)"
                            for values in tenants/*.yaml; do
                                tenant=$(basename "$values" .yaml)
                                helm template "$tenant" helm/tenant-app --namespace "$tenant" -f "$values" \
                                    --set imageRegistry=123456789012.dkr.ecr.eu-west-3.amazonaws.com \
                                    --set api.image.digest="$ZERO" --set web.image.digest="$ZERO" \
                                    --set ingress.wafAclArn=arn:aws:wafv2:eu-west-3:123456789012:regional/webacl/x/y \
                                    --set-json 'networkPolicy.albSourceCidrs=["10.20.0.0/24","10.20.1.0/24"]' \
                                    > "reports/rendered/${tenant}.yaml"
                            done

                            checkov --config-file .checkov.yaml -d terraform --framework terraform \
                                -o cli -o sarif --output-file-path console,reports/checkov-terraform
                            checkov --config-file .checkov.yaml -d reports/rendered --framework kubernetes \
                                -o cli -o sarif --output-file-path console,reports/checkov-kubernetes
                            checkov --config-file .checkov.yaml -d ansible --framework ansible \
                                -o cli -o sarif --output-file-path console,reports/checkov-ansible

                            # Argo CD project + ApplicationSet chart
                            helm lint helm/gitops --set-json 'tenants=["client-a"]'
                        '''
                    }
                }

                stage('Ansible lint') {
                    steps {
                        dir('ansible') {
                            sh '''
                                ansible-galaxy collection install -r requirements.yml
                                ansible-lint --profile production --format sarif > ../reports/ansible-lint.sarif \
                                    || { ansible-lint --profile production; exit 1; }
                            '''
                        }
                    }
                }

                stage('Terraform validate') {
                    steps {
                        sh '''
                            terraform fmt -check -recursive terraform
                            for stack in bootstrap infra platform; do
                                terraform -chdir=terraform/$stack init -backend=false -input=false
                                terraform -chdir=terraform/$stack validate
                            done
                        '''
                    }
                }

                stage('Policy tests (Kyverno)') {
                    steps {
                        sh '''
                            helm lint helm/cluster-policies --set trustedRegistry=r.example --set cosignPublicKey=unused
                            helm template cluster-policies helm/cluster-policies \
                                --set trustedRegistry=123456789012.dkr.ecr.eu-west-3.amazonaws.com --set cosignPublicKey=unused \
                                --show-only templates/require-trusted-images.yaml --show-only templates/require-resources.yaml \
                                > helm/cluster-policies/tests/rendered-policies.yaml
                            kyverno test helm/cluster-policies/tests
                        '''
                    }
                }
            }
        }

        stage('Build images') {
            when { expression { env.RUN_GATES == 'true' } }
            steps {
                sh '''
                    for app in api web; do
                        docker build --pull --tag "iacdemo/$app:$IMAGE_TAG" \
                            --label org.opencontainers.image.revision="$(git rev-parse HEAD)" "apps/$app"
                    done
                '''
            }
        }

        stage('Image scan & SBOM') {
            when { expression { env.RUN_GATES == 'true' } }
            steps {
                sh '''
                    for app in api web; do
                        trivy image --quiet --ignore-unfixed --severity "$SEVERITY" \
                            --format sarif --output "reports/trivy-image-$app.sarif" "iacdemo/$app:$IMAGE_TAG"
                        trivy image --quiet --ignore-unfixed --severity "$SEVERITY" --exit-code 1 "iacdemo/$app:$IMAGE_TAG"
                        syft "iacdemo/$app:$IMAGE_TAG" --quiet -o "cyclonedx-json=reports/sbom-$app.cdx.json"
                    done
                '''
            }
        }

        stage('Terraform plan (infra)') {
            when { expression { env.DO_DEPLOY == 'true' } }
            steps {
                script {
                    withAwsRole {
                        tfInit('infra')
                        sh '''
                            terraform -chdir=terraform/infra plan -input=false -out=tfplan
                            terraform -chdir=terraform/infra show -no-color tfplan > reports/infra-plan.txt
                            # Scan the resolved plan too (covers resources created inside registry modules).
                            terraform -chdir=terraform/infra show -json tfplan > reports/infra-plan.json
                            checkov -f reports/infra-plan.json --framework terraform_plan --soft-fail \
                                -o cli -o sarif --output-file-path console,reports/checkov-plan
                        '''
                    }
                }
            }
        }

        stage('Approval') {
            when { expression { env.DO_DEPLOY == 'true' } }
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input message: 'Review reports/infra-plan.txt. Apply to AWS and deploy the 5 tenants?', ok: 'Deploy'
                }
            }
        }

        stage('Terraform apply (infra)') {
            when { expression { env.DO_DEPLOY == 'true' } }
            steps {
                script {
                    withAwsRole {
                        sh 'terraform -chdir=terraform/infra apply -input=false tfplan'
                    }
                }
            }
        }

        stage('Push & sign images') {
            when { expression { env.DO_DEPLOY == 'true' } }
            steps {
                script {
                    withAwsRole {
                        withCredentials([file(credentialsId: 'cosign-key', variable: 'COSIGN_KEY'),
                                         string(credentialsId: 'cosign-password', variable: 'COSIGN_PASSWORD')]) {
                            sh '''
                                REGISTRY=$(terraform -chdir=terraform/infra output -raw ecr_registry)
                                aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"

                                for app in api web; do
                                    target="$REGISTRY/iacdemo/$app"
                                    docker tag "iacdemo/$app:$IMAGE_TAG" "$target:$IMAGE_TAG"
                                    docker push "$target:$IMAGE_TAG"
                                    digest=$(docker inspect --format '{{index .RepoDigests 0}}' "$target:$IMAGE_TAG" | cut -d@ -f2)
                                    echo "$digest" > "reports/$app.digest"

                                    # Sign the digest and attach the SBOM as a signed attestation.
                                    # Private images: signatures are not uploaded to the public Rekor log.
                                    cosign sign --yes --key "$COSIGN_KEY" --tlog-upload=false "$target@$digest"
                                    cosign attest --yes --key "$COSIGN_KEY" --tlog-upload=false \
                                        --type cyclonedx --predicate "reports/sbom-$app.cdx.json" "$target@$digest"
                                done
                            '''
                        }
                    }
                }
            }
        }

        stage('Terraform apply (platform)') {
            when { expression { env.DO_DEPLOY == 'true' } }
            steps {
                script {
                    withAwsRole {
                        withCredentials([file(credentialsId: 'cosign-key', variable: 'COSIGN_KEY'),
                                         string(credentialsId: 'cosign-password', variable: 'COSIGN_PASSWORD')]) {
                            tfInit('platform')
                            sh '''
                                export TF_VAR_cosign_public_key="$(cosign public-key --key "$COSIGN_KEY")"
                                terraform -chdir=terraform/platform plan -input=false -out=tfplan
                                terraform -chdir=terraform/platform show -no-color tfplan > reports/platform-plan.txt
                                terraform -chdir=terraform/platform apply -input=false tfplan
                            '''
                        }
                    }
                }
            }
        }

        stage('Release (GitOps commit)') {
            when { expression { env.DO_DEPLOY == 'true' } }
            steps {
                withCredentials([usernamePassword(credentialsId: 'github-release',
                                                  usernameVariable: 'GIT_USER', passwordVariable: 'GIT_TOKEN')]) {
                    sh '''
                        # The desired state for every tenant: the signed digests built by this run.
                        cat > "$RELEASE_FILE" <<EOF
# The release every tenant runs. Written only by the Jenkins pipeline ("Release (GitOps
# commit)" stage), after the images have passed every gate and been pushed and signed.
# Argo CD deploys exactly these digests; rolling back is a git revert of the commit.
appVersion: "$IMAGE_TAG"
api:
  image:
    digest: "$(cat reports/api.digest)"
web:
  image:
    digest: "$(cat reports/web.digest)"
EOF
                        git add "$RELEASE_FILE"
                        if git diff --cached --quiet; then
                            echo "Release unchanged: these digests are already deployed"
                        else
                            git -c user.name="$RELEASE_BOT" -c user.email="$RELEASE_BOT_EMAIL" \
                                commit --quiet -m "release: $IMAGE_TAG [skip ci]" -m "Build $BUILD_URL"
                            # The token reaches git through a credential helper, never the command line or the logs.
                            for attempt in 1 2 3; do
                                git -c credential.helper= \
                                    -c credential.helper='!f() { echo "username=$GIT_USER"; echo "password=$GIT_TOKEN"; }; f' \
                                    push origin HEAD:main && break
                                [ "$attempt" = 3 ] && exit 1
                                git pull --rebase --quiet origin main   # main moved: replay the release on top
                            done
                        fi
                        git rev-parse HEAD > reports/release.sha
                        echo "Release commit: $(cat reports/release.sha)"
                    '''
                }
            }
        }

        stage('Argo CD sync') {
            when { expression { env.DO_DEPLOY == 'true' } }
            steps {
                script {
                    withAwsRole {
                        sh '''
                            aws eks update-kubeconfig --name "$(terraform -chdir=terraform/infra output -raw cluster_name)"
                            RELEASE=$(cat reports/release.sha)
                            deadline=$(( $(date +%s) + 900 ))

                            for values in tenants/*.yaml; do
                                app=$(basename "$values" .yaml)
                                until kubectl -n argocd get application "$app" >/dev/null 2>&1; do
                                    [ "$(date +%s)" -lt "$deadline" ] || { echo "Application $app was not generated"; exit 1; }
                                    sleep 5
                                done
                                # Read Git now instead of waiting for the next polling cycle.
                                kubectl -n argocd annotate application "$app" argocd.argoproj.io/refresh=normal --overwrite
                            done

                            for values in tenants/*.yaml; do
                                app=$(basename "$values" .yaml)
                                until [ "$(kubectl -n argocd get application "$app" \
                                        -o jsonpath='{.status.sync.revision} {.status.sync.status} {.status.health.status}')" \
                                        = "$RELEASE Synced Healthy" ]; do
                                    if [ "$(date +%s)" -ge "$deadline" ]; then
                                        kubectl -n argocd get applications -o wide
                                        echo "Argo CD did not converge on $RELEASE"; exit 1
                                    fi
                                    sleep 10
                                done
                                echo "$app: Synced and Healthy at ${RELEASE}"
                            done
                            kubectl get pods -A -l app.kubernetes.io/part-of=iacdemo
                        '''
                    }
                }
            }
        }

        stage('DAST & WAF smoke test') {
            when { expression { env.DO_DEPLOY == 'true' } }
            steps {
                script {
                    withAwsRole {
                        sh '''
                            ALB=$(kubectl -n "$DAST_TENANT" get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
                            URL="http://$ALB/$DAST_TENANT/"
                            echo "Waiting for $URL"
                            for i in $(seq 1 40); do curl -fsS -o /dev/null "$URL" && break; sleep 15; done

                            # The WAF must block classic attacks before they reach any tenant.
                            for payload in "id=1%27%20OR%20%271%27%3D%271" "q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"; do
                                code=$(curl -s -o /dev/null -w '%{http_code}' "$URL?$payload")
                                echo "WAF check $payload -> HTTP $code"
                                [ "$code" = "403" ] || { echo "WAF did not block the request"; exit 1; }
                            done

                            # OWASP ZAP baseline (passive). Rules marked FAIL in .zap/baseline.conf break the build.
                            cp .zap/baseline.conf reports/
                            docker run --rm -v "$WORKSPACE/reports:/zap/wrk:rw" ghcr.io/zaproxy/zaproxy:2.17.0 \
                                zap-baseline.py -t "$URL" -c baseline.conf -I \
                                -r "zap-$DAST_TENANT.html" -J "zap-$DAST_TENANT.json"
                        '''
                    }
                }
            }
        }

        stage('Destroy') {
            when { expression { env.DO_DESTROY == 'true' } }
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input message: 'Destroy ALL tenants, the platform and the AWS infrastructure?', ok: 'Destroy'
                }
                script {
                    withAwsRole {
                        tfInit('infra')
                        tfInit('platform')
                        sh '''
                            # 1. Tenants first. Deleting the ApplicationSet deletes the Applications, whose
                            #    finalizer deletes the workloads; the load balancer controller then removes the ALB.
                            if aws eks update-kubeconfig --name "$(terraform -chdir=terraform/infra output -raw cluster_name)"; then
                                kubectl -n argocd delete applicationset tenants --ignore-not-found --wait=true --timeout=5m || true
                                kubectl -n argocd wait --for=delete applications -l app.kubernetes.io/part-of=iacdemo --timeout=10m || true
                                sleep 60
                            fi
                            # 2. Platform add-ons, 3. infrastructure.
                            terraform -chdir=terraform/platform destroy -input=false -auto-approve -var cosign_public_key=unused
                            terraform -chdir=terraform/infra destroy -input=false -auto-approve
                        '''
                    }
                }
            }
        }
    }

    post {
        always {
            junit allowEmptyResults: true, testResults: 'reports/pytest.xml'
            recordIssues enabledForFailure: true, tools: [sarif(pattern: 'reports/**/*.sarif')]
            publishHTML(target: [reportDir: 'reports', reportFiles: "zap-${env.DAST_TENANT}.html", reportName: 'OWASP ZAP',
                                 allowMissing: true, keepAll: true, alwaysLinkToLastBuild: true])
            archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true, fingerprint: true
        }
        cleanup {
            cleanWs()
        }
    }
}
