// CI/CD pipeline: test -> build image -> push to Amazon ECR -> deploy to EKS with Helm -> smoke test.
//
// Runs on the Jenkins EC2 server created by Terraform. AWS access comes from the
// instance's IAM role (no stored keys); Kubernetes access comes from the EKS
// access entry, which is scoped to the application namespace.

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 30, unit: 'MINUTES')
    }

    // Poll GitHub every ~2 minutes so Jenkins doesn't need to be exposed to
    // GitHub webhooks. Swap for githubPush() if you open port 8080 to GitHub.
    triggers {
        pollSCM('H/2 * * * *')
    }

    parameters {
        string(name: 'AWS_REGION',       defaultValue: 'us-east-1',            description: 'AWS region of the cluster and ECR repo')
        string(name: 'EKS_CLUSTER_NAME', defaultValue: 'tech-challenge-2-eks', description: 'Terraform output: cluster_name')
        string(name: 'ECR_REPOSITORY',   defaultValue: 'hello-world',          description: 'ECR repository name')
        string(name: 'K8S_NAMESPACE',    defaultValue: 'hello-world',          description: 'Namespace to deploy into')
    }

    // Parameters are copied into the environment explicitly: on a job's first
    // build Jenkins hasn't registered them yet, so they'd be empty in `sh` steps.
    environment {
        AWS_REGION       = "${params.AWS_REGION ?: 'us-east-1'}"
        EKS_CLUSTER_NAME = "${params.EKS_CLUSTER_NAME ?: 'tech-challenge-2-eks'}"
        ECR_REPOSITORY   = "${params.ECR_REPOSITORY ?: 'hello-world'}"
        K8S_NAMESPACE    = "${params.K8S_NAMESPACE ?: 'hello-world'}"
        RELEASE_NAME = 'hello-world'
        CHART_DIR    = 'charts/hello-world'
        KUBECONFIG   = "${WORKSPACE}/.kube/config"
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.IMAGE_TAG      = sh(returnStdout: true, script: 'git rev-parse --short=12 HEAD').trim()
                    env.AWS_ACCOUNT_ID = sh(returnStdout: true, script: "aws sts get-caller-identity --query Account --output text --region ${params.AWS_REGION}").trim()
                    env.ECR_REGISTRY   = "${env.AWS_ACCOUNT_ID}.dkr.ecr.${params.AWS_REGION}.amazonaws.com"
                    env.IMAGE_URI      = "${env.ECR_REGISTRY}/${params.ECR_REPOSITORY}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.IMAGE_TAG}"
                }
            }
        }

        stage('Unit tests') {
            steps {
                // Run tests in a throwaway container so the Jenkins host needs no Python setup
                sh '''
                    docker run --rm -e PYTHONDONTWRITEBYTECODE=1 \
                      -v "$WORKSPACE/app":/src -w /src python:3.12-slim \
                      sh -c "pip install -q -r requirements-dev.txt && python -m pytest -q -p no:cacheprovider"
                '''
            }
        }

        stage('Lint chart') {
            steps {
                sh 'helm lint "$CHART_DIR"'
            }
        }

        stage('Build & push image') {
            steps {
                sh '''
                    aws ecr get-login-password --region "$AWS_REGION" \
                      | docker login --username AWS --password-stdin "$ECR_REGISTRY"

                    # Tags are immutable in ECR: skip the push if this commit was already built
                    if aws ecr describe-images --region "$AWS_REGION" \
                         --repository-name "$ECR_REPOSITORY" \
                         --image-ids imageTag="$IMAGE_TAG" >/dev/null 2>&1; then
                      echo "Image $IMAGE_URI:$IMAGE_TAG already in ECR, skipping build."
                    else
                      docker build --pull \
                        --build-arg APP_VERSION="$IMAGE_TAG" \
                        -t "$IMAGE_URI:$IMAGE_TAG" app
                      docker push "$IMAGE_URI:$IMAGE_TAG"
                    fi
                '''
            }
        }

        stage('Deploy to EKS') {
            steps {
                sh '''
                    mkdir -p "$(dirname "$KUBECONFIG")"
                    aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"

                    # --atomic rolls back automatically if the rollout doesn't become healthy
                    helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
                      --namespace "$K8S_NAMESPACE" \
                      --set image.repository="$IMAGE_URI" \
                      --set image.tag="$IMAGE_TAG" \
                      --atomic --wait --timeout 5m

                    kubectl get deploy,hpa,ingress,pods -n "$K8S_NAMESPACE" -o wide
                '''
            }
        }

        stage('Smoke test') {
            steps {
                script {
                    // A brand new ALB needs a few minutes before DNS resolves
                    def host = ''
                    timeout(time: 6, unit: 'MINUTES') {
                        waitUntil(initialRecurrencePeriod: 10000) {
                            host = sh(returnStdout: true, script: '''
                                kubectl get ingress "$RELEASE_NAME" -n "$K8S_NAMESPACE" \
                                  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
                            ''').trim()
                            if (!host) { return false }
                            return sh(returnStatus: true, script: "curl -fsS --max-time 5 http://${host}/ | grep -q 'Hello, World!'") == 0
                        }
                    }
                    env.APP_URL = "http://${host}/"
                    currentBuild.description = env.APP_URL
                    echo "Application is live at ${env.APP_URL}"
                }
            }
        }
    }

    post {
        always {
            sh 'docker image rm "$IMAGE_URI:$IMAGE_TAG" >/dev/null 2>&1 || true'
        }
        success {
            echo "Deployed ${env.IMAGE_URI}:${env.IMAGE_TAG} -> ${env.APP_URL}"
        }
    }
}
