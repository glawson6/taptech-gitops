# Jenkins

Jenkins runs on the management cluster as a GitOps-managed component
(`platform/jenkins/`), and schedules build agents as pods in the
`jenkins-agents` namespace on that same cluster.

Because controller and agents share a cluster there is **no external
authentication to configure** — no API URL, no CA bundle, no service-account
token to paste into the UI. Jenkins uses its own pod identity. The Kubernetes
cloud is declared in JCasC in `platform/jenkins/values.yaml`, not clicked
together in the web interface.

## What Jenkins is allowed to do

`platform/jenkins-agents/rbac.yaml` grants exactly one thing outside its own
namespace: create and watch pods in `jenkins-agents`.

It has no access to Deployments, no access to the `taptech-*` namespaces, and no
credentials for the applications cluster at all. It deploys by committing to
git. Argo CD is the only component that talks to the applications cluster.

## Credentials

All three come from the `taptech-mgmt` 1Password vault via ExternalSecrets in
`platform/jenkins/manifests/mgmt/` — nothing lives in Jenkins' own credential
store, so rotation is a 1Password edit.

| Secret | Namespace | Used for |
|---|---|---|
| `jenkins-admin` | `jenkins` | initial admin login |
| `registry-push` | `jenkins-agents` | pushing images |
| `gitops-repo` | `jenkins-agents` | committing tag bumps here |

## Pipeline shape

The deploy stage is a git commit, not a kubectl call.

```groovy
pipeline {
  agent {
    kubernetes {
      yaml '''
        apiVersion: v1
        kind: Pod
        spec:
          containers:
            - name: maven
              image: maven:3.9-eclipse-temurin-21
              command: ["cat"]
              tty: true
            - name: kaniko
              image: gcr.io/kaniko-project/executor:debug
              command: ["cat"]
              tty: true
              volumeMounts:
                - name: registry
                  mountPath: /kaniko/.docker
            - name: tools
              image: alpine/k8s:1.31.0
              command: ["cat"]
              tty: true
          volumes:
            - name: registry
              secret:
                secretName: registry-push
                items:
                  - key: .dockerconfigjson
                    path: config.json
      '''
    }
  }

  environment {
    APP      = 'customer-service'
    REGISTRY = 'registry.taptech.net/taptech'
    TAG      = "${env.GIT_COMMIT.take(12)}"
  }

  stages {
    stage('Build & test') {
      steps { container('maven') { sh 'mvn -B clean verify' } }
    }

    stage('Image') {
      steps {
        container('kaniko') {
          sh '/kaniko/executor --context=. --destination=$REGISTRY/$APP:$TAG'
        }
      }
    }

    stage('Promote') {
      steps {
        container('tools') {
          withCredentials([usernamePassword(credentialsId: 'gitops-repo',
                                            usernameVariable: 'GIT_USER',
                                            passwordVariable: 'GIT_TOKEN')]) {
            sh '''
              git clone https://$GIT_USER:$GIT_TOKEN@github.com/taptech/taptech-gitops.git gitops
              cd gitops/applications/$APP/overlays/prod
              kustomize edit set image $REGISTRY/$APP=$REGISTRY/$APP:$TAG
              cd -
              cd gitops
              git config user.email jenkins@taptech.net
              git config user.name  jenkins
              git commit -am "deploy($APP): prod -> $TAG [skip ci]"
              git push
            '''
          }
        }
      }
    }
  }
}
```

The commit makes the Argo CD Application OutOfSync. A human presses Sync — prod
has no `automated` block, deliberately. If you would rather the review happen
before the commit lands, have the pipeline open a pull request instead; that is
the stronger gate, since it puts a one-line diff in front of a reviewer.

## Why not Argo CD Image Updater

It watches the registry and writes tags back itself, removing the commit step.
It also means a new image can reach a cluster without anyone deciding it should.
With Jenkins committing, the build that produced the artifact and the commit
that deploys it are one traceable event. Revisit if the commit step becomes
tedious across many services.

## A note on co-location

Jenkins executes code it did not write — `mvn verify` resolves transitive
dependencies and runs their plugins. On the management cluster it shares a pod
network with Argo CD, and Kubernetes namespaces are not a network boundary by
default.

RBAC covers the serious outcomes and is already scoped tightly. NetworkPolicies
would close off reconnaissance and outbound exfiltration; they are deliberately
not in this repo yet. Both MicroK8s (Calico) and K3s (kube-router) enforce them
when you want to add them.
