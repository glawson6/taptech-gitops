// JobDSL definition for the taptech-crm deploy pipeline.
// Materialized by the `seed-jobs` job on every git push to
// taptech-gitops/platform/jenkins/jobs/.
//
// Downstream Jenkinsfile lives in the SOURCE repo:
//   taptech-company/Jenkinsfile.deploy    (root; builds taptech-crm/taptech-platform-app)

pipelineJob('taptech-crm-deploy') {
  description('Build taptech-platform-app (CRM lead intake), push image, and commit tag-bump to taptech-gitops.')

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
            // NOTE: the CRM lives in the taptech-company monorepo. If that
            // repo lives on a different git host / different credential
            // (e.g. GitHub Enterprise, GitLab), update the remote URL and
            // credentials binding here.
            url('https://github.com/glawson6/taptech-company.git')
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
      scriptPath('Jenkinsfile.deploy')
      lightweight(true)
    }
  }
}
