// JobDSL definition for the jaiclaw-io deploy pipeline.
// Materialized by the `seed-jobs` job on every git push to
// taptech-gitops/platform/jenkins/jobs/.
//
// Downstream Jenkinsfile lives in the SOURCE repo:
//   jaiclaw.io/Jenkinsfile

pipelineJob('jaiclaw-io') {
  description('Build the jaiclaw-io SPA image and commit tag-bump to taptech-gitops.')

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
            url('https://github.com/glawson6/jaiclaw.io.git')
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
      scriptPath('Jenkinsfile')
      lightweight(true)
    }
  }
}
