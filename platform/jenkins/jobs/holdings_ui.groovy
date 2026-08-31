// JobDSL definition for the holdings-ui deploy pipeline.
// Materialized by the `seed-jobs` job on every git push to
// taptech-gitops/platform/jenkins/jobs/.
//
// Downstream Jenkinsfile lives in the SOURCE repo:
//   holdings.taptech.net/Jenkinsfile

pipelineJob('holdings-ui') {
  description('Build the taptech-holdings-ui SPA image and commit tag-bump to taptech-gitops.')

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
            url('https://github.com/glawson6/holdings.taptech.net.git')
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
