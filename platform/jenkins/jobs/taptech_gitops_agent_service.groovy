// JobDSL definition for the taptech-gitops-agent-service deploy pipeline.
// Materialized by the `seed-jobs` job on every git push to
// taptech-gitops/platform/jenkins/jobs/.
//
// Downstream Jenkinsfile lives in the SOURCE repo:
//   taptech-gitops-agent/Jenkinsfile
//
// (Repo name confirmed by user: 'taptech-gitops-agent' — not the longer
// 'taptech-gitops-agent-service' suffix used for the ArgoCD app name.)

pipelineJob('taptech-gitops-agent-service') {
  description('Build the taptech-gitops-agent-service image and commit tag-bump to taptech-gitops.')

  logRotator {
    daysToKeep(14)
    numToKeep(20)
  }

  properties {
    disableConcurrentBuilds()
  }

  triggers {
    scm('H/5 * * * *')
  }

  definition {
    cpsScm {
      scm {
        git {
          remote {
            url('https://github.com/glawson6/taptech-gitops-agent.git')
            credentials('gitops-repo')
          }
          branch('*/main')
          extensions {
            cloneOptions {
              shallow(true)
              depth(1)
            }
          }
        }
      }
      // Root Jenkinsfile in the source repo. If the source repo uses a
      // different filename (e.g. Jenkinsfile.deploy), update this line.
      scriptPath('Jenkinsfile')
      lightweight(true)
    }
  }
}
