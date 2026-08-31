// Seed pipeline: read every JobDSL script under platform/jenkins/jobs/
// and materialize the corresponding Jenkins pipeline job.
//
// - Runs inside a Jenkins agent pod (see 'agent { kubernetes {} }' below).
// - Idempotent: re-processing yields the same jobs; edits update them.
// - Removed groovy files → set 'removedJobAction: DELETE' to sweep the
//   corresponding jobs. Leaving as 'IGNORE' so deletions are explicit.
//
// New jobs to add? Just drop another *.groovy under platform/jenkins/jobs/
// and push. SCM polling triggers this seed on the next tick.

pipeline {
  agent {
    kubernetes {
      yaml '''
        apiVersion: v1
        kind: Pod
        spec:
          containers:
            - name: jnlp
              image: jenkins/inbound-agent:latest
      '''
    }
  }
  options {
    // NOTE: `timestamps()` is a wrapper step (Timestamper plugin), not a
    // Declarative option — omit here to keep the seed compiling on stock
    // Jenkins installs. If wanted, wrap stage steps with `timestamps { ... }`.
    buildDiscarder(logRotator(daysToKeepStr: '30', numToKeepStr: '20'))
    timeout(time: 5, unit: 'MINUTES')
    disableConcurrentBuilds()
  }
  stages {
    stage('Process JobDSL scripts') {
      steps {
        jobDsl(
          targets: 'platform/jenkins/jobs/*.groovy',
          removedJobAction: 'IGNORE',
          removedViewAction: 'IGNORE',
          lookupStrategy: 'JENKINS_ROOT',
          // Runs the DSL inside the Groovy sandbox so no manual
          // /scriptApproval click is needed. The DSL we use here
          // (pipelineJob + cpsScm + git) is all sandbox-safe.
          sandbox: true
        )
      }
    }
  }
}
