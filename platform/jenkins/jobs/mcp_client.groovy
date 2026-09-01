// JobDSL definition for the mcp-client deploy pipeline.
// Materialized by the `seed-jobs` job on every git push to
// taptech-gitops/platform/jenkins/jobs/.
//
// Downstream Jenkinsfile lives in the SOURCE repo, not here:
//   taptech-ai-agent-parent/taptech-ai-agent-mcp-client/Jenkinsfile.deploy
// That's the source of truth for build/push/promote; this file only wires
// Jenkins to run it.

pipelineJob('mcp-client-deploy') {
  description('Build mcp-client, push image, and commit tag-bump to taptech-gitops.')

  logRotator {
    daysToKeep(14)
    numToKeep(20)
  }

  properties {
    disableConcurrentBuilds()
  }

  triggers {
    // Poll SCM every 5 minutes for pushes to main. Cheaper than a webhook
    // and matches the ethos of the rest of the pipelines here.
    scm('H/5 * * * *')
  }

  definition {
    cpsScm {
      scm {
        git {
          remote {
            url('https://github.com/glawson6/taptech-chatbot-parent.git')
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
      scriptPath('taptech-ai-agent-mcp-client/Jenkinsfile.deploy')
      lightweight(true)
    }
  }
}
