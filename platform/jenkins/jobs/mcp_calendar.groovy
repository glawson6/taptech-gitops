// JobDSL definition for the mcp-calendar deploy pipeline.
// Materialized by the `seed-jobs` job on every git push to
// taptech-gitops/platform/jenkins/jobs/.
//
// Downstream Jenkinsfile lives in the SOURCE repo:
//   taptech-ai-agent-parent/taptech-ai-agent-mcp-calendar-server/Jenkinsfile.deploy

pipelineJob('mcp-calendar-deploy') {
  description('Build mcp-calendar, push image, and commit tag-bump to taptech-gitops.')

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
            url('https://github.com/glawson6/taptech-ai-agent-parent.git')
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
      scriptPath('taptech-ai-agent-mcp-calendar-server/Jenkinsfile.deploy')
      lightweight(true)
    }
  }
}
