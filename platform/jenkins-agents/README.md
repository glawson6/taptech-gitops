Namespace where Jenkins schedules build pods, on the management cluster.

Jenkins itself is a GitOps-managed component (`platform/jenkins/`). Because
controller and agents share a cluster, there is no external authentication to
configure -- see `docs/jenkins-integration.md`.
